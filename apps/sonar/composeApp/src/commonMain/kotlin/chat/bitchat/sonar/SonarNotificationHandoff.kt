package chat.bitchat.sonar

/** Where a notification tap should navigate once the local chat list is ready. */
sealed class SonarNotificationOpenTarget {
    data class MeshPeer(val peerId: String) : SonarNotificationOpenTarget()
    data class Chat(val chatId: String) : SonarNotificationOpenTarget()
}

/**
 * Shared helpers for notification tap → chat open and for clearing delivered
 * notifications when that chat is opened. Kept pure so Compose unit tests can
 * pin the handoff without constructing [SonarAppState].
 */
object SonarNotificationHandoff {
    const val EXTRA_CONVERSATION_ID = "sonar_conversation_id"
    private const val MESH_CHAT_PREFIX = "mesh:"

    /** Stable local-notification id used by [Notifier] (matches router idKey.hashCode()). */
    fun notificationId(conversationId: String): Int = conversationId.hashCode()

    /** Conversation ids whose delivered notifications should be dismissed together. */
    fun conversationIdsToClear(
        chatId: String,
        relatedIds: Collection<String> = emptyList(),
    ): Set<String> =
        buildSet {
            if (chatId.isNotBlank()) add(chatId)
            relatedIds.forEach { if (it.isNotBlank()) add(it) }
        }

    fun notificationIdsToClear(conversationIds: Collection<String>): Set<Int> =
        conversationIds
            .filter { it.isNotBlank() }
            .mapTo(linkedSetOf()) { notificationId(it) }

    /**
     * Resolve a notification conversation id onto a real open target.
     * Returns null when the id is not yet known locally — callers should
     * refresh and retry instead of inventing a blank chat screen.
     */
    fun resolveOpenTarget(
        conversationId: String,
        knownChatIds: Set<String>,
        foldedGroupPeerIds: Map<String, String>,
        foldedGroupIds: Set<String>,
    ): SonarNotificationOpenTarget? {
        val id = conversationId.trim()
        if (id.isEmpty()) return null
        foldedGroupPeerIds[id]?.takeIf { it.isNotBlank() }?.let {
            return SonarNotificationOpenTarget.MeshPeer(it)
        }
        if (id in knownChatIds) {
            if (id in foldedGroupIds) {
                foldedGroupPeerIds[id]?.takeIf { it.isNotBlank() }?.let {
                    return SonarNotificationOpenTarget.MeshPeer(it)
                }
            }
            return SonarNotificationOpenTarget.Chat(id)
        }
        if (id.startsWith(MESH_CHAT_PREFIX)) {
            val peerId = id.removePrefix(MESH_CHAT_PREFIX)
            if (peerId.isNotBlank()) return SonarNotificationOpenTarget.MeshPeer(peerId)
        }
        return null
    }
}
