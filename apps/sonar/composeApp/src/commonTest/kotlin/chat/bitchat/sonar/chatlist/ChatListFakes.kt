package chat.bitchat.sonar.chatlist

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import chat.bitchat.sonar.MarmotRowModel
import chat.bitchat.sonar.MeshDmRow
import chat.bitchat.sonar.SonarChat
import chat.bitchat.sonar.SonarConversationSummary
import chat.bitchat.sonar.SonarGroupInvite
import chat.bitchat.sonar.SonarRecentTranscriptPage
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableSharedFlow

/**
 * A local store with no relay behind it. Gates let a test hold a read or a
 * mark "in flight"; counters show how much work a burst actually cost.
 */
internal class FakeChatListCore : ChatListCore {
    var chats: List<SonarChat> = emptyList()
    var summaries: List<SonarConversationSummary> = emptyList()
    var pages: List<SonarRecentTranscriptPage> = emptyList()

    /** While set and incomplete, [chats] suspends (a slow local read). */
    var chatsGate: CompletableDeferred<Unit>? = null
    /** While set and incomplete, [markConversationRead] suspends. */
    var markGate: CompletableDeferred<Unit>? = null
    var failMarks = false
    var failSummaries = false

    var chatsCalls = 0
        private set
    var summariesCalls = 0
        private set
    val markedRead = mutableListOf<String>()

    val changes = MutableSharedFlow<String>(extraBufferCapacity = 64)
    override val conversationChanged get() = changes

    override suspend fun chats(): List<SonarChat> {
        chatsCalls++
        chatsGate?.await()
        return chats
    }

    override suspend fun conversationSummaries(): List<SonarConversationSummary> {
        summariesCalls++
        if (failSummaries) error("summaries read failed")
        return summaries
    }

    override suspend fun recentMessagePages(groupLimit: Int, pageLimit: Int): List<SonarRecentTranscriptPage> =
        pages.take(groupLimit)

    override suspend fun markConversationRead(groupIdHex: String) {
        markGate?.await()
        if (failMarks) error("mark failed")
        markedRead += groupIdHex
        summaries = summaries.map { if (it.groupIdHex == groupIdHex) it.copy(unreadCount = 0L) else it }
    }
}

internal fun summary(
    groupId: String,
    latestAtSecs: Long,
    unread: Long = 0L,
    content: String = "hi from $groupId",
    count: Long = 1L,
) = SonarConversationSummary(
    groupIdHex = groupId,
    name = "",
    latestContent = content,
    latestSenderNpub = "npub1peer",
    latestAtSecs = latestAtSecs,
    latestMine = false,
    messageCount = count,
    unreadCount = unread,
)

internal fun marmotRowModel(
    chat: SonarChat,
    title: String = chat.name,
    sub: String = "Tap to open",
    tsSecs: Long = 0L,
    groupIds: List<String> = listOf(chat.id),
    verified: Boolean = false,
    pending: Boolean = false,
    multiMember: Boolean = false,
) = MarmotRowModel(
    id = chat.id,
    title = title,
    sub = sub,
    tsSecs = tsSecs,
    verified = verified,
    groupIds = groupIds,
    pending = pending,
    multiMember = multiMember,
)

/**
 * Stands in for the projection `SonarAppState` owns (folding, dedupe, titles).
 * Every field is snapshot state, like the real one, so the presenter under
 * Molecule recomposes when a test changes it. Actions are recorded.
 */
internal class FakeChatListSources : ChatListSources {
    override var homeMessagesHydrated by mutableStateOf(true)
    override var catchingUp by mutableStateOf(false)
    override var groupInvites by mutableStateOf<List<SonarGroupInvite>>(emptyList())
    override var meshRows by mutableStateOf<List<MeshDmRow>>(emptyList())
    override var marmotChats by mutableStateOf<List<SonarChat>>(emptyList())
    override var noteToSelfGroupId by mutableStateOf<String?>(null)
    var rowModels by mutableStateOf<Map<String, MarmotRowModel>>(emptyMap())

    val actions = mutableListOf<String>()

    override fun marmotRow(chatId: String): MarmotRowModel =
        rowModels[chatId] ?: error("no row model for $chatId")

    override fun openChat(chat: SonarChat) { actions += "openChat:${chat.id}" }
    override fun openDm(peerId: String, name: String) { actions += "openDm:$peerId:$name" }
    override fun acceptGroupInvite(inviteId: String) { actions += "accept:$inviteId" }
    override fun declineGroupInvite(inviteId: String) { actions += "decline:$inviteId" }
    override fun muteChat(conversationId: String, durationSecs: Long?) { actions += "mute:$conversationId:$durationSecs" }
    override fun unmuteChat(conversationId: String) { actions += "unmute:$conversationId" }
    override fun deleteMarmotChat(chatId: String) { actions += "deleteMarmot:$chatId" }
    override fun deleteMeshDm(peerId: String) { actions += "deleteMesh:$peerId" }

    /** Show [chats] as standalone Marmot rows with these row models. */
    fun showMarmot(vararg rows: Pair<SonarChat, MarmotRowModel>) {
        marmotChats = rows.map { it.first }
        rowModels = rows.associate { it.first.id to it.second }
    }
}
