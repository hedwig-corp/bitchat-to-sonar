package chat.bitchat.sonar

import app.cash.molecule.RecompositionMode
import app.cash.molecule.moleculeFlow
import app.cash.turbine.test
import chat.bitchat.sonar.chatlist.ChatListEvent
import chat.bitchat.sonar.chatlist.ChatListPresenter
import chat.bitchat.sonar.chatlist.ChatListRow
import chat.bitchat.sonar.chatlist.FakeChatListCore
import chat.bitchat.sonar.chatlist.summary
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.io.path.createTempDirectory
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * The chat-list presenter over a REAL `SonarAppState` whose core is faked at
 * the [chat.bitchat.sonar.chatlist.ChatListCore] seam: the real reload body,
 * the real fold/dedupe projection, the real open path. This is the call site
 * both the phone Home screen and the desktop sidebar render, which the
 * helper-level tests cannot pin (docs/REGRESSIONS.md, Unguarded).
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ChatListAppStateTest {
    private val me = "npub1me"
    private val giulia = SonarChat("aa01", "", listOf(me, "npub1giulia"))
    // Both sides created a direct group: one person, two groups (R-003).
    private val giuliaAgain = SonarChat("aa02", "", listOf(me, "npub1giulia"))
    private val team = SonarChat("bb01", "Team", listOf(me, "npub1ann", "npub1bob"))

    @AfterTest
    fun restore() = DesktopEnv.useTestRoot(null)

    /** A signed-in account whose last session left [restored] on disk. */
    private fun TestScope.state(core: FakeChatListCore, restored: List<SonarChat> = emptyList()): SonarAppState {
        DesktopEnv.useTestRoot(createTempDirectory("sonar-chat-list").toFile())
        SonarCore.saveBlob("sonar.npub", me)
        if (restored.isNotEmpty()) {
            SonarCore.saveBlob(
                CHAT_SNAPSHOT_BLOB_KEY,
                encodeChatSnapshot(restored, emptyMap(), restored.mapIndexed { i, c -> c.id to 1_000L - i }.toMap()),
            )
        }
        return SonarAppState(backgroundScope, core)
    }

    private fun SonarAppState.desktopPresenter() =
        ChatListPresenter(chatList, chatListSources, waitForHydration = false)

    @Test
    fun theSidebarPaintsTheRestoredSnapshotBeforeTheStoreOpens() = runTest {
        val core = FakeChatListCore()
        val s = state(core, restored = listOf(team, giulia))

        moleculeFlow(RecompositionMode.Immediate) { s.desktopPresenter().present(MutableSharedFlow()) }.test {
            val first = awaitItem()
            assertEquals(listOf(team.id, giulia.id), first.rows.map { it.key }.filterNot(::isNoteToSelfPlaceholder))
            assertEquals("Team", first.rows.first { it.key == team.id }.title)
            assertEquals(0, core.chatsCalls + core.summariesCalls, "first paint touched nothing but local prefs")
        }
    }

    @Test
    fun aLocalReloadReordersTheRowsAndFoldsDuplicateGroupsIntoOneBadge() = runTest {
        val core = FakeChatListCore().apply {
            chats = listOf(team, giulia, giuliaAgain)
            summaries = listOf(
                summary(giuliaAgain.id, 900, unread = 2, content = "are you there?"),
                summary(giulia.id, 500),
                summary(team.id, 700),
            )
        }
        val s = state(core, restored = listOf(team, giulia))

        moleculeFlow(RecompositionMode.Immediate) { s.desktopPresenter().present(MutableSharedFlow()) }.test {
            awaitItem()
            s.chatList.refresh()
            val rows = expectMostRecentItem().rows.filterNot { isNoteToSelfPlaceholder(it.key) }
            // One row for Giulia although she has two groups, carrying the
            // newest message of either, badged from the group that has it.
            assertEquals(2, rows.size)
            val giuliaRow = rows.first() as ChatListRow.Marmot
            assertTrue(giuliaRow.chat.id in setOf(giulia.id, giuliaAgain.id))
            assertEquals("are you there?", giuliaRow.preview)
            assertTrue(giuliaRow.unread)
            assertEquals(team.id, rows[1].key)
            assertFalse(rows[1].unread)
        }
    }

    @Test
    fun openingAFoldedOneToOneMarksEveryDuplicateGroupRead() = runTest {
        val core = FakeChatListCore().apply {
            chats = listOf(giulia, giuliaAgain)
            summaries = listOf(summary(giuliaAgain.id, 900, unread = 2), summary(giulia.id, 500, unread = 1))
        }
        val s = state(core)
        s.chatList.refresh()
        val events = MutableSharedFlow<ChatListEvent>(extraBufferCapacity = 4)

        moleculeFlow(RecompositionMode.Immediate) { s.chatListPresenterForTest().present(events) }.test {
            val row = expectMostRecentItem().rows.single { !isNoteToSelfPlaceholder(it.key) }
            assertTrue(row.unread)
            events.emit(ChatListEvent.Open(row))
            // The badge clears in the very next model, before core answers.
            assertFalse(awaitItem().rows.single { !isNoteToSelfPlaceholder(it.key) }.unread)
            runCurrent()
            assertEquals(setOf(giulia.id, giuliaAgain.id), core.markedRead.toSet())
            cancelAndIgnoreRemainingEvents()
        }
    }

    /** The phone presenter, on a Home the test marks hydrated. */
    private fun SonarAppState.chatListPresenterForTest(): ChatListPresenter {
        markHomeHydratedForTest()
        return chatListPresenter
    }

    // Before the core has ensured Note to Self, the list pins a local
    // placeholder row; it is not what these tests are about.
    private fun isNoteToSelfPlaceholder(key: String) = key == PENDING_NOTE_TO_SELF_ID
}
