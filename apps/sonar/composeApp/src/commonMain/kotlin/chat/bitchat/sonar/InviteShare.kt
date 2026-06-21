package chat.bitchat.sonar

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Host backing the Signal-style universal invite link. Payload lives in the URL
 * **fragment** (`https://$JOIN_LINK_HOST/join#sinvite1…`) so it is never sent to
 * the host — same client-side privacy property as the bare token, while the
 * https URL linkifies in other apps and (once the domain serves the App Links /
 * Universal Links association files) opens Sonar directly.
 *
 * This is the single switch for the domain: every client surface works before it
 * is live; only browser auto-open waits on hosting `.well-known/assetlinks.json`
 * and `.well-known/apple-app-site-association`. See `web/README.md`.
 */
const val JOIN_LINK_HOST = "sonarprivacy.xyz"

/** Shareable universal link — preferred form (linkifies, travels across apps). */
fun inviteUniversalLink(token: String): String = "https://$JOIN_LINK_HOST/join#$token"

/** Legacy custom-scheme link — kept as a backward-compatible alias (PR #89). */
fun inviteDeepLink(token: String): String = "sonar://invite/$token"

/** Human-readable preview of an invite link for a settings row sub-label. */
fun inviteLinkPreview(token: String): String =
    "$JOIN_LINK_HOST/join#…${token.takeLast(6)}"

/** Hand [text] to the platform share sheet (Android chooser; clipboard on desktop). */
expect fun shareInviteText(text: String)

/**
 * Encode [data] as a QR module grid (`true` = dark). Returns null if encoding
 * fails. Pure CPU; callers must run it off the UI/render path.
 */
expect fun qrMatrix(data: String): Array<BooleanArray>?

/**
 * Render [data] as a scannable QR code. The matrix is computed on a background
 * dispatcher (Compose render-path performance rule) and drawn as plain Canvas
 * rects — no bitmap allocation. Colors are fixed black-on-white regardless of
 * theme so the code stays scannable in dark mode.
 */
@Composable
fun SNQrCode(data: String, size: Dp, modifier: Modifier = Modifier) {
    val matrix by produceState<Array<BooleanArray>?>(initialValue = null, data) {
        value = withContext(Dispatchers.Default) { qrMatrix(data) }
    }
    Box(
        modifier.size(size).clip(RoundedCornerShape(12.dp)).background(Color.White),
        contentAlignment = Alignment.Center,
    ) {
        val m = matrix ?: return@Box
        Canvas(Modifier.fillMaxSize().padding(14.dp)) {
            val n = m.size
            if (n == 0) return@Canvas
            val cell = this.size.width / n
            for (y in 0 until n) {
                val row = m[y]
                for (x in 0 until n) {
                    if (row[x]) {
                        drawRect(
                            color = Color.Black,
                            topLeft = Offset(x * cell, y * cell),
                            size = Size(cell + 0.5f, cell + 0.5f),
                        )
                    }
                }
            }
        }
    }
}
