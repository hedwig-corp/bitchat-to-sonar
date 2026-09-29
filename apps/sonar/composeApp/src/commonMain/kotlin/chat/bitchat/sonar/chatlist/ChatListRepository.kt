package chat.bitchat.sonar.chatlist

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import chat.bitchat.sonar.SonarChat
import chat.bitchat.sonar.SonarConversationSummary
import chat.bitchat.sonar.SonarGroupInvite
import chat.bitchat.sonar.SonarMsg
import chat.bitchat.sonar.hydrateLocalConversationRows
import chat.bitchat.sonar.orderChatsByLocalRecency
import chat.bitchat.sonar.pruneConfirmedUnreadSuppressions
import chat.bitchat.sonar.unreadCountsFromSummaries
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** Chats whose newest window [ChatListRepository.publishLocal] reads as real
 *  rows. Every chat below this carries a synthetic `summary:` placeholder. */
internal const val LOCAL_SUMMARY_CHAT_LIMIT = 5

/** Rows per window in [LOCAL_SUMMARY_CHAT_LIMIT]'s bounded pages. */
internal const val LOCAL_SUMMARY_PAGE_LIMIT = 20

/** Same-chat quiet time before a [ChatListCore.conversationChanged] burst is
 *  handled. Changes to DIFFERENT chats are debounced independently. */
internal const val CONVERSATION_CHANGE_DEBOUNCE_MS = 50L

/**
 * The chat list's local data layer: the conversation rows, the bounded
 * snapshot behind their previews, and unread counts, all read from the local
 * store through [ChatListCore].
 *
 * Moved out of `SonarAppState` behind the strangler seam. `SonarAppState`
 * still decides *when* to reload and runs the app-specific steps around a
 * reload (Note to Self, descriptors, invites, timezone); this class owns the
 * state and the parts that talk to core.
 *
 * State is Compose snapshot state where it was before ([chats],
 * [unreadByChat]) and plain fields where it was plain ([messagesByChat],
 * [latestByChat]), so reads from composition keep exactly their old
 * invalidation behaviour. Everything runs on [scope]'s dispatcher (the UI
 * scope in production), which is what makes the plain fields safe.
 */
internal class ChatListRepository(
    private val core: ChatListCore,
    private val scope: CoroutineScope,
    initialChats: List<SonarChat>,
    initialMessagesByChat: Map<String, List<SonarMsg>>,
    initialLatestByChat: Map<String, Long>,
    /** Group ids the user is looking at right now. Suppressed from [unreadByChat]
     *  for this refresh only, never stored (see [applyUnread]). */
    private val viewingGroupIds: () -> Set<String>,
    /** The reload body [refresh] coalesces. `SonarAppState.refreshChatsInner`. */
    private val reload: suspend () -> Unit,
) {
    /** Every Marmot group, ordered newest first by local recency. */
    var chats by mutableStateOf(initialChats)

    /** Bumped whenever [messagesByChat] is reassigned; feeds memo keys. */
    var messagesVersion = 0
        private set

    /** Bounded newest rows per group: real rows for the newest
     *  [LOCAL_SUMMARY_CHAT_LIMIT] chats, a synthetic `summary:` placeholder for
     *  the rest. Strip placeholders before any transcript use. */
    var messagesByChat: Map<String, List<SonarMsg>> = initialMessagesByChat
        set(value) {
            if (value !== field) {
                field = value
                messagesVersion++
            }
        }

    /** Newest message second per group, kept for rows with no real window. */
    var latestByChat: Map<String, Long> = initialLatestByChat

    /** Unread count per Marmot group id. A mesh route id is never a key. */
    var unreadByChat by mutableStateOf<Map<String, Long>>(emptyMap())
        private set

    /**
     * In-flight mark-read suppress only. Summary refresh must not restore
     * badges while `markConversationRead` is still running. Viewing suppress
     * is applied ephemerally in [applyUnread] from [viewingGroupIds], never
     * stored here (storing it let prune keep failed marks forever).
     */
    private val unreadSuppressGroupIds = linkedSetOf<String>()

    private val refreshMutex = Mutex()
    private var refreshRunning = false
    private var refreshPending = false
    private var refreshCompletion: CompletableDeferred<Unit>? = null

    /** Per-key debounce jobs for [collectChanges]: rapid changes to the SAME
     *  chat coalesce, but a burst across DIFFERENT chats no longer drops the
     *  losers (a stream-wide `debounce` kept only the last groupId, deferring
     *  the others' call/pay ring to a housekeeping cycle). */
    private val conversationChangeJobs = mutableMapOf<String, Job>()
    private var conversationChangesCollecting = false

    /** The local store's group list. */
    suspend fun loadChats(): List<SonarChat> = core.chats()

    /** Pending multi-member group invites; empty when the store cannot say. */
    suspend fun loadInvites(): List<SonarGroupInvite> =
        runCatching { core.pendingGroupInvites() }.getOrDefault(emptyList())

    /**
     * Publish one coherent local snapshot of [localChats]: summaries for every
     * row, bounded pages for the newest [LOCAL_SUMMARY_CHAT_LIMIT], ordered by
     * local recency with [previousOrder] as the tie-break. Local reads only.
     *
     * Previously `chats = loadedChats` rendered the core's raw order, then a
     * suspension in `recentMessagePages()` let Compose paint again before the
     * recency sort. That two-step hydrate was the visible startup reorder, so
     * every read happens before the first write.
     */
    suspend fun publishLocal(localChats: List<SonarChat>, previousOrder: List<String>) {
        val activeIds = localChats.mapTo(hashSetOf()) { it.id }
        val summaries = if (localChats.isEmpty()) emptyList() else runCatching {
            core.conversationSummaries()
        }.getOrDefault(emptyList())
        val pages = if (localChats.isEmpty()) emptyList() else runCatching {
            core.recentMessagePages(LOCAL_SUMMARY_CHAT_LIMIT, LOCAL_SUMMARY_PAGE_LIMIT)
        }.getOrDefault(emptyList())
        val hydration = hydrateLocalConversationRows(
            activeChatIds = activeIds,
            existingMessagesByChat = messagesByChat,
            existingLatestByChat = latestByChat,
            summaries = summaries,
            pages = pages,
        )
        messagesByChat = hydration.messagesByChat
        latestByChat = hydration.latestByChat
        chats = orderChatsByLocalRecency(
            chats = localChats,
            latestSecs = { hydration.latestByChat[it] ?: 0L },
            previousOrder = previousOrder,
        )
    }

    /** Drop the snapshot (wipe, restore, folded-chat delete). */
    fun clearSnapshot() {
        messagesByChat = emptyMap()
        latestByChat = emptyMap()
    }

    /**
     * Coalesce concurrent refresh requests: one owner runs [reload], other
     * callers await the same completion, and burst arrivals become one
     * trailing pass. A failure completes every waiter exceptionally.
     */
    suspend fun refresh() {
        var owner = false
        var completion: CompletableDeferred<Unit>? = null
        refreshMutex.withLock {
            if (refreshRunning) {
                refreshPending = true
                completion = refreshCompletion ?: CompletableDeferred<Unit>().also { refreshCompletion = it }
            } else {
                refreshRunning = true
                completion = CompletableDeferred()
                refreshCompletion = completion
                owner = true
            }
        }
        val currentCompletion = completion ?: return
        if (!owner) {
            currentCompletion.await()
            return
        }

        var completed = false
        var failure: Throwable? = null
        try {
            while (true) {
                reload()
                val finishedCompletion = refreshMutex.withLock {
                    if (refreshPending) {
                        refreshPending = false
                        null
                    } else {
                        refreshRunning = false
                        refreshCompletion.also { refreshCompletion = null }
                    }
                }
                if (finishedCompletion != null) {
                    finishedCompletion.complete(Unit)
                    completed = true
                    return
                }
            }
        } catch (t: Throwable) {
            failure = t
            throw t
        } finally {
            if (!completed) {
                withContext(NonCancellable) {
                    val failedCompletion = refreshMutex.withLock {
                        refreshRunning = false
                        refreshPending = false
                        refreshCompletion.also { refreshCompletion = null }
                    }
                    if (failedCompletion != null) {
                        val error = failure
                        if (error == null) failedCompletion.complete(Unit)
                        else failedCompletion.completeExceptionally(error)
                    }
                }
            }
        }
    }

    /**
     * Start handling [ChatListCore.conversationChanged] (idempotent). Each
     * group id is debounced on its own for [CONVERSATION_CHANGE_DEBOUNCE_MS],
     * then handed to [onChange].
     */
    fun collectChanges(onChange: suspend (groupIdHex: String) -> Unit) {
        if (conversationChangesCollecting) return
        conversationChangesCollecting = true
        core.conversationChanged
            .onEach { groupIdHex ->
                conversationChangeJobs.remove(groupIdHex)?.cancel()
                conversationChangeJobs[groupIdHex] = scope.launch {
                    delay(CONVERSATION_CHANGE_DEBOUNCE_MS)
                    onChange(groupIdHex)
                    conversationChangeJobs.remove(groupIdHex)
                }
            }
            .launchIn(scope)
    }

    /** Optimistically clear badges and ask core to zero unread for [groupIds]. */
    fun markRead(groupIds: Collection<String>) {
        if (groupIds.isEmpty()) return
        val marked = groupIds.toSet()
        unreadSuppressGroupIds.addAll(marked)
        unreadByChat = unreadByChat - marked
        scope.launch {
            for (groupId in marked) {
                runCatching { core.markConversationRead(groupId) }
            }
            // End in-flight suppress for this batch, then reconcile from core.
            // Open-session suppress is re-applied inside applyUnread so a
            // failed mark (or a message that landed after mark) cannot hide a
            // real badge for the rest of the process.
            val summaries = runCatching { core.conversationSummaries() }
                .getOrNull()
            unreadSuppressGroupIds.removeAll(marked)
            // null = FFI failure — keep the current map (do not wipe every badge).
            // emptyList() is a real empty inbox and must clear badges.
            if (summaries != null) applyUnread(summaries)
        }
    }

    /** Re-read unread counts from core. A failed read keeps the current map. */
    suspend fun refreshUnread() {
        val summaries = runCatching { core.conversationSummaries() }.getOrNull()
            ?: return
        applyUnread(summaries)
    }

    fun applyUnread(summaries: List<SonarConversationSummary>) {
        // Viewing suppress is session-scoped and must NOT enter
        // unreadSuppressGroupIds. Prune keeps still-unread in-flight ids; if
        // viewed ids were folded into that set, a failed mark while viewing
        // would leave the group suppressed forever after the user leaves
        // (goose/glm NO-GO on #383). iOS keeps the same split via
        // viewingUnreadGroupIds.
        val openIds = viewingGroupIds()
        val pruned = pruneConfirmedUnreadSuppressions(
            unreadSuppressGroupIds.toSet(),
            summaries,
        )
        unreadSuppressGroupIds.clear()
        unreadSuppressGroupIds.addAll(pruned)
        unreadByChat = unreadCountsFromSummaries(summaries, unreadSuppressGroupIds + openIds)
    }

    /** Drop [groupIds]' badges without marking them read (their chat is gone). */
    fun forgetUnread(groupIds: Collection<String>) {
        unreadByChat = unreadByChat - groupIds.toSet()
    }

    /** Account wipe/erase: in-flight suppressions must not outlive the chats. */
    fun clearUnreadSuppressions() {
        unreadSuppressGroupIds.clear()
    }

    internal fun seedUnreadForTest(unread: Map<String, Long>) {
        unreadByChat = unread
    }
}
