package chat.bitchat.sonar

/**
 * Composer-side `@mention` logic: which group members match the token being
 * typed, and what text picking one inserts.
 *
 * This is the *authoring* half only. Deciding whether a received message
 * mentions you, and where its spans are, belongs to the Rust core
 * (`sonar_parse_mentions` / `sonar_mentions_pubkey`) — exactly one decoder
 * reads message content, the same rule `MessageClassification` follows
 * (R-017 in `docs/REGRESSIONS.md`). Nothing here parses an incoming message.
 *
 * Kept pure and free of `SonarCore` so `commonTest` can exercise it on the JVM
 * without loading the native library.
 */

/** A group member the picker can offer. [suffixHex4] is the last 4 hex of their
 * public key, used to disambiguate two members sharing a display name. */
data class MentionCandidate(
    val npub: String,
    val name: String,
    val suffixHex4: String?,
)

/** A mention located in a message, paired with the group member it names.
 *  [npub] is null when the name answers to nobody in this group — a hand-typed
 *  mention, an ambiguous bare name, or a member who has since renamed. */
data class ResolvedMention(
    val span: SonarMentionSpan,
    val npub: String?,
)

/**
 * Everything a transcript row needs to know about its mentions, decoded once
 * per message and memoized by the caller — never recomputed per frame.
 */
data class MentionInfo(
    val mentions: List<ResolvedMention>,
    val mentionsMe: Boolean,
) {
    val isEmpty: Boolean get() = mentions.isEmpty()

    companion object {
        val EMPTY = MentionInfo(emptyList(), false)
    }
}

object Mentions {

    /** Cap on offered suggestions, matching the mesh composer's list. */
    const val MAX_SUGGESTIONS: Int = 5

    /** Mirrors the core scanner's name class (`[\p{L}0-9_]`). */
    private fun isNameChar(c: Char): Boolean = c.isLetter() || c.isDigit() || c == '_'

    /**
     * The part of a display name that can survive on the wire.
     *
     * A kind-0 name is free text — "John Doe", "alice (work)" — but the wire
     * grammar stops at the first character outside the name class. Emitting
     * `@John Doe` would put `@John` on the wire and resolve to nobody, so the
     * token is built from this leading run instead, and a truncated name is
     * forced to carry the `#abcd` suffix so it still resolves by key.
     */
    internal fun wireName(name: String): String = name.takeWhile { isNameChar(it) }

    /**
     * The `@token` currently being typed at the end of [draft], without its
     * `@`, or null when the caret is not inside a mention.
     *
     * Returns an empty string for a lone trailing `@`, which is what opens the
     * picker with the full roster. Like the mesh composer, this assumes the
     * caret sits at the end of the draft.
     */
    fun activeQuery(draft: String): String? {
        val at = draft.lastIndexOf('@')
        if (at < 0) return null
        // Same left boundary as the core scanner: start-of-text or whitespace,
        // so `a@b.com` never opens the picker.
        if (at > 0 && !draft[at - 1].isWhitespace()) return null
        val token = draft.substring(at + 1)
        if (!token.all { isNameChar(it) }) return null
        return token
    }

    /**
     * Roster members whose name starts with the active query, case-insensitively.
     *
     * Empty when the caret is not in a mention, so callers can use emptiness as
     * "hide the picker".
     */
    fun matches(
        draft: String,
        roster: List<MentionCandidate>,
        limit: Int = MAX_SUGGESTIONS,
    ): List<MentionCandidate> {
        val query = activeQuery(draft) ?: return emptyList()
        val needle = query.lowercase()
        return roster
            .filter { it.name.isNotBlank() && it.name.lowercase().startsWith(needle) }
            .filter { isMentionable(it, roster) }
            .sortedBy { it.name.lowercase() }
            .take(limit)
    }

    /**
     * Whether a member can be written as a mention that will actually resolve.
     *
     * Two ways it cannot: the name has no leading run of wire-legal characters
     * ("🎉 party"), so there is no token to build; or the name needs the `#abcd`
     * key to identify its owner — it collides, or it had to be truncated — but
     * the member has no usable key (an npub that would not parse). Offering
     * either produces a mention that silently resolves to nobody, which reads to
     * the sender as "I mentioned them" and to the recipient as nothing at all.
     */
    internal fun isMentionable(pick: MentionCandidate, roster: List<MentionCandidate>): Boolean {
        val name = wireName(pick.name)
        if (name.isEmpty()) return false
        val needsKey = needsSuffix(pick, roster) || name != pick.name
        return !needsKey || pick.suffixHex4 != null
    }

    /**
     * True when [pick] shares a display name with another roster member, so the
     * inserted token must carry the `#abcd` disambiguator.
     */
    fun needsSuffix(pick: MentionCandidate, roster: List<MentionCandidate>): Boolean =
        roster.any { it.npub != pick.npub && it.name.equals(pick.name, ignoreCase = true) }

    /**
     * The text a picked suggestion contributes: `@name`, or `@name#abcd` when
     * the name alone is ambiguous within this group.
     *
     * Bare is preferred for readability and for parity with the mesh composer.
     * The cost is that a bare mention stops resolving if that member renames —
     * the documented trade-off of keeping the wire plain text.
     */
    fun token(pick: MentionCandidate, roster: List<MentionCandidate>): String {
        val name = wireName(pick.name)
        val suffix = pick.suffixHex4
        // The suffix is required when the name alone cannot identify the member:
        // either another member answers to it, or it had to be truncated to fit
        // the wire grammar and so no longer equals the sender's display name.
        val needsKey = needsSuffix(pick, roster) || name != pick.name
        return if (suffix != null && needsKey) "@$name#$suffix" else "@$name"
    }

    /**
     * [draft] with the active `@token` replaced by [pick]'s mention plus a
     * trailing space. Returns [draft] unchanged when the caret is not inside a
     * mention, so a stale tap cannot corrupt the draft.
     */
    fun applyPick(
        draft: String,
        pick: MentionCandidate,
        roster: List<MentionCandidate>,
    ): String {
        if (activeQuery(draft) == null) return draft
        val at = draft.lastIndexOf('@')
        return draft.substring(0, at) + token(pick, roster) + " "
    }
}
