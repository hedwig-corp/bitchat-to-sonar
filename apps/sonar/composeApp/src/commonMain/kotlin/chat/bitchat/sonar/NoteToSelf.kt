package chat.bitchat.sonar

/** Stable pending id used before the solo Marmot group is ensured. */
internal const val PENDING_NOTE_TO_SELF_ID = "note-to-self"

/** Display title for the Signal-style Note to Self row. */
internal const val NOTE_TO_SELF_TITLE = "Note to Self"

/** Placeholder chat shown in the list until [SonarCore.ensureNoteToSelf] lands. */
internal fun pendingNoteToSelfChat(ownNpub: String): SonarChat =
    SonarChat(
        id = PENDING_NOTE_TO_SELF_ID,
        name = NOTE_TO_SELF_TITLE,
        members = listOf(ownNpub).filter { it.isNotBlank() },
    )

internal fun isNoteToSelfChatId(chatId: String, noteToSelfGroupId: String?): Boolean =
    chatId == PENDING_NOTE_TO_SELF_ID ||
        (noteToSelfGroupId != null && chatId == noteToSelfGroupId)

internal fun isNoteToSelfChat(chat: SonarChat, noteToSelfGroupId: String?): Boolean =
    isNoteToSelfChatId(chat.id, noteToSelfGroupId) ||
        (chat.name == NOTE_TO_SELF_TITLE && chat.members.size <= 1)

/**
 * Pin Note to Self at the top of the home message list (Signal-style), then
 * keep the remaining rows in recency order.
 */
internal fun pinNoteToSelfHomeRows(
    rows: List<HomeMessageRow>,
    noteToSelfGroupId: String?,
): List<HomeMessageRow> {
    val (pinned, rest) = rows.partition { row ->
        row is HomeMessageRow.Marmot && isNoteToSelfChat(row.chat, noteToSelfGroupId)
    }
    if (pinned.isEmpty()) return rows
    return listOf(pinned.first()) + rest
}
