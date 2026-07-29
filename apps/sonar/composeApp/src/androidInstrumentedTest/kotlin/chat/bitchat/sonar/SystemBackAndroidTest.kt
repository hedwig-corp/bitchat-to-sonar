package chat.bitchat.sonar

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.espresso.Espresso.pressBack
import androidx.test.ext.junit.runners.AndroidJUnit4
import chat.bitchat.sonar.screens.SonarScanQrSheet
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SystemBackAndroidTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun systemBackPopsTheRealSonarAppStateStack() {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val state = SonarAppState(scope).also { it.push(Screen.Settings) }
        try {
            composeRule.setContent {
                SonarSystemBackHandler(
                    enabled = true,
                    isAtRoot = state.isHome,
                    isCallScreen = state.screen is Screen.Call,
                    onNavigate = state::back,
                )
            }

            pressBack()

            composeRule.runOnIdle { assertTrue(state.isHome) }
        } finally {
            scope.cancel()
        }
    }

    @Test
    fun systemBackAtRootFallsThroughToAndroidOwner() {
        var systemBacks by mutableIntStateOf(0)
        var navigations by mutableIntStateOf(0)
        composeRule.setContent {
            // Stand in for Android's root Activity behavior without finishing the
            // shared test Activity used by the Compose rule.
            PlatformBackHandler(enabled = true) { systemBacks++ }
            SonarSystemBackHandler(
                enabled = true,
                isAtRoot = true,
                isCallScreen = false,
                onNavigate = { navigations++ },
            )
        }

        pressBack()

        composeRule.runOnIdle {
            assertEquals(1, systemBacks)
            assertEquals(0, navigations)
        }
    }

    @Test
    fun systemBackDoesNotPopTheCallScreen() {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val call = Screen.Call(peerId = "mesh:test", name = "Test peer", video = false)
        val state = SonarAppState(scope).also { it.push(call) }
        try {
            composeRule.setContent {
                SonarSystemBackHandler(
                    enabled = true,
                    isAtRoot = state.isHome,
                    isCallScreen = state.screen is Screen.Call,
                    onNavigate = state::back,
                )
            }

            pressBack()

            composeRule.runOnIdle { assertSame(call, state.screen) }
        } finally {
            scope.cancel()
        }
    }

    @Test
    fun transientUiDismissesBeforeTheRouteNavigates() {
        var trayVisible by mutableStateOf(true)
        var navigations by mutableIntStateOf(0)
        composeRule.setContent {
            SonarSystemBackHandler(
                enabled = true,
                isAtRoot = false,
                isCallScreen = false,
                onNavigate = { navigations++ },
            )
            if (trayVisible) {
                TransientBackHandler { trayVisible = false }
            }
        }

        pressBack()

        composeRule.runOnIdle {
            assertFalse(trayVisible)
            assertEquals(0, navigations)
        }
    }

    @Test
    fun chatRowActionsSheetDismissesBeforeRootBackFallsThrough() {
        assertSheetOwnsBack { onClose ->
            ChatRowActionsSheet(
                name = "Test chat",
                isGroup = false,
                muted = false,
                onMute = {},
                onDelete = {},
                onClose = onClose,
            )
        }
    }

    @Test
    fun muteSheetDismissesBeforeRootBackFallsThrough() {
        assertSheetOwnsBack { onClose ->
            MuteSheet(
                name = "Test chat",
                muted = false,
                onMute = {},
                onUnmute = {},
                onClose = onClose,
            )
        }
    }

    @Test
    fun scanQrSheetDismissesBeforeSendPaymentRouteBack() {
        assertSheetOwnsBack { onClose ->
            SonarScanQrSheet(
                onClose = onClose,
                onDetect = { _, _ -> },
            )
        }
    }

    private fun assertSheetOwnsBack(content: @Composable (() -> Unit) -> Unit) {
        var closed by mutableStateOf(false)
        var fallthroughs by mutableIntStateOf(0)
        composeRule.setContent {
            PlatformBackHandler(enabled = true) { fallthroughs++ }
            content { closed = true }
        }

        pressBack()

        composeRule.runOnIdle {
            assertTrue(closed)
            assertEquals(0, fallthroughs)
        }
    }
}
