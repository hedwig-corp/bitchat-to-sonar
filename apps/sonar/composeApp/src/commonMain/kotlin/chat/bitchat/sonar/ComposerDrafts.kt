package chat.bitchat.sonar

/**
 * Session-scoped composer draft map updates.
 *
 * Empty text removes the chat's entry so navigating away and back restores
 * only real in-progress drafts (Signal-style in-memory draft until send).
 */
fun updatedComposerDrafts(
    drafts: Map<String, String>,
    chatId: String,
    text: String,
): Map<String, String> {
    if (text.isEmpty()) {
        if (!drafts.containsKey(chatId)) return drafts
        return drafts - chatId
    }
    if (drafts[chatId] == text) return drafts
    return drafts + (chatId to text)
}

/**
 * Carry one chat's composer entry (draft text, pending reply) across an id swap
 * — a pending conversation reconciling to its real White Noise/Marmot group
 * while the user is typing. Without it the draft typed during setup vanished
 * when the route swapped (QA-A19). An entry already under [toChatId] wins; the
 * pending key is always dropped.
 */
fun <V> movedComposerEntry(entries: Map<String, V>, fromChatId: String, toChatId: String): Map<String, V> {
    if (fromChatId == toChatId) return entries
    val moving = entries[fromChatId] ?: return entries
    val rest = entries - fromChatId
    return if (rest.containsKey(toChatId)) rest else rest + (toChatId to moving)
}

/** Channel / geo-dm keys stay namespaced so they never collide with DM ids. */
fun composerDraftKeyForChannel(geohash: String): String =
    if (geohash == "mesh") "mesh" else "geo:$geohash"

fun composerDraftKeyForGeoDm(geohash: String, peerHex: String): String =
    "geodm:$geohash:$peerHex"
