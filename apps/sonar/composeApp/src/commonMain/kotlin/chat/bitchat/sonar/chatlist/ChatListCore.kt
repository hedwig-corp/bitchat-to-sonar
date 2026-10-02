package chat.bitchat.sonar.chatlist

import chat.bitchat.sonar.SonarChat
import chat.bitchat.sonar.SonarConversationListRow
import chat.bitchat.sonar.SonarConversationSummary
import chat.bitchat.sonar.SonarCore
import chat.bitchat.sonar.SonarRecentTranscriptPage
import kotlinx.coroutines.flow.Flow

/**
 * The slice of [SonarCore] the chat list reads and writes.
 *
 * Every call here is a LOCAL store read or write. None of them waits on a
 * relay, which is what lets the list paint from local storage first (the
 * Signal-Comparable Performance Rule). Relay sync only ever reaches the list
 * indirectly: it writes into the store, and the store fires
 * [conversationChanged].
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

    /** The Marmot half of the Messages list as core folds it: one row per
     *  conversation, duplicate direct groups folded, unread summed over each
     *  row's groups, Note to Self first. The same rows iOS renders. */
    suspend fun conversationList(): List<SonarConversationListRow>

    /** Seed core's display-name cache (pubkey hex → name), which titles rows. */
    suspend fun rememberPeerNames(names: Map<String, String>)

    /** Bounded newest-message windows for the [groupLimit] most recent chats. */
    suspend fun recentMessagePages(groupLimit: Int, pageLimit: Int): List<SonarRecentTranscriptPage>

    /** Zero the index's unread count for one Marmot group. */
    suspend fun markConversationRead(groupIdHex: String)

    /** Group ids whose summary changed (message stored, unread reset). */
    val conversationChanged: Flow<String>
}

/** Production [ChatListCore]: every call goes straight to [SonarCore]. */
internal object SonarCoreChatListCore : ChatListCore {
    override suspend fun chats(): List<SonarChat> = SonarCore.chats()

    override suspend fun conversationSummaries(): List<SonarConversationSummary> =
        SonarCore.conversationSummaries()

    override suspend fun conversationList(): List<SonarConversationListRow> =
        SonarCore.conversationList()

    override suspend fun rememberPeerNames(names: Map<String, String>) =
        SonarCore.rememberPeerNames(names)

    override suspend fun recentMessagePages(groupLimit: Int, pageLimit: Int): List<SonarRecentTranscriptPage> =
        SonarCore.recentMessagePages(groupLimit, pageLimit)

    override suspend fun markConversationRead(groupIdHex: String) =
        SonarCore.markConversationRead(groupIdHex)

    override val conversationChanged: Flow<String> get() = SonarCore.conversationChanged
}
