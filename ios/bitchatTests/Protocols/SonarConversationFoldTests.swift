//
// SonarConversationFoldTests.swift
// bitchatTests
//

import Foundation
import Testing
@testable import Sonar

struct SonarConversationFoldTests {
    @Test
    func foldedDirectHomeTitleUsesMarmotProfile() {
        let title = snFoldedDirectMarmotHomeTitle(
            isDirectGroup: true,
            marmotProfileTitle: "Sara D",
            peerDerivedTitle: "Wrong BLE Name"
        )

        #expect(title == "Sara D")
    }

    @Test
    func nonDirectHomeTitleKeepsPeerDerivedName() {
        let title = snFoldedDirectMarmotHomeTitle(
            isDirectGroup: false,
            marmotProfileTitle: "Room Profile",
            peerDerivedTitle: "Builders Room"
        )

        #expect(title == "Builders Room")
    }

    @Test
    func recoveredRoomTitleKeepsRoomNameWhenOnlyOnePeerIsListed() {
        #expect(
            snMarmotChatDisplayTitle(
                isDirect: false,
                name: "pending room",
                otherMemberCount: 1,
                profileName: "Bob",
                npubFallback: "npub1bob…"
            ) == "pending room"
        )
        #expect(
            snMarmotChatDisplayTitle(
                isDirect: true,
                name: "bob dm",
                otherMemberCount: 1,
                profileName: "Bob",
                npubFallback: "npub1bob…"
            ) == "Bob"
        )
        #expect(
            snMarmotChatDisplayTitle(
                isDirect: false,
                name: "standup",
                otherMemberCount: 1,
                profileName: "Bob",
                npubFallback: "npub1bob…"
            ) == "standup"
        )
        #expect(
            snMarmotChatDisplayTitle(
                isDirect: false,
                name: "",
                otherMemberCount: 2,
                profileName: "Bob",
                npubFallback: "npub1bob…"
            ) == "Group chat"
        )
    }

    @Test
    func recoveredAndResumedDirectChatsPreferLiveSendTarget() {
        #expect(
            snMarmotSendTargetGroupId(
                openChatId: "group-08",
                duplicateGroupIds: ["group-08", "group-09"],
                latestSecs: { $0 == "group-09" ? 2 : 1 }
            ) == "group-09"
        )
        #expect(
            snRemountFoldedOpenGroupId(
                openGroupId: "group-08",
                listedGroupIds: ["group-09"],
                liveFoldTarget: "group-09"
            ) == "group-09"
        )
        #expect(
            snRemountFoldedOpenGroupId(
                openGroupId: "group-09",
                listedGroupIds: ["group-09"],
                liveFoldTarget: "group-09"
            ) == "group-09"
        )
        #expect(
            snRemountFoldedOpenGroupId(
                openGroupId: "group-08",
                listedGroupIds: ["group-08", "group-09"],
                liveFoldTarget: "group-09"
            ) == "group-08"
        )
        #expect(
            snRemountFoldedOpenGroupId(
                openGroupId: "group-08",
                listedGroupIds: ["group-09"],
                liveFoldTarget: nil
            ) == "group-08"
        )
        #expect(
            snRemountFoldedOpenGroupId(
                openGroupId: "group-08",
                listedGroupIds: [],
                liveFoldTarget: "group-09"
            ) == "group-09"
        )
        #expect(
            snRemountFoldedConversationId(
                "marmot:group-08",
                listedGroupIds: ["group-09"],
                liveFoldTarget: "group-09"
            ) == "marmot:group-09"
        )
        #expect(
            snRemountFoldedPath(
                path: [
                    .dm("marmot:group-08"),
                    .groupInfo("marmot:group-08"),
                    .contactProfile("marmot:group-08", "Ada"),
                    .call("marmot:group-08", video: false),
                ],
                listedGroupIds: ["group-09"],
                liveFoldTarget: { _ in "group-09" }
            ) == [
                .dm("marmot:group-09"),
                .groupInfo("marmot:group-09"),
                .contactProfile("marmot:group-09", "Ada"),
                .call("marmot:group-09", video: false),
            ]
        )
        #expect(
            snPathConversationIds([
                .dm("marmot:group-08"),
                .groupInfo("marmot:group-08"),
                .contactProfile("marmot:group-08", "Ada"),
                .call("marmot:group-08", video: false),
                .nearby,
            ]) == [
                "marmot:group-08",
                "marmot:group-08",
                "marmot:group-08",
                "marmot:group-08",
            ]
        )
        #expect(snPathRemountShouldMergeFolds(
            pathIds: ["marmot:group-08", "marmot:group-09"],
            persistedFolds: [:]
        ))
        #expect(!snPathRemountShouldMergeFolds(
            pathIds: ["marmot:group-08"],
            persistedFolds: ["group-08": "group-09"]
        ))
        #expect(
            snPathRemountLiveTarget(
                id: "marmot:group-08",
                persistedFolds: [:],
                knownLiveTargets: ["group-08": "group-09"]
            ) == "group-09"
        )
        #expect(
            snPathRemountLiveTarget(
                id: "marmot:group-08",
                persistedFolds: ["group-08": "group-09"],
                knownLiveTargets: [:]
            ) == "group-09"
        )
        #expect(
            snRemountFoldedPath(
                path: [.groupInfo("marmot:group-08")],
                listedGroupIds: ["group-09"],
                liveFoldTarget: { id in
                    snPathRemountLiveTarget(
                        id: id,
                        persistedFolds: [:],
                        knownLiveTargets: ["group-08": "group-09"]
                    )
                }
            ) == [.groupInfo("marmot:group-09")]
        )
        #expect(snDeletedConversationClearsOpen(
            openId: "marmot:group-08",
            deletedId: "marmot:group-09",
            purgeIds: ["group-08", "group-09"]
        ))
        #expect(snDeletedConversationShouldClearRoute(
            .groupInfo("marmot:group-08"),
            deletedId: "marmot:group-09",
            purgeIds: ["group-08", "group-09"]
        ))
        #expect(!snDeletedConversationShouldClearRoute(
            .groupInfo("marmot:other"),
            deletedId: "marmot:group-09",
            purgeIds: ["group-09"]
        ))
        let meshPurge = snDeletedMeshConversationPurgeIds(
            meshChatIds: ["mesh:peer"],
            foldedGroupIds: ["group-08", "group-09"]
        )
        #expect(snDeletedConversationShouldClearRoute(
            .dm("marmot:group-09"),
            deletedId: "mesh:peer",
            purgeIds: meshPurge
        ))
        #expect(snDeletedConversationShouldClearRoute(
            .groupInfo("marmot:group-08"),
            deletedId: "mesh:peer",
            purgeIds: meshPurge
        ))
        #expect(snDeletedConversationClearsOpen(
            openId: "group-09",
            deletedId: "mesh:peer",
            purgeIds: meshPurge
        ))
        #expect(!snDeletedConversationShouldClearRoute(
            .dm("marmot:group-09"),
            deletedId: "mesh:peer",
            purgeIds: ["mesh:peer"]
        ))
        #expect(snMacSelectionShouldHopAfterOpenSessionCleared(isDM: true, isChannel: false))
        #expect(snMacSelectionShouldHopAfterOpenSessionCleared(isDM: false, isChannel: true))
        #expect(!snMacSelectionShouldHopAfterOpenSessionCleared(isDM: false, isChannel: false))
        #expect(
            snNotificationOpenGroupId(
                tappedGroupId: "group-08",
                liveFoldTarget: "group-09"
            ) == "group-09"
        )
        #expect(
            snNotificationOpenGroupId(
                tappedGroupId: "group-08",
                liveFoldTarget: nil
            ) == "group-08"
        )
        #expect(
            snNotificationOpenGroupId(
                tappedGroupId: "group-09",
                liveFoldTarget: "group-09"
            ) == "group-09"
        )
        #expect(
            snListedOrFoldedSiblingGroupId(
                groupId: "group-09",
                listedGroupIds: ["group-09"],
                historicalFolds: ["group-08": "group-09"]
            ) == "group-09"
        )
        #expect(
            snListedOrFoldedSiblingGroupId(
                groupId: "group-09",
                listedGroupIds: ["group-08"],
                historicalFolds: ["group-08": "group-09"]
            ) == "group-08"
        )
        #expect(
            snListedOrFoldedSiblingGroupId(
                groupId: "group-08",
                listedGroupIds: ["group-09"],
                historicalFolds: ["group-08": "group-09"]
            ) == "group-09"
        )
        #expect(
            snListedOrFoldedSiblingGroupId(
                groupId: "group-09",
                listedGroupIds: [],
                historicalFolds: ["group-08": "group-09"]
            ) == nil
        )
        #expect(
            snListedOrFoldedSiblingGroupId(
                groupId: "group-08",
                listedGroupIds: ["group-09"],
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == "group-09"
        )
        #expect(
            snListedOrFoldedSiblingGroupId(
                groupId: "group-other",
                listedGroupIds: ["group-09"],
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == nil
        )
        #expect(
            snResolvedOpenGroupId(
                groupId: "group-08",
                listedGroupIds: ["group-09"],
                historicalFolds: ["group-08": "group-09"]
            ) == "group-09"
        )
        #expect(
            snResolvedOpenGroupId(
                groupId: "group-08",
                listedGroupIds: [],
                historicalFolds: ["group-08": "group-09"]
            ) == "group-08"
        )
        #expect(
            snResolvedOpenGroupId(
                groupId: "group-09",
                listedGroupIds: ["group-09"],
                historicalFolds: ["group-08": "group-09"]
            ) == "group-09"
        )
        #expect(
            snResolvedOpenGroupId(
                groupId: "group-08",
                listedGroupIds: ["group-09"],
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == "group-09"
        )
        #expect(
            snResolvedOpenGroupId(
                groupId: "group-other",
                listedGroupIds: ["group-09"],
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == "group-other"
        )
        #expect(
            snPersistedLiveFoldTarget(
                tappedGroupId: "marmot:group-08",
                historicalFolds: ["group-08": "group-09"]
            ) == "group-09"
        )
        #expect(
            snNotificationLiveFoldTarget(
                tappedGroupId: "group-08",
                ffiLiveFoldTarget: nil,
                historicalFolds: ["group-08": "group-09"]
            ) == "group-09"
        )
        #expect(
            snNotificationLiveFoldTarget(
                tappedGroupId: "group-08",
                ffiLiveFoldTarget: "group-09",
                historicalFolds: ["group-08": "stale-09"]
            ) == "group-09"
        )
        #expect(
            snNotificationLiveFoldTarget(
                tappedGroupId: "group-08",
                ffiLiveFoldTarget: nil,
                historicalFolds: [:]
            ) == nil
        )
        #expect(
            snConversationsMatchFoldFamily(
                left: "marmot:group-08",
                right: "marmot:group-09",
                historicalFolds: ["group-08": "group-09"]
            )
        )
        #expect(
            !snConversationsMatchFoldFamily(
                left: "marmot:group-08",
                right: "marmot:other",
                historicalFolds: ["group-08": "group-09"]
            )
        )
        #expect(
            snGroupInfoShouldReloadPending(
                openGroupInfoChatId: "marmot:group-09",
                changedId: "group-08",
                historicalFolds: ["group-08": "group-09"]
            )
        )
        #expect(
            snGroupInfoShouldReloadPending(
                openGroupInfoChatId: "marmot:group-09",
                changedId: "marmot:group-09",
                historicalFolds: ["group-08": "group-09"]
            )
        )
        #expect(
            !snGroupInfoShouldReloadPending(
                openGroupInfoChatId: "marmot:group-09",
                changedId: "other",
                historicalFolds: ["group-08": "group-09"]
            )
        )
        #expect(
            !snGroupInfoShouldReloadPending(
                openGroupInfoChatId: nil,
                changedId: "group-08",
                historicalFolds: ["group-08": "group-09"]
            )
        )
        #expect(
            !snGroupInfoShouldReloadPending(
                openGroupInfoChatId: "marmot:group-08",
                changedId: "group-09",
                historicalFolds: [:]
            )
        )
        #expect(
            snGroupInfoShouldReloadPending(
                openGroupInfoChatId: "marmot:group-08",
                changedId: "group-09",
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            )
        )
        #expect(
            snGroupInfoShouldReloadPending(
                openGroupInfoChatId: "marmot:group-09",
                changedId: "group-08",
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            )
        )
        #expect(
            !snGroupInfoShouldReloadPending(
                openGroupInfoChatId: "marmot:group-08",
                changedId: "other",
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            )
        )
        #expect(
            snConversationsMatchFoldFamily(
                left: "marmot:group-08",
                right: "marmot:group-09",
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            )
        )
        #expect(
            !snConversationsMatchFoldFamily(
                left: "marmot:group-08",
                right: "marmot:other",
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            )
        )
        #expect(
            snRemountFoldedOpenValues(
                historicalKeys: ["marmot:group-08", "group-08"],
                liveKeys: ["marmot:group-09", "group-09"],
                values: ["marmot:group-08": UInt64(3)]
            )["marmot:group-09"] == 3
        )
        #expect(
            snRemountFoldedOpenValues(
                historicalKeys: ["marmot:group-08"],
                liveKeys: ["marmot:group-09"],
                values: ["marmot:group-08": UInt64(3), "marmot:group-09": UInt64(1)]
            )["marmot:group-09"] == 1
        )
        #expect(
            snRemountFoldedOpenValues(
                historicalKeys: ["group-08"],
                liveKeys: ["group-09"],
                values: ["group-08": ["old-1", "old-2"]],
                preferExisting: { !$0.isEmpty }
            )["group-09"] == ["old-1", "old-2"]
        )
        #expect(
            snRemountFoldedOpenValues(
                historicalKeys: ["group-08"],
                liveKeys: ["group-09"],
                values: ["group-08": ["old-1"], "group-09": ["already-live"]],
                preferExisting: { !$0.isEmpty }
            )["group-09"] == ["already-live"]
        )
        let remountedDrafts = snRemountComposerDrafts(
            drafts: ["marmot:group-08": "hello from 0.8"],
            historicalKeys: ["marmot:group-08", "group-08"],
            liveKeys: ["marmot:group-09", "group-09"]
        )
        #expect(remountedDrafts["marmot:group-08"] == "hello from 0.8")
        #expect(remountedDrafts["marmot:group-09"] == "hello from 0.8")
        #expect(
            snComposerDraft(
                chatId: "marmot:group-08",
                drafts: remountedDrafts,
                historicalFolds: ["group-08": "group-09"]
            ) == "hello from 0.8"
        )
        #expect(
            snComposerDraft(
                chatId: "marmot:group-08",
                drafts: remountedDrafts,
                historicalFolds: [:]
            ) == "hello from 0.8"
        )
        #expect(
            snComposerDraft(
                chatId: "marmot:group-09",
                drafts: remountedDrafts,
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == "hello from 0.8"
        )
        #expect(
            snComposerDraftsAfterEdit(
                drafts: remountedDrafts,
                chatId: "marmot:group-08",
                text: "",
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ).isEmpty
        )
        #expect(
            snComposerReply(
                chatId: "marmot:group-09",
                replies: ["marmot:group-08": "reply-08"],
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == "reply-08"
        )
        #expect(
            snComposerRepliesAfterClear(
                replies: [
                    "marmot:group-08": "reply-08",
                    "marmot:group-09": "reply-08"
                ],
                chatId: "marmot:group-08",
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ).isEmpty
        )
        #expect(
            snComposerRepliesAfterBegin(
                replies: [:],
                chatId: "marmot:group-08",
                reply: "reply-08",
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            )["marmot:group-09"] == "reply-08"
        )
        #expect(
            snComposerRepliesAfterBegin(
                replies: [:],
                chatId: "marmot:group-08",
                reply: "reply-08",
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            )["marmot:group-08"] == "reply-08"
        )
        #expect(
            snComposerReply(
                chatId: "marmot:group-09",
                replies: snComposerRepliesAfterBegin(
                    replies: [:],
                    chatId: "marmot:group-08",
                    reply: "reply-08",
                    historicalFolds: [:],
                    openedConversationId: "marmot:group-09",
                    openedConversationPaneId: "marmot:group-08"
                ),
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == "reply-08"
        )
        // Persist-folds + `setComposerDraft("", hist)` family-clears live.
        // Remount must copy, not clear, or the iPhone hist pane loses the draft.
        #expect(
            snComposerDraftsAfterEdit(
                drafts: remountedDrafts,
                chatId: "marmot:group-08",
                text: "",
                historicalFolds: ["group-08": "group-09"]
            ).isEmpty
        )
        #expect(
            snRemountComposerDrafts(
                drafts: ["marmot:group-08": "old", "marmot:group-09": "already typing"],
                historicalKeys: ["marmot:group-08"],
                liveKeys: ["marmot:group-09"]
            )["marmot:group-09"] == "already typing"
        )
        #expect(
            snRemountComposerDraftHasText(
                flags: ["marmot:group-08": true],
                historicalKeys: ["marmot:group-08"],
                liveKeys: ["marmot:group-09"]
            )["marmot:group-09"] == true
        )
        #expect(
            snRemountFoldedOpenId(
                historicalKeys: ["marmot:group-08", "group-08"],
                liveId: "marmot:group-09",
                id: "marmot:group-08"
            ) == "marmot:group-09"
        )
        #expect(
            snRemountFoldedOpenId(
                historicalKeys: ["marmot:group-08"],
                liveId: "marmot:group-09",
                id: "other"
            ) == "other"
        )
        #expect(
            snHistoricalFoldsFromAliases(
                listedIds: ["group-09"],
                foldAliases: { $0 == "group-09" || $0 == "group-08" ? ["group-09", "group-08"] : [$0] },
                liveFoldTarget: { $0 == "group-08" || $0 == "group-09" ? "group-09" : nil }
            ) == ["group-08": "group-09"]
        )
        #expect(
            snHistoricalFoldsFromAliases(
                listedIds: ["plain"],
                foldAliases: { [$0] },
                liveFoldTarget: { _ in nil }
            ).isEmpty
        )
        #expect(
            snHistoricalFoldsAfterAccountRestore(
                previousAccountFolds: ["other-08": "other-09", "group-08": "stale-09"],
                listedIds: ["group-09"],
                foldAliases: { $0 == "group-09" || $0 == "group-08" ? ["group-09", "group-08"] : [$0] },
                liveFoldTarget: { $0 == "group-08" || $0 == "group-09" ? "group-09" : nil }
            ) == ["group-08": "group-09"]
        )
        #expect(
            snCollapsedFoldedSnapshotGroups(
                groups: ["group-08", "group-09"],
                id: { $0 },
                historicalFolds: snHistoricalFoldsAfterAccountRestore(
                    previousAccountFolds: ["other-08": "other-09"],
                    listedIds: ["group-09"],
                    foldAliases: { $0 == "group-09" ? ["group-09", "group-08"] : [$0] },
                    liveFoldTarget: { $0 == "group-09" || $0 == "group-08" ? "group-09" : nil }
                )
            ) == ["group-09"]
        )
        #expect(
            snRetainedScanChatIds(
                listedIds: ["group-09"],
                historicalFolds: ["group-08": "group-09"]
            ) == ["group-08", "group-09"]
        )
        #expect(
            snRetainedScanChatIds(
                listedIds: ["group-09"],
                historicalFolds: [:]
            ) == ["group-09"]
        )
        #expect(
            snRetainedScanChatIds(
                listedIds: ["group-09"],
                historicalFolds: [:],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            ) == ["group-08", "group-09"]
        )
        #expect(
            snRetainedScanChatIds(
                listedIds: ["group-09"],
                historicalFolds: [:],
                openedConversationId: "group-other",
                openedConversationPaneId: "group-else"
            ) == ["group-09"]
        )
        #expect(
            snCollapsedFoldedSnapshotGroups(
                groups: ["group-08", "group-09"],
                id: { $0 },
                historicalFolds: [:]
            ) == ["group-08", "group-09"]
        )
        #expect(
            snCollapsedFoldedSnapshotGroups(
                groups: ["group-08", "group-09"],
                id: { $0 },
                historicalFolds: [:],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            ) == ["group-09"]
        )
        // Notification / deep-link ids stay on the hidden 0.8 row until remap.
        #expect(
            snRemountFoldedOpenGroupId(
                openGroupId: "group-08",
                listedGroupIds: ["group-09"],
                liveFoldTarget: "group-09"
            ) == "group-09"
        )
        let pairs = snPromotedFoldedMutePairs(
            previousGroupIds: ["group-08", "group-09"],
            currentGroupIds: ["group-09"],
            liveFoldTarget: { $0 == "group-08" ? "group-09" : nil }
        )
        #expect(pairs.count == 1)
        #expect(pairs.first?.historical == "group-08")
        #expect(pairs.first?.live == "group-09")
        #expect(
            snPromotedFoldedMutePairs(
                previousGroupIds: ["group-08"],
                currentGroupIds: ["group-08"],
                liveFoldTarget: { _ in "group-09" }
            ).isEmpty
        )
        let fromMuteOnly = snPromotedFoldedMutePairs(
            previousGroupIds: [],
            currentGroupIds: ["group-09"],
            muteKeys: ["group-08"],
            liveFoldTarget: { $0 == "group-08" ? "group-09" : nil }
        )
        #expect(fromMuteOnly.first?.historical == "group-08")
        #expect(fromMuteOnly.first?.live == "group-09")
        #expect(
            snPromotedFoldedComposerDrafts(
                previousGroupIds: ["group-08", "group-09"],
                currentGroupIds: ["group-09"],
                drafts: ["group-08": "hello from 0.8"],
                liveFoldTarget: { $0 == "group-08" ? "group-09" : nil }
            )["group-09"] == "hello from 0.8"
        )
        #expect(
            snPromotedFoldedComposerDrafts(
                previousGroupIds: ["group-08", "group-09"],
                currentGroupIds: ["group-09"],
                drafts: ["group-08": "old", "group-09": "already typing"],
                liveFoldTarget: { $0 == "group-08" ? "group-09" : nil }
            )["group-09"] == "already typing"
        )
        #expect(
            snPromotedFoldedComposerDrafts(
                previousGroupIds: [],
                currentGroupIds: ["group-09"],
                drafts: ["group-08": "hello from 0.8"],
                liveFoldTarget: { $0 == "group-08" ? "group-09" : nil }
            )["group-09"] == "hello from 0.8"
        )
        let historicalRows = ["old from 0.8"]
        #expect(
            snPromotedFoldedMessagesByGroup(
                previousGroupIds: ["group-08", "group-09"],
                currentGroupIds: ["group-09"],
                messagesByGroup: ["group-08": historicalRows],
                liveFoldTarget: { $0 == "group-08" ? "group-09" : nil },
                idOf: { $0 }
            )["group-09"] == historicalRows
        )
        #expect(
            snPromotedFoldedMessagesByGroup(
                previousGroupIds: [],
                currentGroupIds: ["group-09"],
                messagesByGroup: ["group-08": historicalRows, "group-09": ["already live"]],
                liveFoldTarget: { $0 == "group-08" ? "group-09" : nil },
                idOf: { $0 }
            )["group-09"] == ["already live"] + historicalRows
        )
        #expect(
            snMergedFoldedMessageLists(
                historical: ["old-1", "shared"],
                live: ["shared", "new-1"],
                idOf: { $0 }
            ) == ["shared", "new-1", "old-1"]
        )
        #expect(
            snPromotedFoldedPendingMessages(
                previousGroupIds: ["group-08", "group-09"],
                currentGroupIds: ["group-09"],
                messagesByChat: ["group-08": ["echo-08"]],
                liveFoldTarget: { $0 == "group-08" ? "group-09" : nil },
                idOf: { $0 }
            )["group-09"] == ["echo-08"]
        )
        #expect(
            snPromotedFoldedPendingMessages(
                previousGroupIds: [],
                currentGroupIds: ["group-09"],
                messagesByChat: ["group-08": ["echo-08"], "group-09": ["echo-09"]],
                liveFoldTarget: { $0 == "group-08" ? "group-09" : nil },
                idOf: { $0 }
            )["group-09"] == ["echo-09", "echo-08"]
        )
        #expect(
            snPromotedFoldedPendingMessages(
                previousGroupIds: [],
                currentGroupIds: ["group-09"],
                messagesByChat: ["group-08": ["echo-08"], "group-09": ["echo-08"]],
                liveFoldTarget: { $0 == "group-08" ? "group-09" : nil },
                idOf: { $0 }
            )["group-09"] == ["echo-08"]
        )
        #expect(
            snRemountedPendingUploadMediaKey(
                "group-08\u{1f}photo.jpg",
                historical: "group-08",
                live: "group-09"
            ) == "group-09\u{1f}photo.jpg"
        )
        #expect(
            snRemountedPendingUploadMediaKey(
                "group-09\u{1f}photo.jpg",
                historical: "group-08",
                live: "group-09"
            ) == "group-09\u{1f}photo.jpg"
        )
        let older = Date(timeIntervalSince1970: 1)
        let newer = Date(timeIntervalSince1970: 2)
        let historicalCall = SNCallRecord(
            id: "call-08",
            date: older,
            message: SNMessage(text: "", time: "00:01")
        )
        let liveCall = SNCallRecord(
            id: "call-09",
            date: newer,
            message: SNMessage(text: "", time: "00:02")
        )
        let promotedCalls = snPromotedFoldedCallLogs(
            previousGroupIds: ["group-08", "group-09"],
            currentGroupIds: ["group-09"],
            callLogs: ["group-08": [historicalCall], "group-09": [liveCall]],
            liveFoldTarget: { $0 == "group-08" ? "group-09" : nil }
        )
        #expect(promotedCalls["group-09"]?.map(\.id) == ["call-08", "call-09"])
        #expect(
            snPromotedFoldedVerifiedIds(
                previousGroupIds: ["group-08", "group-09"],
                currentGroupIds: ["group-09"],
                verifiedIds: ["group-08"],
                liveFoldTarget: { $0 == "group-08" ? "group-09" : nil }
            ) == ["group-08", "group-09"]
        )
        #expect(
            snPromotedFoldedVerifiedIds(
                previousGroupIds: [],
                currentGroupIds: ["group-09"],
                verifiedIds: ["group-08"],
                liveFoldTarget: { $0 == "group-08" ? "group-09" : nil }
            ) == ["group-08", "group-09"]
        )
        #expect(
            snRecoveredVerifiedIdsFromFolds(
                folds: ["group-08": "group-09"],
                verifiedIds: ["group-08"],
                historicalBlobVerified: { _ in false }
            ) == ["group-08", "group-09"]
        )
        #expect(
            snRecoveredVerifiedIdsFromFolds(
                folds: [:],
                verifiedIds: ["group-08"],
                historicalBlobVerified: { _ in false },
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            ) == ["group-08", "group-09"]
        )
        #expect(
            snRecoveredVerifiedIdsFromFolds(
                folds: [:],
                verifiedIds: [],
                historicalBlobVerified: { $0 == "group-08" },
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == ["group-08", "group-09"]
        )
        #expect(
            snRecoveredVerifiedIdsFromFolds(
                folds: [:],
                verifiedIds: ["group-08"],
                historicalBlobVerified: { _ in false }
            ) == ["group-08"]
        )
        #expect(
            snCollapsedFoldedSnapshotGroups(
                groups: ["group-08", "group-09"],
                id: { $0 },
                historicalFolds: ["group-08": "group-09"]
            ) == ["group-09"]
        )
        #expect(
            snCollapsedFoldedSnapshotGroups(
                groups: ["group-08"],
                id: { $0 },
                historicalFolds: ["group-08": "group-09"]
            ) == ["group-08"]
        )
        #expect(
            snLeaveFamilyCorePurgeIds(
                leaveId: "group-09",
                historicalFolds: ["group-08": "group-09"]
            ) == ["group-08"]
        )
        #expect(
            snLeaveFamilyCorePurgeIds(
                leaveId: "group-08",
                historicalFolds: ["group-08": "group-09"]
            ) == ["group-09"]
        )
        #expect(
            snLeaveFamilyCorePurgeIds(
                leaveId: "group-09",
                historicalFolds: [:]
            ).isEmpty
        )
        #expect(
            snDeletedConversationCorePurgeIds(
                listedIds: ["group-09"],
                historicalFolds: ["group-08": "group-09"]
            ) == ["group-08", "group-09"]
        )
        #expect(snCollapsedFoldDisplayName(liveName: "", historicalName: "Family") == "Family")
        #expect(snCollapsedFoldDisplayName(liveName: "new name", historicalName: "Family") == "new name")
        #expect(
            snCollapsedFoldDisplayMembers(
                liveMembers: ["npub1alice", "npub1bob"],
                historicalMembers: ["npub1alice", "npub1carol"]
            ) == ["npub1alice", "npub1bob", "npub1carol"]
        )
        let histGroup = MarmotService.MarmotGroup(
            id: "group-08",
            name: "Family",
            memberNpubs: ["npub1alice", "npub1bob", "npub1carol"],
            isDirect: false
        )
        let liveGroup = MarmotService.MarmotGroup(
            id: "group-09",
            name: "",
            memberNpubs: ["npub1alice", "npub1bob"],
            isDirect: false
        )
        let collapsedGroups = snCollapsedFoldedSnapshotGroups(
            groups: [histGroup, liveGroup],
            id: { $0.id },
            historicalFolds: ["group-08": "group-09"],
            mergeHiddenIntoLive: { live, historical in
                snCollapsedFoldDisplayGroup(live: live, historical: historical)
            }
        )
        #expect(collapsedGroups.map(\.id) == ["group-09"])
        #expect(collapsedGroups.first?.name == "Family")
        #expect(collapsedGroups.first?.memberNpubs == ["npub1alice", "npub1bob", "npub1carol"])
        #expect(collapsedGroups.first?.isDirect == false)
        #expect(
            snCollapsedFoldDisplayGroup(
                live: MarmotService.MarmotGroup(
                    id: "group-09",
                    name: "",
                    memberNpubs: ["npub1alice"],
                    isDirect: true
                ),
                historical: histGroup
            ).isDirect == true
        )
        #expect(
            Set(snMutedFoldKeys(
                groupIdHex: "group-09",
                historicalFolds: ["group-08": "group-09"]
            )) == [
                "group-08", "marmot:group-08",
                "group-09", "marmot:group-09",
            ]
        )
        #expect(
            Set(snMutedFoldKeys(
                groupIdHex: "group-08",
                historicalFolds: ["group-08": "group-09"]
            )) == [
                "group-08", "marmot:group-08",
                "group-09", "marmot:group-09",
            ]
        )
        #expect(snFoldFamilyIds(id: "group-09", historicalFolds: ["group-08": "group-09"]) == ["group-08", "group-09"])
        #expect(snFoldFamilyIds(id: "group-08", historicalFolds: ["group-08": "group-09"]) == ["group-08", "group-09"])
        #expect(snFoldFamilyIds(id: "group-09", historicalFolds: [:]) == ["group-09"])
        #expect(
            snFoldFamilyIds(
                id: "group-09",
                historicalFolds: [:],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            ) == ["group-08", "group-09"]
        )
        #expect(
            snFoldFamilyIds(
                id: "group-08",
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == ["group-08", "group-09"]
        )
        #expect(
            snFoldFamilyIds(
                id: "group-other",
                historicalFolds: [:],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            ) == ["group-other"]
        )
        let wakeFolds = snWakeMuteHistoricalFolds(
            persisted: [:],
            listedIds: ["group-09"],
            foldAliases: { $0 == "group-09" || $0 == "group-08" ? ["group-09", "group-08"] : [$0] },
            liveFoldTarget: { $0 == "group-08" || $0 == "group-09" ? "group-09" : nil }
        )
        #expect(wakeFolds == ["group-08": "group-09"])
        #expect(
            Set(snMutedFoldKeys(groupIdHex: "group-09", historicalFolds: wakeFolds)) == [
                "group-08", "marmot:group-08",
                "group-09", "marmot:group-09",
            ]
        )
        #expect(
            Set(snMutedFoldKeys(groupIdHex: "group-09", historicalFolds: [:])) == [
                "group-09", "marmot:group-09",
            ]
        )
        #expect(
            Set(snMutedFoldKeys(
                groupIdHex: "group-08",
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            )) == [
                "group-08", "marmot:group-08",
                "group-09", "marmot:group-09",
            ]
        )
        #expect(
            Set(snMutedFoldKeys(
                groupIdHex: "group-other",
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            )) == [
                "group-other", "marmot:group-other",
            ]
        )
        #expect(
            snPromotedFoldedMutesFromFolds(
                mutes: ["group-08": 50],
                historicalFolds: ["group-08": "group-09"]
            ) == ["group-08": 50, "group-09": 50]
        )
        #expect(
            snPromotedFoldedMutesFromFolds(
                mutes: ["group-08": 50],
                historicalFolds: [:],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            ) == ["group-08": 50, "group-09": 50]
        )
        #expect(
            snPromotedFoldedMutesFromFolds(
                mutes: ["group-08": 50],
                historicalFolds: [:]
            ) == ["group-08": 50]
        )
        #expect(
            snPromotedFoldedMutesFromFolds(
                mutes: ["group-08": 50, "group-09": 80],
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == ["group-08": 50, "group-09": 80]
        )
        #expect(snLeaveFamilyCorePurgeIds(leaveId: "group-09", historicalFolds: wakeFolds) == ["group-08"])
        #expect(snLeaveFamilyCorePurgeIds(leaveId: "group-09", historicalFolds: [:]).isEmpty)
        #expect(
            snLeaveFamilyCorePurgeIds(
                leaveId: "group-09",
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == ["group-08"]
        )
        #expect(
            snLeaveFamilyCorePurgeIds(
                leaveId: "group-09",
                historicalFolds: [:],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            ) == ["group-08"]
        )
        #expect(
            snLeaveFamilyCorePurgeIds(
                leaveId: "group-08",
                historicalFolds: [:],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            ) == ["group-09"]
        )
        #expect(
            snLeaveFamilyCorePurgeIds(
                leaveId: "group-other",
                historicalFolds: [:],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            ).isEmpty
        )
        #expect(
            snDeletedConversationCorePurgeIds(
                listedIds: ["group-09"],
                historicalFolds: wakeFolds
            ) == ["group-08", "group-09"]
        )
        #expect(
            snDeletedConversationCorePurgeIds(
                listedIds: ["group-09"],
                historicalFolds: [:]
            ) == ["group-09"]
        )
        #expect(
            snDeletedConversationCorePurgeIds(
                listedIds: ["group-09"],
                historicalFolds: [:],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            ) == ["group-08", "group-09"]
        )
        #expect(
            snDeletedConversationCorePurgeIds(
                listedIds: ["group-other"],
                historicalFolds: [:],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            ) == ["group-other"]
        )
        #expect(
            Set(snConversationReadGroupIds(groupId: "group-09", historicalFolds: wakeFolds))
                == ["group-08", "group-09"]
        )
        #expect(
            snConversationReadGroupIds(groupId: "group-09", historicalFolds: [:]) == ["group-09"]
        )
        #expect(
            snTranscriptSourceIds(
                groupId: "group-09",
                listedDirectIds: [],
                historicalFolds: wakeFolds
            ) == ["group-09", "group-08"]
        )
        #expect(
            snTranscriptSourceIds(
                groupId: "group-09",
                listedDirectIds: [],
                historicalFolds: [:]
            ) == ["group-09"]
        )
        #expect(snFirstOpenShouldMergeFolds(seedId: "group-09", persistedFolds: [:]))
        #expect(!snFirstOpenShouldMergeFolds(seedId: "group-09", persistedFolds: wakeFolds))
        #expect(!snFirstOpenShouldReuseCachedFoldMerge(
            seedId: "group-09",
            persistedFolds: [:],
            cachedSeeds: ["group-09"]
        ))
        #expect(snFirstOpenShouldReuseCachedFoldMerge(
            seedId: "group-09",
            persistedFolds: wakeFolds,
            cachedSeeds: ["group-09"]
        ))
        #expect(
            snRetainedTranscriptForChat(
                chatId: "group-09",
                retainedByChat: ["group-08": ["old from 0.8"]],
                historicalFolds: wakeFolds
            ) == ["old from 0.8"]
        )
        #expect(
            snRetainedTranscriptForChat(
                chatId: "group-09",
                retainedByChat: ["group-08": ["old from 0.8"]],
                historicalFolds: [:]
            ).isEmpty
        )
        #expect(
            snMediaFetchGroupIds(startGroupId: "group-09", historicalFolds: [:]) == ["group-09"]
        )
        #expect(
            snMediaFetchGroupIds(startGroupId: "group-09", historicalFolds: wakeFolds)
                == ["group-09", "group-08"]
        )
        #expect(
            !snNotificationClearIds(
                conversationId: "group-09",
                relatedIds: [],
                historicalFolds: [:]
            ).contains("group-08")
        )
        #expect(
            snNotificationClearIds(
                conversationId: "group-09",
                relatedIds: [],
                historicalFolds: [:],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            ).isSuperset(of: ["group-09", "group-08"])
        )
        #expect(
            snNotificationClearIds(
                conversationId: "group-09",
                relatedIds: [],
                historicalFolds: wakeFolds
            ).isSuperset(of: ["group-09", "group-08"])
        )
        #expect(
            SNUnreadCounts.remountFoldedUnread(
                next: [:],
                previous: [:],
                historicalFolds: wakeFolds
            ).isEmpty
        )
        #expect(
            SNUnreadCounts.remountFoldedUnread(
                next: [:],
                previous: ["group-08": 4],
                historicalFolds: wakeFolds
            )["group-08"] == 4
        )
        #expect(
            SNUnreadCounts.remountFoldedUnread(
                next: [:],
                previous: ["group-08": 4],
                historicalFolds: [:],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            )["group-08"] == 4
        )
        #expect(
            SNUnreadCounts.remountFoldedUnread(
                next: [:],
                previous: ["group-08": 4],
                historicalFolds: [:]
            ).isEmpty
        )
        #expect(SonarNSEDecoratePolicy.historicalFoldsUserDefaultsKey == snHistoricalFoldsDefaultsKey)
        #expect(
            Set(snMeshNotificationSuppressIds(
                groupId: "group-09",
                meshId: "mesh:peer",
                historicalFolds: ["group-08": "group-09"]
            )).isSuperset(of: ["group-08", "group-09", "mesh:peer"])
        )
        #expect(
            snNotificationClearIds(
                conversationId: "marmot:group-09",
                relatedIds: [],
                historicalFolds: ["group-08": "group-09"]
            ).isSuperset(of: [
                "marmot:group-09", "group-09",
                "marmot:group-08", "group-08",
            ])
        )
        #expect(
            snNotificationClearIds(
                conversationId: "mesh:peer",
                relatedIds: ["group-09"],
                historicalFolds: ["group-08": "group-09"]
            ).isSuperset(of: ["mesh:peer", "group-09", "group-08", "marmot:group-08"])
        )
        #expect(
            snTranscriptSourceIds(
                groupId: "group-09",
                listedDirectIds: ["group-09"],
                historicalFolds: ["group-08": "group-09"]
            ) == ["group-09", "group-08"]
        )
        #expect(
            snTranscriptSourceIds(
                groupId: "group-09",
                listedDirectIds: ["group-09"],
                historicalFolds: [:]
            ) == ["group-09"]
        )
        #expect(
            snUnreadForFoldFamily(
                groupId: "group-09",
                unreadByGroup: ["group-08": 3],
                historicalFolds: ["group-08": "group-09"]
            ) == 3
        )
        #expect(
            snUnreadForFoldFamily(
                groupId: "group-09",
                unreadByGroup: ["group-08": 3],
                historicalFolds: [:]
            ) == 0
        )
        #expect(
            snUnreadForFoldFamily(
                groupId: "group-09",
                unreadByGroup: ["group-08": 3, "group-09": 1],
                historicalFolds: ["group-08": "group-09"]
            ) == 4
        )
        #expect(
            snUnreadForFoldFamily(
                groupId: "group-09",
                unreadByGroup: ["group-09": 1],
                historicalFolds: ["group-08": "group-09"]
            ) == 1
        )
        // Room / persist-folds: listed live-only would miss bak remainder.
        // `localTranscriptGroups` / blank recovery page these same ids.
        #expect(
            snTranscriptSourceIds(
                groupId: "group-09",
                listedDirectIds: [],
                historicalFolds: ["group-08": "group-09"]
            ) == ["group-09", "group-08"]
        )
        #expect(
            snConversationReadGroupIds(
                groupId: "group-09",
                historicalFolds: ["group-08": "group-09"]
            ) == ["group-09", "group-08"],
            "in-chat mark-read must FFI both siblings before core fold_aliases exist"
        )
        #expect(
            snConversationReadGroupIds(
                groupId: "group-09",
                historicalFolds: [:]
            ) == ["group-09"]
        )
        // Remount remaps hist→live before persist-folds exist. Empty
        // persist must still page hidden hist so unread / load-older
        // do not retire on a short live page.
        #expect(
            snTranscriptSourceIds(
                groupId: "group-09",
                listedDirectIds: [],
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == ["group-09", "group-08"]
        )
        #expect(
            snTranscriptSourceIds(
                groupId: "group-other",
                listedDirectIds: [],
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == ["group-other"]
        )
        // Leftover `pendingMarmotRouteReplacement` after leave must not
        // keep paging hist+live as the open remount pair.
        let leftoverRemount = SNMarmotRouteReplacement(
            pendingId: "marmot:group-08",
            realId: "marmot:group-09"
        )
        let leftoverOpenedPane = snRemountPairOpenedPane(
            openedConversationId: nil,
            openedConversationPaneId: nil,
            routeReplacement: leftoverRemount
        )
        #expect(leftoverOpenedPane.opened == nil)
        #expect(leftoverOpenedPane.pane == nil)
        #expect(
            snTranscriptSourceIds(
                groupId: "group-09",
                listedDirectIds: [],
                historicalFolds: [:],
                openedConversationId: leftoverOpenedPane.opened,
                openedConversationPaneId: leftoverOpenedPane.pane
            ) == ["group-09"]
        )
        let openRemountFallback = snRemountPairOpenedPane(
            openedConversationId: "marmot:group-09",
            openedConversationPaneId: nil,
            routeReplacement: leftoverRemount
        )
        #expect(openRemountFallback.opened == "marmot:group-09")
        #expect(openRemountFallback.pane == "marmot:group-08")
        let unreadOnHist: [String: UInt64] = ["marmot:group-08": 3]
        let stampedUnread = snUnreadCountAtOpenWritten(
            conversationId: "marmot:group-08",
            count: 3,
            unreadAtOpen: [:],
            historicalFolds: [:],
            openedConversationId: "marmot:group-09",
            openedConversationPaneId: "marmot:group-08"
        )
        #expect(snUnreadCountAtOpen(
            conversationId: "marmot:group-09",
            unreadAtOpen: unreadOnHist,
            historicalFolds: [:],
            openedConversationId: "marmot:group-09",
            openedConversationPaneId: "marmot:group-08"
        ) == 3)
        #expect(snUnreadCountAtOpen(
            conversationId: "marmot:group-09",
            unreadAtOpen: stampedUnread,
            historicalFolds: [:],
            openedConversationId: "marmot:group-09",
            openedConversationPaneId: "marmot:group-08"
        ) == 3)
        #expect(
            snOpenChatUnreadPublishId(
                capturedFor: "marmot:group-08",
                openIds: ["marmot:group-09"],
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == "marmot:group-09"
        )
        #expect(
            snOpenChatUnreadPublishId(
                capturedFor: "marmot:group-08",
                openIds: ["marmot:other"],
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == nil
        )
        #expect(
            snConversationReadGroupIds(
                groupId: "group-09",
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == ["group-09", "group-08"]
        )
        #expect(
            snMeshFoldTranscriptSourceIds(
                listedDirectIds: ["group-09"],
                historicalFolds: [:],
                resolvedGroupId: "group-09",
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == ["group-09", "group-08"]
        )
        #expect(
            snExpectedNewestTsForChat(
                chatId: "group-09",
                messagesByChat: [:],
                latestByChat: ["group-09": 10],
                summaryLatestByChat: ["group-08": 50],
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == 50
        )
        #expect(
            snExpectedNewestTsForChat(
                chatId: "group-09",
                messagesByChat: [:],
                latestByChat: ["group-09": 10],
                summaryLatestByChat: ["group-08": 50],
                historicalFolds: [:]
            ) == 10,
            "home-row / NSE stay persist-only without a remount pair"
        )
        #expect(
            snMeshFoldTranscriptSourceIds(
                listedDirectIds: ["group-09"],
                historicalFolds: ["group-08": "group-09"]
            ) == ["group-09", "group-08"]
        )
        #expect(
            snMeshFoldTranscriptSourceIds(
                listedDirectIds: [],
                historicalFolds: ["group-08": "group-09"],
                resolvedGroupId: "group-09"
            ) == ["group-09", "group-08"]
        )
        #expect(
            snMeshFoldTranscriptSourceIds(
                listedDirectIds: ["group-09"],
                historicalFolds: [:]
            ) == ["group-09"]
        )
        #expect(
            snMeshFoldTranscriptSourceIds(
                listedDirectIds: [],
                historicalFolds: ["group-08": "group-09"]
            ).isEmpty
        )
        #expect(
            snMediaFetchGroupIds(
                startGroupId: "group-09",
                historicalFolds: ["group-08": "group-09"]
            ) == ["group-09", "group-08"]
        )
        #expect(
            snMediaFetchGroupIds(
                startGroupId: "group-08",
                historicalFolds: ["group-08": "group-09"]
            ) == ["group-08", "group-09"]
        )
        #expect(
            snMediaFetchGroupIds(
                startGroupId: "group-09",
                historicalFolds: [:]
            ) == ["group-09"]
        )
        #expect(
            snMediaFetchGroupIds(
                startGroupId: "",
                historicalFolds: ["group-08": "group-09"]
            ).isEmpty
        )
        let recoveredAttachment = MarmotService.MarmotMessage(
            id: "hist-media",
            senderNpub: "npub1peer",
            content: "",
            createdAt: Date(timeIntervalSince1970: 1),
            isMine: false,
            media: [
                MarmotService.MarmotMedia(
                    url: "https://blossom.example/old.jpg",
                    mimeType: "image/jpeg",
                    filename: "image.jpg",
                    width: 640,
                    height: 480,
                    durationMs: nil
                )
            ]
        )
        let liveOnly = [
            MarmotService.MarmotMessage(
                id: "l1",
                senderNpub: "npub1me",
                content: "new 0.9",
                createdAt: Date(timeIntervalSince1970: 100),
                isMine: true,
                media: []
            )
        ]
        #expect(
            snPublishedMediaUrlsFromMessages(liveOnly).isEmpty,
            "live-only page must not invent the recovered 0.8 URL"
        )
        #expect(
            snPublishedMediaUrlsFromFamilyPages(
                startGroupId: "group-09",
                historicalFolds: ["group-08": "group-09"],
                pageForId: { id in
                    id == "group-08" ? [recoveredAttachment] : liveOnly
                }
            ) == ["https://blossom.example/old.jpg"]
        )
        #expect(
            snPublishedMediaUrlsFromFamilyPages(
                startGroupId: "group-09",
                historicalFolds: [:],
                pageForId: { _ in liveOnly }
            ).isEmpty
        )
        #expect(
            snPublishedMediaScanRows(
                loaded: nil as [MarmotService.MarmotMessage]?,
                cached: [recoveredAttachment]
            ).map(\.id) == [recoveredAttachment.id]
        )
        #expect(
            snPublishedMediaScanRows(
                loaded: [] as [MarmotService.MarmotMessage],
                cached: [recoveredAttachment]
            ).map(\.id) == [recoveredAttachment.id],
            "empty FFI success on a folded hist id must keep cached 0.8 attachments"
        )
        #expect(
            snPublishedMediaScanRows(
                loaded: liveOnly,
                cached: [recoveredAttachment]
            ).map(\.id) == liveOnly.map(\.id) + [recoveredAttachment.id]
        )
        #expect(
            snBlankTranscriptKnownNonEmpty(
                groupId: "group-09",
                messageCountByGroup: ["group-08": 80],
                historicalFolds: ["group-08": "group-09"]
            )
        )
        #expect(
            !snBlankTranscriptKnownNonEmpty(
                groupId: "group-09",
                messageCountByGroup: ["group-08": 80],
                historicalFolds: [:]
            )
        )
        #expect(
            snBlankTranscriptKnownNonEmpty(
                groupId: "group-09",
                messageCountByGroup: [:],
                latestAtByGroup: ["group-09": 1_700_000_000],
                historicalFolds: ["group-08": "group-09"]
            )
        )
        #expect(
            !snBlankTranscriptKnownNonEmpty(
                groupId: "group-09",
                messageCountByGroup: [:],
                latestAtByGroup: ["group-09": 0],
                historicalFolds: ["group-08": "group-09"]
            )
        )
        // copy_summary leaves live message_count at 0. Home paint must still
        // use latestAt — otherwise process-death buries the remounted row.
        let copied = MarmotService.ConversationSummary(
            groupIdHex: "group-09",
            name: "",
            latestContent: "recovered latest",
            latestSenderNpub: "npub1peer",
            latestAt: Date(timeIntervalSince1970: 1_700_000_000),
            latestMine: false,
            messageCount: 0,
            unreadCount: 0
        )
        #expect(snMarmotHomeRowSummaryKnownNonEmpty(copied))
        #expect(snMarmotHomeRowMessage(loaded: nil, summary: copied)?.content == "recovered latest")
        #expect(
            snMarmotHomeRowMessage(loaded: nil, summary: copied)?.createdAt == copied.latestAt
        )
        let emptyLatest = MarmotService.ConversationSummary(
            groupIdHex: "group-09",
            name: "",
            latestContent: "",
            latestSenderNpub: "",
            latestAt: Date(timeIntervalSince1970: 0),
            latestMine: false,
            messageCount: 0,
            unreadCount: 0
        )
        #expect(!snMarmotHomeRowSummaryKnownNonEmpty(emptyLatest))
        let histSummary = MarmotService.ConversationSummary(
            groupIdHex: "group-08",
            name: "",
            latestContent: "keep this chat",
            latestSenderNpub: "npub1peer",
            latestAt: Date(timeIntervalSince1970: 50),
            latestMine: false,
            messageCount: 80,
            unreadCount: 4
        )
        #expect(
            snHomeRowSummaryForChat(
                groupId: "group-09",
                summaries: ["group-08": histSummary],
                historicalFolds: ["group-08": "group-09"]
            )?.latestContent == "keep this chat"
        )
        #expect(
            snHomeRowSummaryForChat(
                groupId: "group-09",
                summaries: ["group-08": histSummary],
                historicalFolds: [:],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            )?.latestContent == "keep this chat"
        )
        #expect(
            snHomeRowSummaryForChat(
                groupId: "group-09",
                summaries: ["group-08": histSummary],
                historicalFolds: [:]
            ) == nil
        )
        #expect(snMarmotHomeRowMessage(loaded: nil, summary: emptyLatest) == nil)
        #expect(
            snBlankTranscriptFamilyRendered(
                groupId: "group-09",
                messagesByGroup: ["group-08": ["old from 0.8"]],
                historicalFolds: ["group-08": "group-09"]
            )
        )
        #expect(
            !snBlankTranscriptFamilyRendered(
                groupId: "group-09",
                messagesByGroup: ["group-08": ["old from 0.8"]],
                historicalFolds: [:]
            )
        )
        #expect(
            !snFamilyTranscriptNeedsNetworkBackfill(
                groupId: "group-09",
                messagesByGroup: ["group-08": ["old from 0.8"]],
                historicalFolds: ["group-08": "group-09"]
            )
        )
        #expect(
            snFamilyTranscriptNeedsNetworkBackfill(
                groupId: "group-09",
                messagesByGroup: ["group-08": ["old from 0.8"]],
                historicalFolds: [:]
            )
        )
        #expect(
            !snFamilyTranscriptNeedsNetworkBackfill(
                groupId: "group-09",
                messagesByGroup: ["group-08": ["old from 0.8"]],
                historicalFolds: [:],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            )
        )
        #expect(
            snFamilyTranscriptNeedsNetworkBackfill(
                groupId: "group-other",
                messagesByGroup: ["group-08": ["old from 0.8"]],
                historicalFolds: [:],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            )
        )
        #expect(
            snBlankTranscriptFamilyRendered(
                groupId: "group-09",
                messagesByGroup: ["group-08": ["old from 0.8"]],
                historicalFolds: [:],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            )
        )
        #expect(
            !snBlankTranscriptKnownNonEmpty(
                groupId: "group-09",
                messageCountByGroup: ["group-08": 80],
                historicalFolds: [:]
            )
        )
        #expect(
            snBlankTranscriptKnownNonEmpty(
                groupId: "group-09",
                messageCountByGroup: ["group-08": 80],
                historicalFolds: [:],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            )
        )
        #expect(
            snFamilyTranscriptNeedsNetworkBackfill(
                groupId: "group-09",
                messagesByGroup: [:],
                historicalFolds: ["group-08": "group-09"]
            )
        )
        #expect(
            snUnreadForFoldFamily(
                groupId: "group-09",
                unreadByGroup: [:],
                historicalFolds: ["group-08": "group-09"]
            ) == 0
        )
        #expect(
            snVerifiedForFoldFamily(
                groupId: "group-09",
                verifiedIds: Set(["group-08"]),
                historicalFolds: ["group-08": "group-09"]
            )
        )
        #expect(
            !snVerifiedForFoldFamily(
                groupId: "group-09",
                verifiedIds: Set(["group-08"]),
                historicalFolds: [:]
            )
        )
        #expect(
            snHydrationTargetGroupId(
                sourceId: "group-08",
                activeGroupIds: ["group-09"],
                historicalFolds: ["group-08": "group-09"]
            ) == "group-09"
        )
        #expect(
            snHydrationTargetGroupId(
                sourceId: "group-09",
                activeGroupIds: ["group-09"],
                historicalFolds: ["group-08": "group-09"]
            ) == "group-09"
        )
        #expect(
            snHydrationTargetGroupId(
                sourceId: "group-08",
                activeGroupIds: ["group-09"],
                historicalFolds: [:]
            ) == nil
        )
        #expect(
            snHydrationTargetGroupId(
                sourceId: "group-08",
                activeGroupIds: ["group-09"],
                historicalFolds: [:],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            ) == "group-09"
        )
        let remountedExtract = (1...80).map { "hist-\($0)" }
        #expect(snHydrationHasRealTranscriptRows(rows: remountedExtract, idOf: { $0 }))
        #expect(!snHydrationHasRealTranscriptRows(rows: ["summary:group-09:200:1"], idOf: { $0 }))
        #expect(!snHydrationHasRealTranscriptRows(rows: [], idOf: { $0 }))
        let histMsg = MarmotService.MarmotMessage(
            id: "hist-1",
            senderNpub: "npub1peer",
            content: "old",
            createdAt: Date(timeIntervalSince1970: 1),
            isMine: false,
            media: []
        )
        let liveMsg = MarmotService.MarmotMessage(
            id: "live-1",
            senderNpub: "npub1me",
            content: "resumed",
            createdAt: Date(timeIntervalSince1970: 200),
            isMine: true,
            media: []
        )
        let synthetic = MarmotService.MarmotMessage(
            id: "summary:group-09:200:1",
            senderNpub: "npub1me",
            content: "resumed",
            createdAt: Date(timeIntervalSince1970: 200),
            isMine: true,
            media: []
        )
        #expect(
            snHydrateMergedPageRows(existing: [histMsg], incoming: [liveMsg]).map(\.id)
                == ["hist-1", "live-1"]
        )
        #expect(
            snHydrateMergedPageRows(existing: [synthetic, histMsg], incoming: [liveMsg]).map(\.id)
                == ["hist-1", "live-1"]
        )
        let histPreview = MarmotService.ConversationSummary(
            groupIdHex: "group-08",
            name: "",
            latestContent: "keep this chat",
            latestSenderNpub: "npub1peer",
            latestAt: Date(timeIntervalSince1970: 100),
            latestMine: false,
            messageCount: 3,
            unreadCount: 3
        )
        let remounted = snRemountedConversationSummaries(
            summaries: [histPreview],
            activeGroupIds: ["group-09"],
            historicalFolds: ["group-08": "group-09"]
        )
        #expect(remounted["group-09"]?.latestContent == "keep this chat")
        #expect(remounted["group-09"]?.groupIdHex == "group-09")
        #expect(remounted["group-08"] == nil)
        let liveNewer = MarmotService.ConversationSummary(
            groupIdHex: "group-09",
            name: "",
            latestContent: "already on live",
            latestSenderNpub: "npub1peer",
            latestAt: Date(timeIntervalSince1970: 200),
            latestMine: true,
            messageCount: 1,
            unreadCount: 0
        )
        let keptLive = snRemountedConversationSummaries(
            summaries: [histPreview, liveNewer],
            activeGroupIds: ["group-09"],
            historicalFolds: ["group-08": "group-09"]
        )
        #expect(keptLive["group-09"]?.latestContent == "already on live")
        let namedHist = MarmotService.ConversationSummary(
            groupIdHex: "group-08",
            name: "standup",
            latestContent: "keep this chat",
            latestSenderNpub: "npub1peer",
            latestAt: Date(timeIntervalSince1970: 100),
            latestMine: false,
            messageCount: 3,
            unreadCount: 3
        )
        let namedOntoLive = snRemountedConversationSummaries(
            summaries: [liveNewer],
            activeGroupIds: ["group-09"],
            historicalFolds: ["group-08": "group-09"],
            previous: ["group-08": namedHist]
        )
        #expect(namedOntoLive["group-09"]?.latestContent == "already on live")
        #expect(namedOntoLive["group-09"]?.name == "standup")
        let liveHidden = MarmotService.ConversationSummary(
            groupIdHex: "group-09",
            name: "",
            latestContent: "",
            latestSenderNpub: "npub1peer",
            latestAt: Date(timeIntervalSince1970: 0),
            latestMine: false,
            messageCount: 0,
            unreadCount: 0
        )
        let keptHist = snRemountedConversationSummaries(
            summaries: [liveHidden],
            activeGroupIds: ["group-09"],
            historicalFolds: ["group-08": "group-09"],
            previous: ["group-08": histPreview]
        )
        #expect(keptHist["group-08"]?.latestAt == histPreview.latestAt)
        #expect(keptHist["group-09"]?.latestAt == histPreview.latestAt)
        #expect(keptHist["group-09"]?.latestContent == "keep this chat")
        #expect(keptHist["group-09"]?.unreadCount == 0)
        let remountKeptHist = snRemountedConversationSummaries(
            summaries: [liveHidden],
            activeGroupIds: ["group-09"],
            historicalFolds: [:],
            previous: ["group-08": histPreview],
            openedConversationId: "group-09",
            openedConversationPaneId: "group-08"
        )
        #expect(remountKeptHist["group-08"]?.latestAt == histPreview.latestAt)
        #expect(remountKeptHist["group-09"]?.latestAt == histPreview.latestAt)
        #expect(
            snRemountedConversationSummaries(
                summaries: [liveHidden],
                activeGroupIds: ["group-09"],
                historicalFolds: [:],
                previous: ["group-08": histPreview]
            )["group-08"] == nil
        )
        #expect(
            snRemountPairHistoricalFolds(
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == ["group-08": "group-09"]
        )
        #expect(snRemountPairHistoricalFolds(historicalFolds: [:]).isEmpty)
        #expect(
            snRemountedConversationSummaries(
                summaries: [],
                activeGroupIds: ["group-09"],
                historicalFolds: ["group-08": "group-09"],
                previous: ["group-08": histPreview]
            ).isEmpty
        )
        #expect(
            snFoldFamilyCachedMessages(
                groupId: "group-09",
                messagesByGroup: ["group-08": ["keep this chat"]],
                historicalFolds: ["group-08": "group-09"],
                idOf: { $0 }
            ) == ["keep this chat"]
        )
        #expect(
            snFoldFamilyCachedMessages(
                groupId: "group-09",
                messagesByGroup: ["group-09": ["already on live"], "group-08": ["keep this chat"]],
                historicalFolds: ["group-08": "group-09"],
                idOf: { $0 }
            ) == ["already on live", "keep this chat"]
        )
        #expect(
            snFoldFamilyCachedMessages(
                groupId: "group-09",
                messagesByGroup: ["group-09": ["already on live"], "group-08": ["keep this chat"]],
                historicalFolds: [:],
                idOf: { $0 }
            ) == ["already on live"]
        )
        #expect(
            snFoldFamilyCachedMessages(
                groupId: "group-09",
                messagesByGroup: ["group-09": ["already on live"], "group-08": ["keep this chat"]],
                historicalFolds: [:],
                idOf: { $0 },
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            ) == ["already on live", "keep this chat"]
        )
        #expect(
            snConversationRefreshIds(
                changedGroupId: "group-08",
                listedGroupIds: ["group-09"],
                historicalFolds: ["group-08": "group-09"]
            ) == ["group-08", "group-09"]
        )
        #expect(
            snConversationRefreshIds(
                changedGroupId: "group-09",
                listedGroupIds: ["group-09"],
                historicalFolds: ["group-08": "group-09"]
            ) == ["group-09"]
        )
        #expect(
            snConversationRefreshIds(
                changedGroupId: "group-09",
                listedGroupIds: ["group-09"],
                historicalFolds: [:]
            ) == ["group-09"]
        )
        #expect(
            snConversationRefreshIds(
                changedGroupId: "group-08",
                listedGroupIds: ["group-09"],
                historicalFolds: [:]
            ) == ["group-08"]
        )
        #expect(
            snConversationRefreshIds(
                changedGroupId: "group-08",
                listedGroupIds: ["group-09"],
                historicalFolds: [:],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            ) == ["group-08", "group-09"]
        )
        #expect(snConversationRefreshShouldMergeFolds(
            changedGroupIds: ["group-09"],
            persistedFolds: [:]
        ))
        #expect(!snConversationRefreshShouldMergeFolds(
            changedGroupIds: ["group-09"],
            persistedFolds: ["group-08": "group-09"]
        ))
        #expect(!snViewingConversationShouldMarkRead(
            viewingGroupIds: ["group-08"],
            changedGroupId: "group-09",
            refreshId: "group-09",
            historicalFolds: [:]
        ))
        #expect(snViewingConversationShouldMarkRead(
            viewingGroupIds: ["group-08"],
            changedGroupId: "group-09",
            refreshId: "group-09",
            historicalFolds: ["group-08": "group-09"]
        ))
        #expect(snViewingConversationShouldMarkRead(
            viewingGroupIds: ["group-09"],
            changedGroupId: "group-09",
            refreshId: "group-09",
            historicalFolds: [:]
        ))
        #expect(snViewingConversationShouldMarkRead(
            viewingGroupIds: ["group-08"],
            changedGroupId: "group-09",
            refreshId: "group-09",
            historicalFolds: [:],
            openedConversationId: "group-09",
            openedConversationPaneId: "group-08"
        ))
        #expect(!snViewingConversationShouldMarkRead(
            viewingGroupIds: ["other"],
            changedGroupId: "group-09",
            refreshId: "group-09",
            historicalFolds: [:],
            openedConversationId: "group-09",
            openedConversationPaneId: "group-08"
        ))
        // First-resume send echoes on hist; the relay copy lands on live.
        #expect(
            snOptimisticFreshCanonicalRows(
                echoGroupId: "group-08",
                freshRowsByGroup: ["group-09": ["canonical-09"]],
                cachedRowsByGroup: ["group-08": ["optimistic-1"]],
                historicalFolds: [:],
                isLocalEcho: { $0.hasPrefix("optimistic-") },
                idOf: { $0 }
            ).isEmpty
        )
        #expect(
            snOptimisticFreshCanonicalRows(
                echoGroupId: "group-08",
                freshRowsByGroup: ["group-09": ["canonical-09"]],
                cachedRowsByGroup: ["group-08": ["optimistic-1"]],
                historicalFolds: [:],
                isLocalEcho: { $0.hasPrefix("optimistic-") },
                idOf: { $0 },
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            ) == ["canonical-09"]
        )
        #expect(
            snOptimisticFreshCanonicalRows(
                echoGroupId: "group-08",
                freshRowsByGroup: ["group-09": ["canonical-09"]],
                cachedRowsByGroup: ["group-08": ["optimistic-1"]],
                historicalFolds: ["group-08": "group-09"],
                isLocalEcho: { $0.hasPrefix("optimistic-") },
                idOf: { $0 }
            ) == ["canonical-09"]
        )
        let stripped = snTranscriptsAfterOptimisticReconcile(
            echoGroupId: "group-08",
            messagesByGroup: [
                "group-08": ["optimistic-1"],
                "group-09": ["canonical-09", "optimistic-1"]
            ],
            pendingIds: ["optimistic-1"],
            survivorIds: [],
            visible: ["canonical-09"],
            historicalFolds: ["group-08": "group-09"],
            idOf: { $0 }
        )
        #expect(stripped["group-08"] == ["canonical-09"])
        #expect(stripped["group-09"] == ["canonical-09"])
        let remountStripped = snTranscriptsAfterOptimisticReconcile(
            echoGroupId: "group-09",
            messagesByGroup: [
                "group-08": ["optimistic-1"],
                "group-09": ["canonical-09", "optimistic-1"]
            ],
            pendingIds: ["optimistic-1"],
            survivorIds: [],
            visible: ["canonical-09"],
            historicalFolds: [:],
            idOf: { $0 },
            openedConversationId: "group-09",
            openedConversationPaneId: "group-08"
        )
        #expect(!(remountStripped["group-08"] ?? []).contains("optimistic-1"))
        #expect(remountStripped["group-09"] == ["canonical-09"])
        #expect(
            snRemountedOptimisticPending(
                pendingByGroup: ["group-08": ["optimistic-1"]],
                historicalGroupId: "group-08",
                liveGroupId: "group-09",
                idOf: { $0 }
            ) == ["group-09": ["optimistic-1"]]
        )
        // Remount moved the echo to live; send closure still names hist.
        #expect(
            snOptimisticPendingLookupIds(
                sendGroupId: "group-08",
                echoId: "optimistic-1",
                pendingByGroup: ["group-09": ["optimistic-1"]],
                historicalFolds: ["group-08": "group-09"]
            ) == Set(["group-08", "group-09"])
        )
        #expect(
            snOptimisticPendingStoreId(
                sendGroupId: "group-08",
                echoId: "optimistic-1",
                pendingByGroup: ["group-09": ["optimistic-1"]],
                historicalFolds: ["group-08": "group-09"]
            ) == "group-09"
        )
        #expect(
            snOptimisticPendingLookupIds(
                sendGroupId: "group-08",
                echoId: "optimistic-1",
                pendingByGroup: ["group-09": ["optimistic-1"]],
                historicalFolds: [:]
            ) == Set(["group-08", "group-09"])
        )
        #expect(
            snOptimisticPendingStoreId(
                sendGroupId: "group-08",
                echoId: "optimistic-1",
                pendingByGroup: ["group-09": ["optimistic-1"]],
                historicalFolds: [:]
            ) == "group-09"
        )
        #expect(
            snOptimisticPendingStoreId(
                sendGroupId: "group-08",
                echoId: "optimistic-1",
                pendingByGroup: ["group-08": ["optimistic-1"]],
                historicalFolds: [:]
            ) == "group-08"
        )
        #expect(
            snOptimisticPendingLookupIds(
                sendGroupId: "group-08",
                echoId: "optimistic-1",
                pendingByGroup: ["group-08": ["optimistic-1"]],
                historicalFolds: [:],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            ) == Set(["group-08", "group-09"])
        )
        #expect(
            snOptimisticPendingStoreId(
                sendGroupId: "group-08",
                echoId: "optimistic-1",
                pendingByGroup: ["group-08": ["optimistic-1"]],
                historicalFolds: [:],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            ) == "group-09"
        )
        #expect(
            snOptimisticPendingStoreId(
                sendGroupId: "group-09",
                echoId: "optimistic-1",
                pendingByGroup: ["group-09": ["optimistic-1"]],
                historicalFolds: [:],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            ) == "group-09"
        )
        #expect(snConversationOpenShouldMergeFolds(
            openId: "marmot:group-08",
            incomingId: "marmot:group-09",
            persistedFolds: [:]
        ))
        #expect(!snConversationOpenShouldMergeFolds(
            openId: "marmot:group-08",
            incomingId: "marmot:group-09",
            persistedFolds: ["group-08": "group-09"]
        ))
        #expect(!snConversationOpenShouldMergeFolds(
            openId: "marmot:group-08",
            incomingId: "marmot:group-08",
            persistedFolds: [:]
        ))
        #expect(!snConversationOpenShouldMergeFolds(
            openId: "marmot:group-09",
            incomingId: "marmot:other",
            persistedFolds: ["group-08": "group-09"]
        ))
        #expect(!snNotificationOpenShouldJump(
            openId: "marmot:group-08",
            incomingId: "marmot:group-09",
            historicalFolds: [:]
        ))
        #expect(snNotificationOpenShouldJump(
            openId: "marmot:group-09",
            incomingId: "marmot:group-08",
            historicalFolds: [:],
            openedConversationId: "marmot:group-09",
            openedConversationPaneId: "marmot:group-08"
        ))
        #expect(snNotificationOpenShouldJump(
            openId: "marmot:group-08",
            incomingId: "marmot:group-09",
            historicalFolds: ["group-08": "group-09"]
        ))
        #expect(snNotificationOpenShouldJump(
            openId: "group-08",
            incomingId: "group-09",
            historicalFolds: ["group-08": "group-09"]
        ))
        #expect(!snNotificationOpenShouldJump(
            openId: "marmot:group-08",
            incomingId: "marmot:other",
            historicalFolds: ["group-08": "group-09"]
        ))
        #expect(snCurrentOpenConversationId(
            pathDMId: nil,
            openedConversationId: "marmot:group-08"
        ) == "marmot:group-08")
        #expect(snCurrentOpenConversationId(
            pathDMId: "marmot:group-08",
            openedConversationId: "marmot:group-09"
        ) == "marmot:group-09")
        #expect(snCurrentOpenConversationId(
            pathDMId: nil,
            openedConversationId: nil
        ) == nil)
        #expect(snOpenedDMShouldSkipHydrate(
            openingId: "marmot:group-09",
            suppressedIds: ["marmot:group-09", "group-09"]
        ))
        #expect(snOpenedDMShouldSkipHydrate(
            openingId: "group-09",
            suppressedIds: ["marmot:group-09"]
        ))
        #expect(!snOpenedDMShouldSkipHydrate(
            openingId: "marmot:other",
            suppressedIds: ["marmot:group-09"]
        ))
        let remountReplacement = SNMarmotRouteReplacement(
            pendingId: "marmot:group-08",
            realId: "marmot:group-09"
        )
        #expect(
            snOpenedDMRemountOpenedPane(
                openingId: "marmot:group-08",
                routeReplacement: remountReplacement
            ) == (opened: "marmot:group-09", pane: "marmot:group-08")
        )
        #expect(
            snOpenedDMRemountOpenedPane(
                openingId: "group-08",
                routeReplacement: remountReplacement
            ) == (opened: "marmot:group-09", pane: "marmot:group-08")
        )
        #expect(
            snOpenedDMRemountOpenedPane(
                openingId: "marmot:group-09",
                routeReplacement: remountReplacement
            ) == (opened: "marmot:group-09", pane: "marmot:group-08")
        )
        #expect(
            snOpenedDMRemountOpenedPane(
                openingId: "marmot:other",
                routeReplacement: remountReplacement
            ) == (opened: "marmot:other", pane: "marmot:other")
        )
        #expect(
            snOpenedDMRemountOpenedPane(
                openingId: "marmot:group-08",
                routeReplacement: nil
            ) == (opened: "marmot:group-08", pane: "marmot:group-08")
        )
        let remountKeys = snRemountOpeningHydrateKeys(
            openId: "marmot:group-08",
            groupId: "group-08",
            liveId: "marmot:group-09",
            liveGroupId: "group-09"
        )
        #expect(snOpenedDMShouldSkipHydrate(openingId: "marmot:group-08", suppressedIds: remountKeys))
        #expect(snOpenedDMShouldSkipHydrate(openingId: "group-08", suppressedIds: remountKeys))
        #expect(snOpenedDMShouldSkipHydrate(openingId: "marmot:group-09", suppressedIds: remountKeys))
        #expect(!snOpenedDMShouldSkipHydrate(openingId: "marmot:other", suppressedIds: remountKeys))
        let stampedEmpty = snRemountMarksTranscriptHydrated(
            historicalId: "marmot:group-08",
            liveId: "marmot:group-09",
            hydratedIds: []
        )
        #expect(snOpenedDMShouldSkipHydrate(openingId: "marmot:group-09", suppressedIds: stampedEmpty))
        #expect(snOpenedDMShouldSkipHydrate(openingId: "group-09", suppressedIds: stampedEmpty))
        #expect(!snOpenedDMShouldSkipHydrate(openingId: "marmot:group-08", suppressedIds: stampedEmpty))
        let stampedKeep = snRemountMarksTranscriptHydrated(
            historicalId: "marmot:group-08",
            liveId: "marmot:group-09",
            hydratedIds: ["marmot:group-08", "other"]
        )
        #expect(snOpenedDMShouldSkipHydrate(openingId: "marmot:group-09", suppressedIds: stampedKeep))
        #expect(stampedKeep.contains("other"))
        #expect(!snOpenedDMShouldSkipHydrate(openingId: "marmot:group-08", suppressedIds: stampedKeep))
        #expect(snRemountLocalHydratingIds(
            historicalKeys: ["marmot:group-08", "group-08"],
            liveKeys: ["marmot:group-09", "group-09"],
            hydrating: ["marmot:group-08", "other"]
        ) == ["marmot:group-09", "group-09", "other"])
        #expect(snRemountLocalHydratingIds(
            historicalKeys: ["marmot:group-08", "group-08"],
            liveKeys: ["marmot:group-09", "group-09"],
            hydrating: []
        ).isEmpty)
        #expect(snRemountStableTranscriptSessionKey(
            previousKey: "marmot:group-08",
            screenId: "marmot:group-09",
            historicalFolds: ["group-08": "group-09"]
        ) == "marmot:group-08")
        #expect(snRemountStableTranscriptSessionKey(
            previousKey: "marmot:group-08",
            screenId: "marmot:other",
            historicalFolds: ["group-08": "group-09"]
        ) == "marmot:other")
        #expect(snRemountStableTranscriptSessionKey(
            previousKey: "marmot:group-08",
            screenId: "marmot:group-09",
            historicalFolds: [:]
        ) == "marmot:group-09")
        #expect(snRemountStableTranscriptSessionKey(
            previousKey: "marmot:group-08",
            screenId: "marmot:group-09",
            historicalFolds: [:],
            openedConversationId: "marmot:group-09",
            openedConversationPaneId: "marmot:group-08"
        ) == "marmot:group-08")
        #expect(snRemountStableTranscriptSessionKey(
            previousKey: "marmot:group-08",
            screenId: "marmot:other",
            historicalFolds: [:],
            openedConversationId: "marmot:group-09",
            openedConversationPaneId: "marmot:group-08"
        ) == "marmot:other")
        let stampedUnreadAtOpen = snUnreadCountAtOpenWritten(
            conversationId: "marmot:group-09",
            count: 3,
            unreadAtOpen: [:],
            historicalFolds: [:],
            openedConversationId: "marmot:group-09",
            openedConversationPaneId: "marmot:group-08"
        )
        var liveOnlyUnreadLeave = stampedUnreadAtOpen
        liveOnlyUnreadLeave["marmot:group-09"] = nil
        #expect(snUnreadCountAtOpen(
            conversationId: "marmot:group-09",
            unreadAtOpen: liveOnlyUnreadLeave,
            historicalFolds: [:],
            openedConversationId: "marmot:group-09",
            openedConversationPaneId: "marmot:group-08"
        ) == 3)
        let clearedUnreadAtOpen = snUnreadCountAtOpenWritten(
            conversationId: "marmot:group-09",
            count: nil,
            unreadAtOpen: stampedUnreadAtOpen,
            historicalFolds: [:],
            openedConversationId: "marmot:group-09",
            openedConversationPaneId: "marmot:group-08"
        )
        #expect(snUnreadCountAtOpen(
            conversationId: "marmot:group-09",
            unreadAtOpen: clearedUnreadAtOpen,
            historicalFolds: [:],
            openedConversationId: "marmot:group-09",
            openedConversationPaneId: "marmot:group-08"
        ) == nil)
        #expect(snUnreadCountAtOpen(
            conversationId: "marmot:group-08",
            unreadAtOpen: clearedUnreadAtOpen,
            historicalFolds: [:],
            openedConversationId: "marmot:group-09",
            openedConversationPaneId: "marmot:group-08"
        ) == nil)
        #expect(snMacConversationPaneIdentity(
            selectionId: "marmot:group-09",
            openedConversationId: "marmot:group-09",
            openedConversationPaneId: "marmot:group-08"
        ) == "marmot:group-08")
        #expect(snMacConversationPaneIdentity(
            selectionId: "marmot:other",
            openedConversationId: "marmot:group-09",
            openedConversationPaneId: "marmot:group-08"
        ) == "marmot:other")
        #expect(snClosedDMShouldSkipFoldRemountHop(
            closingId: "marmot:group-08",
            pathDMId: "marmot:group-09",
            openedConversationId: "marmot:group-09",
            routeReplacement: SNMarmotRouteReplacement(
                pendingId: "marmot:group-08",
                realId: "marmot:group-09"
            )
        ))
        #expect(!snClosedDMShouldSkipFoldRemountHop(
            closingId: "marmot:group-08",
            pathDMId: "marmot:group-08",
            openedConversationId: "marmot:group-09",
            routeReplacement: SNMarmotRouteReplacement(
                pendingId: "marmot:group-08",
                realId: "marmot:group-09"
            )
        ))
        #expect(!snClosedDMShouldSkipFoldRemountHop(
            closingId: "marmot:group-09",
            pathDMId: "marmot:group-09",
            openedConversationId: "marmot:group-09",
            routeReplacement: SNMarmotRouteReplacement(
                pendingId: "marmot:group-08",
                realId: "marmot:group-09"
            )
        ))
        #expect(
            snRemountFoldedPath(
                path: [
                    .dm("marmot:group-08"),
                    .groupInfo("marmot:group-08"),
                ],
                listedGroupIds: ["group-09"],
                liveFoldTarget: { _ in "group-09" },
                preserveIds: ["marmot:group-08"]
            ) == [
                .dm("marmot:group-08"),
                .groupInfo("marmot:group-09"),
            ]
        )
        #expect(snRemountShouldPreserveOpenTranscriptRoute(
            routeId: "marmot:group-08",
            preserveIds: ["group-08"]
        ))
        #expect(snPendingMediaPreviewBelongsToChat(
            previewPeerId: "marmot:group-09",
            chatId: "marmot:group-08",
            openedConversationId: "marmot:group-09",
            openedConversationPaneId: "marmot:group-08",
            historicalFolds: [:]
        ))
        #expect(snPendingMediaPreviewBelongsToChat(
            previewPeerId: "marmot:group-09",
            chatId: "marmot:group-08",
            openedConversationId: nil,
            openedConversationPaneId: nil,
            historicalFolds: ["group-08": "group-09"]
        ))
        #expect(!snPendingMediaPreviewBelongsToChat(
            previewPeerId: "marmot:other",
            chatId: "marmot:group-08",
            openedConversationId: "marmot:group-09",
            openedConversationPaneId: "marmot:group-08",
            historicalFolds: ["group-08": "group-09"]
        ))
        #expect(snPendingMediaPreviewBelongsToChat(
            previewPeerId: "marmot:group-08",
            chatId: "marmot:group-09",
            openedConversationId: "marmot:group-09",
            openedConversationPaneId: "marmot:group-08",
            historicalFolds: [:]
        ))
        #expect(!snPendingMediaPreviewBelongsToChat(
            previewPeerId: "marmot:group-08",
            chatId: "marmot:group-09",
            openedConversationId: nil,
            openedConversationPaneId: nil,
            historicalFolds: [:]
        ))
        #expect(
            snPromotedFoldedPendingMediaPreviewPeerId(
                peerId: "marmot:group-08",
                historicalFolds: ["group-08": "group-09"]
            ) == "marmot:group-09"
        )
        #expect(
            snPromotedFoldedPendingMediaPreviewPeerId(
                peerId: "marmot:group-08",
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == "marmot:group-09"
        )
        #expect(
            snPromotedFoldedPendingMediaPreviewPeerId(
                peerId: "marmot:group-08",
                historicalFolds: [:]
            ) == "marmot:group-08"
        )
        #expect(
            snPromotedFoldedPendingMediaPreviewPeerId(
                peerId: "marmot:group-09",
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == "marmot:group-09"
        )
        #expect(snClosedDMShouldClearOpened(
            closingId: "marmot:group-08",
            openedConversationId: "marmot:group-09",
            openedConversationPaneId: "marmot:group-08"
        ))
        #expect(snClosedDMShouldClearOpened(
            closingId: "group-08",
            openedConversationId: "marmot:group-09",
            openedConversationPaneId: "marmot:group-08"
        ))
        #expect(!snClosedDMShouldClearOpened(
            closingId: "marmot:other",
            openedConversationId: "marmot:group-09",
            openedConversationPaneId: "marmot:group-08"
        ))
        #expect(snClosedDMShouldClearOpened(
            closingId: "marmot:group-09",
            openedConversationId: "marmot:group-09",
            openedConversationPaneId: "marmot:group-09"
        ))
        let leftoverRoute = SNMarmotRouteReplacement(
            pendingId: "marmot:group-08",
            realId: "marmot:group-09"
        )
        #expect(snClosedDMShouldClearPendingRouteReplacement(
            closingId: "marmot:group-09",
            openedConversationId: "marmot:group-09",
            openedConversationPaneId: "marmot:group-08",
            routeReplacement: leftoverRoute
        ))
        #expect(snClosedDMShouldClearPendingRouteReplacement(
            closingId: "marmot:group-08",
            openedConversationId: "marmot:group-09",
            openedConversationPaneId: "marmot:group-08",
            routeReplacement: leftoverRoute
        ))
        #expect(!snClosedDMShouldClearPendingRouteReplacement(
            closingId: "marmot:other",
            openedConversationId: "marmot:group-09",
            openedConversationPaneId: "marmot:group-08",
            routeReplacement: leftoverRoute
        ))
        #expect(!snClosedDMShouldClearPendingRouteReplacement(
            closingId: "marmot:group-09",
            openedConversationId: nil,
            openedConversationPaneId: nil,
            routeReplacement: leftoverRoute
        ))
        #expect(snMacSelectionAfterFoldRemount(
            selectionId: "marmot:group-08",
            openId: "marmot:group-08",
            realId: "marmot:group-09"
        ) == "marmot:group-09")
        #expect(snMacSelectionAfterFoldRemount(
            selectionId: "group-08",
            openId: "marmot:group-08",
            realId: "marmot:group-09"
        ) == "marmot:group-09")
        #expect(snMacSelectionAfterFoldRemount(
            selectionId: "marmot:other",
            openId: "marmot:group-08",
            realId: "marmot:group-09"
        ) == "marmot:other")
        #expect(!snMacSelectionChangeShouldClearPath(
            nextId: "marmot:group-09",
            openedConversationId: "marmot:group-09",
            openedConversationPaneId: "marmot:group-08"
        ))
        #expect(!snMacSelectionChangeShouldClearPath(
            nextId: "group-09",
            openedConversationId: "marmot:group-09",
            openedConversationPaneId: "marmot:group-08"
        ))
        #expect(snMacSelectionChangeShouldClearPath(
            nextId: "marmot:group-09",
            openedConversationId: "marmot:group-09",
            openedConversationPaneId: "marmot:group-09"
        ))
        #expect(snMacSelectionChangeShouldClearPath(
            nextId: "marmot:other",
            openedConversationId: "marmot:group-09",
            openedConversationPaneId: "marmot:group-08"
        ))
        #expect(
            snConversationRefreshIds(
                changedGroupId: "group-08",
                listedGroupIds: [],
                historicalFolds: ["group-08": "group-09"]
            ) == ["group-08"]
        )
        #expect(
            snConversationRefreshShouldLoadPage(
                refreshId: "group-08",
                listedGroupIds: ["group-09"],
                cachedGroupIds: [],
                changedGroupId: "group-08",
                historicalFolds: ["group-08": "group-09"]
            )
        )
        #expect(
            !snConversationRefreshShouldLoadPage(
                refreshId: "brand-new",
                listedGroupIds: ["group-09"],
                cachedGroupIds: [],
                changedGroupId: "brand-new",
                historicalFolds: ["group-08": "group-09"]
            )
        )
        #expect(
            snConversationChangeTargetId(
                changedGroupId: "group-08",
                listedGroupIds: ["group-09"],
                historicalFolds: ["group-08": "group-09"]
            ) == "group-09"
        )
        #expect(
            !snConversationRefreshShouldLoadPage(
                refreshId: "group-08",
                listedGroupIds: ["group-09"],
                cachedGroupIds: [],
                changedGroupId: "group-08",
                historicalFolds: [:]
            )
        )
        #expect(
            snConversationRefreshShouldLoadPage(
                refreshId: "group-08",
                listedGroupIds: ["group-09"],
                cachedGroupIds: [],
                changedGroupId: "group-08",
                historicalFolds: [:],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            )
        )
        #expect(
            snConversationChangeTargetId(
                changedGroupId: "group-08",
                listedGroupIds: ["group-09"],
                historicalFolds: [:]
            ) == "group-08"
        )
        #expect(
            snConversationChangeTargetId(
                changedGroupId: "group-08",
                listedGroupIds: ["group-09"],
                historicalFolds: [:],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            ) == "group-09"
        )
        #expect(
            snConversationChangeShouldRefreshOpenMesh(
                openMeshChatId: "mesh:peer-a",
                changedGroupId: "group-08",
                historicalFolds: ["group-08": "group-09"],
                peerIdForGroup: { $0 == "group-09" ? "peer-a" : nil },
                meshChatId: { "mesh:\($0)" }
            )
        )
        #expect(
            snConversationChangeShouldRefreshOpenMesh(
                openMeshChatId: "mesh:peer-a",
                changedGroupId: "group-09",
                historicalFolds: ["group-08": "group-09"],
                peerIdForGroup: { $0 == "group-09" ? "peer-a" : nil },
                meshChatId: { "mesh:\($0)" }
            )
        )
        #expect(
            !snConversationChangeShouldRefreshOpenMesh(
                openMeshChatId: "mesh:peer-a",
                changedGroupId: "group-08",
                historicalFolds: ["group-08": "group-09"],
                peerIdForGroup: { _ in nil },
                meshChatId: { "mesh:\($0)" }
            )
        )
        #expect(
            !snConversationChangeShouldRefreshOpenMesh(
                openMeshChatId: "mesh:peer-b",
                changedGroupId: "group-08",
                historicalFolds: ["group-08": "group-09"],
                peerIdForGroup: { $0 == "group-09" ? "peer-a" : nil },
                meshChatId: { "mesh:\($0)" }
            )
        )
        #expect(
            !snConversationChangeShouldRefreshOpenMesh(
                openMeshChatId: "mesh:peer-a",
                changedGroupId: "group-08",
                historicalFolds: [:],
                peerIdForGroup: { $0 == "group-09" ? "peer-a" : nil },
                meshChatId: { "mesh:\($0)" }
            )
        )
        #expect(
            snConversationChangeShouldRefreshOpenMesh(
                openMeshChatId: "mesh:peer-a",
                changedGroupId: "group-08",
                historicalFolds: [:],
                peerIdForGroup: { $0 == "group-09" ? "peer-a" : nil },
                meshChatId: { "mesh:\($0)" },
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            )
        )
        #expect(
            snPendingUploadLookupGroupIds(
                groupId: "group-08",
                historicalFolds: ["group-08": "group-09"]
            ) == ["group-08", "group-09"]
        )
        #expect(
            snPendingUploadLookupGroupIds(
                groupId: "group-08",
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == ["group-08", "group-09"]
        )
        #expect(
            snPendingUploadStoreGroupId(
                groupId: "group-08",
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == "group-09"
        )
        #expect(
            snPendingUploadLookupGroupIds(
                groupId: "group-other",
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == ["group-other"]
        )
        #expect(
            snPendingUploadStoreGroupId(
                groupId: "group-other",
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == "group-other"
        )
        #expect(
            snPendingUploadStoreGroupId(
                groupId: "group-08",
                historicalFolds: ["group-08": "group-09"]
            ) == "group-09"
        )
        #expect(
            snComposerDraft(
                chatId: "marmot:group-09",
                drafts: ["marmot:group-08": "hello from 0.8"],
                historicalFolds: ["group-08": "group-09"]
            ) == "hello from 0.8"
        )
        #expect(
            snRetainedTranscriptForChat(
                chatId: "marmot:group-09",
                retainedByChat: ["marmot:group-08": ["old from 0.8"]],
                historicalFolds: ["group-08": "group-09"]
            ) == ["old from 0.8"]
        )
        #expect(
            snRetainedTranscriptForChat(
                chatId: "marmot:group-09",
                retainedByChat: ["marmot:group-08": ["old from 0.8"]],
                historicalFolds: [:]
            ).isEmpty
        )
        #expect(
            snRetainedTranscriptForChat(
                chatId: "marmot:group-09",
                retainedByChat: ["marmot:group-08": ["old from 0.8"]],
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == ["old from 0.8"]
        )
        #expect(snFirstOpenShouldMergeFolds(seedId: "group-09", persistedFolds: [:]))
        #expect(snFirstOpenShouldMergeFolds(seedId: "marmot:group-09", persistedFolds: [:]))
        #expect(!snFirstOpenShouldMergeFolds(seedId: "group-09", persistedFolds: ["group-08": "group-09"]))
        #expect(!snFirstOpenShouldMergeFolds(seedId: "marmot:group-09", persistedFolds: ["group-08": "group-09"]))
        // Unresumed first open looks like family-of-one. Caching that empty
        // merge must not skip the hop after the first 0.9 send.
        #expect(!snFirstOpenShouldReuseCachedFoldMerge(
            seedId: "group-08",
            persistedFolds: [:],
            cachedSeeds: ["group-08"]
        ))
        #expect(!snFirstOpenShouldReuseCachedFoldMerge(
            seedId: "group-09",
            persistedFolds: [:],
            cachedSeeds: ["group-09"]
        ))
        #expect(snFirstOpenShouldReuseCachedFoldMerge(
            seedId: "group-09",
            persistedFolds: ["group-08": "group-09"],
            cachedSeeds: ["group-09"]
        ))
        #expect(!snFirstOpenShouldReuseCachedFoldMerge(
            seedId: "group-09",
            persistedFolds: ["group-08": "group-09"],
            cachedSeeds: []
        ))
        #expect(
            snFirstOpenTranscriptPaintRows(
                chatId: "marmot:group-09",
                retainedByChat: ["marmot:group-09": ["new 0.9"]],
                snapshotPaint: ["old from 0.8"],
                historicalFolds: ["group-08": "group-09"],
                idOf: { $0 }
            ) == ["new 0.9", "old from 0.8"]
        )
        #expect(
            snFirstOpenTranscriptPaintRows(
                chatId: "marmot:group-09",
                retainedByChat: ["marmot:group-08": ["old from 0.8"]],
                snapshotPaint: ["snap"],
                historicalFolds: ["group-08": "group-09"],
                idOf: { $0 }
            ) == ["old from 0.8", "snap"]
        )
        #expect(
            Set(
                snFirstOpenTranscriptPaintRows(
                    chatId: "group-09",
                    retainedByChat: [
                        "group-09": ["new 0.9"],
                        "group-08": ["old from 0.8"],
                    ],
                    snapshotPaint: ["new 0.9"],
                    historicalFolds: ["group-08": "group-09"],
                    idOf: { $0 }
                )
            ) == ["new 0.9", "old from 0.8"]
        )
        #expect(
            snFirstOpenTranscriptPaintRows(
                chatId: "group-09",
                retainedByChat: [
                    "group-09": ["new 0.9"],
                    "group-08": ["old from 0.8"],
                ],
                snapshotPaint: ["new 0.9"],
                historicalFolds: [:],
                idOf: { $0 }
            ) == ["new 0.9"]
        )
        #expect(
            Set(
                snFirstOpenTranscriptPaintRows(
                    chatId: "group-09",
                    retainedByChat: [
                        "group-09": ["new 0.9"],
                        "group-08": ["old from 0.8"],
                    ],
                    snapshotPaint: ["new 0.9"],
                    historicalFolds: [:],
                    idOf: { $0 },
                    openedConversationId: "group-09",
                    openedConversationPaneId: "group-08"
                )
            ) == ["new 0.9", "old from 0.8"]
        )
        #expect(snFirstOpenHasLocalTranscriptPaint(retained: [String](), familyCached: ["old from 0.8"]))
        #expect(snFirstOpenHasLocalTranscriptPaint(retained: ["leave"], familyCached: [String]()))
        #expect(!snFirstOpenHasLocalTranscriptPaint(retained: [String](), familyCached: [String]()))
        #expect(
            snNewestPageShouldMergeFamilyWindow(
                existingCanonicalCount: 40,
                hiddenSiblingHasRows: false,
                hasFoldFamily: true,
                pinnedToOlderEdge: false
            )
        )
        #expect(
            !snNewestPageShouldMergeFamilyWindow(
                existingCanonicalCount: 40,
                hiddenSiblingHasRows: false,
                hasFoldFamily: true,
                pinnedToOlderEdge: true
            )
        )
        #expect(
            snNewestPageShouldPreserveRemountedPin(
                isNewestPage: true,
                pinnedToOlderEdge: true,
                remountCopiedPinOntoTarget: true,
                explicitNewestReload: false
            )
        )
        #expect(
            !snNewestPageShouldPreserveRemountedPin(
                isNewestPage: true,
                pinnedToOlderEdge: true,
                remountCopiedPinOntoTarget: true,
                explicitNewestReload: true
            )
        )
        #expect(
            !snNewestPageShouldPreserveRemountedPin(
                isNewestPage: true,
                pinnedToOlderEdge: true,
                remountCopiedPinOntoTarget: false,
                explicitNewestReload: false
            )
        )
        #expect(
            !snNewestPageShouldPreserveRemountedPin(
                isNewestPage: true,
                pinnedToOlderEdge: false,
                remountCopiedPinOntoTarget: true,
                explicitNewestReload: false
            )
        )
        #expect(
            !snNewestPageShouldMergeFamilyWindow(
                existingCanonicalCount: 40,
                hiddenSiblingHasRows: false,
                hasFoldFamily: false,
                pinnedToOlderEdge: false
            )
        )
        #expect(
            snTranscriptReadIsUntrusted(
                fetched: [String](),
                coreStarted: true,
                knownLatestSecs: 1_700_000
            )
        )
        #expect(
            snTranscriptReadIsUntrusted(
                fetched: nil as [String]?,
                coreStarted: true,
                knownLatestSecs: 0
            )
        )
        #expect(
            snTranscriptReadIsUntrusted(
                fetched: [String](),
                coreStarted: false,
                knownLatestSecs: 0
            )
        )
        #expect(
            !snTranscriptReadIsUntrusted(
                fetched: [String](),
                coreStarted: true,
                knownLatestSecs: 0
            )
        )
        #expect(
            !snTranscriptReadIsUntrusted(
                fetched: ["row"],
                coreStarted: true,
                knownLatestSecs: 1_700_000
            )
        )
        #expect(
            snNewestPageShouldMergeFamilyWindow(
                existingCanonicalCount: 40,
                hiddenSiblingHasRows: true,
                hasFoldFamily: false,
                pinnedToOlderEdge: false
            )
        )
        #expect(
            !snNewestPageShouldMergeFamilyWindow(
                existingCanonicalCount: 0,
                hiddenSiblingHasRows: true,
                hasFoldFamily: true,
                pinnedToOlderEdge: false
            )
        )
        #expect(
            snDMHasLocalMarmotPaint(
                groupId: "group-09",
                listedGroupIds: ["group-09"],
                messagesByGroup: ["group-08": ["keep this chat"]],
                historicalFolds: ["group-08": "group-09"],
                idOf: { $0 }
            )
        )
        #expect(
            !snDMHasLocalMarmotPaint(
                groupId: "group-09",
                listedGroupIds: ["group-09"],
                messagesByGroup: ["group-08": ["keep this chat"]],
                historicalFolds: [:],
                idOf: { $0 }
            )
        )
        #expect(snPersistedLiveFoldTarget(groupId: "group-08", historicalFolds: ["group-08": "group-09"]) == "group-09")
        #expect(snPersistedLiveFoldTarget(groupId: "group-09", historicalFolds: ["group-08": "group-09"]) == nil)
        #expect(
            snResolvedLiveFoldTarget(
                groupId: "group-08",
                historicalFolds: ["group-08": "group-09"],
                ffiLiveFoldTarget: nil
            ) == "group-09"
        )
        #expect(
            snResolvedLiveFoldTarget(
                groupId: "group-08",
                historicalFolds: [:],
                ffiLiveFoldTarget: "group-09"
            ) == "group-09"
        )
        #expect(
            snResolvedLiveFoldTarget(
                groupId: "group-08",
                historicalFolds: [:],
                ffiLiveFoldTarget: nil,
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            ) == "group-09"
        )
        #expect(
            snResolvedLiveFoldTarget(
                groupId: "group-08",
                historicalFolds: [:],
                ffiLiveFoldTarget: nil
            ) == nil
        )
        #expect(
            snResolvedLiveFoldTarget(
                groupId: "group-08",
                historicalFolds: ["group-08": "group-09"],
                ffiLiveFoldTarget: nil,
                openedConversationId: "other-live",
                openedConversationPaneId: "group-08"
            ) == "group-09"
        )
        #expect(
            snSnapshotLatestAfterHistoricalFolds(
                latestByChat: ["group-08": 1_700_000_000],
                historicalFolds: ["group-08": "group-09"]
            ) == ["group-08": 1_700_000_000, "group-09": 1_700_000_000]
        )
        #expect(
            snSnapshotLatestAfterHistoricalFolds(
                latestByChat: ["group-08": 1_700_000_200, "group-09": 1_700_000_050],
                historicalFolds: ["group-08": "group-09"]
            )["group-09"] == 1_700_000_200
        )
        #expect(
            snSnapshotLatestAfterHistoricalFolds(
                latestByChat: ["group-08": 1_700_000_000],
                historicalFolds: [:]
            ) == ["group-08": 1_700_000_000]
        )
        #expect(
            snSnapshotLatestAfterHistoricalFolds(
                latestByChat: ["group-08": 1_700_000_000],
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == ["group-08": 1_700_000_000, "group-09": 1_700_000_000]
        )
        #expect(
            snSnapshotLatestAfterHistoricalFolds(
                latestByChat: ["group-08": 1_700_000_000],
                historicalFolds: [:],
                openedConversationId: "group-other",
                openedConversationPaneId: "group-else"
            ) == ["group-08": 1_700_000_000]
        )
        #expect(
            snLocalLatestTsForChat(
                chatId: "group-09",
                messagesByChat: [:],
                latestByChat: ["group-08": 1_700_000_000],
                historicalFolds: ["group-08": "group-09"]
            ) == 1_700_000_000
        )
        #expect(
            snLocalLatestTsForChat(
                chatId: "group-09",
                messagesByChat: [:],
                latestByChat: ["group-08": 1_700_000_000],
                historicalFolds: [:]
            ) == 0
        )
        #expect(
            snLocalLatestTsForChat(
                chatId: "group-09",
                messagesByChat: [:],
                latestByChat: ["group-08": 1_700_000_000],
                historicalFolds: [:],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            ) == 1_700_000_000
        )
        #expect(
            snLocalLatestTsForChat(
                chatId: "group-other",
                messagesByChat: [:],
                latestByChat: ["group-08": 1_700_000_000],
                historicalFolds: [:],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            ) == 0
        )
        #expect(
            snLocalLatestTsForChat(
                chatId: "group-09",
                messagesByChat: ["group-09": Array((1...80).reversed().map(Int64.init))],
                latestByChat: [:],
                historicalFolds: ["group-08": "group-09"]
            ) == 80
        )
        #expect(
            snLocalLatestTsForChat(
                chatId: "group-09",
                messagesByChat: ["group-09": Array((1...80).reversed().map(Int64.init))],
                latestByChat: ["group-09": 200],
                historicalFolds: ["group-08": "group-09"]
            ) == 200
        )
        #expect(snQuotedParentInFamilyCache(parentId: "m5", familyMessages: Array(1...40).map { "m\($0)" }, idOf: { $0 }) == "m5")
        #expect(snQuotedParentInFamilyCache(parentId: "M5", familyMessages: Array(1...40).map { "m\($0)" }, idOf: { $0 }) == "m5")
        #expect(snQuotedParentInFamilyCache(parentId: "m5", familyMessages: Array(11...40).map { "m\($0)" }, idOf: { $0 }) == nil)
        #expect(snChatSnapshotLatestTs(messageTimestamps: Array((1...80).reversed().map(Int64.init)), persistedLatest: 0) == 80)
        #expect(snChatSnapshotLatestTs(messageTimestamps: Array((1...80).reversed().map(Int64.init)), persistedLatest: 200) == 200)
        #expect(
            snLocalLatestTsForChat(
                chatId: "group-09",
                messagesByChat: [:],
                latestByChat: ["group-09": snChatSnapshotLatestTs(
                    messageTimestamps: Array((1...80).reversed().map(Int64.init)),
                    persistedLatest: 0
                )],
                historicalFolds: ["group-08": "group-09"]
            ) == 80
        )
        let folds = ["group-08": "group-09"]
        #expect(
            snExpectedNewestTsForChat(
                chatId: "group-09",
                messagesByChat: [:],
                latestByChat: ["group-09": 10],
                summaryLatestByChat: ["group-08": 50],
                historicalFolds: folds
            ) == 50
        )
        #expect(
            snExpectedNewestTsForChat(
                chatId: "group-09",
                messagesByChat: [:],
                latestByChat: ["group-09": 10],
                summaryLatestByChat: [:],
                historicalFolds: folds
            ) == 10
        )
        #expect(
            snExpectedNewestTsForChat(
                chatId: "group-09",
                messagesByChat: [:],
                latestByChat: [:],
                summaryLatestByChat: ["group-08": 50],
                historicalFolds: folds
            ) == 50
        )
        #expect(
            snExpectedNewestTsForChat(
                chatId: "group-09",
                messagesByChat: [:],
                latestByChat: [:],
                summaryLatestByChat: [:],
                historicalFolds: folds
            ) == 0
        )
        #expect(
            !SNUnreadCounts.shouldRetireOpenUnread(
                unreadAtOpen: 4,
                anchorFound: false,
                feedNewest: Date(timeIntervalSince1970: 10),
                expectedNewest: Date(timeIntervalSince1970: TimeInterval(
                    snExpectedNewestTsForChat(
                        chatId: "group-09",
                        messagesByChat: [:],
                        latestByChat: [:],
                        summaryLatestByChat: ["group-08": 50],
                        historicalFolds: folds
                    )
                )),
                familyHasOlder: false
            )
        )
        #expect(snFoldedSiblingHasMore(historicalHasMore: true, liveHasMore: false))
        #expect(snFoldedSiblingHasMore(historicalHasMore: false, liveHasMore: true))
        #expect(!snFoldedSiblingHasMore(historicalHasMore: false, liveHasMore: false))
        #expect(
            snHiddenFoldFamilyNeedsPage(
                groupId: "group-09",
                historicalFolds: ["group-08": "group-09"],
                pagedGroupIds: ["group-09"]
            )
        )
        #expect(
            snHiddenFoldFamilyIdsNeedingPage(
                groupId: "group-09",
                historicalFolds: ["group-08": "group-09"],
                pagedGroupIds: ["group-09"]
            ) == ["group-08"]
        )
        #expect(
            snPagedFoldFamilyGroupIds(trustedFfiPageIds: ["group-09", ""]) == ["group-09"] as Set
        )
        #expect(
            snLoadOlderHiddenSiblingsNeedingNewestPage(
                listedLiveIds: ["group-09"],
                historicalFolds: ["group-08": "group-09"],
                pagedGroupIds: ["group-09"]
            ) == ["group-08"]
        )
        #expect(
            snLoadOlderHiddenSiblingsNeedingNewestPage(
                listedLiveIds: ["group-09"],
                historicalFolds: ["group-08": "group-09"],
                pagedGroupIds: ["group-08", "group-09"]
            ).isEmpty
        )
        #expect(
            snLoadOlderFamilyPageIds(
                openGroupId: "group-09",
                historicalFolds: ["group-08": "group-09"],
                hasOlderByGroup: ["group-08": true]
            ) == ["group-08"]
        )
        #expect(
            snLoadOlderFamilyPageIds(
                openGroupId: "group-09",
                historicalFolds: ["group-08": "group-09"],
                hasOlderByGroup: ["group-08": true, "group-09": true]
            ) == ["group-08", "group-09"]
        )
        #expect(
            snLoadOlderFamilyPageIds(
                openGroupId: "group-09",
                historicalFolds: ["group-08": "group-09"],
                hasOlderByGroup: ["group-08": false, "group-09": false]
            ).isEmpty
        )
        #expect(
            snLoadOlderFamilyPageIds(
                openGroupId: "group-09",
                historicalFolds: [:],
                hasOlderByGroup: ["group-09": true]
            ) == ["group-09"]
        )
        #expect(
            snLoadOlderBusyRetryShouldWait(
                openGroupId: "group-09",
                loadingGroupIds: ["group-08"],
                historicalFolds: ["group-08": "group-09"]
            )
        )
        #expect(
            snLoadOlderBusyRetryShouldWait(
                openGroupId: "group-09",
                loadingGroupIds: ["group-09"],
                historicalFolds: ["group-08": "group-09"]
            )
        )
        #expect(
            !snLoadOlderBusyRetryShouldWait(
                openGroupId: "group-09",
                loadingGroupIds: ["group-08"],
                historicalFolds: [:]
            )
        )
        #expect(
            !snFoldFamilySourceNeedsNewestPage(
                groupId: "group-09",
                pagedGroupIds: ["group-08"],
                cachedRowCount: 20
            )
        )
        #expect(
            snFoldFamilySourceNeedsNewestPage(
                groupId: "group-08",
                pagedGroupIds: ["group-09"],
                cachedRowCount: 0
            )
        )
        #expect(
            snFoldFamilyCanonicalMessageIDs(
                groupId: "group-09",
                messagesByGroup: ["group-09": ["l1"], "group-08": ["h1"]],
                historicalFolds: ["group-08": "group-09"],
                idOf: { $0 }
            ) == ["h1", "l1"] as Set
        )
        #expect(
            !snHiddenFoldFamilyNeedsPage(
                groupId: "group-09",
                historicalFolds: ["group-08": "group-09"],
                pagedGroupIds: ["group-08", "group-09"]
            )
        )
        #expect(
            !snHiddenFoldFamilyNeedsPage(
                groupId: "group-09",
                historicalFolds: [:],
                pagedGroupIds: ["group-09"]
            )
        )
        #expect(
            snHiddenFoldFamilyNeedsPage(
                groupId: "group-09",
                historicalFolds: [:],
                pagedGroupIds: ["group-09"],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            )
        )
        #expect(
            snHiddenFoldFamilyIdsNeedingPage(
                groupId: "group-09",
                historicalFolds: [:],
                pagedGroupIds: ["group-09"],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            ) == ["group-08"]
        )
        #expect(
            snHiddenFoldFamilyIdsNeedingPage(
                groupId: "group-08",
                historicalFolds: [:],
                pagedGroupIds: ["group-09"],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            ).isEmpty
        )
        #expect(
            snLoadOlderHiddenSiblingsNeedingNewestPage(
                listedLiveIds: ["group-09"],
                historicalFolds: [:],
                pagedGroupIds: ["group-09"],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            ) == ["group-08"]
        )
        #expect(
            snLoadOlderFamilyPageIds(
                openGroupId: "group-09",
                historicalFolds: [:],
                hasOlderByGroup: ["group-08": true],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            ) == ["group-08"]
        )
        #expect(
            snLoadOlderBusyRetryShouldWait(
                openGroupId: "group-09",
                loadingGroupIds: ["group-08"],
                historicalFolds: [:],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            )
        )
        #expect(
            snFoldFamilyHasOlder(
                groupId: "group-09",
                hasOlderByGroup: ["group-08": true],
                historicalFolds: [:],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            )
        )
        #expect(
            snFoldFamilySourceNeedsNewestPage(
                groupId: "group-08",
                pagedGroupIds: ["group-09"],
                cachedRowCount: 0
            )
        )
        #expect(
            !snFoldFamilySourceNeedsNewestPage(
                groupId: "group-09",
                pagedGroupIds: ["group-09"],
                cachedRowCount: 0
            )
        )
        #expect(
            !snFoldFamilySourceNeedsNewestPage(
                groupId: "group-09",
                pagedGroupIds: [],
                cachedRowCount: 20
            )
        )
        #expect(
            snFoldFamilyHasOlder(
                groupId: "group-09",
                hasOlderByGroup: ["group-08": false, "group-09": false],
                historicalFolds: ["group-08": "group-09"],
                unpagedHiddenSibling: true
            )
        )
        #expect(
            !snFoldFamilyHasOlder(
                groupId: "group-09",
                hasOlderByGroup: ["group-08": false, "group-09": false],
                historicalFolds: ["group-08": "group-09"],
                unpagedHiddenSibling: false
            )
        )
        #expect(
            snFoldFamilyHasOlder(
                groupId: "group-09",
                hasOlderByGroup: ["group-08": true],
                historicalFolds: ["group-08": "group-09"]
            )
        )
        #expect(
            !snFoldFamilyHasOlder(
                groupId: "group-09",
                hasOlderByGroup: ["group-08": true],
                historicalFolds: [:]
            )
        )
        #expect(
            snFoldFamilyHasOlder(
                groupId: "group-09",
                hasOlderByGroup: ["group-08": false, "group-09": false],
                historicalFolds: ["group-08": "group-09"],
                cachedCount: 31,
                pageSize: 30
            )
        )
        #expect(!snFoldFamilyCacheHasOlderThanPage(cachedCount: 30, pageSize: 30))
        #expect(snSeededFoldFamilyTranscriptHasMore(cachedCount: 40, familyHasOlder: false))
        #expect(!snSeededFoldFamilyTranscriptHasMore(cachedCount: 30, familyHasOlder: false))
        #expect(snSeededFoldFamilyTranscriptHasMore(cachedCount: 30, familyHasOlder: true))
        #expect(
            !SNUnreadCounts.shouldRetireOpenUnread(
                unreadAtOpen: 3,
                anchorFound: false,
                feedNewest: Date(timeIntervalSince1970: 1),
                expectedNewest: Date(timeIntervalSince1970: 100),
                familyHasOlder: false
            )
        )
        #expect(
            !SNUnreadCounts.shouldRetireOpenUnread(
                unreadAtOpen: 3,
                anchorFound: false,
                feedNewest: Date(timeIntervalSince1970: 200),
                expectedNewest: Date(timeIntervalSince1970: 100),
                familyHasOlder: true
            )
        )
        #expect(
            snNewestPageFamilyHasOlder(
                existingCount: 80,
                incomingCount: 2,
                rawPageCount: 2,
                previousHasOlder: false
            )
        )
        #expect(
            !snNewestPageFamilyHasOlder(
                existingCount: 10,
                incomingCount: 5,
                rawPageCount: 5,
                previousHasOlder: false
            )
        )
        #expect(
            snNewestPageFamilyHasOlder(
                existingCount: 10,
                incomingCount: 5,
                rawPageCount: 31,
                previousHasOlder: false
            )
        )
        #expect(
            snNewestPageFamilyHasOlder(
                existingCount: 10,
                incomingCount: 5,
                rawPageCount: 5,
                previousHasOlder: true
            )
        )
        #expect(
            snNewestPageFamilyHasOlder(
                existingCount: 20,
                incomingCount: 2,
                rawPageCount: 2,
                previousHasOlder: false,
                hasFoldFamily: true
            )
        )
        #expect(
            !snNewestPageFamilyHasOlder(
                existingCount: 20,
                incomingCount: 2,
                rawPageCount: 2,
                previousHasOlder: false,
                hasFoldFamily: false
            )
        )
        #expect(
            !snNewestPageFamilyHasOlder(
                existingCount: 0,
                incomingCount: 2,
                rawPageCount: 2,
                previousHasOlder: false,
                hasFoldFamily: true
            )
        )
        #expect(
            snLoadOlderPageHasOlder(
                rawPageCount: 0,
                pageSize: 30,
                admittedNewRows: false,
                previousHasOlder: true
            )
        )
        #expect(
            snLoadOlderPageHasOlder(
                rawPageCount: 5,
                pageSize: 30,
                admittedNewRows: false,
                previousHasOlder: true
            )
        )
        #expect(
            !snLoadOlderPageHasOlder(
                rawPageCount: 5,
                pageSize: 30,
                admittedNewRows: true,
                previousHasOlder: true
            )
        )
        #expect(
            snLoadOlderPageHasOlder(
                rawPageCount: 31,
                pageSize: 30,
                admittedNewRows: true,
                previousHasOlder: false
            )
        )
        #expect(
            !snLoadOlderPageHasOlder(
                rawPageCount: 0,
                pageSize: 30,
                admittedNewRows: false,
                previousHasOlder: false
            )
        )
        #expect(
            snCachedFoldFamilySourceLimit(
                cachedCount: 80,
                currentLimit: 30,
                retainedLimit: 500
            ) == 80
        )
        #expect(
            snCachedFoldFamilySourceLimit(
                cachedCount: 10,
                currentLimit: 30,
                retainedLimit: 500
            ) == 30
        )
        #expect(
            snCachedFoldFamilySourceLimit(
                cachedCount: 520,
                currentLimit: 30,
                retainedLimit: 500
            ) == 500
        )
        #expect(
            snQuotedMessageRevealLimit(
                parentId: "m5",
                cached: (1...40).map { "m\($0)" },
                idOf: { $0 }
            ) == 36
        )
        #expect(
            snQuotedMessageRevealLimit(
                parentId: "m39",
                cached: (1...40).map { "m\($0)" },
                idOf: { $0 }
            ) == 30
        )
        #expect(
            snQuotedMessageRevealLimit(
                parentId: "missing",
                cached: (1...40).map { "m\($0)" },
                idOf: { $0 }
            ) == nil
        )
        #expect(
            snQuotedMessageRevealLimit(
                parentId: "r1",
                cached: (1...520).map { "r\($0)" },
                idOf: { $0 }
            ) == 500
        )
        #expect(snShouldSettleQuotedJump(parentInFeed: true))
        #expect(!snShouldSettleQuotedJump(parentInFeed: false))
        #expect(
            !snShouldClearQuotedJumpAfterMiss(added: false, parentVisible: false)
        )
        #expect(
            !snShouldClearQuotedJumpAfterMiss(added: true, parentVisible: false)
        )
        #expect(
            snShouldClearQuotedJumpAfterMiss(added: true, parentVisible: true)
        )
        #expect(snQuotedJumpRetryToken(itemCount: 500, oldestId: "old", newestId: "new") == "500:old:new")
        #expect(
            snQuotedJumpRetryToken(itemCount: 500, oldestId: "older", newestId: "new") !=
                snQuotedJumpRetryToken(itemCount: 500, oldestId: "old", newestId: "new")
        )
        #expect(
            snQuotedJumpParentId(
                conversationId: "marmot:group-09",
                jumps: ["group-08": "parent-08"],
                historicalFolds: ["group-08": "group-09"]
            ) == "parent-08"
        )
        #expect(
            snQuotedJumpParentId(
                conversationId: "group-09",
                jumps: ["group-08": "parent-08"],
                historicalFolds: [:]
            ) == nil
        )
        #expect(
            snQuotedJumpParentId(
                conversationId: "marmot:group-09",
                jumps: ["marmot:group-08": "parent-08"],
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == "parent-08"
        )
        #expect(
            snQuotedJumpWritten(
                conversationId: "marmot:group-08",
                parentId: "parent-08",
                jumps: [:],
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            )["marmot:group-09"] == "parent-08"
        )
        #expect(
            snQuotedJumpCleared(
                conversationId: "marmot:group-08",
                jumps: [
                    "marmot:group-08": "parent-08",
                    "marmot:group-09": "parent-08"
                ],
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            )["marmot:group-09"] == nil
        )
        #expect(
            snQuotedJumpWritten(
                conversationId: "marmot:group-08",
                parentId: "parent-08",
                jumps: [:],
                historicalFolds: ["group-08": "group-09"]
            )["marmot:group-09"] == "parent-08"
        )
        #expect(
            snQuotedJumpCleared(
                conversationId: "marmot:group-09",
                jumps: [
                    "group-08": "parent-08",
                    "marmot:group-08": "parent-08",
                    "group-09": "parent-08",
                    "marmot:group-09": "parent-08"
                ],
                historicalFolds: ["group-08": "group-09"]
            )["group-08"] == nil
        )
        #expect(
            snFoldFamilyPagingCursor(
                groupId: "group-09",
                cursorsByGroup: ["group-08": "cursor-08"],
                historicalFolds: ["group-08": "group-09"]
            ) == "cursor-08"
        )
        #expect(
            snFoldFamilyPagingCursor(
                groupId: "group-09",
                cursorsByGroup: ["group-08": "cursor-08", "group-09": "cursor-09"],
                historicalFolds: ["group-08": "group-09"]
            ) == "cursor-09"
        )
        #expect(
            snFoldFamilyPagingCursor(
                groupId: "group-09",
                cursorsByGroup: ["group-08": "cursor-08"],
                historicalFolds: [:]
            ) == nil
        )
        #expect(
            snFoldFamilyPagingCursor(
                groupId: "group-09",
                cursorsByGroup: ["group-08": "cursor-08"],
                historicalFolds: [:],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            ) == "cursor-08"
        )
        #expect(
            snPromotedFoldedPagingFlags(
                previousGroupIds: ["group-08", "group-09"],
                currentGroupIds: ["group-09"],
                flags: ["group-08": true, "group-09": false],
                liveFoldTarget: { $0 == "group-08" ? "group-09" : nil }
            ) == ["group-08": true, "group-09": true]
        )
        #expect(
            snPromotedFoldedPagingCursors(
                previousGroupIds: ["group-08"],
                currentGroupIds: ["group-09"],
                cursors: ["group-08": "cursor-08"],
                liveFoldTarget: { $0 == "group-08" ? "group-09" : nil }
            )["group-09"] == "cursor-08"
        )
        #expect(
            snPromotedFoldedPagingCursors(
                previousGroupIds: ["group-08"],
                currentGroupIds: ["group-09"],
                cursors: ["group-08": "cursor-08", "group-09": "cursor-09"],
                liveFoldTarget: { $0 == "group-08" ? "group-09" : nil }
            )["group-09"] == "cursor-09"
        )
        #expect(
            snComposerDraftsAfterEdit(
                drafts: ["marmot:group-08": "hello from 0.8"],
                chatId: "marmot:group-09",
                text: "",
                historicalFolds: ["group-08": "group-09"]
            ).isEmpty
        )
        #expect(
            snPaymentActivityPeerKeys(
                conversationId: "marmot:group-09",
                historicalFolds: ["group-08": "group-09"]
            ) == [
                "marmot:group-09", "group-09",
                "marmot:group-08", "group-08",
            ]
        )
        #expect(
            snCallLogsForChat(
                conversationId: "marmot:group-09",
                callLogs: [
                    "marmot:group-08": [historicalCall],
                    "marmot:group-09": [liveCall],
                ],
                historicalFolds: ["group-08": "group-09"],
                idOf: { $0.id },
                dateOf: { $0.date }
            ).map(\.id) == ["call-08", "call-09"]
        )
        #expect(
            snCallLogsForChat(
                conversationId: "marmot:group-09",
                callLogs: ["marmot:group-08": [historicalCall]],
                historicalFolds: ["group-08": "group-09"],
                idOf: { $0.id },
                dateOf: { $0.date }
            ).map(\.id) == ["call-08"]
        )
        #expect(
            snCallLogsForChat(
                conversationId: "marmot:group-09",
                callLogs: ["marmot:group-08": [historicalCall]],
                historicalFolds: [:],
                idOf: { $0.id },
                dateOf: { $0.date }
            ).isEmpty
        )
        #expect(
            Set(snPendingMessageKeys(
                conversationId: "marmot:group-09",
                sourceGroupIds: ["group-09"],
                historicalFolds: ["group-08": "group-09"]
            )).isSuperset(of: [
                "marmot:group-09", "group-09",
                "marmot:group-08", "group-08",
            ])
        )
        #expect(
            !snPendingMessageKeys(
                conversationId: "marmot:group-09",
                sourceGroupIds: ["group-09"],
                historicalFolds: [:]
            ).contains("marmot:group-08")
        )
        #expect(
            Set(snPendingMessageKeys(
                conversationId: "marmot:group-08",
                sourceGroupIds: ["group-08"],
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            )).isSuperset(of: [
                "marmot:group-08", "group-08",
                "marmot:group-09", "group-09",
            ])
        )
        let histTrill = Date(timeIntervalSince1970: 80)
        let liveTrill = Date(timeIntervalSince1970: 90)
        #expect(
            snTrillCooldownUntil(
                conversationId: "marmot:group-09",
                cooldownUntilByChat: ["marmot:group-08": histTrill],
                historicalFolds: ["group-08": "group-09"]
            ) == histTrill
        )
        #expect(
            snTrillCooldownUntil(
                conversationId: "marmot:group-09",
                cooldownUntilByChat: [
                    "marmot:group-08": histTrill,
                    "marmot:group-09": liveTrill,
                ],
                historicalFolds: ["group-08": "group-09"]
            ) == liveTrill
        )
        #expect(
            snTrillCooldownUntil(
                conversationId: "marmot:group-09",
                cooldownUntilByChat: ["marmot:group-08": histTrill],
                historicalFolds: [:]
            ) == nil
        )
        #expect(
            snTrillCooldownUntil(
                conversationId: "marmot:group-09",
                cooldownUntilByChat: snTrillCooldownWritten(
                    conversationId: "marmot:group-08",
                    until: histTrill,
                    cooldownUntilByChat: [:],
                    historicalFolds: [:],
                    openedConversationId: "marmot:group-09",
                    openedConversationPaneId: "marmot:group-08"
                ),
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == histTrill
        )
        #expect(
            snPaymentActivityPeerKeys(
                conversationId: "group-08",
                historicalFolds: ["group-08": "group-09"]
            ) == [
                "group-08", "marmot:group-08",
                "group-09", "marmot:group-09",
            ]
        )
        #expect(
            snRemountPairConversationIds(
                conversationId: "marmot:group-08",
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == ["marmot:group-08", "marmot:group-09"]
        )
        #expect(
            snPaymentActivityPeerKeys(
                conversationId: "marmot:group-08",
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ).isSuperset(of: [
                "marmot:group-08", "group-08",
                "marmot:group-09", "group-09",
            ])
        )
        #expect(
            !snPaymentActivityPeerKeys(
                conversationId: "marmot:other",
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ).contains("marmot:group-09")
        )
        #expect(
            snCallLogsForChat(
                conversationId: "marmot:group-08",
                callLogs: ["marmot:group-09": [liveCall]],
                historicalFolds: [:],
                idOf: { $0.id },
                dateOf: { $0.date },
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ).map(\.id) == ["call-09"]
        )
        #expect(
            snCallConversationStoreId(
                conversationId: "marmot:group-08",
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == "marmot:group-09"
        )
        #expect(
            snCallConversationStoreId(
                conversationId: "group-08",
                historicalFolds: ["group-08": "group-09"]
            ) == "group-09"
        )
        #expect(
            snCallConversationStoreId(
                conversationId: "marmot:other",
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == "marmot:other"
        )
        #expect(
            snPaymentConversationStoreId(
                peerKey: "marmot:group-08",
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == "marmot:group-09"
        )
        #expect(
            snPaymentConversationStoreId(
                peerKey: "group-08",
                historicalFolds: ["group-08": "group-09"]
            ) == "group-09"
        )
        #expect(
            snPaymentConversationStoreId(
                peerKey: "wallet",
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == "wallet"
        )
        #expect(
            snPaymentConversationStoreId(
                peerKey: "unify:peer",
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == "unify:peer"
        )
        #expect(
            snRemountedPaymentPeerKey(
                peerKey: "marmot:group-08",
                historicalKeys: ["marmot:group-08", "group-08"],
                liveKey: "marmot:group-09"
            ) == "marmot:group-09"
        )
        #expect(
            snRemountedPaymentPeerKey(
                peerKey: "wallet",
                historicalKeys: ["marmot:group-08"],
                liveKey: "marmot:group-09"
            ) == "wallet"
        )
        #expect(
            snRemountedPaymentPeerKey(
                peerKey: "unify:peer",
                historicalKeys: ["unify:peer"],
                liveKey: "marmot:group-09"
            ) == "unify:peer"
        )
        #expect(
            snRemountedPaymentPeerKeysFromFolds(
                peerKeys: ["group-08", "group-09", "wallet", "unify:peer"],
                historicalFolds: ["group-08": "group-09"]
            ) == ["group-09", "group-09", "wallet", "unify:peer"]
        )
        #expect(
            snRemountedPaymentPeerKeysFromFolds(
                peerKeys: ["group-08", "group-09", "wallet", "unify:peer"],
                historicalFolds: [:],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            ) == ["group-09", "group-09", "wallet", "unify:peer"]
        )
        #expect(
            snRemountedPaymentPeerKeysFromFolds(
                peerKeys: ["group-08", "group-09", "wallet", "unify:peer"],
                historicalFolds: [:]
            ) == ["group-08", "group-09", "wallet", "unify:peer"]
        )
        #expect(
            snRemountedPaymentPeerKeysFromFolds(
                peerKeys: ["group-08", "wallet"],
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == ["group-09", "wallet"]
        )
        #expect(snPurgedHistoricalFolds(["group-08": "group-09"], deletedIds: ["group-09"]).isEmpty)
        #expect(
            snPurgedHistoricalFolds(["group-08": "group-09"], deletedIds: ["unrelated"])
                == ["group-08": "group-09"]
        )
        #expect(
            snPrunedOrphanedHistoricalFolds(
                ["group-08": "group-09"],
                listedIds: ["other-room"],
                listedAuthoritative: true
            ).isEmpty
        )
        #expect(
            snPrunedOrphanedHistoricalFolds(
                ["group-08": "group-09"],
                listedIds: ["group-09"],
                listedAuthoritative: true
            ) == ["group-08": "group-09"]
        )
        #expect(
            snPrunedOrphanedHistoricalFolds(
                ["group-08": "group-09"],
                listedIds: [],
                listedAuthoritative: false
            ) == ["group-08": "group-09"]
        )
        #expect(
            snPrunedOrphanedHistoricalFolds(
                ["group-08": "group-09"],
                listedIds: [],
                listedAuthoritative: true
            ) == ["group-08": "group-09"]
        )
        let historicalMark = SNScanMark(secs: 50, count: 12)
        let promotedMarks = snPromotedFoldedScanMarks(
            previousGroupIds: ["group-08", "group-09"],
            currentGroupIds: ["group-09"],
            watermarks: ["group-08": historicalMark],
            liveFoldTarget: { $0 == "group-08" ? "group-09" : nil }
        )
        #expect(promotedMarks["group-09"] == historicalMark)
        #expect(
            snChatsNeedingMessageScan(
                latestByChat: ["group-09": historicalMark],
                scannedWatermark: promotedMarks
            ).isEmpty
        )
        let remountMarks = snPromotedFoldedScanMarks(
            previousGroupIds: ["group-08", "group-09"],
            currentGroupIds: ["group-09"],
            watermarks: ["group-08": historicalMark],
            liveFoldTarget: {
                snResolvedLiveFoldTarget(
                    groupId: $0,
                    historicalFolds: [:],
                    ffiLiveFoldTarget: nil,
                    openedConversationId: "group-09",
                    openedConversationPaneId: "group-08"
                )
            }
        )
        #expect(remountMarks["group-09"] == historicalMark)
        #expect(
            snPromotedFoldedScanMarks(
                previousGroupIds: ["group-08", "group-09"],
                currentGroupIds: ["group-09"],
                watermarks: ["group-08": historicalMark],
                liveFoldTarget: {
                    snResolvedLiveFoldTarget(
                        groupId: $0,
                        historicalFolds: [:],
                        ffiLiveFoldTarget: nil
                    )
                }
            )["group-09"] == nil
        )
        #expect(snMarmotSendNeedsPeerUpdate("no key package found on relays for npub1abc"))
        #expect(snMarmotSendUserMessage("no key package found on relays for npub1abc") == "Waiting for them to update Sonar")
        #expect(
            snMarmotInviteUserMessage("this recovered chat cannot invite until it is resumed")
                == "Send a message first to resume this chat, then invite"
        )
        #expect(snRecoveredChatNeedsPeerUpdate(hasLiveFoldSibling: false, keyPackageMissing: true))
        #expect(!snRecoveredChatNeedsPeerUpdate(hasLiveFoldSibling: true, keyPackageMissing: true))
        // FFI hides the folded 0.8 id, so listed duplicates go back to 1.
        // Rooms never have listed 1:1 duplicates. The hist→live blob is
        // the live sibling.
        #expect(
            snRecoveredChatHasLiveFoldSibling(
                chatId: "group-08",
                listedDuplicateCount: 1,
                historicalFolds: ["group-08": "group-09"]
            )
        )
        #expect(
            snRecoveredChatHasLiveFoldSibling(
                chatId: "marmot:group-09",
                listedDuplicateCount: 1,
                historicalFolds: ["group-08": "group-09"]
            )
        )
        #expect(
            !snRecoveredChatHasLiveFoldSibling(
                chatId: "group-08",
                listedDuplicateCount: 1,
                historicalFolds: [:]
            )
        )
        #expect(
            snRecoveredChatHasLiveFoldSibling(
                chatId: "group-08",
                listedDuplicateCount: 1,
                historicalFolds: [:],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            )
        )
        #expect(
            !snRecoveredChatHasLiveFoldSibling(
                chatId: "group-other",
                listedDuplicateCount: 1,
                historicalFolds: [:],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            )
        )
        #expect(
            snRecoveredChatHasLiveFoldSibling(
                chatId: "group-08",
                listedDuplicateCount: 2,
                historicalFolds: [:]
            )
        )
        #expect(
            snRemountClearsRecoveredWaitingFlag(
                needsUpdate: ["marmot:group-08", "other"],
                remountedIds: ["marmot:group-08", "group-08", "marmot:group-09", "group-09"]
            ) == ["other"]
        )
        #expect(
            snRemountClearsRecoveredWaitingFlag(
                needsUpdate: ["marmot:group-08", "marmot:group-09"],
                remountedIds: ["marmot:group-08", "group-08", "marmot:group-09", "group-09"]
            ).isEmpty
        )
        #expect(
            snRecoveredLegacyMediaUnavailable(
                "encrypted media error: this attachment is from an older Sonar and cannot be opened after the update"
            )
        )
        #expect(!snRecoveredLegacyMediaUnavailable("hash verification failed"))
        #expect(
            !snRecoveredLegacyMediaUnavailable(
                "error sending request for url (https://127.0.0.1:1/old.bin)"
            )
        )
        #expect(
            SNRecoveredLegacyMediaCopy
                == "This attachment is from an older Sonar and can't be opened after the update."
        )
    }

    @Test
    func notificationTapRecoversFoldFromAliasesWhenPersistBlobEmpty() {
        let persist: [String: String] = [:]
        let listed = ["group-09"]
        #expect(
            !snNotificationOpenIsReady(
                requestedGroupId: "group-08",
                remounted: snNotificationOpenGroupId(
                    tappedGroupId: "group-08",
                    liveFoldTarget: snNotificationLiveFoldTarget(
                        tappedGroupId: "group-08",
                        ffiLiveFoldTarget: nil,
                        historicalFolds: persist
                    )
                ),
                listed: Set(listed)
            )
        )
        let discovered = snHistoricalFoldsFromAliases(
            listedIds: listed,
            foldAliases: { $0 == "group-09" ? ["group-09", "group-08"] : [$0] },
            liveFoldTarget: { $0 == "group-09" ? "group-09" : nil }
        )
        #expect(discovered == ["group-08": "group-09"])
        let remounted = snNotificationOpenGroupId(
            tappedGroupId: "group-08",
            liveFoldTarget: snNotificationLiveFoldTarget(
                tappedGroupId: "group-08",
                ffiLiveFoldTarget: nil,
                historicalFolds: persist.merging(discovered) { _, new in new }
            )
        )
        #expect(remounted == "group-09")
        #expect(
            snNotificationOpenIsReady(
                requestedGroupId: "group-08",
                remounted: remounted,
                listed: Set(listed)
            )
        )
        #expect(
            snNotificationOpenIsReady(
                requestedGroupId: "group-08",
                remounted: "group-09",
                listed: []
            )
        )
        #expect(
            snNotificationOpenIsReady(
                requestedGroupId: "group-09",
                remounted: "group-09",
                listed: ["group-09"]
            )
        )
        #expect(
            !snNotificationOpenIsReady(
                requestedGroupId: "group-08",
                remounted: "group-08",
                listed: ["group-09"]
            )
        )
    }

    @Test
    func remountKeepsPendingJoinRequestsOnFoldFamily() {
        let folds = ["group-08": "group-09"]
        let requests = ["npub1joiner"]
        #expect(
            snPendingJoinRequestsAcrossRemount(
                previousChatId: "marmot:group-08",
                nextChatId: "marmot:group-09",
                requests: requests,
                historicalFolds: folds
            ) == requests
        )
        #expect(
            snPendingJoinRequestsAcrossRemount(
                previousChatId: "marmot:group-09",
                nextChatId: "marmot:group-08",
                requests: requests,
                historicalFolds: folds
            ) == requests
        )
        #expect(
            snPendingJoinRequestsAcrossRemount(
                previousChatId: "marmot:group-08",
                nextChatId: "marmot:other-room",
                requests: requests,
                historicalFolds: folds
            ).isEmpty
        )
        #expect(
            snPendingJoinRequestsAcrossRemount(
                previousChatId: "",
                nextChatId: "marmot:group-09",
                requests: requests,
                historicalFolds: folds
            ) == requests
        )
        #expect(
            snPendingJoinRequestsAcrossRemount(
                previousChatId: "marmot:group-08",
                nextChatId: "marmot:group-09",
                requests: requests,
                historicalFolds: [:]
            ).isEmpty
        )
        #expect(
            snPendingJoinRequestsAcrossRemount(
                previousChatId: "marmot:group-08",
                nextChatId: "marmot:group-09",
                requests: requests,
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == requests
        )
        #expect(
            snPendingJoinRequestsAcrossRemount(
                previousChatId: "marmot:group-09",
                nextChatId: "marmot:group-08",
                requests: requests,
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ) == requests
        )
        #expect(
            snPendingJoinRequestsAcrossRemount(
                previousChatId: "marmot:group-08",
                nextChatId: "marmot:other-room",
                requests: requests,
                historicalFolds: [:],
                openedConversationId: "marmot:group-09",
                openedConversationPaneId: "marmot:group-08"
            ).isEmpty
        )
    }

    @Test
    func sameNpubMeshFingerprintsShareIdentityKey() {
        let npub = String(repeating: "ab", count: 32)
        #expect(
            snMeshConversationIdentityKey(peerId: "abef0238b73563e6", linkedNpubHex: npub)
                == snMeshConversationIdentityKey(peerId: "dfb13e10b8069122", linkedNpubHex: npub.uppercased())
        )
        #expect(
            snMeshConversationIdentityKey(peerId: "abef0238b73563e6", linkedNpubHex: npub)
                != snMeshConversationIdentityKey(peerId: "sara-fp", linkedNpubHex: String(repeating: "cd", count: 32))
        )
        #expect(
            snMeshConversationIdentityKey(peerId: "unlinked-a", linkedNpubHex: nil)
                != snMeshConversationIdentityKey(peerId: "unlinked-b", linkedNpubHex: nil)
        )
    }

    @Test
    func rotatingVincenzoAliasesCollapseWithoutAbsorbingSara() {
        let vincenzoNpub = String(repeating: "ab", count: 32)
        let saraNpub = String(repeating: "cd", count: 32)
        let links = [
            "fp-vincenzo": vincenzoNpub,
            "fp-vincenzo-mac": vincenzoNpub.uppercased(),
            "fp-sara": saraNpub,
        ]
        let groups = snGroupMeshPeerIdsByIdentity(
            peerIds: Array(links.keys),
            linkedNpubByPeer: links
        )
        .map { Set($0) }

        #expect(groups.count == 2)
        #expect(groups.contains(Set(["fp-vincenzo", "fp-vincenzo-mac"])))
        #expect(groups.contains(Set(["fp-sara"])))
    }

    @Test
    func sameNpubMeshFingerprintsCollapseToOneHomeRow() {
        let npub = String(repeating: "ab", count: 32)
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        let rows: [String: SNDMRow] = [
            "abef0238b73563e6": SNDMRow(
                id: "abef0238b73563e6",
                title: "Vincenzo Palazzo",
                preview: "👀",
                time: "00:58",
                unread: false,
                presence: false,
                verified: false,
                isMarmot: false,
                lastDate: older
            ),
            "dfb13e10b8069122": SNDMRow(
                id: "dfb13e10b8069122",
                title: "Vincenzo Palazzo",
                preview: "Ok it is receiving notifica",
                time: "00:58",
                unread: true,
                presence: false,
                verified: false,
                isMarmot: false,
                lastDate: newer
            ),
            "sara-fp": SNDMRow(
                id: "sara-fp",
                title: "Sara D",
                preview: "hi",
                time: "00:01",
                unread: false,
                presence: false,
                verified: false,
                isMarmot: false,
                lastDate: older
            ),
        ]
        let linked = [
            "abef0238b73563e6": npub,
            "dfb13e10b8069122": npub,
            "sara-fp": String(repeating: "cd", count: 32),
        ]

        let collapsed = snCollapseMeshDMRowsByIdentity(
            rowsByPeer: rows,
            linkedNpubByPeer: linked,
            persistedFoldPeerIds: ["abef0238b73563e6"]
        )

        #expect(collapsed.count == 2)
        #expect(collapsed["abef0238b73563e6"] != nil)
        #expect(collapsed["dfb13e10b8069122"] == nil)
        #expect(collapsed["abef0238b73563e6"]?.preview == "Ok it is receiving notifica")
        #expect(collapsed["abef0238b73563e6"]?.unread == true)
        #expect(collapsed["abef0238b73563e6"]?.id == "abef0238b73563e6")
        #expect(collapsed["sara-fp"]?.title == "Sara D")
    }

    @Test
    func selectCanonicalMeshPeerPrefersPersistedFoldTarget() {
        #expect(
            snSelectCanonicalMeshPeerId(
                aliases: ["dfb13e10b8069122", "abef0238b73563e6"],
                persistedFoldPeerIds: ["dfb13e10b8069122"]
            ) == "dfb13e10b8069122"
        )
        #expect(
            snSelectCanonicalMeshPeerId(
                aliases: ["dfb13e10b8069122", "abef0238b73563e6"],
                persistedFoldPeerIds: []
            ) == "abef0238b73563e6"
        )
    }

    @Test
    func filterPeerKeysDropsConflictingFavoriteClaim() {
        // Reverse index may still list sara under vincenzo's npub if a stale
        // favorite claimed it; current linked map must drop her (Compose parity).
        let vincenzo = String(repeating: "ab", count: 32)
        let sara = String(repeating: "cd", count: 32)
        let filtered = snFilterPeerKeysMatchingNpubHex(
            candidates: ["fp-vincenzo", "fp-vincenzo-mac", "fp-sara"],
            linkedNpubHexByPeer: [
                "fp-vincenzo": vincenzo,
                "fp-vincenzo-mac": vincenzo,
                "fp-sara": sara,
            ],
            targetNpubHex: vincenzo
        )
        #expect(filtered == ["fp-vincenzo", "fp-vincenzo-mac"])
        #expect(!filtered.contains("fp-sara"))
    }

    @Test
    func liveMeshRoutePrefersConnectedAliasOverCanonical() {
        let connected = "dfb13e10b8069122"
        let canonical = "abef0238b73563e6"
        #expect(
            snSelectLiveMeshRoutePeerId(
                aliases: [canonical, connected],
                isConnected: { $0 == connected },
                isReachable: { _ in false },
                requireDirectConnection: true
            ) == connected
        )
        #expect(
            snSelectLiveMeshRoutePeerId(
                aliases: [canonical, connected],
                isConnected: { _ in false },
                isReachable: { $0 == connected },
                requireDirectConnection: true
            ) == nil
        )
        #expect(
            snSelectLiveMeshRoutePeerId(
                aliases: [canonical, connected],
                isConnected: { _ in false },
                isReachable: { $0 == connected },
                requireDirectConnection: false
            ) == connected
        )
    }

    @Test
    func rekeyAlignsLiveMeshRowWithFullPeerKeysCanonical() {
        // Live row is only under fingerprint B; full peerKeys universe prefers
        // inactive A (lexicographically smaller). Without rekey, Marmot fold
        // targets A while the mesh row stays at B → duplicate home rows.
        let live = "dfb13e10b8069122"
        let staleCanonical = "abef0238b73563e6"
        let rows: [String: SNDMRow] = [
            live: SNDMRow(
                id: live,
                title: "Vincenzo Palazzo",
                preview: "Ok it is receiving notifica",
                time: "00:58",
                unread: true,
                presence: false,
                verified: false,
                isMarmot: false,
                lastDate: Date(timeIntervalSince1970: 200)
            ),
        ]
        let aligned = snRekeyMeshRowsToCanonicalIds(rowsByPeer: rows) { key in
            key == live ? staleCanonical : nil
        }
        #expect(aligned.count == 1)
        #expect(aligned[staleCanonical] != nil)
        #expect(aligned[live] == nil)
        #expect(aligned[staleCanonical]?.id == staleCanonical)
        #expect(aligned[staleCanonical]?.preview == "Ok it is receiving notifica")
        #expect(aligned[staleCanonical]?.unread == true)
    }

    // MARK: Internet DM buckets (docs/CHAT-TYPES.md — id shape 6)

    /// The real shape from the bug report: the alias set is the canonical
    /// 16-hex short id, but the peer's internet reply is stored under their
    /// 64-hex Noise public key because they were out of BLE range.
    private static let peerShortId = "630dcd2966c43366"
    private static let peerNoiseKeyHex =
        "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

    /// Synthetic key material, not a real contact's: the test only needs
    /// `sha256(noiseKeyHex)[0..<16] == shortId` to hold, which any 32 bytes
    /// give. `PeerID(publicKey:)` does that derivation for real.
    private static let shortIdForNoiseKeyHex: (String) -> String? = { hex in
        Data(hexString: hex).map { PeerID(publicKey: $0).bare }
    }

    private func meshRow(
        _ id: String,
        _ text: String,
        at secs: TimeInterval,
        status: DeliveryStatus? = nil
    ) -> BitchatMessage {
        BitchatMessage(
            id: id,
            sender: "Peer",
            content: text,
            timestamp: Date(timeIntervalSince1970: secs),
            isRelay: false,
            isPrivate: true,
            deliveryStatus: status
        )
    }

    private func peerKeys(bucketKeys: [String]) -> [String] {
        snMeshPrivateChatKeys(
            aliases: [Self.peerShortId],
            noiseKeyBuckets: snMeshNoiseKeyBuckets(
                bucketKeys: bucketKeys,
                aliases: [Self.peerShortId],
                shortIdForNoiseKeyHex: Self.shortIdForNoiseKeyHex
            )
        )
    }

    @Test
    func outOfRangeInternetDmBucketIsPartOfTheTranscript() {
        // Derived from the live bucket keys, not from favorites: unfavouriting
        // the peer must not hide her transcript again.
        let keys = peerKeys(bucketKeys: [Self.peerShortId, Self.peerNoiseKeyHex])
        #expect(keys == [Self.peerShortId, Self.peerNoiseKeyHex])

        // Only the Noise-key bucket holds the newest row — exactly what the
        // chat-list preview showed while the transcript stayed a message behind.
        let buckets: [String: [BitchatMessage]] = [
            Self.peerNoiseKeyHex: [meshRow("m1", "reply over the internet", at: 200)],
        ]
        let merged = snMergeMeshPrivateChats(keys: keys) { buckets[$0] }
        #expect(merged.map(\.id) == ["m1"])
        #expect(snMeshPrivateChatCount(keys: keys) { buckets[$0] } == 1)
    }

    @Test
    func fingerprintShapedBucketAlsoResolves() {
        // The other 64-hex shape: the fingerprint, whose first 16 hex ARE the
        // short id. `MessageStore` holds real buckets in both shapes.
        let fingerprint = Self.peerShortId + String(repeating: "0", count: 48)
        let keys = peerKeys(bucketKeys: [Self.peerShortId, fingerprint])
        #expect(keys == [Self.peerShortId, fingerprint])
        // Key presence is not readability: assert the merge actually reaches
        // that bucket in the exact string form the key list carries.
        let buckets: [String: [BitchatMessage]] = [
            fingerprint: [meshRow("m1", "reply over the internet", at: 200)],
        ]
        #expect(snMergeMeshPrivateChats(keys: keys) { buckets[$0] }.map(\.id) == ["m1"])
    }

    @Test
    func receivedInternetRowOverridesTheConversationTransport() {
        // The rows this fix surfaces arrived over the internet while the peer
        // was out of BLE range; rendering them as Bluetooth bubbles would
        // contradict the chat's own header.
        #expect(snMeshRowVia(receivedViaInternet: true, default: .mesh) == .internet)
        #expect(snMeshRowVia(receivedViaInternet: true, default: .internet) == .internet)
        // Additive: nothing else changes. Our own sends carry nil.
        #expect(snMeshRowVia(receivedViaInternet: nil, default: .mesh) == .mesh)
        #expect(snMeshRowVia(receivedViaInternet: false, default: .mesh) == .mesh)
        #expect(snMeshRowVia(receivedViaInternet: nil, default: .internet) == .internet)
    }

    @Test
    func mirroredRowIsNotRenderedTwice() {
        // `mirrorToEphemeralIfNeeded` copies the row onto the short id once the
        // peer is live again, so both buckets can hold the same message id.
        let keys = peerKeys(bucketKeys: [Self.peerShortId, Self.peerNoiseKeyHex])
        let buckets: [String: [BitchatMessage]] = [
            Self.peerShortId: [
                meshRow("m0", "Y", at: 100),
                meshRow("m1", "reply over the internet", at: 200),
            ],
            Self.peerNoiseKeyHex: [meshRow("m1", "reply over the internet", at: 200)],
        ]
        let merged = snMergeMeshPrivateChats(keys: keys) { buckets[$0] }
        #expect(merged.map(\.id) == ["m0", "m1"])
        #expect(snMeshPrivateChatCount(keys: keys) { buckets[$0] } == 2)
    }

    @Test
    func aliasBucketWinsOverAStalerMirroredCopy() {
        // Several send paths update delivery status on ONE bucket only, so the
        // two copies of a mirrored row can diverge. The alias bucket — the one
        // `sendPrivateMessage` appends to and marks `.sent` — must win.
        let keys = peerKeys(bucketKeys: [Self.peerShortId, Self.peerNoiseKeyHex])
        let buckets: [String: [BitchatMessage]] = [
            Self.peerShortId: [
                meshRow("m0", "Y", at: 100),
                meshRow("m1", "reply", at: 200, status: .sent),
            ],
            Self.peerNoiseKeyHex: [meshRow("m1", "reply", at: 200, status: .sending)],
        ]
        let merged = snMergeMeshPrivateChats(keys: keys) { buckets[$0] }
        // The losing copy must be dropped, not merely ordered behind: exactly
        // one m1 survives, and it is the alias bucket's.
        #expect(merged.map(\.id) == ["m0", "m1"])
        #expect(merged.filter { $0.id == "m1" }.count == 1)
        #expect(merged.first { $0.id == "m1" }?.deliveryStatus == .sent)
    }

    @Test
    func unlinkedConversationKeepsSingleBucketReturn() {
        // No Noise-key bucket ⇒ single key; the single-bucket path must stay
        // identity-preserving (no re-sort, no dedup pass).
        let keys = peerKeys(bucketKeys: [Self.peerShortId])
        #expect(keys == [Self.peerShortId])
        let rows = [meshRow("m0", "Y", at: 100), meshRow("m1", "reply over the internet", at: 200)]
        let merged = snMergeMeshPrivateChats(keys: keys) { $0 == Self.peerShortId ? rows : nil }
        #expect(merged.map(\.id) == ["m0", "m1"])
    }

    @Test
    func anotherPeersNoiseKeyNeverJoinsTheTranscript() {
        let vincenzoNoiseKeyHex = String(repeating: "ab", count: 32)
        let keys = peerKeys(bucketKeys: [
            Self.peerShortId,
            Self.peerNoiseKeyHex,
            vincenzoNoiseKeyHex,
            "abef0238b73563e6",
        ])
        #expect(keys == [Self.peerShortId, Self.peerNoiseKeyHex])
        #expect(!keys.contains(vincenzoNoiseKeyHex))
    }

    @Test
    func nonHexAndAliasShapedBucketsAreNotDuplicated() {
        // A geohash/name-shaped 64-char key is not a Noise key, and an alias
        // already in the key list must not be appended a second time.
        let buckets = [
            Self.peerShortId,
            Self.peerNoiseKeyHex.uppercased(),
            String(repeating: "z", count: 64),
        ]
        let keys = peerKeys(bucketKeys: buckets)
        #expect(keys == [Self.peerShortId, Self.peerNoiseKeyHex])
    }
}
