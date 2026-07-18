package chat.bitchat.sonar

/**
 * Shared helpers for notification tap → chat open and for clearing delivered
 * notifications when that chat is opened. Kept pure so Compose unit tests can
 * pin the handoff without constructing [SonarAppState].
 */
object SonarNotificationHandoff {
    const val EXTRA_CONVERSATION_ID = "sonar_conversation_id"

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
}
