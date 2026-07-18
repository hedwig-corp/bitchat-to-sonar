package chat.bitchat.sonar

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.runComposeUiTest
import androidx.compose.ui.unit.dp
import kotlin.test.Test
import kotlin.test.assertTrue

/**
 * Phase-2 hosts `bottomContent` in a [Box]. Chat bottom chrome must emit a
 * single vertical root — multiple root children overlap at top-start, which
 * crushed the emoji/sticker tray under the composer on Android (stuck
 * "Loading stickers…" + IME still visible).
 */
@OptIn(ExperimentalTestApi::class)
class EmojiTrayPhase2ChromeUiTest {

    @Test
    fun phase2BoxHostStacksTrayAboveComposerWhenChromeUsesColumnRoot() = runComposeUiTest {
        var trayY = Float.NaN
        var composerY = Float.NaN
        setContent {
            // Mirror TranscriptPhase2HostScaffold's bottom overlay host.
            Box(Modifier.fillMaxSize()) {
                Box(Modifier.align(Alignment.BottomCenter)) {
                    Column(Modifier.fillMaxWidth()) {
                        Box(
                            Modifier
                                .fillMaxWidth()
                                .height(320.dp)
                                .testTag("emoji-tray")
                                .onGloballyPositioned { trayY = it.positionInRoot().y },
                        )
                        Box(
                            Modifier
                                .fillMaxWidth()
                                .height(50.dp)
                                .testTag("composer")
                                .onGloballyPositioned { composerY = it.positionInRoot().y },
                        )
                    }
                }
            }
        }
        waitForIdle()
        runOnIdle {
            assertTrue(trayY.isFinite() && composerY.isFinite(), "both chrome pieces must lay out")
            assertTrue(
                trayY < composerY,
                "tray must stack above composer in the Phase-2 Box host (trayY=$trayY composerY=$composerY)",
            )
        }
    }

    @Test
    fun phase2BoxHostOverlapsLooseChromeChildrenWithoutColumnRoot() = runComposeUiTest {
        var trayY = Float.NaN
        var composerY = Float.NaN
        setContent {
            Box(Modifier.fillMaxSize()) {
                Box(Modifier.align(Alignment.BottomCenter)) {
                    // Bug shape: ChatBottomChrome emitting two roots into the Box.
                    Box(
                        Modifier
                            .fillMaxWidth()
                            .height(320.dp)
                            .testTag("emoji-tray")
                            .onGloballyPositioned { trayY = it.positionInRoot().y },
                    )
                    Box(
                        Modifier
                            .fillMaxWidth()
                            .height(50.dp)
                            .testTag("composer")
                            .onGloballyPositioned { composerY = it.positionInRoot().y },
                    )
                }
            }
        }
        waitForIdle()
        runOnIdle {
            assertTrue(trayY.isFinite() && composerY.isFinite(), "both chrome pieces must lay out")
            assertTrue(
                kotlin.math.abs(trayY - composerY) < 1f,
                "without a Column root, Phase-2 Box children share the same origin (trayY=$trayY composerY=$composerY)",
            )
        }
    }
}
