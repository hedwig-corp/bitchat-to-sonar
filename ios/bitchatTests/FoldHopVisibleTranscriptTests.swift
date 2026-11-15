//
// FoldHopVisibleTranscriptTests.swift
// bitchatTests
//
// A v1 (MDK 0.8) chat that folds onto its v2 group WHILE it is open: the
// path remount rewrites the visible `.dm(v1)` route to `.dm(live)`, and the
// NavigationStack updates that screen in place, so neither `closedDM(v1)` nor
// `openedDM(live)` runs. Found by the app-level upgrade walk on the iOS
// simulator: the peer's v2 replies never painted in the open chat (the live
// transcript was not following the store), and after leaving, a tap on the
// row logged `chat_open … path=already-open` and did nothing, because the
// open state was still on the v1 id (R-062). These tests drive the real
// `remountFoldedNavigationPath` call site.
//
// This is free and unencumbered software released into the public domain.
//

import Foundation
import Testing
@testable import Sonar

@MainActor
@Suite(.serialized)
struct FoldHopVisibleTranscriptTests {
    private static let v1 = "fac23279fac23279fac23279fac23279"
    private static let live = "be0d9676be0d9676be0d9676be0d9676"
    private static var v1Chat: String { SonarAppStore.marmotIDPrefix + v1 }
    private static var liveChat: String { SonarAppStore.marmotIDPrefix + live }

    /// The user is in the v1 chat when the fold lands.
    private func openV1Chat(_ store: SonarAppStore) {
        store.path = [.dm(Self.v1Chat)]
        _ = store.conversationViewState(Self.v1Chat)
        store.openedDM(Self.v1Chat)
        #expect(store.conversationViewState(Self.v1Chat).isActive)
    }

    /// The fold's path remount, as `remountFoldedOpenChatIfNeeded` runs it
    /// once `groups()` hides the v1 room and lists the live one.
    private func foldLands(_ store: SonarAppStore) {
        store.remountFoldedNavigationPath(
            listedGroupIds: [Self.live],
            knownLiveTargets: [Self.v1: Self.live]
        )
    }

    /// Fails without the fix: the live transcript stayed detached from the
    /// store (its rows were only the window it adopted), and the v1 one kept
    /// rebuilding for a screen nobody was looking at.
    @Test
    func theVisibleTranscriptFollowsTheStoreOnTheLiveIdAfterTheFold() {
        let (store, cleanup) = makeIsolatedSonarAppStore()
        defer { cleanup() }
        openV1Chat(store)

        foldLands(store)

        #expect(store.path == [.dm(Self.liveChat)])
        #expect(store.conversationViewState(Self.liveChat).isActive,
                "the live transcript must follow the store or the peer's replies never paint")
        #expect(!store.conversationViewState(Self.v1Chat).isActive)
        #expect(store.isConversationOpen(Self.liveChat))
    }

    /// Fails without the fix: closing the screen (now on the live id) did not
    /// clear the open state still recorded on the v1 id, so the next tap on
    /// the row was "already open" and never pushed the chat.
    @Test
    func leavingAfterTheFoldClosesTheChatSoItsRowOpensAgain() {
        let (store, cleanup) = makeIsolatedSonarAppStore()
        defer { cleanup() }
        openV1Chat(store)
        foldLands(store)

        store.path = []
        store.closedDM(Self.liveChat)

        #expect(!store.isConversationOpen(Self.liveChat))
        #expect(!store.isConversationOpen(Self.v1Chat))
        #expect(!store.conversationViewState(Self.liveChat).isActive)
        #expect(store.pendingMarmotRouteReplacement == nil)
    }

    /// When SwiftUI does fire the lifecycle pair after the route swap, a late
    /// `closedDM(v1)` must not close the chat the user is still in.
    @Test
    func aLateDisappearOfTheV1ScreenDoesNotCloseTheLiveChat() {
        let (store, cleanup) = makeIsolatedSonarAppStore()
        defer { cleanup() }
        openV1Chat(store)
        foldLands(store)

        store.openedDM(Self.liveChat)
        store.closedDM(Self.v1Chat)

        #expect(store.isConversationOpen(Self.liveChat))
        #expect(store.conversationViewState(Self.liveChat).isActive)
    }

    /// Only an in-place change of the top DM route is a hop.
    @Test
    func onlyTheTopDMRouteChangingIdIsAHop() {
        let hop = snFoldHopOfVisibleDM(previousTop: .dm("a"), nextTop: .dm("b"))
        #expect(hop?.historical == "a" && hop?.live == "b")
        #expect(snFoldHopOfVisibleDM(previousTop: .dm("a"), nextTop: .dm("a")) == nil)
        #expect(snFoldHopOfVisibleDM(previousTop: nil, nextTop: .dm("b")) == nil)
        #expect(snFoldHopOfVisibleDM(previousTop: .dm("a"), nextTop: .settings) == nil)
    }
}
