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
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.derivedStateOf
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
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.bitchat.sonar.PaySheet
import chat.bitchat.sonar.PayableContact
import chat.bitchat.sonar.ConvRow
import chat.bitchat.sonar.SonarAppState
import chat.bitchat.sonar.ToastBar
import chat.bitchat.sonar.payFmt
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
    // `payableContacts()` walks every mesh peer, mesh DM row and direct Marmot
    // chat, resolving a BOLT12 offer and a display name for each. Calling it
    // straight from the composable body re-ran that whole scan on every
    // recomposition — including once per keystroke in the field below, which
    // is what made this list feel sluggish.
    //
    // derivedStateOf keeps the scan off the typing path: `query` is not read
    // inside it, so typing never invalidates it, and it only recomputes when
    // the peer/chat state it actually reads changes — and only notifies when
    // the resulting list differs.
    val contacts by remember(state) { derivedStateOf { state.payableContacts() } }
    val listed = remember(contacts, trimmed) {
        if (trimmed.isEmpty()) contacts
        else contacts.filter { it.name.contains(trimmed, ignoreCase = true) }
    }

    Column(Modifier.fillMaxSize().background(s.bg)) {
        SNNavHeader("Send payment", hairline = false, onBack = { state.back() })

        // LazyColumn, not a scrolling Column: a Column with verticalScroll
        // composes every contact row up front and recomposes them all on each
        // pass. The header is one item; only the rows are lazy.
        LazyColumn(
            Modifier.fillMaxSize(),
            contentPadding = PaddingValues(bottom = 40.dp),
        ) {
            item {
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
                        Text("Name, @username, name@domain or Bolt12…", color = s.text3, fontSize = 15.sp)
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
            }

            if (listed.isEmpty()) {
                item {
                // .wallet-empty, verbatim from the design — a quiet line, not a
                // full empty state with an icon tile.
                Text(
                    "No matching contacts. Try a username or Bolt12 offer above.",
                    color = s.text3, fontSize = 14.sp, textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 24.dp),
                )
                }
            } else {
                // The design uses the shared ConvRow (`.bc-row`): 16/11
                // padding, 16.5/650 title, a `.bc-signal` sub, a hairline from
                // x=72 that is suppressed on the last row — and nothing on the
                // right. Hand-rolling this row is what made the list look
                // wrong; reuse the component instead.
                itemsIndexed(listed, key = { _, c -> c.chatId }) { i, contact ->
                    ConvRow(
                        avatar = { SonarAvatar(contact.name, 44.dp, presence = contact.nearby) },
                        title = contact.name,
                        sub = contact.subtitle,
                        subFontSize = 13.5.sp,
                        subLeading = {
                            if (contact.nearby) {
                                Box(Modifier.size(8.dp).clip(CircleShape).background(s.accent))
                            } else {
                                SNIcon(SNIconName.Bolt, 12.dp, s.net, weight = 2.2f)
                            }
                        },
                        divider = i < listed.lastIndex,
                        onClick = { contactTarget = contact },
                    )
                }
            }

            item {
            // .st-note already carries its own 12px top margin.
            Text(
                "Only people who publish a payment address appear here. " +
                    "Payments settle directly to their wallet — no claim step.",
                color = s.text3, fontSize = 12.sp, lineHeight = 17.sp,
                modifier = Modifier.padding(start = 24.dp, end = 24.dp, top = 12.dp, bottom = 4.dp),
            )
            }
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
            ExternalDestination(SNIconName.Globe, "Resolve address · over the internet", input.trim())
        else -> null
    }
}

/** Short human label for a raw destination (design: `raw.split('@')[0]`). */
internal fun payableDisplayName(destination: String): String {
    val v = destination.trim()
    if ('@' in v) return v.substringBefore('@')
    return if (v.length > 14) v.take(12) + "…" else v
}
