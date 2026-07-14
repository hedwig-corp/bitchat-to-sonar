//
// ConversationViewState.swift
// bitchat
//
// Signal-style per-conversation render state (CVLoadCoordinator/CVRenderState
// pattern): the transcript's [SNMessage] array is built OFF the SwiftUI render
// path — once per coalesced data change — and screens render the precomputed,
// immutable result. Before this, SonarDMScreen re-ran the full mapping
// (pay/media/sticker parsing + sorting) inside `body` on every store
// invalidation, which made typing and sending visibly lag on device.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Combine
import Foundation

struct SNConversationTranscriptSource {
    static let meshID = "$mesh"

    let id: String
    let rows: [SNMessage]
    let hasMore: Bool
}

/// Pure conversation-wide window operations shared by the Apple transcript
/// coordinator and its regression tests. Source windows are bounded
/// independently; this layer is what prevents a newer transport from hiding an
/// older folded transport forever once the 500-row render budget is full.
enum SNConversationTranscriptWindow {
    static func ordered(_ source: [SNMessage]) -> [SNMessage] {
        var byID: [String: SNMessage] = [:]
        for message in source { byID[message.id] = message }
        return byID.values.sorted(by: isOrderedBefore)
    }

    static func newest(_ source: [SNMessage], limit: Int) -> [SNMessage] {
        Array(ordered(source).suffix(max(0, limit)))
    }

    static func nearestOlderPage(
        in source: [SNMessage],
        before oldestVisible: SNMessage,
        pageSize: Int
    ) -> [SNMessage] {
        Array(
            ordered(source)
                .filter { isOrderedBefore($0, oldestVisible) }
                .suffix(max(0, pageSize))
        )
    }

    static func prepending(
        _ older: [SNMessage],
        to existing: [SNMessage],
        limit: Int
    ) -> [SNMessage] {
        Array(ordered(existing + older).prefix(max(0, limit)))
    }

    /// A full retained window is historical even before the next prepend has
    /// to evict a row. Pin it at that boundary so a concurrent live append
    /// cannot discard the oldest visible row while the reader is at the top.
    static func shouldPreserveOlderEdge(
        afterGrowingTo visibleLimit: Int,
        retainedLimit: Int,
        previous: [SNMessage],
        next: [SNMessage]
    ) -> Bool {
        if visibleLimit >= retainedLimit, next.count >= retainedLimit { return true }
        let nextIDs = Set(next.map(\.id))
        return previous.contains { !nextIDs.contains($0.id) }
    }

    static func refreshing(
        _ existing: [SNMessage],
        from candidates: [SNMessage],
        limit: Int,
        preservingOlderEdge: Bool
    ) -> [SNMessage] {
        guard preservingOlderEdge, !existing.isEmpty else {
            return newest(candidates, limit: limit)
        }
        var updates: [String: SNMessage] = [:]
        for candidate in candidates { updates[candidate.id] = candidate }
        return ordered(existing.map { updates[$0.id] ?? $0 })
    }

    static func hasRowsOlder(than oldestVisible: SNMessage?, in source: [SNMessage]) -> Bool {
        guard let oldestVisible else { return false }
        return source.contains { isOrderedBefore($0, oldestVisible) }
    }

    /// A global page is safe only after every pageable source has one complete
    /// page behind the visible anchor. This preserves the k-way merge frontier:
    /// a far-older source must not fill the page while a newer source still has
    /// unloaded rows that belong before it.
    static func sourceIDsNeedingExpansion(
        _ sources: [SNConversationTranscriptSource],
        before oldestVisible: SNMessage,
        pageSize: Int
    ) -> Set<String> {
        guard pageSize > 0 else { return [] }
        return Set(sources.compactMap { source in
            guard source.hasMore else { return nil }
            let olderCount = source.rows.lazy
                .filter { isOrderedBefore($0, oldestVisible) }
                .prefix(pageSize)
                .count
            return olderCount < pageSize ? source.id : nil
        })
    }

    static func isOrderedBefore(_ lhs: SNMessage, _ rhs: SNMessage) -> Bool {
        let lhsDate = lhs.sortDate ?? .distantPast
        let rhsDate = rhs.sortDate ?? .distantPast
        if lhsDate == rhsDate { return lhs.id < rhs.id }
        return lhsDate < rhsDate
    }
}

/// Precomputed transcript for ONE open conversation.
///
/// Rebuilds are triggered by the store's (already throttled) invalidation
/// stream, coalesced again here, and the result is published only when it
/// actually changed — unrelated store activity (wallet, BLE presence, radar)
/// costs one cheap equality check instead of a full SwiftUI transcript pass.
///
/// The build itself runs on the main actor: every input it reads
/// (`messagesByGroup`, `privateChats`, ledgers, call logs) is main-actor
/// state, and one build over a page-bounded transcript is a few milliseconds.
/// What matters is that it happens per data CHANGE, not per RENDER. Moving
/// the mapping fully off-main (true CVLoader) requires snapshotting that
/// input surface and is tracked as a follow-up.
@MainActor
final class ConversationViewState: ObservableObject {
    /// Immutable, render-ready transcript (oldest first, control lines
    /// resolved, pay bubbles and call rows folded in).
    @Published private(set) var messages: [SNMessage] = []
    @Published private(set) var hasOlderMessages = false
    @Published private(set) var isLoadingOlder = false

    let conversationId: String

    private weak var store: SonarAppStore?
    private var invalidationSub: AnyCancellable?
    private var rebuildScheduled = false
    /// Render budget grows a page at a time and remains independent from the
    /// Marmot database cache window. It therefore bounds pure mesh and folded
    /// mesh + Marmot conversations too, not only the paged source.
    private var visibleMessageLimit = TransportConfig.sonarTranscriptPageCount
    /// Each folded transport also owns a bounded source window. Keeping this
    /// separate from the conversation-wide budget lets the global window page
    /// into an older source even while another source still has newer rows.
    private var sourceMessageLimit = TransportConfig.sonarTranscriptPageCount
    private var meshNewestOffset = 0
    private var needsNewestReload = false
    private var lastMeshMessageCount = 0
    private static let olderSourceLoadAttemptLimit = 3

    init(conversationId: String, store: SonarAppStore) {
        self.conversationId = conversationId
        self.store = store
        self.lastMeshMessageCount = store.cachedMeshMessageCount(conversationId)
        // First build is synchronous so the opening chat paints from local
        // state immediately (local-first rule) instead of after a debounce.
        rebuildNow()
        // The store already coalesces upstream invalidations (~10/sec cap);
        // the extra debounce collapses those bursts into one rebuild.
        self.invalidationSub = store.objectWillChange
            .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleRebuild() }
    }

    /// Coalesce rebuild requests: at most one queued build at a time. A change
    /// arriving mid-build is covered by the next invalidation tick.
    private func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.rebuildScheduled = false
            self.rebuildNow()
        }
    }

    /// Build and publish only when the result differs — the equality check is
    /// what turns unrelated store invalidations into no-ops for SwiftUI.
    func rebuildNow() {
        guard let store else { return }
        let meshCount = store.cachedMeshMessageCount(conversationId)
        if needsNewestReload, meshCount > lastMeshMessageCount {
            // Keep the historical mesh boundary anchored while live rows append
            // at the unseen newer edge. They become visible on return-to-newest.
            meshNewestOffset += meshCount - lastMeshMessageCount
        }
        lastMeshMessageCount = meshCount
        if needsNewestReload {
            // Keep all folded source cursors aligned with the global historical
            // window. Otherwise background refresh could reset one source to
            // its newest page while the visible anchor remains much older.
            store.preserveHistoricalDM(conversationId)
        }
        let sourceLookaheadLimit = min(
            TransportConfig.sonarTranscriptRetainedCount,
            sourceMessageLimit + 1
        )
        let candidates = store.dmMsgs(
            conversationId,
            limit: sourceLookaheadLimit,
            meshNewestOffset: meshNewestOffset
        )
        let visible = SNConversationTranscriptWindow.refreshing(
            messages,
            from: candidates,
            limit: visibleMessageLimit,
            preservingOlderEdge: needsNewestReload
        )
        if visible != messages {
            messages = visible
        }
        hasOlderMessages = SNConversationTranscriptWindow.hasRowsOlder(
            than: messages.first,
            in: candidates
        )
            || store.canLoadOlderDM(conversationId)
            || store.hasCachedMeshOlderDM(
                conversationId,
                visibleLimit: sourceMessageLimit,
                newestOffset: meshNewestOffset
            )
    }

    /// Load one older local page. Repeated top-edge appearances are coalesced;
    /// the fixed conversation id prevents late work from publishing into a
    /// different chat after navigation.
    func loadOlder() async -> Bool {
        guard !isLoadingOlder, hasOlderMessages, let store else { return false }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        let pageSize = TransportConfig.sonarTranscriptPageCount
        let retained = TransportConfig.sonarTranscriptRetainedCount

        func prependClosestCandidatePage() -> Bool {
            guard let oldest = messages.first else { return false }
            let candidates = store.dmMsgs(
                conversationId,
                limit: min(retained, sourceMessageLimit + 1),
                meshNewestOffset: meshNewestOffset
            )
            let older = SNConversationTranscriptWindow.nearestOlderPage(
                in: candidates,
                before: oldest,
                pageSize: pageSize
            )
            guard !older.isEmpty else { return false }
            let sources = store.dmTranscriptSources(
                conversationId,
                candidates: candidates,
                sourceLimit: sourceMessageLimit,
                meshNewestOffset: meshNewestOffset
            )
            guard SNConversationTranscriptWindow.sourceIDsNeedingExpansion(
                sources,
                before: oldest,
                pageSize: pageSize
            ).isEmpty else { return false }

            let previous = messages
            visibleMessageLimit = min(retained, visibleMessageLimit + pageSize)
            let next = SNConversationTranscriptWindow.prepending(
                older,
                to: previous,
                limit: visibleMessageLimit
            )
            if SNConversationTranscriptWindow.shouldPreserveOlderEdge(
                afterGrowingTo: visibleMessageLimit,
                retainedLimit: retained,
                previous: previous,
                next: next
            ) {
                needsNewestReload = true
                store.preserveHistoricalDM(conversationId)
            }
            if next != previous { messages = next }

            hasOlderMessages = SNConversationTranscriptWindow.hasRowsOlder(
                than: messages.first,
                in: candidates
            )
                || store.canLoadOlderDM(conversationId)
                || store.hasCachedMeshOlderDM(
                    conversationId,
                    visibleLimit: sourceMessageLimit,
                    newestOffset: meshNewestOffset
                )
            return next != previous
        }

        // Folded sources can already contain a globally adjacent page even
        // though each source is independently bounded. Consume that page before
        // issuing another local database read.
        if prependClosestCandidatePage() { return true }

        for attempt in 0..<Self.olderSourceLoadAttemptLimit {
            guard let oldest = messages.first else { return false }
            let candidates = store.dmMsgs(
                conversationId,
                limit: min(retained, sourceMessageLimit + 1),
                meshNewestOffset: meshNewestOffset
            )
            let sourceIDs = SNConversationTranscriptWindow.sourceIDsNeedingExpansion(
                store.dmTranscriptSources(
                    conversationId,
                    candidates: candidates,
                    sourceLimit: sourceMessageLimit,
                    meshNewestOffset: meshNewestOffset
                ),
                before: oldest,
                pageSize: pageSize
            )
            let meshCount = store.cachedMeshMessageCount(conversationId)
            let currentMeshEnd = max(0, meshCount - meshNewestOffset)
            let currentMeshStart = max(0, currentMeshEnd - sourceMessageLimit)
            let meshRowsLoaded = sourceIDs.contains(SNConversationTranscriptSource.meshID)
                ? min(pageSize, currentMeshStart)
                : 0
            let groupIDs = sourceIDs.subtracting([SNConversationTranscriptSource.meshID])
            let databaseCanLoad = !groupIDs.isEmpty
            guard meshRowsLoaded > 0 || databaseCanLoad else {
                rebuildNow()
                return false
            }

            let addedFromDatabase = databaseCanLoad
                ? await store.loadOlderDM(conversationId, groupIDs: groupIDs)
                : false
            let sourceGrowth = max(addedFromDatabase ? pageSize : 0, meshRowsLoaded)
            let meshOverflow = max(0, sourceMessageLimit + meshRowsLoaded - retained)
            let databaseMovesWindow = addedFromDatabase
                && sourceMessageLimit + pageSize > retained
            if meshOverflow > 0 || databaseMovesWindow {
                needsNewestReload = true
                store.preserveHistoricalDM(conversationId)
            }
            meshNewestOffset += meshOverflow
            sourceMessageLimit = min(retained, sourceMessageLimit + sourceGrowth)

            if prependClosestCandidatePage() { return true }

            // A summary refresh can momentarily own the same group loader. Give
            // that bounded local read a chance to finish rather than consuming
            // the top-edge appearance permanently.
            if !addedFromDatabase, meshRowsLoaded == 0,
               attempt + 1 < Self.olderSourceLoadAttemptLimit {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        rebuildNow()
        return false
    }

    /// Return a movable historical window to the live edge. Below the retained
    /// cap, pages are contiguous and no reload is needed.
    func loadNewestIfNeeded() async {
        guard needsNewestReload, let store else { return }
        // The bottom can become visible while an older database request is
        // still completing. Wait for its defer to release the group loader;
        // otherwise loadLocalPage would coalesce away this live-edge reset.
        while isLoadingOlder {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard needsNewestReload else { return }
        let loaded = await store.loadNewestDM(conversationId)
        guard loaded else { return }
        needsNewestReload = false
        meshNewestOffset = 0
        visibleMessageLimit = TransportConfig.sonarTranscriptPageCount
        sourceMessageLimit = TransportConfig.sonarTranscriptPageCount
        lastMeshMessageCount = store.cachedMeshMessageCount(conversationId)
        rebuildNow()
    }
}
