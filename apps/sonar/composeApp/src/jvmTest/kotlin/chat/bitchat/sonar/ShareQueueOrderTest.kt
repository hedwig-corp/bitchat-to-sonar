package chat.bitchat.sonar

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/**
 * Which share the picker offers when a second one arrives while the first is
 * still on screen (QA finding on #559, iOS QA-089).
 *
 * The user shares A, leaves the picker without choosing, then shares B from
 * another app. They are looking for B. The picker used to keep A and queue B
 * behind it, so one tap on a chat sent A — last time's file. iOS had the same
 * shape through its App Group inbox (oldest payload first); both now offer the
 * share that just arrived and keep the older one next in line.
 */
class ShareQueueOrderTest {

    private fun state(): SonarAppState {
        DesktopEnv.useTestRoot(kotlin.io.path.createTempDirectory("sonar-sharequeue").toFile())
        return SonarAppState(CoroutineScope(Job()))
    }

    @AfterTest
    fun restore() = DesktopEnv.useTestRoot(null)

    private fun share(name: String) = SharedContent(
        text = null,
        files = DroppedFiles(
            files = listOf(DroppedFile(bytes = byteArrayOf(1, 2, 3), filename = name, mime = "text/csv")),
            rejectedCount = 0,
        ),
    )

    @Test
    fun theShareJustMadeIsOfferedBeforeTheOneAlreadyUp() {
        val app = state()
        val old = share("old-draft.csv")
        val fresh = share("fresh.csv")

        app.handleSharedContent(old)
        assertSame(old, app.pendingShare)

        app.handleSharedContent(fresh)
        assertSame(fresh, app.pendingShare, "the picker must show the share that just arrived")
        assertTrue(app.screen is Screen.ShareTo)

        // The older share is not lost: it is offered once this one resolves.
        app.cancelPendingShare()
        assertSame(old, app.pendingShare)
        app.cancelPendingShare()
        assertNull(app.pendingShare)
    }

    @Test
    fun cancellingOffersTheQueuedShareInAFreshPicker() {
        val app = state()
        val old = share("old-draft.csv")
        app.handleSharedContent(old)
        app.handleSharedContent(share("fresh.csv"))

        // The picker's Back button. It used to promote the queued share while
        // ShareTo was still on top (so nothing was pushed) and then pop it:
        // the promoted share sat pending with no picker on screen.
        app.cancelPendingShare()
        assertSame(old, app.pendingShare)
        assertTrue(app.screen is Screen.ShareTo, "the queued share needs a visible picker")

        app.cancelPendingShare()
        assertNull(app.pendingShare)
        assertTrue(app.screen !is Screen.ShareTo, "no dead picker left behind")
    }

    @Test
    fun systemBackOutOfThePickerCancelsTheShare() {
        val app = state()
        app.handleSharedContent(share("a.csv"))

        // A bare pop kept `a.csv` pending but invisible; the next share then
        // queued behind a picker nobody could see and Sonar showed nothing.
        app.navigateBack()
        assertNull(app.pendingShare)
        assertTrue(app.screen !is Screen.ShareTo)

        val next = share("b.csv")
        app.handleSharedContent(next)
        assertSame(next, app.pendingShare)
        assertTrue(app.screen is Screen.ShareTo)
    }
}
