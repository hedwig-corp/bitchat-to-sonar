package chat.bitchat.sonar

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.bitchat.sonar.ui.sonar

/**
 * Marmot v1 → v2 flag day (MDK 0.8 → v0.14). Core classifies each contact from
 * their KeyPackages and refuses a send nobody in the chat can read any more;
 * these types carry its answer to the chat screen. See
 * `core/sonar-core/src/marmot_protocol.rs`.
 */
enum class SonarMarmotChatGateState { Open, Blocked, PartlyUpdated }

data class SonarMarmotChatGate(
    val state: SonarMarmotChatGateState,
    /** Hex pubkeys of the other members already on Marmot v2. */
    val updatedMemberHexes: List<String> = emptyList(),
)

/** Substring of core's send error when every other member moved to Marmot v2
 *  (`sonar_core::error::PEER_UPDATED_SONAR_MARKER`). */
const val PEER_UPDATED_SONAR_MARKER = "peer has updated Sonar"

fun isPeerUpdatedSonarError(message: String?): Boolean =
    message?.contains(PEER_UPDATED_SONAR_MARKER) == true

/** What the chat screen shows for a chat's Marmot gate. */
sealed interface SonarComposerGate {
    /** Normal composer, no note. */
    data object Open : SonarComposerGate

    /** Every other member moved: the composer is replaced by the update panel. */
    data object UpdateRequired : SonarComposerGate

    /** Some group members moved: a note above the transcript, composer stays. */
    data class PartlyUpdated(val updatedCount: Int) : SonarComposerGate
}

/**
 * The real call site's decision (ChatScreen reads it through
 * [SonarAppState.composerGate]). A mesh-folded chat with a live Bluetooth link
 * sends over BLE, which the Marmot version does not touch, so it stays open;
 * out of range it falls back to Marmot and is gated like a pure Marmot chat.
 */
fun composerGateFor(gate: SonarMarmotChatGate?, sendsOverMesh: Boolean): SonarComposerGate {
    if (gate == null || sendsOverMesh) return SonarComposerGate.Open
    return when (gate.state) {
        SonarMarmotChatGateState.Open -> SonarComposerGate.Open
        SonarMarmotChatGateState.Blocked -> SonarComposerGate.UpdateRequired
        SonarMarmotChatGateState.PartlyUpdated ->
            SonarComposerGate.PartlyUpdated(gate.updatedMemberHexes.size)
    }
}

fun marmotUpdateRequiredText(name: String): String =
    "$name has updated Sonar. Update the app to keep chatting"

const val MARMOT_PARTLY_UPDATED_REST = " — they can't read new messages until you update the app"

fun marmotPartlyUpdatedBold(count: Int): String =
    if (count == 1) "1 member has updated Sonar" else "$count members have updated Sonar"

/** Where this build gets its updates: Zapstore, Google Play, or the GitHub
 *  release page for sideloaded and desktop builds. */
expect fun sonarAppUpdateUrl(): String

const val SONAR_GITHUB_RELEASES_URL = "https://github.com/hedwig-corp/bitchat-to-sonar/releases"
const val SONAR_ZAPSTORE_URL = "https://zapstore.dev/apps/chat.bitchat.sonar"
const val SONAR_PLAY_URL = "https://play.google.com/store/apps/details?id=chat.bitchat.sonar"

/** Map the installing package to its store page (Android installer source). */
fun sonarUpdateUrlForInstaller(installer: String?): String = when {
    installer == null -> SONAR_GITHUB_RELEASES_URL
    installer.startsWith("dev.zapstore") -> SONAR_ZAPSTORE_URL
    installer == "com.android.vending" -> SONAR_PLAY_URL
    else -> SONAR_GITHUB_RELEASES_URL
}

/** Stands in for the composer when [composerGate] is [SonarComposerGate.UpdateRequired]
 *  (Signal's pattern for a recipient you can no longer message: the input is
 *  replaced, not just disabled, so no media, sticker or voice path is left). */
@Composable
fun MarmotComposerSlot(
    composerGate: SonarComposerGate,
    peerName: String,
    onUpdate: () -> Unit,
    composer: @Composable () -> Unit,
) {
    if (composerGate is SonarComposerGate.UpdateRequired) {
        MarmotUpdateRequiredPanel(peerName, onUpdate)
    } else {
        composer()
    }
}

@Composable
fun MarmotUpdateRequiredPanel(peerName: String, onUpdate: () -> Unit) {
    val s = sonar
    Column(
        Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 10.dp, bottom = 12.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(
            marmotUpdateRequiredText(peerName),
            color = s.text2, fontSize = 14.sp, lineHeight = 19.sp, textAlign = TextAlign.Center,
        )
        Box(
            Modifier.clip(RoundedCornerShape(19.dp)).background(s.netFill)
                .semantics { role = Role.Button }
                .clickable(onClick = onUpdate)
                .padding(horizontal = 18.dp, vertical = 9.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text("Update Sonar", color = s.onNet, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}
