package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SonarNotificationHandoffTest {
    @Test
    fun notificationIdMatchesRouterIdKeyHash() {
        val chatId = "mesh:deadbeef"
        assertEquals(chatId.hashCode(), SonarNotificationHandoff.notificationId(chatId))
        assertEquals(
            SonarNotificationRouter.build(
                idKey = chatId,
                kind = SonarNotificationKind.Message,
                conversationTitle = "Alice",
            )?.id,
            SonarNotificationHandoff.notificationId(chatId),
        )
    }

    @Test
    fun conversationIdsToClearUnionsRelatedIdsAndDropsBlanks() {
        assertEquals(
            setOf("chat-a", "group-1", "mesh:peer"),
            SonarNotificationHandoff.conversationIdsToClear(
                chatId = "chat-a",
                relatedIds = listOf("group-1", "", "mesh:peer", "chat-a"),
            ),
        )
    }

    @Test
    fun notificationIdsToClearAreStablePerConversation() {
        val ids = SonarNotificationHandoff.notificationIdsToClear(
            listOf("chat-a", "chat-b", "chat-a", ""),
        )
        assertEquals(2, ids.size)
        assertTrue(SonarNotificationHandoff.notificationId("chat-a") in ids)
        assertTrue(SonarNotificationHandoff.notificationId("chat-b") in ids)
    }

    @Test
    fun resolveOpenTargetRemapsFoldedGroupToMeshPeer() {
        assertEquals(
            SonarNotificationOpenTarget.MeshPeer("peer-a"),
            SonarNotificationHandoff.resolveOpenTarget(
                conversationId = "group-hex",
                knownChatIds = setOf("group-hex", "mesh:peer-a"),
                foldedGroupPeerIds = mapOf("group-hex" to "peer-a"),
                foldedGroupIds = setOf("group-hex"),
            ),
        )
    }

    @Test
    fun resolveOpenTargetOpensKnownChatAndMeshId() {
        assertEquals(
            SonarNotificationOpenTarget.Chat("group-1"),
            SonarNotificationHandoff.resolveOpenTarget(
                conversationId = "group-1",
                knownChatIds = setOf("group-1"),
                foldedGroupPeerIds = emptyMap(),
                foldedGroupIds = emptySet(),
            ),
        )
        assertEquals(
            SonarNotificationOpenTarget.MeshPeer("deadbeef"),
            SonarNotificationHandoff.resolveOpenTarget(
                conversationId = "mesh:deadbeef",
                knownChatIds = emptySet(),
                foldedGroupPeerIds = emptyMap(),
                foldedGroupIds = emptySet(),
            ),
        )
    }

    @Test
    fun resolveOpenTargetReturnsNullForUnknownId() {
        assertNull(
            SonarNotificationHandoff.resolveOpenTarget(
                conversationId = "missing-group",
                knownChatIds = setOf("other"),
                foldedGroupPeerIds = emptyMap(),
                foldedGroupIds = emptySet(),
            ),
        )
    }

    @Test
    fun resolveOpenTargetRemapsFoldedHistoricalIdOntoLiveSibling() {
        assertEquals(
            SonarNotificationOpenTarget.Chat("group-09"),
            SonarNotificationHandoff.resolveOpenTarget(
                conversationId = "group-08",
                knownChatIds = setOf("group-09"),
                foldedGroupPeerIds = emptyMap(),
                foldedGroupIds = emptySet(),
                liveFoldTargets = mapOf("group-08" to "group-09"),
            ),
        )
        assertEquals(
            SonarNotificationOpenTarget.Chat("missing-live"),
            SonarNotificationHandoff.resolveOpenTarget(
                conversationId = "group-08",
                knownChatIds = setOf("group-09"),
                foldedGroupPeerIds = emptyMap(),
                foldedGroupIds = emptySet(),
                liveFoldTargets = mapOf("group-08" to "missing-live"),
            ),
        )
        assertEquals(
            SonarNotificationOpenTarget.Chat("group-09"),
            SonarNotificationHandoff.resolveOpenTarget(
                conversationId = "group-08",
                knownChatIds = emptySet(),
                foldedGroupPeerIds = emptyMap(),
                foldedGroupIds = emptySet(),
                liveFoldTargets = mapOf("group-08" to "group-09"),
            ),
        )
    }

    @Test
    fun notificationLiveFoldTargetsUsesPersistedBlobWhenFfiIsDown() {
        val fromBlob = SonarNotificationHandoff.notificationLiveFoldTargets(
            conversationId = "marmot:group-08",
            persistedFolds = mapOf("group-08" to "group-09"),
            ffiLiveFoldTarget = null,
        )
        assertEquals("group-09", fromBlob["group-08"])
        assertEquals("group-09", fromBlob["marmot:group-08"])
        assertEquals(
            SonarNotificationOpenTarget.Chat("group-09"),
            SonarNotificationHandoff.resolveOpenTarget(
                conversationId = "marmot:group-08",
                knownChatIds = setOf("group-09"),
                foldedGroupPeerIds = emptyMap(),
                foldedGroupIds = emptySet(),
                liveFoldTargets = fromBlob,
            ),
        )
    }

    @Test
    fun notificationLiveFoldTargetsPrefersFfiOverStaleBlob() {
        val fromFfi = SonarNotificationHandoff.notificationLiveFoldTargets(
            conversationId = "group-08",
            persistedFolds = mapOf("group-08" to "stale-09"),
            ffiLiveFoldTarget = "group-09",
        )
        assertEquals("group-09", fromFfi["group-08"])
        assertEquals(
            emptyMap(),
            SonarNotificationHandoff.notificationLiveFoldTargets(
                conversationId = "group-08",
                persistedFolds = emptyMap(),
                ffiLiveFoldTarget = null,
            ),
        )
        val fromRemount = SonarNotificationHandoff.notificationLiveFoldTargets(
            conversationId = "marmot:group-08",
            persistedFolds = emptyMap(),
            ffiLiveFoldTarget = null,
            openedConversationId = "group-09",
            openedConversationPaneId = "group-08",
        )
        assertEquals("group-09", fromRemount["group-08"])
        assertEquals("group-09", fromRemount["marmot:group-08"])
        assertEquals(
            SonarNotificationOpenTarget.Chat("group-09"),
            SonarNotificationHandoff.resolveOpenTarget(
                conversationId = "marmot:group-08",
                knownChatIds = setOf("group-09"),
                foldedGroupPeerIds = emptyMap(),
                foldedGroupIds = emptySet(),
                liveFoldTargets = fromRemount,
            ),
        )
        assertEquals(
            "stale-09",
            SonarNotificationHandoff.notificationLiveFoldTargets(
                conversationId = "group-08",
                persistedFolds = mapOf("group-08" to "stale-09"),
                ffiLiveFoldTarget = null,
                openedConversationId = "group-09",
                openedConversationPaneId = "group-08",
            )["group-08"],
            "persist-folds win over remount pair",
        )
        val fromUnrelatedPersist = SonarNotificationHandoff.notificationLiveFoldTargets(
            conversationId = "marmot:group-08",
            persistedFolds = mapOf("other-08" to "other-09"),
            ffiLiveFoldTarget = null,
            openedConversationId = "group-09",
            openedConversationPaneId = "group-08",
        )
        assertEquals("group-09", fromUnrelatedPersist["group-08"])
        assertEquals("group-09", fromUnrelatedPersist["marmot:group-08"])
    }

    @Test
    fun normalizeJumpMessageIdTrimsAndDropsBlanks() {
        assertEquals("msg-1", SonarNotificationHandoff.normalizeJumpMessageId(" msg-1 "))
        assertNull(SonarNotificationHandoff.normalizeJumpMessageId("   "))
        assertNull(SonarNotificationHandoff.normalizeJumpMessageId(null))
    }

    @Test
    fun pendingOpenConversationCarriesOptionalJump() {
        val req = PendingOpenConversation("chat-a", jumpMessageId = "msg-9")
        assertEquals("chat-a", req.conversationId)
        assertEquals("msg-9", req.jumpMessageId)
        assertNull(PendingOpenConversation("chat-b").jumpMessageId)
    }
}
