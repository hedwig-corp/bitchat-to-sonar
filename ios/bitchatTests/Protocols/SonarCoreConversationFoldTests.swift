import Foundation
import Testing
@testable import Sonar

/// The iOS side of the core-owned Messages list (`conversationList`): Home,
/// open, mark-read and mute read core's folded sets, the same sets Compose
/// renders (R-003, R-052). Core's own tests pin the fold rule itself
/// (`core/sonar-core/src/conversation_list.rs`).
struct SonarCoreConversationFoldTests {
    private func row(_ ids: [String], unread: UInt64 = 0) -> MarmotService.ConversationListRow {
        MarmotService.ConversationListRow(
            conversationId: ids[0], kind: .direct, groupIds: ids, counterpartHex: nil,
            name: "", latestContent: "", latestSenderHex: "", latestAt: Date(timeIntervalSince1970: 0),
            latestMine: false, latestGroupId: ids[0], messageCount: 0, unreadCount: unread, version: 0
        )
    }

    private func group(_ id: String) -> MarmotService.MarmotGroup {
        MarmotService.MarmotGroup(id: id, name: "", memberNpubs: ["npub1me", "npub1sara"])
    }

    @Test
    func everyGroupOfARowMapsToTheWholeSetRowGroupFirst() {
        let map = snConversationGroupIdsByGroup([row(["s2", "s1"]), row(["l1"])])
        #expect(map["s1"] == ["s2", "s1"])
        #expect(map["s2"] == ["s2", "s1"])
        #expect(map["l1"] == ["l1"])
    }

    @Test
    func coreSetResolvesInRowOrderAndSkipsGroupsThatAreGone() {
        let sets = snConversationGroupIdsByGroup([row(["s2", "s1", "s3"])])
        let byId = ["s1": group("s1"), "s2": group("s2")]
        #expect(snCoreFoldedGroups("s1", sets: sets, groupsById: byId)?.map(\.id) == ["s2", "s1"])
    }

    @Test
    func aGroupCoreHasNotListedFallsBackToTheLocalFold() {
        let sets = snConversationGroupIdsByGroup([row(["s2", "s1"])])
        #expect(snCoreFoldedGroups("new", sets: sets, groupsById: ["new": group("new")]) == nil)
    }

    @Test
    func droppingAGroupLeavesItsRowMatesFolded() {
        let map = snConversationGroupIdsByGroup([row(["s2", "s1", "s3"]), row(["l1"])])
        let next = snDroppingConversationGroup("s2", from: map)
        #expect(next["s2"] == nil)
        #expect(next["s1"] == ["s1", "s3"])
        #expect(next["s3"] == ["s1", "s3"])
        #expect(next["l1"] == ["l1"])
        #expect(snDroppingConversationGroup("unknown", from: map) == map)
    }
}
