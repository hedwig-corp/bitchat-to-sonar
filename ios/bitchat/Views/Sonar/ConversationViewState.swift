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
    private var meshNewestOffset = 0
    private var needsNewestReload = false
    private var lastMeshMessageCount = 0

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
        let lookaheadLimit = min(
            TransportConfig.sonarTranscriptRetainedCount,
            visibleMessageLimit + 1
        )
        let built = store.dmMsgs(
            conversationId,
            limit: lookaheadLimit,
            meshNewestOffset: meshNewestOffset
        )
        let visible = Array(built.suffix(visibleMessageLimit))
        if visible != messages {
            messages = visible
        }
        hasOlderMessages = built.count > visibleMessageLimit
            || store.canLoadOlderDM(conversationId)
            || store.hasCachedMeshOlderDM(
                conversationId,
                visibleLimit: visibleMessageLimit,
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
        let previous = messages
        let pageSize = TransportConfig.sonarTranscriptPageCount
        let retained = TransportConfig.sonarTranscriptRetainedCount
        let meshCount = store.cachedMeshMessageCount(conversationId)
        let currentMeshEnd = max(0, meshCount - meshNewestOffset)
        let currentMeshStart = max(0, currentMeshEnd - visibleMessageLimit)
        let meshRowsLoaded = min(pageSize, currentMeshStart)
        let databaseCanLoad = store.canLoadOlderDM(conversationId)
        let requestedGrowth = max(databaseCanLoad ? pageSize : 0, meshRowsLoaded)
        let meshOverflow = max(0, visibleMessageLimit + meshRowsLoaded - retained)
        let databaseMovesWindow = databaseCanLoad
            && visibleMessageLimit + pageSize > retained
        if meshOverflow > 0 || databaseMovesWindow {
            needsNewestReload = true
        }
        meshNewestOffset += meshOverflow
        visibleMessageLimit = min(
            retained,
            visibleMessageLimit + requestedGrowth
        )
        let addedFromDatabase = await store.loadOlderDM(conversationId)
        rebuildNow()
        return addedFromDatabase || messages != previous
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
        lastMeshMessageCount = store.cachedMeshMessageCount(conversationId)
        rebuildNow()
    }
}
