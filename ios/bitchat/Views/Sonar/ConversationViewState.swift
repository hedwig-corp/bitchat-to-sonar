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
#if DEBUG
import BitLogger
#endif

struct SNConversationTranscriptSource {
    static let meshID = "$mesh"
    static let paymentActivityID = "$payment-activity"
    static let callLogID = "$call-log"

    let id: String
    let rows: [SNMessage]
    let hasMore: Bool
}

struct SNConversationTranscriptLoadResult {
    static let none = SNConversationTranscriptLoadResult()

    private(set) var maxSourceGrowth = 0
    private(set) var movedRetainedWindow = false

    var added: Bool { maxSourceGrowth > 0 }

    mutating func record(before: Set<String>, after: Set<String>) {
        maxSourceGrowth = max(maxSourceGrowth, after.subtracting(before).count)
        movedRetainedWindow = movedRetainedWindow || !before.subtracting(after).isEmpty
    }
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
        preservingOlderEdge: Bool,
        pinningOlderEdgeAtCapacity: Bool = false
    ) -> [SNMessage] {
        guard preservingOlderEdge, !existing.isEmpty else {
            // A final database page can be shorter than the retained budget.
            // Retain the uncovered prefix of EACH independently bounded source
            // so one older folded source cannot make another source's rolling
            // candidate boundary look authoritative. Ephemeral rows without a
            // persisted local source are always rebuilt from candidates.
            let orderedCandidates = ordered(candidates)
            guard !orderedCandidates.isEmpty else { return [] }
            let candidatesBySource = Dictionary(
                grouping: orderedCandidates.compactMap { message in
                    message.transcriptSourceID.map { ($0, message) }
                },
                by: { $0.0 }
            )
            let candidatePayIDs = Set(orderedCandidates.compactMap { $0.pay?.id })
            var uncoveredPrefixes: [SNMessage] = []
            for (sourceID, sourceCandidates) in candidatesBySource {
                guard let sourceStart = sourceCandidates.map(\.1).min(by: isOrderedBefore) else {
                    continue
                }
                uncoveredPrefixes += existing.filter {
                    $0.transcriptSourceID == sourceID
                        && isOrderedBefore($0, sourceStart)
                        && ($0.pay.map { !candidatePayIDs.contains($0.id) } ?? true)
                }
            }
            let merged = ordered(uncoveredPrefixes + orderedCandidates)
            if pinningOlderEdgeAtCapacity {
                // The historical render budget can be one row short when a
                // debounced refresh delivers several live rows together. Keep
                // only the remaining capacity from the older edge so the
                // anchor cannot be evicted before the coordinator pins it.
                return Array(merged.prefix(max(0, limit)))
            }
            return Array(merged.suffix(max(0, limit)))
        }
        var updates: [String: SNMessage] = [:]
        for candidate in candidates { updates[candidate.id] = candidate }
        // Local echoes are ephemeral rows without a persisted source (see
        // SNMessage.transcriptSourceID): once the Marmot model reconciles an
        // echo with its canonical database row it vanishes from candidates,
        // and keeping the stale copy here would freeze a bubble at "Sending"
        // in a pinned historical window until the user returns to the bottom.
        // Drop reconciled echoes and admit the sender's own newer rows in
        // their place — foreign live rows still wait at the unseen newer edge.
        let kept = existing.compactMap { row in
            updates[row.id] ?? (isLocalEchoID(row.id) ? nil : row)
        }
        let existingIDs = Set(existing.map(\.id))
        let newestKept = kept.max(by: isOrderedBefore)
        let ownReplacements = candidates.filter { candidate in
            candidate.mine
                && !existingIDs.contains(candidate.id)
                && (newestKept.map { isOrderedBefore($0, candidate) } ?? true)
        }
        return ordered(kept + ownReplacements)
    }

    static func isLocalEchoID(_ id: String) -> Bool {
        id.hasPrefix(MarmotChatModel.optimisticIDPrefix)
            || id.hasPrefix(MarmotChatModel.failedOptimisticIDPrefix)
    }

    static func hasRowsOlder(than oldestVisible: SNMessage?, in source: [SNMessage]) -> Bool {
        guard let oldestVisible else { return false }
        return source.contains { isOrderedBefore($0, oldestVisible) }
    }

    static func localPageGrowth(
        totalRows: Int,
        sourceLimit: Int,
        newestOffset: Int,
        pageSize: Int
    ) -> Int {
        let currentEnd = max(0, totalRows - max(0, newestOffset))
        let currentStart = max(0, currentEnd - max(0, sourceLimit))
        return min(max(0, pageSize), currentStart)
    }

    /// A global page is safe only after every pageable source has one complete
    /// page behind the visible anchor. This preserves the k-way merge frontier:
    /// a far-older source must not fill the page while a newer source still has
    /// unloaded rows that belong before it.
    static func sourceIDsNeedingExpansion(
        _ sources: [SNConversationTranscriptSource],
        before oldestVisible: SNMessage,
        pageSize: Int,
        ignoring stalledSourceIDs: Set<String> = []
    ) -> Set<String> {
        guard pageSize > 0 else { return [] }
        return Set(sources.compactMap { source in
            guard source.hasMore, !stalledSourceIDs.contains(source.id) else { return nil }
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

#if DEBUG
/// SONAR_BENCH: aggregate meter for transcript rebuild cost.
///
/// A rebuild is triggered per store invalidation for every retained
/// `ConversationViewState`, so the diagnostic signal is the per-second total
/// across conversations, not one line per rebuild. Logging per rebuild would
/// itself be part of the cost being measured.
@MainActor
enum SNTranscriptRebuildMeter {
    private static var rebuilds = 0
    private static var totalMs = 0.0
    private static var maxMs = 0.0
    private static var conversationIds = Set<String>()
    private static var windowStart = CFAbsoluteTimeGetCurrent()

    static func record(conversationId: String, rows: Int, ms: Double) {
        _ = rows
        rebuilds += 1
        totalMs += ms
        maxMs = max(maxMs, ms)
        conversationIds.insert(conversationId)
        let now = CFAbsoluteTimeGetCurrent()
        let window = now - windowStart
        guard window >= 1 else { return }
        SecureLogger.info(
            "SONAR_BENCH transcript_rebuild window_s=\(String(format: "%.2f", window)) "
                + "rebuilds=\(rebuilds) conversations=\(conversationIds.count) "
                + "total_ms=\(Int(totalMs.rounded())) max_ms=\(Int(maxMs.rounded()))",
            category: .session
        )
        rebuilds = 0
        totalMs = 0
        maxMs = 0
        conversationIds.removeAll()
        windowStart = now
    }
}

/// SONAR_BENCH: counts UIKit host applies that skip vs rebuild after the
/// adapter has already decided content is unchanged (true O(1) path).
@MainActor
enum SNTranscriptApplyMeter {
    private static var skips = 0
    private static var applies = 0
    private static var windowStart = CFAbsoluteTimeGetCurrent()

    static func record(skipped: Bool, revision: UInt64) {
        if skipped { skips += 1 } else { applies += 1 }
        let now = CFAbsoluteTimeGetCurrent()
        let window = now - windowStart
        guard window >= 1 else { return }
        SecureLogger.info(
            "SONAR_BENCH transcript_apply window_s=\(String(format: "%.2f", window)) "
                + "skip=\(skips) apply=\(applies) last_revision=\(revision)",
            category: .session
        )
        skips = 0
        applies = 0
        windowStart = now
    }
}
#endif

/// Immutable transcript snapshot published by `ConversationViewState`.
///
/// The revision advances only when `messages` change. Downstream UIKit hosts
/// compare this revision instead of re-walking the message array on every
/// SwiftUI body evaluation (composer keystrokes, unrelated store ticks).
struct SNConversationRenderState: Equatable {
    let revision: UInt64
    let messages: [SNMessage]
    let messageIndexByID: [String: Int]

    static let empty = SNConversationRenderState(revision: 0, messages: [], messageIndexByID: [:])

    static func make(messages: [SNMessage], revision: UInt64) -> SNConversationRenderState {
        var indexByID: [String: Int] = [:]
        indexByID.reserveCapacity(messages.count)
        for (i, message) in messages.enumerated() where indexByID[message.id] == nil {
            indexByID[message.id] = i
        }
        return SNConversationRenderState(
            revision: revision,
            messages: messages,
            messageIndexByID: indexByID
        )
    }
}

/// Advance the render snapshot only when the visible row list actually changed.
func snAdvancedConversationRenderState(
    previous: SNConversationRenderState,
    messages: [SNMessage]
) -> SNConversationRenderState {
    if messages == previous.messages { return previous }
    return .make(messages: messages, revision: previous.revision &+ 1)
}

/// Store-invalidation subscription for ONE conversation transcript.
///
/// Retained (closed) conversations keep their last transcript so reopening
/// paints without an empty first frame, but they must not keep rebuilding it:
/// the store's invalidation stream is shared, so every attached conversation
/// adds a full transcript pass to EVERY invalidation for the rest of the
/// session. Owning attachment separately is what makes retention cost memory
/// only — the Compose side retains plain rows in `retainedTranscriptByChat` and
/// recomputes for the open chat alone.
final class SNTranscriptRebuildSubscription {
    private let debounceInterval: DispatchQueue.SchedulerTimeType.Stride
    private var cancellable: AnyCancellable?

    var isAttached: Bool { cancellable != nil }

    init(debounceInterval: DispatchQueue.SchedulerTimeType.Stride = .milliseconds(80)) {
        self.debounceInterval = debounceInterval
    }

    func attach<P: Publisher>(
        to invalidations: P,
        onInvalidate: @escaping () -> Void
    ) where P.Output == Void, P.Failure == Never {
        guard cancellable == nil else { return }
        cancellable = invalidations
            .debounce(for: debounceInterval, scheduler: DispatchQueue.main)
            .sink { _ in onInvalidate() }
    }

    func detach() {
        cancellable = nil
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
    /// Immutable render snapshot (revision + messages + first-id index).
    /// Screens that only need rows read `messages`; the UIKit host consumes
    /// `renderState` so skip stays O(1) in the adapter.
    @Published private(set) var renderState = SNConversationRenderState.empty
    /// Convenience for SwiftUI lists / empty checks — same rows as `renderState`.
    var messages: [SNMessage] { renderState.messages }
    @Published private(set) var hasOlderMessages = false
    @Published private(set) var isLoadingOlder = false

    let conversationId: String

    private weak var store: SonarAppStore?
    private let rebuildSubscription: SNTranscriptRebuildSubscription
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
    private var paymentNewestOffset = 0
    private var callNewestOffset = 0
    private var needsNewestReload = false
    private var lastMeshMessageCount = 0
    private var lastPaymentActivityCount = 0
    private var lastCallRecordCount = 0
    private static let olderSourceLoadAttemptLimit = 3

    private func publishMessages(_ next: [SNMessage]) {
        renderState = snAdvancedConversationRenderState(previous: renderState, messages: next)
    }

    init(
        conversationId: String,
        store: SonarAppStore,
        rebuildSubscription: SNTranscriptRebuildSubscription = SNTranscriptRebuildSubscription()
    ) {
        self.conversationId = conversationId
        self.store = store
        self.rebuildSubscription = rebuildSubscription
        self.lastMeshMessageCount = store.cachedMeshMessageCount(conversationId)
        self.lastPaymentActivityCount = store.cachedPaymentActivityCount(conversationId)
        self.lastCallRecordCount = store.cachedCallRecordCount(conversationId)
        // First build is synchronous so the opening chat paints from local
        // state immediately (local-first rule) instead of after a debounce.
        rebuildNow()
    }

    var isActive: Bool { rebuildSubscription.isAttached }

    /// Follow store invalidations while this conversation is on screen. The
    /// synchronous rebuild is what makes reopen paint current: a retained
    /// transcript stopped following the store when the chat was closed.
    func activate() {
        guard let store, !rebuildSubscription.isAttached else { return }
        rebuildNow()
        // The store already coalesces upstream invalidations (~10/sec cap);
        // the extra debounce collapses those bursts into one rebuild.
        rebuildSubscription.attach(to: store.objectWillChange) { [weak self] in
            self?.scheduleRebuild()
        }
    }

    /// Stop following store invalidations. `messages` is kept for reopen paint.
    func deactivate() {
        rebuildSubscription.detach()
    }

    /// Coalesce rebuild requests: at most one queued build at a time. A change
    /// arriving mid-build is covered by the next invalidation tick.
    private func scheduleRebuild() {
        guard rebuildSubscription.isAttached, !rebuildScheduled else { return }
        rebuildScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.rebuildScheduled = false
            guard self.rebuildSubscription.isAttached else { return }
            self.rebuildNow()
        }
    }

    /// Build and publish only when the result differs — the equality check is
    /// what turns unrelated store invalidations into no-ops for SwiftUI.
    func rebuildNow() {
        guard let store else { return }
        #if DEBUG
        let rebuildStarted = CFAbsoluteTimeGetCurrent()
        defer {
            SNTranscriptRebuildMeter.record(
                conversationId: conversationId,
                rows: messages.count,
                ms: (CFAbsoluteTimeGetCurrent() - rebuildStarted) * 1000
            )
        }
        #endif
        let meshCount = store.cachedMeshMessageCount(conversationId)
        let paymentCount = store.cachedPaymentActivityCount(conversationId)
        let callCount = store.cachedCallRecordCount(conversationId)
        if needsNewestReload, meshCount > lastMeshMessageCount {
            // Keep the historical mesh boundary anchored while live rows append
            // at the unseen newer edge. They become visible on return-to-newest.
            meshNewestOffset += meshCount - lastMeshMessageCount
        }
        if needsNewestReload, paymentCount > lastPaymentActivityCount {
            paymentNewestOffset += paymentCount - lastPaymentActivityCount
        }
        if needsNewestReload, callCount > lastCallRecordCount {
            callNewestOffset += callCount - lastCallRecordCount
        }
        lastMeshMessageCount = meshCount
        lastPaymentActivityCount = paymentCount
        lastCallRecordCount = callCount
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
            meshNewestOffset: meshNewestOffset,
            paymentNewestOffset: paymentNewestOffset,
            callNewestOffset: callNewestOffset
        )
        let visible = SNConversationTranscriptWindow.refreshing(
            messages,
            from: candidates,
            limit: visibleMessageLimit,
            preservingOlderEdge: needsNewestReload,
            pinningOlderEdgeAtCapacity: !needsNewestReload
                && visibleMessageLimit >= TransportConfig.sonarTranscriptRetainedCount
        )
        publishMessages(visible)
        if !needsNewestReload,
           visibleMessageLimit >= TransportConfig.sonarTranscriptRetainedCount,
           visible.count >= TransportConfig.sonarTranscriptRetainedCount {
            // A partial final page may later fill with live rows. Pin exactly
            // when the actual retained window becomes full, before the next
            // append can evict the historical anchor.
            needsNewestReload = true
            store.preserveHistoricalDM(conversationId)
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
            || store.hasCachedRenderOnlyOlderDM(
                conversationId,
                visibleLimit: sourceMessageLimit,
                paymentNewestOffset: paymentNewestOffset,
                callNewestOffset: callNewestOffset
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

        func prependClosestCandidatePage(ignoringStalled stalledSourceIDs: Set<String> = []) -> Bool {
            guard let oldest = messages.first else { return false }
            let candidates = store.dmMsgs(
                conversationId,
                limit: min(retained, sourceMessageLimit + 1),
                meshNewestOffset: meshNewestOffset,
                paymentNewestOffset: paymentNewestOffset,
                callNewestOffset: callNewestOffset
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
                meshNewestOffset: meshNewestOffset,
                paymentNewestOffset: paymentNewestOffset,
                callNewestOffset: callNewestOffset
            )
            guard SNConversationTranscriptWindow.sourceIDsNeedingExpansion(
                sources,
                before: oldest,
                pageSize: pageSize,
                ignoring: stalledSourceIDs
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
            if next != previous { publishMessages(next) }

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
                || store.hasCachedRenderOnlyOlderDM(
                    conversationId,
                    visibleLimit: sourceMessageLimit,
                    paymentNewestOffset: paymentNewestOffset,
                    callNewestOffset: callNewestOffset
                )
            return next != previous
        }

        // Folded sources can already contain a globally adjacent page even
        // though each source is independently bounded. Consume that page before
        // issuing another local database read.
        if prependClosestCandidatePage() { return true }

        var progressedSourceIDs = Set<String>()
        for attempt in 0..<Self.olderSourceLoadAttemptLimit {
            guard let oldest = messages.first else { return false }
            let candidates = store.dmMsgs(
                conversationId,
                limit: min(retained, sourceMessageLimit + 1),
                meshNewestOffset: meshNewestOffset,
                paymentNewestOffset: paymentNewestOffset,
                callNewestOffset: callNewestOffset
            )
            let sourceIDs = SNConversationTranscriptWindow.sourceIDsNeedingExpansion(
                store.dmTranscriptSources(
                    conversationId,
                    candidates: candidates,
                    sourceLimit: sourceMessageLimit,
                    meshNewestOffset: meshNewestOffset,
                    paymentNewestOffset: paymentNewestOffset,
                    callNewestOffset: callNewestOffset
                ),
                before: oldest,
                pageSize: pageSize
            )
            let meshCount = store.cachedMeshMessageCount(conversationId)
            let meshRowsLoaded = sourceIDs.contains(SNConversationTranscriptSource.meshID)
                ? SNConversationTranscriptWindow.localPageGrowth(
                    totalRows: meshCount,
                    sourceLimit: sourceMessageLimit,
                    newestOffset: meshNewestOffset,
                    pageSize: pageSize
                )
                : 0
            let paymentRowsLoaded = sourceIDs.contains(SNConversationTranscriptSource.paymentActivityID)
                ? SNConversationTranscriptWindow.localPageGrowth(
                    totalRows: store.cachedPaymentActivityCount(conversationId),
                    sourceLimit: sourceMessageLimit,
                    newestOffset: paymentNewestOffset,
                    pageSize: pageSize
                )
                : 0
            let callRowsLoaded = sourceIDs.contains(SNConversationTranscriptSource.callLogID)
                ? SNConversationTranscriptWindow.localPageGrowth(
                    totalRows: store.cachedCallRecordCount(conversationId),
                    sourceLimit: sourceMessageLimit,
                    newestOffset: callNewestOffset,
                    pageSize: pageSize
                )
                : 0
            let localSourceIDs: Set<String> = [
                SNConversationTranscriptSource.meshID,
                SNConversationTranscriptSource.paymentActivityID,
                SNConversationTranscriptSource.callLogID,
            ]
            let groupIDs = sourceIDs.subtracting(localSourceIDs)
            let databaseCanLoad = !groupIDs.isEmpty
            guard meshRowsLoaded > 0 || paymentRowsLoaded > 0 || callRowsLoaded > 0 || databaseCanLoad else {
                rebuildNow()
                return false
            }

            let databaseLoad = databaseCanLoad
                ? await store.loadOlderDM(conversationId, groupIDs: groupIDs)
                : .none
            let sourceGrowth = [
                databaseLoad.maxSourceGrowth,
                meshRowsLoaded,
                paymentRowsLoaded,
                callRowsLoaded
            ].max() ?? 0
            if meshRowsLoaded > 0 { progressedSourceIDs.insert(SNConversationTranscriptSource.meshID) }
            if paymentRowsLoaded > 0 { progressedSourceIDs.insert(SNConversationTranscriptSource.paymentActivityID) }
            if callRowsLoaded > 0 { progressedSourceIDs.insert(SNConversationTranscriptSource.callLogID) }
            if databaseLoad.added { progressedSourceIDs.formUnion(groupIDs) }
            let meshOverflow = max(0, sourceMessageLimit + meshRowsLoaded - retained)
            let paymentOverflow = max(0, sourceMessageLimit + paymentRowsLoaded - retained)
            let callOverflow = max(0, sourceMessageLimit + callRowsLoaded - retained)
            if meshOverflow > 0 || paymentOverflow > 0 || callOverflow > 0 || databaseLoad.movedRetainedWindow {
                needsNewestReload = true
                store.preserveHistoricalDM(conversationId)
            }
            meshNewestOffset += meshOverflow
            paymentNewestOffset += paymentOverflow
            callNewestOffset += callOverflow
            sourceMessageLimit = min(retained, sourceMessageLimit + sourceGrowth)

            if prependClosestCandidatePage() { return true }

            // A summary refresh can momentarily own the same group loader. Give
            // that bounded local read a chance to finish rather than consuming
            // the top-edge appearance permanently.
            if !databaseLoad.added,
               meshRowsLoaded == 0,
               paymentRowsLoaded == 0,
               callRowsLoaded == 0,
               attempt + 1 < Self.olderSourceLoadAttemptLimit {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        // A source whose page never grew across all attempts has a stale
        // hasMore (loader busy or local page exhausted). Don't let it fence
        // off every other source's cached older page permanently — consume
        // the adjacent page with only the stalled sources off the frontier.
        if let oldest = messages.first {
            let stalledSourceIDs = SNConversationTranscriptWindow.sourceIDsNeedingExpansion(
                store.dmTranscriptSources(
                    conversationId,
                    candidates: store.dmMsgs(
                        conversationId,
                        limit: min(retained, sourceMessageLimit + 1),
                        meshNewestOffset: meshNewestOffset,
                        paymentNewestOffset: paymentNewestOffset,
                        callNewestOffset: callNewestOffset
                    ),
                    sourceLimit: sourceMessageLimit,
                    meshNewestOffset: meshNewestOffset,
                    paymentNewestOffset: paymentNewestOffset,
                    callNewestOffset: callNewestOffset
                ),
                before: oldest,
                pageSize: pageSize
            ).subtracting(progressedSourceIDs)
            if !stalledSourceIDs.isEmpty,
               prependClosestCandidatePage(ignoringStalled: stalledSourceIDs) {
                return true
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
        // A send-triggered conversation refresh can own the per-group loader
        // for more than the loader's own busy-retry budget. Giving up here
        // stranded the pinned historical window: new canonical rows (including
        // the user's own send) stayed invisible until another bottom-edge
        // event happened to fire. Retry bounded instead of failing silently.
        var loaded = await store.loadNewestDM(conversationId)
        var retriesLeft = 3
        while !loaded, retriesLeft > 0 {
            retriesLeft -= 1
            try? await Task.sleep(nanoseconds: 250_000_000)
            while isLoadingOlder {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            guard needsNewestReload else { return }
            loaded = await store.loadNewestDM(conversationId)
        }
        guard loaded else { return }
        needsNewestReload = false
        meshNewestOffset = 0
        paymentNewestOffset = 0
        callNewestOffset = 0
        visibleMessageLimit = TransportConfig.sonarTranscriptPageCount
        sourceMessageLimit = TransportConfig.sonarTranscriptPageCount
        lastMeshMessageCount = store.cachedMeshMessageCount(conversationId)
        lastPaymentActivityCount = store.cachedPaymentActivityCount(conversationId)
        lastCallRecordCount = store.cachedCallRecordCount(conversationId)
        rebuildNow()
    }
}
