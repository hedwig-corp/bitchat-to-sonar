package chat.bitchat.sonar

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.runComposeUiTest
import chat.bitchat.sonar.screens.OtherMeshAppNotice
import chat.bitchat.sonar.ui.SonarTheme
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Stock bitchat beside Sonar on one phone shares its radio and mesh service
 * UUID, and nearby devices then reach only one of the two (SPEC.md §12.2).
 * Sonar can't fix that from its side, so the radar says so and opens the
 * other app's App info for a force-stop.
 */
@OptIn(ExperimentalTestApi::class)
class OtherMeshAppNoticeUiTest {

    @Test
    fun theNoticeNamesTheOtherAppAndOpensItsSettings() = runComposeUiTest {
        val app = KNOWN_OTHER_MESH_APPS.single { it.packageName == "com.bitchat.droid" }
        var opened = 0
        setContent {
            SonarTheme { OtherMeshAppNotice(app) { opened++ } }
        }

        onNodeWithText("bitchat is also on this phone").assertIsDisplayed()
        onNodeWithText("Force-stop bitchat", substring = true).assertIsDisplayed()
        onNodeWithText("App info").performClick()
        assertEquals(1, opened)
    }

    /** Android 11+ reports a package missing unless the manifest names it
     *  under <queries>, so a package added to the list alone never warns. */
    @Test
    fun everyKnownMeshAppIsVisibleThroughTheManifest() {
        val manifest = java.io.File("src/androidMain/AndroidManifest.xml").readText()
        val queries = manifest.substringAfter("<queries>").substringBefore("</queries>")
        for (app in KNOWN_OTHER_MESH_APPS) {
            assertTrue(
                "<package android:name=\"${app.packageName}\" />" in queries,
                "AndroidManifest.xml <queries> must list ${app.packageName}",
            )
        }
    }
}
