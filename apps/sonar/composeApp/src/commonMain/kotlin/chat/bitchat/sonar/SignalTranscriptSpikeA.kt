package chat.bitchat.sonar

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInParent
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt

/**
 * Spike A — Signal-iOS short-feed transcript host (feature-flagged).
 *
 * Full-height list, composer overlaid and lifted with [imePadding], owned
 * bottom content padding = measured chrome (composer + IME gap). Short feeds
 * stay TOP-ALIGNED — empty space above the composer is correct. Do **not** use
 * LazyColumn `reverseLayout` here (that is Spike B).
 *
 * Enable:
 *  - env `SONAR_SPIKE_SIGNAL_TRANSCRIPT_A=1`
 *  - system property `sonar.spike.signalTranscriptA=1`
 *  - [SignalTranscriptSpikeA.forceEnabled] = true (tests)
 *  - Android: Debug builds only for env/property paths (Release always off)
 */
object SignalTranscriptSpikeA {
    const val ENV_KEY = "SONAR_SPIKE_SIGNAL_TRANSCRIPT_A"
    const val PROPERTY_KEY = "sonar.spike.signalTranscriptA"

    /** Test / local override. Honored only when [sonarDebugForceFlagsAllowed]. */
    @Volatile
    var forceEnabled: Boolean = false

    fun isEnabled(): Boolean =
        (forceEnabled && sonarDebugForceFlagsAllowed) ||
            signalTranscriptSpikeAPlatformEnabled()
}

/** Platform gate: Android Debug + env/property; JVM opt-in via env/property. */
internal expect fun signalTranscriptSpikeAPlatformEnabled(): Boolean

/**
 * Full-height list under an overlaid composer. [listContent] receives the
 * owned bottom inset to apply as LazyColumn `contentPadding.bottom`.
 * Reuses [TranscriptTailPinning] for R-009 keyboard/IME tail pin.
 */
@Composable
internal fun SignalTranscriptSpikeAScaffold(
    listState: LazyListState,
    listKey: Any? = null,
    isPrepending: () -> Boolean = { false },
    modifier: Modifier = Modifier,
    listContent: @Composable BoxScope.(bottomInset: Dp) -> Unit,
    bottomContent: @Composable () -> Unit,
) {
    var bottomChromePx by remember { mutableIntStateOf(0) }
    val density = LocalDensity.current
    val bottomInset = with(density) {
        if (bottomChromePx > 0) bottomChromePx.toDp() else 56.dp
    }

    Box(modifier.fillMaxSize()) {
        listContent(bottomInset)
        Box(
            Modifier
                .align(Alignment.BottomCenter)
                .imePadding()
                .onGloballyPositioned { coords ->
                    val parentH = coords.parentLayoutCoordinates?.size?.height ?: return@onGloballyPositioned
                    val chrome = (parentH - coords.positionInParent().y).roundToInt().coerceAtLeast(0)
                    if (chrome != bottomChromePx) bottomChromePx = chrome
                },
        ) {
            bottomContent()
        }
    }

    // R-009: was-at-tail pin across IME / chrome inset changes.
    TranscriptTailPinning(
        listState = listState,
        key = listKey,
        isPrepending = isPrepending,
    )
}
