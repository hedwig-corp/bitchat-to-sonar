package chat.bitchat.sonar

import androidx.compose.ui.test.ComposeUiTest
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.runComposeUiTest
import chat.bitchat.sonar.chatlist.FakeChatListCore
import chat.bitchat.sonar.chatlist.summary
import chat.bitchat.sonar.desktop.SonarDesktopRoot
import chat.bitchat.sonar.ui.SonarTheme
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.runBlocking
import kotlin.io.path.createTempDirectory
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The chat list as the user sees it: the real screens (phone Home, the share
 * picker, the desktop sidebar) rendered over a real `SonarAppState` whose core
 * is faked at the `ChatListCore` seam. Pins the renderers, not just the model:
 * each row's title and unread dot on both chat kinds, and that each tap, long
 * press and sheet action reaches the conversation it names.
 */
@OptIn(ExperimentalTestApi::class)
class ChatListScreensUiTest {
    private val me = "npub1me"
    private val giulia = SonarChat("aa01", "", listOf(me, "npub1giulia"))
    // Both sides created a direct group: one person, two groups (R-003).
    private val giuliaAgain = SonarChat("aa02", "", listOf(me, "npub1giulia"))
    private val team = SonarChat("bb01", "Team", listOf(me, "npub1ann", "npub1bob"))
    private val saraNpub = chat.bitchat.sonar.crypto.Bech32.encode("npub", ByteArray(32) { 2 })!!
    private val saraGroup = SonarChat("cc01", "", listOf(me, saraNpub))
    private val saraPeer = "f3237e63aa11bb22"

    /** A 1:1 with no kind-0 profile is titled by the counterpart's short npub. */
    private val giuliaTitle = shortNpubLabel("npub1giulia")

    @AfterTest
    fun restore() = DesktopEnv.useTestRoot(null)

    private fun core() = FakeChatListCore().apply {
        chats = listOf(giulia, giuliaAgain, team, saraGroup)
        summaries = listOf(
            summary(saraGroup.id, 900, unread = 1, content = "hi over white noise"),
            summary(giuliaAgain.id, 800, unread = 2, content = "are you there?"),
            summary(team.id, 700, content = "team news"),
            summary(giulia.id, 500),
        )
    }

    /**
     * A signed-in account whose local store holds [core]'s chats, plus Sara:
     * met over Bluetooth, now writing over White Noise. The scope is
     * unconfined so each tap's work runs before the next assertion.
     */
    private fun state(core: FakeChatListCore, restored: List<SonarChat> = emptyList(), hydrate: Boolean = true): SonarAppState {
        DesktopEnv.useTestRoot(createTempDirectory("sonar-chat-list-ui").toFile())
        SonarCore.saveBlob("sonar.npub", me)
        if (restored.isNotEmpty()) {
            SonarCore.saveBlob(CHAT_SNAPSHOT_BLOB_KEY, encodeChatSnapshot(restored, emptyMap()))
        }
        val s = SonarAppState(CoroutineScope(SupervisorJob() + Dispatchers.Unconfined), core)
        if (hydrate) {
            runBlocking {
                s.chatList.refresh()
                s.seedMeshFoldedPersonForTest(
                    peerId = saraPeer,
                    npubHex = "02".repeat(32),
                    bleMessages = listOf(SonarMsg("ble-1", saraNpub, "hi over bluetooth", mine = false, tsSecs = 100)),
                    groups = emptyList(),
                )
                s.chatList.refreshUnread()
            }
            s.markHomeHydratedForTest()
        }
        return s
    }

    private fun SonarAppState.saraTitle(): String = meshDmRows.single().name

    /**
     * Wait on a wall-clock deadline. The desktop `waitUntil` measures its
     * timeout on the test's frame clock and can spin forever on a condition
     * that never holds; this fails with the state it saw instead.
     */
    private fun ComposeUiTest.awaitThat(timeoutMs: Long = 5_000, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (!condition()) {
            check(System.currentTimeMillis() < deadline) { "condition never held" }
            mainClock.advanceTimeBy(16)
            Thread.sleep(10)
        }
    }

    @Test
    fun homeTitlesBothChatKindsAndDotsTheUnreadOnes() = runComposeUiTest {
        val s = state(core())
        setContent { SonarTheme(dark = true) { SonarScreenHost(s) } }
        waitForIdle()

        // One row per person: Giulia's two groups are one row, Sara's White
        // Noise group is folded into her Bluetooth row.
        onNodeWithText(giuliaTitle).assertExists()
        onNodeWithText(s.saraTitle()).assertExists()
        onNodeWithText("Team").assertExists()
        onNodeWithText("Note to Self").assertExists()

        // Unread: Giulia (badge in her second group), Sara (mesh-folded, R-052).
        onNode(hasText(giuliaTitle) and hasContentDescription("Unread")).assertExists()
        onNode(hasText(s.saraTitle()) and hasContentDescription("Unread")).assertExists()
        onNode(hasText("Team") and hasContentDescription("Unread")).assertDoesNotExist()
        onNode(hasText("Note to Self") and hasContentDescription("Unread")).assertDoesNotExist()
    }

    @Test
    fun tappingARowOpensItsConversationAndClearsItsDot() = runComposeUiTest {
        val core = core()
        val s = state(core)
        setContent { SonarTheme(dark = true) { SonarScreenHost(s) } }
        waitForIdle()

        // The mesh-folded row: opens the Bluetooth DM, read-marks the folded group.
        onNode(hasText(s.saraTitle()) and hasClickAction()).performClick()
        awaitThat { (s.screen as? Screen.Chat)?.id == "mesh:$saraPeer" }
        assertEquals(listOf(saraGroup.id), core.markedRead)
        s.resetToHome()
        waitForIdle()
        onNode(hasText(s.saraTitle()) and hasContentDescription("Unread")).assertDoesNotExist()

        // The duplicate-group 1:1: read-marks both of Giulia's groups.
        onNode(hasText(giuliaTitle) and hasClickAction()).performClick()
        awaitThat { (s.screen as? Screen.Chat)?.id in setOf(giulia.id, giuliaAgain.id) }
        assertEquals(setOf(saraGroup.id, giulia.id, giuliaAgain.id), core.markedRead.toSet())
    }

    @Test
    fun rowActionsMuteThenDeleteTheConversationTheyWereOpenedOn() = runComposeUiTest {
        val core = core()
        val s = state(core)
        setContent { SonarTheme(dark = true) { SonarScreenHost(s) } }
        waitForIdle()

        onNode(hasText("Team") and hasClickAction()).performTouchInput { longClick() }
        waitForIdle()
        onNodeWithText("Mute").performClick()
        waitForIdle()
        onNodeWithText("1 hour").performClick()
        waitForIdle()
        assertTrue(s.isChatMuted(team.id), "Mute reached the row's conversation")
        assertFalse(s.isChatMuted(giulia.id))

        onNode(hasText("Team") and hasClickAction()).performTouchInput { longClick() }
        waitForIdle()
        onNodeWithText("Muted").assertExists()
        onNodeWithText("Leave group").performClick() // the row action (Team is a group)
        waitForIdle()
        onNodeWithText("Leave this group?").assertExists()
        onNode(hasText("Leave group") and hasClickAction()).performClick() // the confirm
        awaitThat { core.removed.isNotEmpty() }
        assertEquals(listOf("leave:${team.id}"), core.removed)
        waitForIdle()
        onNodeWithText("Team").assertDoesNotExist()

        // A 1:1 deletes every duplicate group, not just the row's.
        onNode(hasText(giuliaTitle) and hasClickAction()).performTouchInput { longClick() }
        waitForIdle()
        onNodeWithText("Delete chat").performClick()
        waitForIdle()
        onNode(hasText("Delete chat") and hasClickAction()).performClick()
        awaitThat { core.removed.size == 3 }
        assertEquals(setOf("delete:${giulia.id}", "delete:${giuliaAgain.id}"), core.removed.drop(1).toSet())
        waitForIdle()
        onNodeWithText(giuliaTitle).assertDoesNotExist()
    }

    @Test
    fun anInviteBannerAcceptsIntoAPendingGroupChat() = runComposeUiTest {
        val core = core().apply {
            invites = listOf(SonarGroupInvite("inv1", "dd01", "Hikers", "", "npub1w", 4, emptyList()))
        }
        val s = state(core)
        setContent { SonarTheme(dark = true) { SonarScreenHost(s) } }
        waitForIdle()

        onNodeWithText("4 members · invite").assertExists()
        onNode(hasText("Hikers") and hasClickAction()).performClick()
        waitForIdle()
        onNodeWithText("Accept").performClick()
        awaitThat { s.screen is Screen.Chat }
        assertTrue(s.groupInvites.isEmpty(), "the invite left the list")
        assertEquals("Hikers", (s.screen as Screen.Chat).name)
    }

    @Test
    fun theDesktopSidebarPaintsRestoredRowsAndSelectsOnClick() = runComposeUiTest {
        // Cold start: the store has not opened yet, only the restored snapshot.
        val s = state(core(), restored = listOf(team, giulia), hydrate = false)
        setContent { SonarTheme(dark = true) { SonarDesktopRoot(s) } }
        waitForIdle()

        onNodeWithText("Team").assertExists()
        onNodeWithText(giuliaTitle).assertExists()
        onNode(hasText("Team") and hasClickAction()).performClick()
        awaitThat { (s.screen as? Screen.Chat)?.id == team.id }
        // Opening Team reloaded the store, which brought Giulia's second group:
        // her one row now stands for whichever group is newest (R-003).
        onNode(hasText(giuliaTitle) and hasClickAction()).performClick()
        awaitThat { (s.screen as? Screen.Chat)?.id in setOf(giulia.id, giuliaAgain.id) }
        // Select, not push: the stack collapsed to Home before Giulia opened,
        // so Back lands on Home rather than on Team.
        s.back()
        waitForIdle()
        assertTrue(s.isHome)
    }

    @Test
    fun theSharePickerTitlesOneToOnesAndSendsToThePickedChat() = runComposeUiTest {
        val s = state(core())
        s.handleSharedContent(SharedContent(text = "hello share", files = DroppedFiles(emptyList(), 0)))
        setContent { SonarTheme(dark = true) { SonarScreenHost(s) } }
        waitForIdle()

        // R-053: a 1:1's group name is blank, so a raw-name picker showed an
        // untitled row. It must read like Home.
        onNodeWithText("Send to…").assertExists()
        onNode(hasText(giuliaTitle) and hasClickAction()).assertExists()
        onNode(hasText("Team") and hasClickAction()).assertExists()

        // Search by the shown title (the Filter event).
        onNode(hasSetTextAction()).performTextInput("giul")
        waitForIdle()
        onNode(hasText("Team") and hasClickAction()).assertDoesNotExist()
        onNode(hasText(giuliaTitle) and hasClickAction()).performClick()
        awaitThat { s.screen is Screen.Chat }
        assertNull(s.pendingShare, "the share went to the picked chat")
        assertTrue((s.screen as Screen.Chat).id in setOf(giulia.id, giuliaAgain.id))
    }
}
