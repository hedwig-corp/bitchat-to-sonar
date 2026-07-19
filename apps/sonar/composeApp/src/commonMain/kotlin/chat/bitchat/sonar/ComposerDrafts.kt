package chat.bitchat.sonar

/** Durable composer-draft blob key (local process only — no cross-device sync). */
const val COMPOSER_DRAFTS_BLOB_KEY = "composer.drafts.v1"

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

/**
 * Encode drafts as `chatId=<hex-utf8>` lines (same shape as mesh-name blobs).
 * Values are hex-framed so newlines/`=` in typed text cannot inject lines.
 */
fun encodeComposerDrafts(drafts: Map<String, String>): String =
    drafts.entries
        .filter { it.key.isNotBlank() && it.value.isNotEmpty() }
        .joinToString("\n") { "${it.key}=${hexEncodeUtf8(it.value)}" }

fun decodeComposerDrafts(blob: String): Map<String, String> =
    blob.lineSequence()
        .mapNotNull { line ->
            val i = line.indexOf('=')
            if (i <= 0) return@mapNotNull null
            val key = line.substring(0, i)
            if (key.isBlank()) return@mapNotNull null
            val raw = line.substring(i + 1)
            val value = hexDecodeUtf8(raw) ?: raw
            if (value.isEmpty()) null else key to value
        }
        .toMap()
