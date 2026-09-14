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
/** Tap payload queued until the chat list is ready to open. */
data class PendingOpenConversation(
    val conversationId: String,
    val jumpMessageId: String? = null,
)

object SonarNotificationHandoff {
    const val EXTRA_CONVERSATION_ID = "sonar_conversation_id"
    /** Stable local message id for Jump open-action (#372). Optional. */
    const val EXTRA_MESSAGE_ID = "sonar_message_id"
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
     * Cold-start shade taps still name the hidden 0.8 id. FFI
     * `liveFoldTarget` is empty until the engine is up, but the host already
     * persisted hist→live in [sonar.historicalFolds]. FFI wins when present.
     */
    fun notificationLiveFoldTargets(
        conversationId: String,
        persistedFolds: Map<String, String>,
        ffiLiveFoldTarget: String?,
    ): Map<String, String> {
        val aliases = conversationIdAliases(conversationId)
        if (aliases.isEmpty()) return emptyMap()
        val targets = linkedMapOf<String, String>()
        fun remember(live: String) {
            val dest = live.trim().removePrefix("marmot:").trim()
            if (dest.isEmpty()) return
            for (from in aliases) targets[from] = dest
        }
        for (alias in aliases) {
            persistedFolds[alias]?.let { remember(it) }
        }
        ffiLiveFoldTarget?.trim()?.takeIf { it.isNotEmpty() }?.let { remember(it) }
        return targets
    }

    /** Bare hex plus optional `marmot:` prefix so either tap shape remaps. */
    fun conversationIdAliases(conversationId: String): Set<String> {
        val trimmed = conversationId.trim()
        if (trimmed.isEmpty()) return emptySet()
        val bare = trimmed.removePrefix("marmot:")
        return buildSet {
            add(trimmed)
            if (bare.isNotEmpty()) add(bare)
            if (bare.isNotEmpty() && !trimmed.startsWith("marmot:")) add("marmot:$bare")
        }
    }

    /**
     * Resolve a notification conversation id onto a real open target.
     * A persisted hist→live remap opens the live sibling even when that
     * id is not in [knownChatIds] yet (cold start / FFI hide). Unknown
     * ids without a fold still return null so callers can refresh/retry.
     */
    fun resolveOpenTarget(
        conversationId: String,
        knownChatIds: Set<String>,
        foldedGroupPeerIds: Map<String, String>,
        foldedGroupIds: Set<String>,
        liveFoldTargets: Map<String, String> = emptyMap(),
    ): SonarNotificationOpenTarget? {
        val id = conversationId.trim()
        if (id.isEmpty()) return null
        foldedGroupPeerIds[id]?.takeIf { it.isNotBlank() }?.let {
            return SonarNotificationOpenTarget.MeshPeer(it)
        }
        conversationIdAliases(id).firstNotNullOfOrNull { alias ->
            liveFoldTargets[alias]?.takeIf { it.isNotBlank() && it != id && it != alias }
        }?.let { live ->
            return SonarNotificationOpenTarget.Chat(live)
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

    fun normalizeJumpMessageId(messageId: String?): String? =
        messageId?.trim()?.takeIf { it.isNotEmpty() }
}
