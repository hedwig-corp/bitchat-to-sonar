package chat.bitchat.sonar.chatlist

import app.cash.turbine.test
import chat.bitchat.sonar.SonarChat
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The chat list's local data layer against a store with no relay behind it.
 * These pin the code `SonarAppState` now delegates to: the per-chat change
 * debounce, the single-flight reload, and unread with in-flight mark-read.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ChatListRepositoryTest {
    private val giulia = SonarChat("g-giulia", "", listOf("npub1me", "npub1giulia"))
    private val sara = SonarChat("g-sara", "", listOf("npub1me", "npub1sara"))
    private val team = SonarChat("g-team", "Team", listOf("npub1me", "npub1a", "npub1b"))

    private fun TestScope.repository(
        core: FakeChatListCore,
        scope: CoroutineScope = backgroundScope,
        viewing: () -> Set<String> = { emptySet() },
        reload: (suspend (ChatListRepository) -> Unit)? = null,
    ): ChatListRepository {
        lateinit var repo: ChatListRepository
        repo = ChatListRepository(
            core = core,
            scope = scope,
            initialChats = emptyList(),
            initialMessagesByChat = emptyMap(),
            initialLatestByChat = emptyMap(),
            viewingGroupIds = viewing,
            reload = {
                if (reload != null) reload(repo)
                else repo.publishLocal(repo.loadChats(), repo.chats.map { it.id })
            },
        )
        return repo
    }

    @Test
    fun aBurstOfChangesToOneChatIsHandledOnce() = runTest {
        val core = FakeChatListCore()
        val repo = repository(core)
        val handled = Channel<String>(Channel.UNLIMITED)
        repo.collectChanges { handled.send(it) }
        runCurrent()

        handled.receiveAsFlow().test {
            // Five stored messages 10 ms apart: one quiet window, one handle.
            repeat(5) {
                core.changes.emit(giulia.id)
                advanceTimeBy(10)
            }
            expectNoEvents()
            advanceTimeBy(CONVERSATION_CHANGE_DEBOUNCE_MS)
            runCurrent()
            assertEquals(giulia.id, awaitItem())
            expectNoEvents()
        }
    }

    @Test
    fun aBurstAcrossChatsHandlesEveryChatOnce() = runTest {
        val core = FakeChatListCore()
        val repo = repository(core)
        val handled = Channel<String>(Channel.UNLIMITED)
        repo.collectChanges { handled.send(it) }
        runCurrent()

        handled.receiveAsFlow().test {
            // A stream-wide debounce kept only the last id; each chat must win.
            listOf(giulia.id, sara.id, giulia.id, team.id, sara.id).forEach {
                core.changes.emit(it)
                advanceTimeBy(5)
            }
            advanceTimeBy(CONVERSATION_CHANGE_DEBOUNCE_MS)
            runCurrent()
            assertEquals(setOf(giulia.id, sara.id, team.id), setOf(awaitItem(), awaitItem(), awaitItem()))
            expectNoEvents()
        }
    }

    @Test
    fun concurrentRefreshesCoalesceIntoOneTrailingReload() = runTest {
        val core = FakeChatListCore().apply {
            chats = listOf(giulia, sara)
            summaries = listOf(summary(giulia.id, 100), summary(sara.id, 200))
            chatsGate = CompletableDeferred()
        }
        val repo = repository(core)

        // The first caller owns the reload and is parked in a slow local read;
        // nine more arrive meanwhile (a burst of conversation changes).
        val callers = List(10) { async { repo.refresh() } }
        runCurrent()
        assertEquals(1, core.chatsCalls)

        core.chatsGate!!.complete(Unit)
        callers.awaitAll()
        // One owner pass plus ONE trailing pass for everything that arrived
        // while it ran — not ten reloads.
        assertEquals(2, core.chatsCalls)
        assertEquals(listOf(sara.id, giulia.id), repo.chats.map { it.id })
    }

    @Test
    fun aFailedReloadFailsItsWaitersAndLetsTheNextRefreshRun() = runTest {
        val core = FakeChatListCore().apply { chats = listOf(giulia) }
        var fail = true
        val repo = repository(core, reload = { r ->
            if (fail) error("store not readable yet")
            r.publishLocal(r.loadChats(), emptyList())
        })
        assertTrue(runCatching { repo.refresh() }.isFailure)
        fail = false
        repo.refresh()
        assertEquals(listOf(giulia.id), repo.chats.map { it.id })
    }

    @Test
    fun publishLocalPaintsEveryChatFromTheIndexWithoutReadingEveryTranscript() = runTest {
        // Seven chats; bounded pages exist only for the newest five. The rest
        // still get a subtitle and a sort key from the summary index.
        val chats = (1..7).map { SonarChat("g$it", "", listOf("npub1me", "npub1p$it")) }
        val core = FakeChatListCore().apply {
            this.chats = chats
            summaries = chats.mapIndexed { i, c -> summary(c.id, latestAtSecs = 1_000L + i) }
        }
        val repo = repository(core)
        repo.refresh()

        assertEquals(chats.reversed().map { it.id }, repo.chats.map { it.id }, "newest first")
        val oldest = repo.messagesByChat.getValue("g1").single()
        assertTrue(oldest.id.startsWith("summary:g1:"), "a synthetic subtitle row, not a transcript row")
        assertEquals("hi from g1", oldest.content)
        assertEquals(1_000L, repo.latestByChat["g1"])
    }

    @Test
    fun markReadClearsTheBadgeAtOnceAndHoldsItWhileTheMarkIsInFlight() = runTest {
        val core = FakeChatListCore().apply {
            summaries = listOf(summary(giulia.id, 100, unread = 3), summary(sara.id, 90, unread = 1))
            markGate = CompletableDeferred()
        }
        val repo = repository(core)
        repo.refreshUnread()
        assertEquals(mapOf(giulia.id to 3L, sara.id to 1L), repo.unreadByChat)

        repo.markRead(listOf(giulia.id))
        assertNull(repo.unreadByChat[giulia.id], "optimistic: the badge clears before core answers")
        runCurrent()

        // A housekeeping refresh lands while the mark is still in flight and
        // core still says 3. It must not flash the badge back.
        repo.refreshUnread()
        assertNull(repo.unreadByChat[giulia.id])
        assertEquals(1L, repo.unreadByChat[sara.id], "other chats keep their badges")

        core.markGate!!.complete(Unit)
        runCurrent()
        assertEquals(listOf(giulia.id), core.markedRead)
        assertNull(repo.unreadByChat[giulia.id])
    }

    @Test
    fun aFailedMarkReleasesTheSuppressionSoARealBadgeComesBack() = runTest {
        val core = FakeChatListCore().apply {
            summaries = listOf(summary(giulia.id, 100, unread = 2))
            failMarks = true
        }
        val repo = repository(core)
        repo.refreshUnread()
        repo.markRead(listOf(giulia.id))
        runCurrent()
        // Core never zeroed it, so hiding it for the rest of the process would
        // lose a real unread message (#383).
        assertEquals(2L, repo.unreadByChat[giulia.id])
    }

    @Test
    fun theOpenChatIsSuppressedOnlyWhileItIsOpen() = runTest {
        var viewing = setOf(giulia.id)
        val core = FakeChatListCore().apply { summaries = listOf(summary(giulia.id, 100, unread = 2)) }
        val repo = repository(core, viewing = { viewing })
        repo.refreshUnread()
        assertNull(repo.unreadByChat[giulia.id], "a message landing in the open chat leaves no badge")

        viewing = emptySet()
        repo.refreshUnread()
        assertEquals(2L, repo.unreadByChat[giulia.id], "viewing suppress is never stored")
    }

    @Test
    fun aFailedSummaryReadKeepsTheBadgesItHad() = runTest {
        val core = FakeChatListCore().apply { summaries = listOf(summary(giulia.id, 100, unread = 2)) }
        val repo = repository(core)
        repo.refreshUnread()
        core.failSummaries = true
        repo.refreshUnread()
        assertEquals(2L, repo.unreadByChat[giulia.id], "an FFI failure is not an empty inbox")
    }
}
