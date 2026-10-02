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
            name: "", title: "Sara", preview: .text("secret"),
            latestContent: "secret", latestSenderHex: "", latestAt: Date(timeIntervalSince1970: 0),
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

    @Test
    func theStartupSnapshotKeepsRowsButNeverMessageText() {
        let withFile = MarmotService.ConversationListRow(
            conversationId: "f1", kind: .direct, groupIds: ["f1"], counterpartHex: nil,
            name: "", title: nil, preview: .file("contract.pdf"), latestContent: "contract.pdf",
            latestSenderHex: "", latestAt: Date(timeIntervalSince1970: 5), latestMine: false,
            latestGroupId: "f1", messageCount: 1, unreadCount: 0, version: 1
        )
        let photo = MarmotService.ConversationListRow(
            conversationId: "p1", kind: .direct, groupIds: ["p1"], counterpartHex: nil,
            name: "", title: "Luca", preview: .photos(2), latestContent: "2 photos",
            latestSenderHex: "", latestAt: Date(timeIntervalSince1970: 6), latestMine: false,
            latestGroupId: "p1", messageCount: 1, unreadCount: 1, version: 1
        )
        let safe = snSnapshotSafeRows([row(["s1", "s2"], unread: 2), withFile, photo])
        #expect(safe.allSatisfy { $0.latestContent.isEmpty })
        #expect(safe[0].preview == .empty)
        #expect(safe[1].preview == .empty, "a file name is message content too")
        #expect(safe[2].preview == .photos(2), "media kinds are metadata and stay")
        #expect(safe[0].title == "Sara")
        #expect(safe[0].unreadCount == 2)
        #expect(safe[0].groupIds == ["s1", "s2"])
    }

    @Test
    func deletingAGroupShrinksItsRowAndDropsAnEmptyOne() {
        let rows = [row(["s2", "s1"]), row(["l1"])]
        let afterHead = snDroppingConversationRowGroup("s2", from: rows)
        #expect(afterHead.map(\.conversationId) == ["s1", "l1"])
        #expect(afterHead[0].groupIds == ["s1"])
        #expect(snDroppingConversationRowGroup("l1", from: rows).map(\.conversationId) == ["s2"])
    }

    @Test
    @MainActor
    func corePreviewsAreWordedLikeComposeRows() {
        #expect(SonarAppStore.previewText(.empty) == nil)
        #expect(SonarAppStore.previewText(.text("hi")) == "hi")
        #expect(SonarAppStore.previewText(.photos(1)) == "Photo")
        #expect(SonarAppStore.previewText(.photos(3)) == "3 photos")
        #expect(SonarAppStore.previewText(.file("")) == "File")
        #expect(SonarAppStore.previewText(.voiceCall) == "Voice call")
        #expect(SonarAppStore.previewText(.payment) == "\u{20BF} Payment")
    }
}
