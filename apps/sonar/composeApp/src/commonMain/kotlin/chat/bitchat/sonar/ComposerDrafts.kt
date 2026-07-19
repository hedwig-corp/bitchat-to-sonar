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

/** Channel / geo-dm keys stay namespaced so they never collide with DM ids. */
fun composerDraftKeyForChannel(geohash: String): String =
    if (geohash == "mesh") "mesh" else "geo:$geohash"

fun composerDraftKeyForGeoDm(geohash: String, peerHex: String): String =
    "geodm:$geohash:$peerHex"
