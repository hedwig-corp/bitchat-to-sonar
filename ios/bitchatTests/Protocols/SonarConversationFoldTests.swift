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
            snConversationRefreshIds(
                changedGroupId: "group-08",
                listedGroupIds: ["group-09"],
                historicalFolds: ["group-08": "group-09"]
            ) == ["group-09"]
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
                changedGroupId: "group-08",
                listedGroupIds: [],
                historicalFolds: ["group-08": "group-09"]
            ) == ["group-08"]
        )
        #expect(
            snConversationChangeTargetId(
                changedGroupId: "group-08",
                listedGroupIds: ["group-09"],
                historicalFolds: ["group-08": "group-09"]
            ) == "group-09"
        )
        #expect(
            snPendingUploadLookupGroupIds(
                groupId: "group-08",
                historicalFolds: ["group-08": "group-09"]
            ) == ["group-08", "group-09"]
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
            !snNewestPageShouldMergeFamilyWindow(
                existingCanonicalCount: 40,
                hiddenSiblingHasRows: false,
                hasFoldFamily: false,
                pinnedToOlderEdge: false
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
        #expect(snFoldedSiblingHasMore(historicalHasMore: true, liveHasMore: false))
        #expect(snFoldedSiblingHasMore(historicalHasMore: false, liveHasMore: true))
        #expect(!snFoldedSiblingHasMore(historicalHasMore: false, liveHasMore: false))
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
            snPaymentActivityPeerKeys(
                conversationId: "group-08",
                historicalFolds: ["group-08": "group-09"]
            ) == [
                "group-08", "marmot:group-08",
                "group-09", "marmot:group-09",
            ]
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
