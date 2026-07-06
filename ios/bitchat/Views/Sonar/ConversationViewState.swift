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

    let conversationId: String

    private weak var store: SonarAppStore?
    private var invalidationSub: AnyCancellable?
    private var rebuildScheduled = false

    init(conversationId: String, store: SonarAppStore) {
        self.conversationId = conversationId
        self.store = store
        // First build is synchronous so the opening chat paints from local
        // state immediately (local-first rule) instead of after a debounce.
        self.messages = store.dmMsgs(conversationId)
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
        let built = store.dmMsgs(conversationId)
        if built != messages {
            messages = built
        }
    }
}
