//
// PendingChatTranscriptHandoverTests.swift
// bitchatTests
//
// Starting a chat by npub opens a local pending transcript immediately and
// swaps the route to the real Marmot group once background setup finishes.
// The swap can land as an in-place update of the visible DM screen, so the
// real conversation's render state must be attached by the store itself —
// otherwise the first message's echo never sees its relay ack and sits at
// "Sending" forever.
//

import Foundation
import Testing
@testable import Sonar

@MainActor
@Suite(.serialized)
struct PendingChatTranscriptHandoverTests {
    private static let peer = "npub1ghmjy6aj9kncekftjvz3dmxd73yqzrdl092f2ym2mak002dtepfqp89xna"

    /// Pins the real call site (`finishPendingSecureChat`, reached through the
    /// `marmot.$groups` sink): the screen's lifecycle callbacks are simulated
    /// only for the pending id, exactly as an in-place route update leaves them.
    @Test
    func resolvingTheVisiblePendingChatAttachesTheRealTranscript() async throws {
        let (store, cleanup) = makeIsolatedSonarAppStore()
        defer { cleanup() }

        let pendingId = try #require(store.startSecureChat(npub: Self.peer))
        // What SonarDMScreen does for the pending route: build, then onAppear.
        let pendingState = store.conversationViewState(pendingId)
        store.openedDM(pendingId)
        #expect(pendingState.isActive)

        let groupId = "5e1ec7ed"
        store.marmot.groups = [
            MarmotService.MarmotGroup(
                id: groupId,
                name: "",
                memberNpubs: [SNMarmotProfileCache.canonicalKey(Self.peer)]
            )
        ]
        let realId = SonarAppStore.marmotIDPrefix + groupId
        for _ in 0..<200 where store.path.last != .dm(realId) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(store.path.last == .dm(realId), "the pending route must resolve to the real group")

        #expect(
            store.conversationViewState(realId).isActive,
            "the real transcript must follow the store or its echo never leaves Sending"
        )
        #expect(!pendingState.isActive, "the pending transcript must stop rebuilding after leave (R-038)")
    }
}
