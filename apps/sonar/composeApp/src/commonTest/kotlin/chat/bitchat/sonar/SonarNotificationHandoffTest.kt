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
}
