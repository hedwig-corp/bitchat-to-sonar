//
// TimezoneShareGroupIdsTests.swift
// bitchatTests
//
// The local-time share list is built from one read of the override map and
// never walks chat aliases unless an alias override exists (R-055: the walk
// ran per group, twice, on every `$groups` publish and froze the UI).
// This is free and unencumbered software released into the public domain.
//

import Foundation
import Testing
@testable import Sonar

struct TimezoneShareGroupIdsTests {
    private let prefix = "marmot:"

    @Test
    func noOverridesFollowsTheGlobalSwitch() {
        var aliasLookups = 0
        let off = snTimezoneShareGroupIds(
            groupIds: ["g1", "g2"], mappedGroupIds: ["g3"], marmotIDPrefix: prefix,
            overrides: [:], global: false,
            aliasOverride: { _ in aliasLookups += 1; return nil }
        )
        let on = snTimezoneShareGroupIds(
            groupIds: ["g1", "g2"], mappedGroupIds: ["g3"], marmotIDPrefix: prefix,
            overrides: [:], global: true,
            aliasOverride: { _ in aliasLookups += 1; return nil }
        )
        #expect(off == [])
        #expect(on == ["g1", "g2", "g3"])
        #expect(aliasLookups == 0)
    }

    @Test
    func aDirectOverrideWinsWithoutAnyAliasWalk() {
        var aliasLookups = 0
        let ids = snTimezoneShareGroupIds(
            groupIds: ["g1", "g2", "g3"], mappedGroupIds: [], marmotIDPrefix: prefix,
            overrides: ["marmot:g2": false, "g3": true], global: true,
            aliasOverride: { _ in aliasLookups += 1; return nil }
        )
        // g2 is off by its chat-row key; g3's bare key still shares; g1 follows global.
        #expect(ids == ["g1", "g3"])
        #expect(aliasLookups == 0, "only group keys in the map: no alias walk")
    }

    @Test
    func eitherKeyFormSharingIsEnough() {
        let ids = snTimezoneShareGroupIds(
            groupIds: ["g1"], mappedGroupIds: [], marmotIDPrefix: prefix,
            overrides: ["marmot:g1": false, "g1": true], global: false,
            aliasOverride: { _ in nil }
        )
        #expect(ids == ["g1"])
    }

    @Test
    func anAliasOverrideIsConsultedOnlyWhenAliasKeysExist() {
        var asked: [String] = []
        let ids = snTimezoneShareGroupIds(
            groupIds: ["g1", "g2"], mappedGroupIds: [], marmotIDPrefix: prefix,
            overrides: ["mesh-peer-7": true], global: false,
            aliasOverride: { chatId in
                asked.append(chatId)
                return chatId == "marmot:g2" ? true : nil
            }
        )
        #expect(ids == ["g2"])
        #expect(asked.contains("marmot:g2"))
    }
}
