//
// HomeRowsGroupIndexTests.swift
// bitchatTests
//
// The chat list resolves every row's mute flag, and resolving one chat used to
// scan every Marmot group (by id, then a filter deriving each group's peer
// key). A rebuild was O(groups²): ~370 ms on the main thread at 426 groups,
// several times per foreground (R-057, found by the QA-160 large-account
// fixture). These tests drive the real `dmRows` call site and pin the index
// that replaced the scans.
//
// This is free and unencumbered software released into the public domain.
//

import Foundation
import Testing
@testable import Sonar

@MainActor
@Suite(.serialized)
struct HomeRowsGroupIndexTests {
    private static let me = "npub1ownaccount"

    private static func group(_ id: String, _ peer: String) -> MarmotService.MarmotGroup {
        MarmotService.MarmotGroup(id: id, name: "", memberNpubs: [me, peer])
    }

    /// Fails without the fix: each of the 160 rows derived all 160 groups'
    /// peer keys (25,600+). With the index it is a handful per group. One chat
    /// is muted so every row resolves its keys: with no mutes at all
    /// `isChatMuted` returns before the lookups.
    @Test
    func aChatListRebuildDerivesEachGroupsPeerKeyABoundedNumberOfTimes() {
        let (store, cleanup) = makeIsolatedSonarAppStore()
        defer { cleanup() }
        let count = 160
        store.marmot.npub = Self.me
        store.marmot.groups = (0..<count).map { Self.group("g\($0)", "npub1peer\($0)") }
        let muted = SonarAppStore.marmotIDPrefix + "g0"
        store.muteChat(muted, for: nil)
        defer { store.unmuteChat(muted) }

        let before = SNDirectPeerKeyDerivations.count
        let rows = store.dmRows
        let derived = SNDirectPeerKeyDerivations.count - before

        #expect(rows.count == count)
        #expect(
            derived <= 16 * count,
            "a rebuild derived \(derived) peer keys for \(count) groups: a per-row scan of every group is back"
        )
    }

    /// The index must not change what a row resolves to: a mute stored on one
    /// of two 1:1 groups with the same person still mutes that person's row.
    @Test
    func aMuteOnOneOfTwoGroupsWithThePersonMutesTheirRow() {
        let (store, cleanup) = makeIsolatedSonarAppStore()
        defer { cleanup() }
        store.marmot.npub = Self.me
        store.marmot.groups = [
            Self.group("bob1", "npub1bob"),
            Self.group("carol", "npub1carol"),
            Self.group("bob2", "npub1bob"),
        ]
        let muted = SonarAppStore.marmotIDPrefix + "bob1"
        store.muteChat(muted, for: nil)
        defer { store.unmuteChat(muted) }

        let rows = store.dmRows
        let bob = rows.filter { ["bob1", "bob2"].contains($0.marmotGroupId ?? "") }
        let carol = rows.filter { $0.marmotGroupId == "carol" }
        #expect(bob.count == 1, "both 1:1 groups with Bob fold into one row")
        #expect(bob.first?.muted == true)
        #expect(carol.first?.muted == false)
    }

    /// The index is cached; a new group or a changed own npub must rebuild it.
    @Test
    func theIndexFollowsGroupsAndOwnNpub() {
        let (store, cleanup) = makeIsolatedSonarAppStore()
        defer { cleanup() }
        store.marmot.groups = [Self.group("bob1", "npub1bob")]
        // Without our own npub both members count as counterparts: not 1:1.
        #expect(store.marmot.groupIndex.directGroupsByPeer.isEmpty)

        store.marmot.npub = Self.me
        let bobKey = SNMarmotProfileCache.canonicalKey("npub1bob")
        #expect(store.marmot.groupIndex.directGroupsByPeer[bobKey]?.map(\.id) == ["bob1"])

        store.marmot.groups.append(Self.group("bob2", "npub1bob"))
        #expect(store.marmot.groupIndex.directGroupsByPeer[bobKey]?.map(\.id) == ["bob1", "bob2"])
        #expect(store.marmot.groupIndex.groupsById["bob2"]?.memberNpubs == [Self.me, "npub1bob"])
    }
}
