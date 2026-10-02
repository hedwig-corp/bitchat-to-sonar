package chat.bitchat.sonar.chatlist

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import chat.bitchat.sonar.MarmotRowModel
import chat.bitchat.sonar.MeshDmRow
import chat.bitchat.sonar.SonarChat
import chat.bitchat.sonar.SonarConversationListKind
import chat.bitchat.sonar.SonarConversationListRow
import chat.bitchat.sonar.SonarConversationPreview
import chat.bitchat.sonar.SonarConversationSummary
import chat.bitchat.sonar.directMarmotPeerKey
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

    /** The account's own npub, for [coreLikeConversationRows]' fold. */
    var ownNpub = "npub1me"
    var noteToSelfId: String? = null
    /** When set, [conversationList] answers exactly this. */
    var listRows: List<SonarConversationListRow>? = null
    var failList = false
    var listCalls = 0
        private set

    override suspend fun conversationList(): List<SonarConversationListRow> {
        listCalls++
        if (failList) error("conversation list read failed")
        return listRows ?: coreLikeConversationRows(chats, summaries, ownNpub, noteToSelfId, rememberedNames)
    }

    val rememberedNames = mutableMapOf<String, String>()
    override suspend fun rememberPeerNames(names: Map<String, String>) {
        rememberedNames += names
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

    override val marmotRows: Map<String, MarmotRowModel> get() = rowModels

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

/**
 * What core's `conversation_list` answers for [chats] + [summaries]
 * (`core/sonar-core/src/conversation_list.rs`): direct chats with the same
 * counterpart fold into one row (newest group first, lowest id on a tie),
 * unread is summed over the set and is 0 for Note to Self, which sorts first;
 * then newest first, id on a tie. Core's own tests pin the real rule; this is
 * the fake's copy so host tests see core-shaped rows.
 */
internal fun coreLikeConversationRows(
    chats: List<SonarChat>,
    summaries: List<SonarConversationSummary>,
    ownNpub: String,
    noteToSelfId: String?,
    names: Map<String, String> = emptyMap(),
): List<SonarConversationListRow> {
    val byId = summaries.associateBy { it.groupIdHex }
    val latest = { gid: String -> byId[gid]?.latestAtSecs ?: 0L }
    val buckets = LinkedHashMap<String, MutableList<SonarChat>>()
    for (chat in chats) {
        val key = if (chat.id == noteToSelfId) "\u0000${chat.id}"
        else directMarmotPeerKey(chat, ownNpub) ?: "\u0000${chat.id}"
        buckets.getOrPut(key) { mutableListOf() } += chat
    }
    return buckets.values.map { set ->
        val sorted = set.sortedWith(compareByDescending<SonarChat> { latest(it.id) }.thenBy { it.id })
        val head = sorted.first()
        val nts = head.id == noteToSelfId
        val newest = sorted.firstNotNullOfOrNull { c -> byId[c.id]?.takeIf { it.latestAtSecs > 0 } }
        SonarConversationListRow(
            conversationId = head.id,
            kind = when {
                nts -> SonarConversationListKind.NoteToSelf
                directMarmotPeerKey(head, ownNpub) != null -> SonarConversationListKind.Direct
                else -> SonarConversationListKind.Group
            },
            groupIds = sorted.map { it.id },
            counterpartHex = directMarmotPeerKey(head, ownNpub),
            name = sorted.firstOrNull { it.name.isNotEmpty() }?.name ?: "",
            title = when {
                nts -> null
                directMarmotPeerKey(head, ownNpub) != null ->
                    names[directMarmotPeerKey(head, ownNpub)]
                        ?: sorted.firstOrNull { it.name.isNotEmpty() }?.name
                else -> sorted.firstOrNull { it.name.isNotEmpty() }?.name
            },
            preview = newest?.latestContent?.let { SonarConversationPreview.Text(it) }
                ?: SonarConversationPreview.Empty,
            latestContent = newest?.latestContent ?: "",
            latestSenderHex = newest?.latestSenderNpub ?: "",
            latestAtSecs = newest?.latestAtSecs ?: 0L,
            latestMine = newest?.latestMine ?: false,
            latestGroupId = newest?.groupIdHex ?: head.id,
            messageCount = sorted.sumOf { byId[it.id]?.messageCount ?: 0L },
            unreadCount = if (nts) 0L else sorted.sumOf { byId[it.id]?.unreadCount ?: 0L },
            version = sorted.sumOf { byId[it.id]?.messageCount ?: 0L } + sorted.size,
        )
    }.sortedWith(
        compareByDescending<SonarConversationListRow> { it.kind == SonarConversationListKind.NoteToSelf }
            .thenByDescending { it.latestAtSecs }
            .thenBy { it.conversationId },
    )
}
