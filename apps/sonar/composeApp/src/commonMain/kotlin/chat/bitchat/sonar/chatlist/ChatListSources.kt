package chat.bitchat.sonar.chatlist

import chat.bitchat.sonar.MarmotRowModel
import chat.bitchat.sonar.MeshDmRow
import chat.bitchat.sonar.SonarChat
import chat.bitchat.sonar.SonarGroupInvite

/**
 * The conversation projection [ChatListPresenter] reads, and the actions it
 * asks for, that `SonarAppState` still owns: folding a Bluetooth peer and their
 * White Noise groups into one person (R-003), deduping duplicate direct
 * groups, pending chats, titles from kind-0 profiles, mutes and presence.
 *
 * Reads must be Compose snapshot state, or memoized over it, so the presenter
 * recomposes when they change. Everything here is local; nothing waits on a
 * relay.
 *
 * This interface is deliberately the pilot's to-do list: each member is logic
 * that both apps implement separately today (`SonarAppState.kt` and
 * `SonarAppStore.swift`) and that should move into `sonar-core` so iOS can
 * share it. See `docs/CHAT-LIST-PRESENTER.md`.
 */
internal interface ChatListSources {
    /** Mesh storage and the Marmot store have formed one local Home model. */
    val homeMessagesHydrated: Boolean

    /** A catch-up sync is in flight (status chip hint only). */
    val catchingUp: Boolean

    val groupInvites: List<SonarGroupInvite>

    /** One row per person met over Bluetooth, White Noise legs folded in. */
    val meshRows: List<MeshDmRow>

    /** Standalone Marmot conversations: folded groups removed, duplicate
     *  direct groups deduped, pending chats and Note to Self included. */
    val marmotChats: List<SonarChat>

    /** The real Note to Self group id once ensured, else null. */
    val noteToSelfGroupId: String?

    /** Memoized row view models for [marmotChats], by chat id. Read once per
     *  pass: every read re-checks the memo key. */
    val marmotRows: Map<String, MarmotRowModel>

    fun openChat(chat: SonarChat)
    fun openDm(peerId: String, name: String)
    fun acceptGroupInvite(inviteId: String)
    fun declineGroupInvite(inviteId: String)
    fun muteChat(conversationId: String, durationSecs: Long?)
    fun unmuteChat(conversationId: String)
    fun deleteMarmotChat(chatId: String)
    fun deleteMeshDm(peerId: String)
}
