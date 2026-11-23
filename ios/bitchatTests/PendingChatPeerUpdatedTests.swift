//
// PendingChatPeerUpdatedTests.swift
// bitchatTests
//
// Starting a NEW chat from this (Marmot v1) build with someone whose every
// install moved to Marmot v2: core's `start_dm` refuses with "peer has updated
// Sonar". The pending chat must keep the user in place and replace the
// composer with the update panel, not fail back to the radar with a generic
// error. Driven through the store's real call site (`startSecureChat(npub:)`
// → background setup → `composerGate`, read by `SonarDMScreen` and the Mac
// pane); only the relay wait plus core's `startDm` are stubbed.
// This is free and unencumbered software released into the public domain.
//

import Foundation
import Testing
@testable import Sonar

@MainActor
@Suite(.serialized)
struct PendingChatPeerUpdatedTests {
    private static let peer = "npub1ghmjy6aj9kncekftjvz3dmxd73yqzrdl092f2ym2mak002dtepfqp89xna"

    @Test
    func aNewChatWithAContactOnMarmotV2ShowsTheUpdatePanel() async throws {
        let (store, cleanup) = makeIsolatedSonarAppStore()
        defer { cleanup() }
        store.marmot.directChatSetupOverrideForTesting = { _ in
            throw MarmotService.ServiceError.core(
                "peer has updated Sonar: update the app to keep chatting"
            )
        }

        let pendingId = try #require(store.startSecureChat(npub: Self.peer))
        // Local-first: the pending chat is on screen before setup answers.
        #expect(store.path.last == .dm(pendingId))
        for _ in 0..<300 where store.composerGate(pendingId) != .updateRequired {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(store.composerGate(pendingId) == .updateRequired, "the composer is replaced by the update panel")
        #expect(store.pendingMarmotRouteFailure == nil, "the Mac pane is not sent back to the radar")
        #expect(store.path.last == .dm(pendingId), "the user stays in the chat")
    }

    @Test
    func anyOtherSetupFailureKeepsTheComposer() async throws {
        let (store, cleanup) = makeIsolatedSonarAppStore()
        defer { cleanup() }
        store.marmot.directChatSetupOverrideForTesting = { _ in
            throw MarmotService.ServiceError.core("relay timeout")
        }

        let pendingId = try #require(store.startSecureChat(npub: Self.peer))
        for _ in 0..<300 where store.pendingMarmotRouteFailure == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(store.pendingMarmotRouteFailure?.pendingId == pendingId)
        #expect(store.composerGate(pendingId) == .open)
    }
}
