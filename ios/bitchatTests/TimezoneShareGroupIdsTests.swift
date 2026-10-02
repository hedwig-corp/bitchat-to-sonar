//
// TimezoneShareGroupIdsTests.swift
// bitchatTests
//
// The local-time share list is built from one read of the override map, and
// a group's alias override is resolved once per group, never by re-scanning
// every group (R-055: the per-group walk ran on every foreground and every
// `$groups` publish and froze the UI for about a second on 400 groups).
// This is free and unencumbered software released into the public domain.
//

import Foundation
import Testing
@testable import Sonar

struct TimezoneShareGroupIdsTests {
    private let prefix = "marmot:"

    private func group(_ id: String, _ members: [String]) -> MarmotService.MarmotGroup {
        MarmotService.MarmotGroup(id: id, name: "", memberNpubs: members)
    }

    @Test
    func noOverridesFollowsTheGlobalSwitch() {
        let off = snTimezoneShareGroupIds(
            groupIds: ["g1", "g2"], mappedGroupIds: ["g3"], marmotIDPrefix: prefix,
            overrides: [:], global: false, aliasOverrideByGroup: [:]
        )
        let on = snTimezoneShareGroupIds(
            groupIds: ["g1", "g2"], mappedGroupIds: ["g3"], marmotIDPrefix: prefix,
            overrides: [:], global: true, aliasOverrideByGroup: [:]
        )
        #expect(off == [])
        #expect(on == ["g1", "g2", "g3"])
    }

    @Test
    func aDirectOverrideWinsOverTheAliasAndTheGlobalSwitch() {
        let ids = snTimezoneShareGroupIds(
            groupIds: ["g1", "g2", "g3"], mappedGroupIds: [], marmotIDPrefix: prefix,
            overrides: ["marmot:g2": false, "g3": true], global: true,
            aliasOverrideByGroup: ["g2": true]
        )
        // g2 is off by its own key even though an alias says on; g3 shares by
        // its bare key; g1 follows global.
        #expect(ids == ["g1", "g3"])
    }

    @Test
    func eitherKeyFormSharingIsEnough() {
        let ids = snTimezoneShareGroupIds(
            groupIds: ["g1"], mappedGroupIds: [], marmotIDPrefix: prefix,
            overrides: ["marmot:g1": false, "g1": true], global: false,
            aliasOverrideByGroup: [:]
        )
        #expect(ids == ["g1"])
    }

    @Test
    func anAliasOverrideAppliesOnlyWithoutADirectEntry() {
        let ids = snTimezoneShareGroupIds(
            groupIds: ["g1", "g2"], mappedGroupIds: [], marmotIDPrefix: prefix,
            overrides: ["mesh-peer-7": true], global: false,
            aliasOverrideByGroup: ["g2": true]
        )
        #expect(ids == ["g2"])
    }

    // MARK: - Alias builder

    @Test
    func aLaterDuplicateGroupInheritsItsSiblingsOverride() {
        // The chat was toggled on while only g1 existed with Bob; g2 is a
        // second 1:1 group with Bob created afterwards.
        let groups = [group("g1", ["me", "bob"]), group("g2", ["me", "bob"]), group("g3", ["me", "carol"])]
        let aliases = snTimezoneAliasOverridesByGroup(
            groups: groups, marmotIDPrefix: prefix,
            overrides: ["marmot:g1": true, "g1": true, "bob": true],
            directPeerKey: { $0.memberNpubs.first { $0 != "me" } },
            peerKeyForms: { group in group.memberNpubs.filter { $0 != "me" } }
        )
        #expect(aliases["g2"] == true)
        #expect(aliases["g3"] == nil, "Carol's chat was never toggled")
    }

    @Test
    func anOverrideStoredOnlyUnderThePeerKeyReachesTheirGroups() {
        let groups = [group("g1", ["me", "bob"])]
        let aliases = snTimezoneAliasOverridesByGroup(
            groups: groups, marmotIDPrefix: prefix,
            overrides: ["bobhex": false],
            directPeerKey: { $0.memberNpubs.first { $0 != "me" } },
            peerKeyForms: { _ in ["bob", "bobhex"] }
        )
        #expect(aliases["g1"] == false)
    }

    @Test
    func groupChatsNeverInheritAPeerOverride() {
        let groups = [group("team", ["me", "bob", "carol"])]
        let aliases = snTimezoneAliasOverridesByGroup(
            groups: groups, marmotIDPrefix: prefix,
            overrides: ["bob": true],
            directPeerKey: { $0.memberNpubs.count == 2 ? $0.memberNpubs.first { $0 != "me" } : nil },
            peerKeyForms: { group in group.memberNpubs.filter { $0 != "me" } }
        )
        #expect(aliases.isEmpty)
    }

    /// The cost guard: each group's peer key is computed exactly once, however
    /// many groups there are. The old per-group walk re-derived the whole
    /// conversation for every group, which on 400 groups is 160,000 peer-key
    /// computations and about a second on the main thread.
    @Test
    func thePeerKeyIsComputedOncePerGroup() {
        let groups = (0..<400).map { group("g\($0)", ["me", "peer\($0 % 50)"]) }
        var peerKeyCalls = 0
        _ = snTimezoneAliasOverridesByGroup(
            groups: groups, marmotIDPrefix: prefix,
            overrides: ["peer7": true, "marmot:g3": false],
            directPeerKey: { group in
                peerKeyCalls += 1
                return group.memberNpubs.first { $0 != "me" }
            },
            peerKeyForms: { group in group.memberNpubs.filter { $0 != "me" } }
        )
        #expect(peerKeyCalls == groups.count)
    }
}
