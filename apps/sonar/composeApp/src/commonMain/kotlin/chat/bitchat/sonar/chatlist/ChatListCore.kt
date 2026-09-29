package chat.bitchat.sonar.chatlist

import chat.bitchat.sonar.SonarChat
import chat.bitchat.sonar.SonarConversationSummary
import chat.bitchat.sonar.SonarCore
import chat.bitchat.sonar.SonarGroupInvite
import chat.bitchat.sonar.SonarRecentTranscriptPage
import kotlinx.coroutines.flow.Flow

/**
 * The slice of [SonarCore] the chat list reads and writes.
 *
 * Every read here is a LOCAL store read. None of them waits on a relay,
 * which is what lets the list paint from local storage first (the
 * Signal-Comparable Performance Rule). Relay sync only ever reaches the list
 * indirectly: it writes into the store, and the store fires
 * [conversationChanged]. The row actions ([deleteChat], [leaveGroup]) are
 * writes; leaving also publishes a leave update, off the paint path.
 *
 * An interface so [ChatListRepository] and [ChatListPresenter] run on the JVM
 * against a fake core. Production uses [SonarCoreChatListCore]. It is also the
 * inventory of what a core-owned chat-list API has to answer; see
 * `docs/CHAT-LIST-PRESENTER.md`.
 */
internal interface ChatListCore {
    /** Every Marmot group this account belongs to, from the local store. */
    suspend fun chats(): List<SonarChat>

    /** One row per conversation from the core-owned index, newest first:
     *  latest message preview fields, message count and unread count. */
    suspend fun conversationSummaries(): List<SonarConversationSummary>

    /** Bounded newest-message windows for the [groupLimit] most recent chats. */
    suspend fun recentMessagePages(groupLimit: Int, pageLimit: Int): List<SonarRecentTranscriptPage>

    /** Multi-member group invites waiting for accept/decline, from the local store. */
    suspend fun pendingGroupInvites(): List<SonarGroupInvite>

    /** Zero the index's unread count for one Marmot group. */
    suspend fun markConversationRead(groupIdHex: String)

    /** Delete a 1:1 group from this device (the row's Delete). */
    suspend fun deleteChat(groupIdHex: String)

    /** Leave a multi-member group and remove it from this device. */
    suspend fun leaveGroup(groupIdHex: String)

    /** Group ids whose summary changed (message stored, unread reset). */
    val conversationChanged: Flow<String>
}

/** Production [ChatListCore]: every call goes straight to [SonarCore]. */
internal object SonarCoreChatListCore : ChatListCore {
    override suspend fun chats(): List<SonarChat> = SonarCore.chats()

    override suspend fun conversationSummaries(): List<SonarConversationSummary> =
        SonarCore.conversationSummaries()

    override suspend fun recentMessagePages(groupLimit: Int, pageLimit: Int): List<SonarRecentTranscriptPage> =
        SonarCore.recentMessagePages(groupLimit, pageLimit)

    override suspend fun pendingGroupInvites(): List<SonarGroupInvite> = SonarCore.pendingGroupInvites()

    override suspend fun markConversationRead(groupIdHex: String) =
        SonarCore.markConversationRead(groupIdHex)

    override suspend fun deleteChat(groupIdHex: String) = SonarCore.deleteChat(groupIdHex)

    override suspend fun leaveGroup(groupIdHex: String) = SonarCore.leaveGroup(groupIdHex)

    override val conversationChanged: Flow<String> get() = SonarCore.conversationChanged
}
