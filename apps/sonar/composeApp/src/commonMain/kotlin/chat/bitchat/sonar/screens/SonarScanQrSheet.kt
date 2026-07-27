package chat.bitchat.sonar.screens

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.bitchat.sonar.ui.SNGhostButton
import chat.bitchat.sonar.ui.SNIcon
import chat.bitchat.sonar.ui.SNIconName
import chat.bitchat.sonar.ui.SNPrimaryButton
import chat.bitchat.sonar.ui.SonarQrScanner
import chat.bitchat.sonar.ui.SonarType
import chat.bitchat.sonar.ui.sonar

/**
 * Scan to pay — 1:1 with the design's `ScanQrSheet`
 * (design/handoff/project/sonar/pay.jsx + the `.scan-*` styles in theme.css):
 * viewfinder with corner brackets and a sweeping line, then the "found" card
 * with the decoded code and a Continue / Scan again pair.
 *
 * Where the design fakes detection with sample codes, this runs the real
 * camera ([SonarQrScanner]) and classifies whatever it decodes.
 */
@Composable
fun SonarScanQrSheet(
    onClose: () -> Unit,
    onDetect: (destination: String, fixedSats: Long?) -> Unit,
) {
    val s = sonar
    var found by remember { mutableStateOf<String?>(null) }
    var failure by remember { mutableStateOf<String?>(null) }

    Box(
        Modifier.fillMaxSize().background(s.scrim).clickable(onClick = onClose),
        contentAlignment = Alignment.BottomCenter,
    ) {
        Surface(color = s.surface, shape = RoundedCornerShape(topStart = 22.dp, topEnd = 22.dp)) {
            Column(
                Modifier.fillMaxWidth().padding(start = 14.dp, end = 14.dp, top = 16.dp, bottom = 20.dp)
            ) {
                Text("Scan to pay", color = s.text, fontSize = 17.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.height(10.dp))

                val code = found
                if (code == null) {
                    // ── .scan-view / .scan-frame ──
                    Column(
                        Modifier.fillMaxWidth().padding(top = 10.dp, bottom = 4.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Box(
                            Modifier.size(210.dp).clip(RoundedCornerShape(22.dp))
                                .background(
                                    Brush.linearGradient(listOf(Color(0xFF101820), Color(0xFF06090C)))
                                ),
                        ) {
                            if (failure == null) {
                                SonarQrScanner(
                                    onCode = { found = it },
                                    onUnavailable = { failure = it },
                                )
                            }
                            ScanCorners(s.accent)
                            if (failure == null) ScanSweep(s.accent)
                        }
                        Spacer(Modifier.height(14.dp))
                        // .scan-hint
                        Text(
                            failure ?: "Point at a bitcoin, Lightning or Bolt12 QR code",
                            color = s.text3, fontSize = 13.sp, textAlign = TextAlign.Center,
                        )
                    }
                    Spacer(Modifier.height(10.dp))
                    SNGhostButton("Cancel") { onClose() }
                } else {
                    val kind = scannedKind(code)
                    // ── .scan-found ──
                    Row(
                        Modifier.fillMaxWidth().padding(top = 10.dp, bottom = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Box(
                            Modifier.size(44.dp).clip(RoundedCornerShape(13.dp)).background(s.netSoft),
                            contentAlignment = Alignment.Center,
                        ) { SNIcon(kind.icon, 22.dp, s.netDeep) }
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text(kind.name, color = s.text, fontSize = 15.sp, fontWeight = FontWeight.Bold, maxLines = 1)
                            Text(kind.sub, color = s.text2, fontSize = 12.5.sp, maxLines = 1)
                        }
                    }
                    // ── .scan-code: mono, wrapped ──
                    Text(
                        code,
                        color = s.text2,
                        style = SonarType.mono(12.0),
                        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)
                            .clip(RoundedCornerShape(12.dp)).background(s.surface2)
                            .padding(horizontal = 13.dp, vertical = 11.dp),
                        maxLines = 3,
                    )
                    Spacer(Modifier.height(10.dp))
                    SNPrimaryButton(
                        if (kind.fixedSats != null) "Continue · ${chat.bitchat.sonar.payFmt(kind.fixedSats)} sats"
                        else "Enter amount",
                        net = true,
                    ) { onDetect(code, kind.fixedSats) }
                    Spacer(Modifier.height(6.dp))
                    SNGhostButton("Scan again") { found = null }
                }
            }
        }
    }
}

/**
 * .scan-frame .c — four 34dp L-brackets inset 14dp, 3dp accent. CSS makes each
 * one by dropping two borders off a square; Compose's `border()` has no
 * per-side control, so each bracket is drawn as two bars instead.
 */
@Composable
private fun ScanCorners(accent: Color) {
    Box(Modifier.fillMaxSize()) {
        ScanBracket(Modifier.align(Alignment.TopStart), accent, top = true, start = true)
        ScanBracket(Modifier.align(Alignment.TopEnd), accent, top = true, start = false)
        ScanBracket(Modifier.align(Alignment.BottomStart), accent, top = false, start = true)
        ScanBracket(Modifier.align(Alignment.BottomEnd), accent, top = false, start = false)
    }
}

@Composable
private fun ScanBracket(modifier: Modifier, accent: Color, top: Boolean, start: Boolean) {
    val edge = 34.dp
    val w = 3.dp
    Box(modifier.padding(14.dp).size(edge)) {
        // the horizontal arm
        Box(
            Modifier.align(if (top) Alignment.TopStart else Alignment.BottomStart)
                .width(edge).height(w).clip(RoundedCornerShape(w / 2)).background(accent)
        )
        // the vertical arm
        Box(
            Modifier.align(if (start) Alignment.TopStart else Alignment.TopEnd)
                .width(w).height(edge).clip(RoundedCornerShape(w / 2)).background(accent)
        )
    }
}

/** .scan-line — 2.2s ease-in-out sweep between 26dp and 180dp. */
@Composable
private fun ScanSweep(accent: Color) {
    val transition = rememberInfiniteTransition(label = "scan")
    val y by transition.animateFloat(
        initialValue = 26f,
        targetValue = 180f,
        animationSpec = infiniteRepeatable(tween(1100), RepeatMode.Reverse),
        label = "scanY",
    )
    Box(
        Modifier.fillMaxWidth().padding(horizontal = 18.dp).offset(y = y.dp)
            .height(2.dp).clip(RoundedCornerShape(2.dp))
            .background(
                Brush.horizontalGradient(
                    listOf(Color.Transparent, accent, Color.Transparent)
                )
            )
    )
}

/** What a decoded payload is, for the "found" card. */
internal data class ScannedKind(
    val icon: SNIconName,
    val name: String,
    val sub: String,
    val fixedSats: Long?,
)

internal fun scannedKind(raw: String): ScannedKind {
    val v = raw.trim()
    val lower = v.lowercase().removePrefix("lightning:").removePrefix("bitcoin:")
    return when {
        lower.startsWith("lno1") -> ScannedKind(
            SNIconName.Bolt, "Bolt12 offer", "Reusable · over Lightning", null
        )
        lower.startsWith("lnbc") || lower.startsWith("lntb") || lower.startsWith("lnbcrt") -> {
            val sats = bolt11AmountSats(lower)
            ScannedKind(
                SNIconName.Bolt,
                "Lightning invoice",
                if (sats != null) "${chat.bitchat.sonar.payFmt(sats)} sats requested" else "No amount · you choose",
                sats,
            )
        }
        '@' in lower -> ScannedKind(SNIconName.Globe, v, "Lightning address", null)
        else -> ScannedKind(SNIconName.Coin, "Bitcoin address", "On-chain", null)
    }
}

/**
 * Amount encoded in a BOLT11 human-readable part, in sats, or null when the
 * invoice leaves the amount open. `lnbc21u1…` → 21 micro-BTC → 2,100 sats.
 * Multipliers per BOLT-11: m = 10⁻³, u = 10⁻⁶, n = 10⁻⁹, p = 10⁻¹² BTC.
 */
internal fun bolt11AmountSats(invoice: String): Long? {
    // The separator is the LAST '1': bech32 excludes '1' from the data
    // charset, so any earlier one belongs to the amount ("lnbc21u1…" — taking
    // the first would read 2 BTC instead of 2,100 sats).
    val hrpEnd = invoice.lastIndexOf('1').takeIf { it > 3 } ?: return null
    val prefix = invoice.substring(0, hrpEnd)
    val digitsStart = prefix.indexOfFirst { it.isDigit() }.takeIf { it > 0 } ?: return null
    var amountPart = prefix.substring(digitsStart)
    if (amountPart.isEmpty()) return null
    val multiplier = amountPart.last()
    val scale: Double = when (multiplier) {
        'm' -> 1e-3
        'u' -> 1e-6
        'n' -> 1e-9
        'p' -> 1e-12
        else -> 1.0
    }
    if (!multiplier.isDigit()) amountPart = amountPart.dropLast(1)
    val value = amountPart.toDoubleOrNull() ?: return null
    if (value <= 0.0) return null
    val sats = value * scale * 100_000_000.0
    // p-denominated invoices can encode sub-satoshi amounts; round up so we
    // never underpay, and treat a zero result as "no amount".
    val rounded = kotlin.math.ceil(sats - 1e-9).toLong()
    return rounded.takeIf { it > 0 }
}
