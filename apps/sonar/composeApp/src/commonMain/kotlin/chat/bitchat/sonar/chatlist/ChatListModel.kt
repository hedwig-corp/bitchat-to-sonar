package chat.bitchat.sonar.chatlist

import androidx.compose.runtime.Immutable
import chat.bitchat.sonar.SonarChat
import chat.bitchat.sonar.SonarGroupInvite

/**
 * Everything the Messages list renders, as one immutable value.
 *
 * Produced by [ChatListPresenter]; rendered by the phone Home screen and the
 * desktop sidebar. Rows are already merged across transports, ordered by
 * recency and pinned (Note to Self first), so a renderer only lays them out.
 */
@Immutable
internal data class ChatListModel(
    /** False until mesh storage and the encrypted Marmot store formed one
     *  coherent local model. Relay state never enters this flag. */
    val hydrated: Boolean,
    /** A foreground or push-tap catch-up sync is running. A passive hint for
     *  the status chip; it never gates paint or sending. */
    val catchingUp: Boolean,
    /** Pending group invites, pinned above the rows as actionable banners. */
    val invites: List<SonarGroupInvite>,
    /** One row per conversation, newest first, Note to Self pinned on top. */
    val rows: List<ChatListRow>,
    /** The active filter; rows already match it. Empty = no filter. */
    val query: String = "",
) {
    /** Nothing to show: no invites and no rows. */
    val empty: Boolean get() = invites.isEmpty() && rows.isEmpty()

    /** List key of the last item, whose divider hides (design
     *  `.bc-list .bc-row:last-child::after { display: none }`). */
    val lastKey: String?
        get() = rows.lastOrNull()?.key ?: invites.lastOrNull()?.let { inviteKey(it) }

    companion object {
        fun inviteKey(invite: SonarGroupInvite): String = "invite:" + invite.id
    }
}

/**
 * One conversation row. The two kinds are structurally different chats (see
 * `docs/CHAT-TYPES.md`), so they stay two types rather than one row with
 * nullable halves.
 */
@Immutable
internal sealed interface ChatListRow {
    /** Stable LazyColumn key, unique across both kinds. */
    val key: String
    val title: String
    val preview: String
    /** Newest message second; 0 when the row has none yet. */
    val tsSecs: Long
    val unread: Boolean
    val verified: Boolean
    /** The conversation id mutes and notifications are keyed on
     *  (`mesh:<peerId>` for a mesh-folded row, the group id otherwise). */
    val conversationId: String

    /**
     * A person first met over Bluetooth, with any White Noise legs folded in
     * (one row per person, R-003). Opens through `openDm`.
     */
    @Immutable
    data class Mesh(
        val peerId: String,
        override val title: String,
        override val preview: String,
        override val tsSecs: Long,
        override val unread: Boolean,
        override val verified: Boolean,
    ) : ChatListRow {
        override val key: String get() = "mesh:$peerId"
        override val conversationId: String get() = "mesh:$peerId"
    }

    /**
     * A pure White Noise/Marmot conversation: a 1:1 (duplicate groups folded),
     * a group, a chat still being set up, or Note to Self. Opens through
     * `openChat`.
     */
    @Immutable
    data class Marmot(
        val chat: SonarChat,
        override val title: String,
        override val preview: String,
        override val tsSecs: Long,
        override val unread: Boolean,
        override val verified: Boolean,
        /** Secure-chat setup is still in flight; row actions are disabled. */
        val pending: Boolean,
        /** A multi-member group (leave, not delete). */
        val group: Boolean,
        val noteToSelf: Boolean,
    ) : ChatListRow {
        override val key: String get() = chat.id
        override val conversationId: String get() = chat.id
    }
}

/** What the Messages list can be asked to do. */
internal sealed interface ChatListEvent {
    /** Open a row's conversation. Opening marks it read, so the unread state
     *  at open is captured before the mark (see `docs/CHAT-TYPES.md`). */
    data class Open(val row: ChatListRow) : ChatListEvent

    /** Narrow the rows to those whose title, preview or group name contains
     *  [query] (case-insensitive). Blank clears the filter. */
    data class Filter(val query: String) : ChatListEvent

    data class AcceptInvite(val inviteId: String) : ChatListEvent
    data class DeclineInvite(val inviteId: String) : ChatListEvent

    /** Mute [conversationId] for [durationSecs]; null = until turned back on. */
    data class Mute(val conversationId: String, val durationSecs: Long?) : ChatListEvent
    data class Unmute(val conversationId: String) : ChatListEvent

    /** Delete a 1:1 (every duplicate group) or leave a group ([mesh] false,
     *  [id] = group id), or delete a mesh conversation with its folded White
     *  Noise legs ([mesh] true, [id] = peer id). */
    data class Delete(val id: String, val mesh: Boolean) : ChatListEvent
}
