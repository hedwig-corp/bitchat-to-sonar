package chat.bitchat.sonar.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.bitchat.sonar.PaySheet
import chat.bitchat.sonar.PayableContact
import chat.bitchat.sonar.SonarAppState
import chat.bitchat.sonar.ToastBar
import chat.bitchat.sonar.payFmt
import chat.bitchat.sonar.ui.SNEmptyState
import chat.bitchat.sonar.ui.SNIcon
import chat.bitchat.sonar.ui.SNIconName
import chat.bitchat.sonar.ui.SNNavHeader
import chat.bitchat.sonar.ui.SNSectionLabel
import chat.bitchat.sonar.ui.SonarAvatar
import chat.bitchat.sonar.ui.sonarQrScanSupported
import chat.bitchat.sonar.ui.sonar

/**
 * Send payment — the standalone recipient picker reached from the new-chat
 * sheet ("Start a chat → Send a payment"). 1:1 with the design's
 * `SendPaymentScreen` in `design/handoff/project/sonar/pay.jsx`: balance line,
 * a destination field, an external "Pay …" row that appears once the input
 * looks like an address/offer/invoice, and the "People you can pay" list of
 * contacts who publish a payment address.
 *
 * The "Scan a QR code" row is camera-backed: CameraX + zxing on Android
 * ([SonarQrScanner]). Desktop has no camera pipeline, so
 * [sonarQrScanSupported] is false there and the row is hidden rather than
 * offering a dead viewfinder — pasting the code into the field reaches the
 * same destinations.
 */
@Composable
fun SonarSendPaymentScreen(state: SonarAppState) {
    val s = sonar
    // Recompose when a payment lands so the balance line stays honest.
    state.paymentActivityVersion

    var query by remember { mutableStateOf("") }
    // Chosen recipient: a contact (pay through their chat) or a raw destination.
    var contactTarget by remember { mutableStateOf<PayableContact?>(null) }
    var externalTarget by remember { mutableStateOf<String?>(null) }
    // Amount carried by a scanned invoice, if it fixes one.
    var fixedSats by remember { mutableStateOf<Long?>(null) }
    var scanning by remember { mutableStateOf(false) }

    val trimmed = query.trim()
    val contacts = state.payableContacts()
    val listed = if (trimmed.isEmpty()) contacts
    else contacts.filter { it.name.contains(trimmed, ignoreCase = true) }

    Column(Modifier.fillMaxSize().background(s.bg)) {
        SNNavHeader("Send payment", hairline = false, onBack = { state.back() })

        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState())
                .padding(bottom = 40.dp)
        ) {
            Row(
                Modifier.fillMaxWidth().padding(start = 18.dp, end = 18.dp, top = 4.dp, bottom = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                SNIcon(SNIconName.Coin, 14.dp, s.text3, weight = 2f)
                Spacer(Modifier.width(7.dp))
                Text(
                    "Your balance · ${payFmt(state.walletBalanceSats())} sats",
                    color = s.text2, fontSize = 13.sp,
                )
            }

            // ── Destination field ──
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 14.dp)
                    .clip(RoundedCornerShape(13.dp)).background(s.surface2)
                    .padding(horizontal = 14.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                SNIcon(SNIconName.Search, 17.dp, s.text3, weight = 2f)
                Spacer(Modifier.width(9.dp))
                Box(Modifier.weight(1f)) {
                    if (query.isEmpty()) {
                        Text("Name, name@domain or Bolt12…", color = s.text3, fontSize = 15.sp)
                    }
                    BasicTextField(
                        value = query,
                        onValueChange = { query = it },
                        singleLine = true,
                        textStyle = TextStyle(color = s.text, fontSize = 15.sp),
                        cursorBrush = SolidColor(s.accent),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }

            // ── .sp-scan: scan a QR code ──
            if (sonarQrScanSupported()) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 8.dp)
                        .clip(RoundedCornerShape(14.dp)).background(s.accentSoft)
                        .clickable { scanning = true }
                        .padding(horizontal = 14.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(
                        Modifier.size(38.dp).clip(RoundedCornerShape(11.dp)).background(s.accentFill),
                        contentAlignment = Alignment.Center,
                    ) { SNIcon(SNIconName.Qr, 20.dp, s.onAccent) }
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text(
                            "Scan a QR code",
                            color = s.text, fontSize = 15.sp, fontWeight = FontWeight.Bold,
                        )
                        Text(
                            "Bitcoin, Lightning invoice or Bolt12 offer",
                            color = s.accentDeep, fontSize = 12.5.sp, maxLines = 1,
                        )
                    }
                    SNIcon(SNIconName.Chevron, 15.dp, s.text3, weight = 2.2f)
                }
            }

            // ── External destination ──
            val external = payableDestination(trimmed)
            if (external != null) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 8.dp)
                        .clip(RoundedCornerShape(14.dp)).background(s.netSoft)
                        .clickable { externalTarget = external.destination; fixedSats = external.fixedSats }
                        .padding(horizontal = 14.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(
                        Modifier.size(38.dp).clip(RoundedCornerShape(11.dp)).background(s.netFill),
                        contentAlignment = Alignment.Center,
                    ) { SNIcon(external.icon, 19.dp, s.onNet) }
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text(
                            "Pay “$trimmed”",
                            color = s.text, fontSize = 15.sp, fontWeight = FontWeight.Bold,
                            maxLines = 1,
                        )
                        Text(external.subtitle, color = s.netDeep, fontSize = 12.5.sp, maxLines = 1)
                    }
                    SNIcon(SNIconName.Chevron, 15.dp, s.text3, weight = 2.2f)
                }
            }

            // ── People you can pay ──
            SNSectionLabel("People you can pay")

            if (listed.isEmpty()) {
                SNEmptyState(
                    icon = SNIconName.Coin,
                    title = if (contacts.isEmpty()) "Nobody to pay yet" else "No matching contacts",
                    desc = "Only people who publish a payment address show up here. " +
                        "You can still pay any Lightning address or Bolt12 offer using the field above.",
                )
            } else {
                listed.forEach { contact ->
                    Row(
                        Modifier.fillMaxWidth().clickable { contactTarget = contact }
                            .padding(horizontal = 14.dp, vertical = 9.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        SonarAvatar(contact.name, 44.dp, presence = contact.nearby)
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text(
                                contact.name,
                                color = s.text, fontSize = 16.sp, fontWeight = FontWeight.SemiBold,
                            )
                            Text(contact.subtitle, color = s.text2, fontSize = 13.sp)
                        }
                        SNIcon(SNIconName.Chevron, 15.dp, s.text3, weight = 2.2f)
                    }
                }
            }

            Spacer(Modifier.height(6.dp))
            Text(
                "Payments settle straight to their wallet — there is no claim step.",
                color = s.text3, fontSize = 12.5.sp, lineHeight = 17.sp,
                modifier = Modifier.padding(horizontal = 18.dp, vertical = 6.dp),
            )
        }
    }

    contactTarget?.let { contact ->
        PaySheet(
            peerName = contact.name,
            balanceSats = state.walletBalanceSats(),
            mesh = contact.nearby,
            fiatOf = { state.fiatOrNull(it) },
            onSend = { sats ->
                // Route through the chat so the peer still gets the in-chat
                // ⚡PAY receipt, exactly as paying from inside the chat does.
                // Detached: this screen pops on the same frame.
                state.sendPayDetached(contact.chatId, sats)
                state.back()
            },
            onClose = { contactTarget = null },
        )
    }

    if (scanning) {
        SonarScanQrSheet(
            onClose = { scanning = false },
            onDetect = { destination, sats ->
                scanning = false
                fixedSats = sats
                externalTarget = destination
            },
        )
    }

    externalTarget?.let { destination ->
        PaySheet(
            peerName = payableDisplayName(destination),
            balanceSats = state.walletBalanceSats(),
            mesh = false,
            fixedSats = fixedSats,
            fiatOf = { state.fiatOrNull(it) },
            onSend = { sats ->
                // Detached: this screen pops on the same frame.
                state.payDestinationDetached(destination, sats, payableDisplayName(destination))
                state.back()
            },
            onClose = { externalTarget = null; fixedSats = null },
        )
    }

    state.toast?.let { ToastBar(it) { state.toast = null } }
}

/** How an external destination is labelled in the "Pay …" row. */
internal data class ExternalDestination(
    val icon: SNIconName,
    val subtitle: String,
    /** What to hand the wallet — for a BIP-21 URI this is the extracted rail. */
    val destination: String,
    /** Amount the payload fixes, if any. */
    val fixedSats: Long? = null,
)

/**
 * Classify what the user typed. Anything Breez can resolve counts: a BOLT12
 * offer (`lno1…`), a BOLT11 invoice (`lnbc…`/`lntb…`), or a Lightning address
 * (`name@domain`). Returns null while the input is still just a contact-name
 * search, which keeps the row from flickering in on every keystroke.
 */
internal fun payableDestination(input: String): ExternalDestination? {
    val v = input.lowercase()
    return when {
        // A pasted BIP-21 / lightning URI resolves exactly like a scanned one,
        // so the offer inside `?lno=` is paid rather than the URI itself.
        v.startsWith("bitcoin:") || v.startsWith("lightning:") -> {
            val k = scannedKind(input)
            k.destination.takeIf { it.isNotBlank() }
                ?.let { ExternalDestination(k.icon, k.sub, it, k.fixedSats) }
        }
        v.startsWith("lno1") ->
            ExternalDestination(SNIconName.Bolt, "Bolt12 offer · over Lightning", input.trim().lowercase())
        v.startsWith("lnbc") || v.startsWith("lntb") || v.startsWith("lnbcrt") ->
            ExternalDestination(
                SNIconName.Bolt, "Lightning invoice", input.trim().lowercase(),
                bolt11AmountSats(input.trim().lowercase()),
            )
        // A Lightning address needs a user and a dotted host: "a@b.c".
        v.count { it == '@' } == 1 && v.substringBefore('@').isNotEmpty() &&
            v.substringAfter('@').let { it.contains('.') && !it.startsWith('.') && !it.endsWith('.') } ->
            ExternalDestination(SNIconName.Globe, "Lightning address · over the internet", input.trim())
        else -> null
    }
}

/** Short human label for a raw destination (design: `raw.split('@')[0]`). */
internal fun payableDisplayName(destination: String): String {
    val v = destination.trim()
    if ('@' in v) return v.substringBefore('@')
    return if (v.length > 14) v.take(12) + "…" else v
}
