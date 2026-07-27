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
import chat.bitchat.sonar.wallet.bolt11AmountSats
import chat.bitchat.sonar.wallet.btcToSats
import chat.bitchat.sonar.wallet.looksBech32
import chat.bitchat.sonar.wallet.parseUriParams

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
                    ) { onDetect(kind.destination, kind.fixedSats) }
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

/**
 * What a scanned/typed payload resolves to: the string the wallet should
 * actually be handed, plus how to label it and any amount it fixes.
 */
internal data class ScannedKind(
    val icon: SNIconName,
    val name: String,
    val sub: String,
    val fixedSats: Long?,
    /** What to pay. NOT the raw payload — see [scannedKind]. */
    val destination: String,
)

/**
 * Resolve a scanned or pasted payment payload.
 *
 * The important case is the **BIP-21 unified URI**, which is what modern
 * wallets put in a QR code:
 *
 *     bitcoin:BC1Q…?amount=0.0001&lno=lno1…&lightning=lnbc…
 *
 * The on-chain address is the fallback; the good rails ride in the query
 * string. Handing that whole URI to the wallet — query string and all — is how
 * this used to fail: the BOLT12 offer sitting in `lno=` was never looked at,
 * the code was labelled a plain on-chain address, and the send went nowhere.
 *
 * Preference order is best-rail-first: `lno` (reusable BOLT12 offer) →
 * `lightning` (BOLT11 invoice) → the bare on-chain address.
 */
internal fun scannedKind(raw: String): ScannedKind {
    val v = raw.trim()
    val lowerAll = v.lowercase()

    // ── BIP-21 unified URI ──
    if (lowerAll.startsWith("bitcoin:")) {
        val body = v.substring("bitcoin:".length)
        val address = body.substringBefore('?')
        val params = parseUriParams(body.substringAfter('?', ""))
        val uriSats = btcToSats(params["amount"])

        // BOLT12 offer — the best rail a unified QR can carry.
        val offer = params["lno"] ?: params["b12"]
        if (!offer.isNullOrBlank()) {
            return ScannedKind(
                SNIconName.Bolt, "Bolt12 offer", "Reusable · over Lightning",
                uriSats, offer.trim().lowercase(),
            )
        }
        // BOLT11 invoice — its own amount wins over the URI's.
        val invoice = params["lightning"]
        if (!invoice.isNullOrBlank()) {
            val clean = invoice.trim().lowercase()
            val sats = bolt11AmountSats(clean) ?: uriSats
            return ScannedKind(
                SNIconName.Bolt, "Lightning invoice",
                if (sats != null) "${chat.bitchat.sonar.payFmt(sats)} sats requested"
                else "No amount — this invoice can't be paid",
                sats, clean,
            )
        }
        // On-chain only. Bech32 is case-insensitive, base58 is NOT — never
        // lowercase a base58 address or it stops being the same address.
        val clean = if (looksBech32(address)) address.lowercase() else address
        return ScannedKind(
            SNIconName.Coin, "Bitcoin address", "On-chain",
            uriSats, clean,
        )
    }

    // ── bare payloads, optionally scheme-prefixed ──
    val bare = when {
        lowerAll.startsWith("lightning:") -> v.substring("lightning:".length).trim()
        else -> v
    }
    val lower = bare.lowercase()
    return when {
        lower.startsWith("lno1") -> ScannedKind(
            SNIconName.Bolt, "Bolt12 offer", "Reusable · over Lightning", null, lower
        )
        lower.startsWith("lnbc") || lower.startsWith("lntb") || lower.startsWith("lnbcrt") -> {
            val sats = bolt11AmountSats(lower)
            ScannedKind(
                SNIconName.Bolt,
                "Lightning invoice",
                if (sats != null) "${chat.bitchat.sonar.payFmt(sats)} sats requested"
                else "No amount — this invoice can't be paid",
                sats, lower,
            )
        }
        '@' in bare -> ScannedKind(SNIconName.Globe, bare, "Lightning address", null, bare)
        else -> ScannedKind(SNIconName.Coin, "Bitcoin address", "On-chain", null, bare)
    }
}





