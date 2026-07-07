package chat.bitchat.sonar

/**
 * The ⚡REACT message convention (mesh sibling of NIP-25): mesh chats have no
 * Nostr events, so reactions ride the encrypted chat content like ⚡PAY:
 *
 *   ⚡REACT|1|<targetMessageId>|<emoji>|<add|remove>
 *
 * Lines persist with the transcript like any message and are folded into the
 * target message's [SonarMsg.reactions] at display time (last-write-wins per
 * sender — one reaction per person, a new add replaces). Unknown versions
 * render as plain text (forward-compatible, same as ⚡PAY).
 */
data class ReactionLine(val targetMessageId: String, val emoji: String, val add: Boolean) {
    fun encoded(): String = "⚡REACT|1|$targetMessageId|$emoji|${if (add) "add" else "remove"}"

    companion object {
        private const val PREFIX = "⚡REACT|"
        private const val MAX_EMOJI_CODE_POINTS = 16
        private const val MAX_TARGET_ID_LENGTH = 64

        /** Cheap prefilter so hot paths (previews, folds) skip the full
         *  decode for ordinary chat lines. */
        fun isReactionLine(content: String): Boolean = content.startsWith(PREFIX)

        fun decode(content: String): ReactionLine? {
            if (!content.startsWith(PREFIX)) return null
            val parts = content.split("|")
            if (parts.size != 5 || parts[1] != "1") return null
            val target = parts[2].trim()
            // Mirror the iOS validator exactly (hex-or-dash target, non-empty
            // emoji for BOTH verbs) so the platforms accept and reject the
            // same lines and never diverge on a peer-crafted payload.
            if (target.isEmpty() || target.length > MAX_TARGET_ID_LENGTH) return null
            // ASCII-only: Char.isDigit() accepts Unicode digits (e.g. ٩) that
            // iOS Character.isHexDigit rejects — keep both validators identical.
            if (!target.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' || it == '-' }) return null
            val add = when (parts[4]) { "add" -> true; "remove" -> false; else -> return null }
            val emoji = parts[3].trim()
            if (emoji.isEmpty()) return null
            if (codePointCount(emoji) > MAX_EMOJI_CODE_POINTS) return null
            return ReactionLine(target, emoji, add)
        }

        private fun codePointCount(s: String): Int {
            var i = 0
            var n = 0
            while (i < s.length) {
                i += if (s[i].isHighSurrogate() && i + 1 < s.length && s[i + 1].isLowSurrogate()) 2 else 1
                n++
            }
            return n
        }
    }
}

/**
 * Fold ⚡REACT control lines out of a transcript: the lines are removed from the
 * visible list and aggregated (in list order, last-write-wins per sender) into
 * the [SonarMsg.reactions] of their target messages, merged with any
 * core-provided (Marmot kind-7) aggregate. Pure — runs in the state holder,
 * never on the composable render path. Cheap no-op when no line is present.
 */
internal fun foldMeshReactions(source: List<SonarMsg>): List<SonarMsg> {
    if (source.none { it.content.startsWith("⚡REACT|") }) return source
    // target id → (sender key → current emoji; null = cleared). "" = me.
    val byTarget = HashMap<String, LinkedHashMap<String, String?>>()
    val visible = ArrayList<SonarMsg>(source.size)
    for (m in source) {
        val line = ReactionLine.decode(m.content)
        if (line == null) { visible.add(m); continue }
        // A local reaction send that FAILED must not fold: the peer never got
        // it, so showing the chip would lie. (Sending/sent lines fold
        // optimistically like normal local echoes.)
        if (m.mine && sonarDeliveryFailed(m.state)) continue
        val senderKey = if (m.mine) "" else m.senderNpub.ifBlank { "?" }
        val perSender = byTarget.getOrPut(line.targetMessageId) { LinkedHashMap() }
        if (line.add) {
            perSender[senderKey] = line.emoji
        } else if (perSender[senderKey] == line.emoji) {
            // A remove only clears its own named emoji, so a stale/duplicated
            // remove arriving after a replace never wipes the newer reaction
            // (matches the iOS fold semantics).
            perSender[senderKey] = null
        }
    }
    if (byTarget.isEmpty()) return visible
    return visible.map { m ->
        val senders = byTarget[m.id] ?: return@map m
        var mineEmoji: String? = null
        val counts = LinkedHashMap<String, Int>()
        for ((sender, emoji) in senders) {
            if (emoji == null) continue
            counts[emoji] = (counts[emoji] ?: 0) + 1
            if (sender.isEmpty()) mineEmoji = emoji
        }
        val merged = LinkedHashMap<String, SonarReaction>()
        for (r in m.reactions) merged[r.emoji] = r
        for ((emoji, count) in counts) {
            val existing = merged[emoji]
            merged[emoji] = SonarReaction(
                emoji = emoji,
                count = (existing?.count ?: 0) + count,
                mine = existing?.mine == true || emoji == mineEmoji,
            )
        }
        if (merged.isEmpty()) m
        else m.copy(
            reactions = merged.values.sortedWith(
                compareByDescending<SonarReaction> { it.count }.thenBy { it.emoji }
            )
        )
    }
}
