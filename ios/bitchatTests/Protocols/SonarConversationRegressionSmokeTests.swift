//
// SonarConversationRegressionSmokeTests.swift
// bitchatTests
//

import Foundation
import Testing
@testable import Sonar

/// Cross-platform parity fixture for the conversation regressions seen on real
/// devices: duplicate direct groups, a newer Sara message appearing on the
/// wrong Vincenzo row, and unstable ordering after restart.
struct SonarConversationRegressionSmokeTests {
    private func npub(_ byte: UInt8) -> String {
        try! Bech32.encode(hrp: "npub", data: Data(repeating: byte, count: 32))
    }

    @Test
    func saraAndVincenzoRemainSeparateCryptographicConversations() {
        let own = npub(1)
        let sara = npub(2)
        let vincenzo = npub(3)
        let groups = [
            MarmotService.MarmotGroup(id: "sara-old", name: "", memberNpubs: [own, sara]),
            MarmotService.MarmotGroup(id: "vincenzo", name: "", memberNpubs: [own, vincenzo]),
            MarmotService.MarmotGroup(id: "sara-new", name: "", memberNpubs: [own, sara]),
        ]

        let grouped = snCanonicalDirectMarmotGroups(groups, ownNpub: own)

        #expect(grouped.count == 2)
        #expect(grouped[sara]?.map(\.id) == ["sara-old", "sara-new"])
        #expect(grouped[vincenzo]?.map(\.id) == ["vincenzo"])
    }

    @Test
    func newSaraMessageMovesOnlySaraRowAndKeepsSaraTitle() {
        let old = Date(timeIntervalSince1970: 100)
        let new = Date(timeIntervalSince1970: 300)
        let rows = [
            SNDMRow(
                id: "vincenzo-mac", title: "Vincenzo-Mac", preview: "Yesterday",
                time: "", unread: false, presence: false, verified: false,
                isMarmot: false, lastDate: old
            ),
            SNDMRow(
                id: "sara", title: snFoldedDirectMarmotHomeTitle(
                    isDirectGroup: true,
                    marmotProfileTitle: "Sara D",
                    peerDerivedTitle: "Vincenzo-Mac"
                ), preview: "Good morning", time: "", unread: true,
                presence: false, verified: false, isMarmot: false, lastDate: new
            ),
        ]

        let ordered = snSortDMRowsByRecency(rows)

        #expect(ordered.map(\.id) == ["sara", "vincenzo-mac"])
        #expect(ordered.first?.title == "Sara D")
        #expect(ordered.first?.preview == "Good morning")
    }

    @Test
    func restartTieOrderIsDeterministic() {
        let same = Date(timeIntervalSince1970: 200)
        let rows = [
            SNDMRow(
                id: "vincenzo", title: "Vincenzo", preview: "", time: "",
                unread: false, presence: false, verified: false,
                isMarmot: false, lastDate: same
            ),
            SNDMRow(
                id: "sara", title: "Sara D", preview: "", time: "",
                unread: false, presence: false, verified: false,
                isMarmot: false, lastDate: same
            ),
        ]

        #expect(snSortDMRowsByRecency(rows).map(\.id) == ["sara", "vincenzo"])
        #expect(snSortDMRowsByRecency(Array(rows.reversed())).map(\.id) == ["sara", "vincenzo"])
    }
}
