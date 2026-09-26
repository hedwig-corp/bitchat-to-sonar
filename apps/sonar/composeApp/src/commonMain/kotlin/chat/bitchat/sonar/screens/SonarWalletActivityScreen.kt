package chat.bitchat.sonar.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.bitchat.sonar.Screen
import chat.bitchat.sonar.SonarAppState
import chat.bitchat.sonar.wallet.LegacyDeleteGate
import chat.bitchat.sonar.wallet.legacyDeleteBlockMessage
import chat.bitchat.sonar.resources.Res
import chat.bitchat.sonar.resources.arriving
import chat.bitchat.sonar.resources.checking
import chat.bitchat.sonar.resources.delete_old_wallet
import chat.bitchat.sonar.resources.it_s_empty_safe_to_remove
import chat.bitchat.sonar.resources.leaving
import chat.bitchat.sonar.resources.mint_offline_retrying
import chat.bitchat.sonar.resources.not_ready
import chat.bitchat.sonar.resources.old_lightning_wallet
import chat.bitchat.sonar.resources.send_from_old_wallet
import chat.bitchat.sonar.resources.setting_up
import chat.bitchat.sonar.resources.sonar_checked_the_old_wallet_it_holds
import chat.bitchat.sonar.resources.your_wallet_from_before_sonar_moved_to
import org.jetbrains.compose.resources.stringResource
import androidx.compose.foundation.clickable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import chat.bitchat.sonar.rowTimeLabel
import chat.bitchat.sonar.wallet.SonarPaymentActivity
import chat.bitchat.sonar.wallet.WalletActivityItem
import chat.bitchat.sonar.ui.SNIcon
import chat.bitchat.sonar.ui.SNIconName
import chat.bitchat.sonar.ui.SNNavHeader
import chat.bitchat.sonar.ui.SNSectionLabel
import chat.bitchat.sonar.ui.sonar
import chat.bitchat.sonar.SNQrCode
import chat.bitchat.sonar.shareInviteText
import chat.bitchat.sonar.ui.SNPrimaryButton
import chat.bitchat.sonar.ui.SonarType
import chat.bitchat.sonar.wallet.SendErrorKind
import chat.bitchat.sonar.wallet.WalletOutcome
import chat.bitchat.sonar.wallet.WalletPaymentEvent
import chat.bitchat.sonar.resources.amount_in_sats
import chat.bitchat.sonar.resources.anyone_can_pay_this_address_any_amount
import chat.bitchat.sonar.resources.copied
import chat.bitchat.sonar.resources.copy
import chat.bitchat.sonar.resources.create_invoice
import chat.bitchat.sonar.resources.one_time_invoice_for_it_can_be_paid_once
import chat.bitchat.sonar.resources.couldn_t_create_the_invoice_try_again
import chat.bitchat.sonar.resources.receive
import chat.bitchat.sonar.resources.received
import chat.bitchat.sonar.resources.request_an_amount
import chat.bitchat.sonar.resources.send
import chat.bitchat.sonar.resources.share
import chat.bitchat.sonar.resources.this_kind_of_payment_isn_t_supported_yet
import chat.bitchat.sonar.resources.your_wallet_is_busy_try_again_in_a
import chat.bitchat.sonar.resources.your_wallet_is_still_connecting_to_the
import chat.bitchat.sonar.resources.your_wallet_is_still_starting_try_again
import org.jetbrains.compose.resources.StringResource
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.KeyboardType
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Wallet — 1:1 with the design's `WalletScreen` + `WalletActivity`
 * (design/handoff/project/sonar/settings.jsx and pay.jsx): the balance block,
 * the Receive / Send pair, then the transaction log.
 *
 * Receive is how the wallet is funded from outside: the reusable offer as a
 * QR, or a one-time BOLT11 invoice for an amount (what most wallets can pay).
 * Send opens the send-payment picker. Both belong to the Cashu wallet only;
 * the legacy card keeps its own controls.
 */
@Composable
fun SonarWalletActivityScreen(state: SonarAppState) {
    val s = sonar
    var receiving by remember { mutableStateOf(false) }
    // Subscribe to ledger changes so the list recomposes on new entries:
    // chat ⚡PAY receipts (payVersion) and direct wallet payment activity
    // (paymentActivityVersion) — both read through state, never the store.
    state.payVersion
    state.paymentActivityVersion

    val balanceSats = state.walletBalanceSats()
    // Chat receipts + direct wallet activity, deduped, newest first.
    //
    // `walletActivity()` merges two ledgers, dedupes and sorts. Off the render
    // path via derivedStateOf: it recomputes only when the ledgers it reads
    // actually change, instead of on every recomposition of this screen.
    val entries by remember(state) { derivedStateOf { state.walletActivity() } }

    Column(Modifier.fillMaxSize().background(s.bg)) {
        SNNavHeader("Wallet", hairline = false, onBack = { state.back() })

        // LazyColumn, not a scrolling Column: a Column with verticalScroll
        // composes every row up front, so opening the screen paid for the whole
        // ledger and scrolling had nothing to recycle.
        LazyColumn(
            Modifier.fillMaxSize(),
            contentPadding = PaddingValues(bottom = 40.dp),
        ) {
            item {
                // ── .wallet-balance: centered column, 14px top / 6px bottom, 3px gap ──
                Column(
                    Modifier.fillMaxWidth().padding(top = 14.dp, bottom = 6.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    // .wallet-balnum: 34/800, -0.02em. `money()` is the design's
                    // walletStr — sats or fiat, whichever the user displays in.
                    Text(
                        state.money(balanceSats),
                        color = s.text,
                        fontSize = 34.sp,
                        fontWeight = FontWeight.ExtraBold,
                        letterSpacing = (-0.68).sp,
                    )
                    Spacer(Modifier.height(3.dp))
                    // .wallet-ballabel: 12.5px, text3
                    Text(
                        "Balance · pays directly, no claim step",
                        color = s.text3,
                        fontSize = 12.5.sp,
                    )
                    WalletStatusLine(state)
                }
                // keyshare-btns, reused: Receive (accent) + Send (neutral).
                Row(
                    Modifier.fillMaxWidth().padding(start = 18.dp, end = 18.dp, top = 10.dp, bottom = 6.dp),
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    KeyShareButton(
                        label = stringResource(Res.string.receive),
                        bg = s.accentFill,
                        fg = s.onAccent,
                        icon = { SNIcon(SNIconName.Download, 17.dp, it, weight = 2.2f) },
                        modifier = Modifier.weight(1f),
                    ) { receiving = true }
                    KeyShareButton(
                        label = stringResource(Res.string.send),
                        bg = s.surface2,
                        fg = s.text,
                        icon = { SNIcon(SNIconName.Send, 17.dp, it, weight = 2f) },
                        modifier = Modifier.weight(1f),
                    ) { state.push(Screen.SendPayment) }
                }
                if (state.legacyWallet.present) LegacyWalletCard(state)
                SNSectionLabel("Activity")
            }

            if (entries.isEmpty()) {
                item {
                    // .wallet-empty: centered text3, 14px, 30px/20px padding
                    Text(
                        "No transactions yet.",
                        color = s.text3,
                        fontSize = 14.sp,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 30.dp),
                    )
                }
            } else {
                itemsIndexed(entries, key = { _, entry -> entry.id }) { i, entry ->
                    ActivityRow(entry, state, divider = i < entries.lastIndex)
                }
            }
        }
    }

    if (receiving) ReceiveSheet(state, onClose = { receiving = false })
}

/** A one-time invoice on show, with the amount it was made for. */
private data class ShownInvoice(val invoice: String, val sats: Long, val paymentId: String)

/**
 * Whether [event] is the payment of the one-time invoice on show — by id,
 * never by amount (a same-sized payment to the reusable offer is not this
 * invoice). Once paid, the sheet stops offering it.
 */
internal fun paysShownInvoice(event: WalletPaymentEvent?, paymentId: String?): Boolean =
    paymentId != null && event != null && event.incoming && event.settled && event.paymentId == paymentId

/**
 * Receive — fund the wallet from any outside wallet. By default the wallet's
 * reusable offer (any amount, any number of times); "Request an amount" makes
 * a one-time BOLT11 invoice instead, and closing that section goes back to
 * the offer. The invoice call runs off the main thread in the engine.
 */
@Composable
private fun ReceiveSheet(state: SonarAppState, onClose: () -> Unit) {
    val s = sonar
    val scope = rememberCoroutineScope()
    val clipboard = LocalClipboardManager.current
    var copied by remember { mutableStateOf(false) }
    LaunchedEffect(copied) { if (copied) { delay(1700); copied = false } }
    var requesting by remember { mutableStateOf(false) }
    var amountText by remember { mutableStateOf("") }
    var invoice by remember { mutableStateOf<ShownInvoice?>(null) }
    var creating by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<StringResource?>(null) }
    // "Received …" only for a payment that lands while the sheet is open.
    val seenOnOpen = remember { state.lastIncomingWalletPayment }
    val received = state.lastIncomingWalletPayment?.takeIf { it != seenOnOpen }
    // A paid one-time invoice cannot be paid again: go back to the reusable
    // offer. Only the SHOWN invoice — one still being created is untouched.
    LaunchedEffect(state.lastIncomingWalletPayment) {
        if (paysShownInvoice(state.lastIncomingWalletPayment, invoice?.paymentId)) {
            invoice = null
            copied = false
        }
    }

    val offer = state.cashuOffer
    val shown = invoice?.invoice ?: offer
    val amountSats = amountText.toLongOrNull() ?: 0L
    val canCreate = state.walletOnline && amountSats > 0 && !creating

    Sheet(stringResource(Res.string.receive), onClose) {
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 12.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            if (shown == null) {
                Text(
                    stringResource(Res.string.your_wallet_is_still_connecting_to_the),
                    color = s.text2, fontSize = 13.5.sp, lineHeight = 20.sp, textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth().padding(vertical = 28.dp),
                )
            } else {
                // keyshare-qr: the white card, holding a real, scannable QR.
                Box(
                    Modifier.padding(top = 6.dp).shadow(6.dp, RoundedCornerShape(20.dp))
                        .clip(RoundedCornerShape(20.dp)).background(Color.White).padding(2.dp)
                ) {
                    SNQrCode(shown, 212.dp)
                }
                // keyshare-keyrow: mono, middle-truncated.
                Box(
                    Modifier.fillMaxWidth().padding(top = 14.dp)
                        .clip(RoundedCornerShape(12.dp)).background(s.surface2)
                        .padding(horizontal = 14.dp, vertical = 11.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(middleTruncated(shown), color = s.text2, style = SonarType.mono(12.5), maxLines = 1)
                }
                // keyshare-btns: Copy (accent → green Copied) + Share.
                Row(
                    Modifier.fillMaxWidth().padding(top = 10.dp),
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    KeyShareButton(
                        label = stringResource(if (copied) Res.string.copied else Res.string.copy),
                        bg = if (copied) s.green else s.accentFill,
                        fg = if (copied) Color.White else s.onAccent,
                        icon = {
                            if (copied) SNIcon(SNIconName.Check, 17.dp, it, weight = 2.2f)
                            else SNIcon(SNIconName.Copy, 17.dp, it, weight = 2.2f)
                        },
                        modifier = Modifier.weight(1f),
                    ) {
                        clipboard.setText(AnnotatedString(shown))
                        copied = true
                    }
                    val shareTitle = stringResource(Res.string.share)
                    KeyShareButton(
                        label = shareTitle,
                        bg = s.surface2,
                        fg = s.text,
                        icon = { SNIcon(SNIconName.Share, 17.dp, it, weight = 2f) },
                        modifier = Modifier.weight(1f),
                    ) { shareInviteText(shown, shareTitle) }
                }
                Text(
                    invoice?.let { stringResource(Res.string.one_time_invoice_for_it_can_be_paid_once, state.money(it.sats)) }
                        ?: stringResource(Res.string.anyone_can_pay_this_address_any_amount),
                    color = s.text2, fontSize = 12.5.sp, lineHeight = 18.sp, textAlign = TextAlign.Center,
                    modifier = Modifier.widthIn(max = 280.dp).padding(top = 12.dp),
                )
            }
            received?.let {
                Text(
                    stringResource(Res.string.received, state.money(it.amountSats)),
                    color = s.greenDeep, fontSize = 14.sp, fontWeight = FontWeight.Bold,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth().padding(top = 10.dp),
                )
            }

            // Request an amount: a one-time BOLT11 invoice. Closing the
            // section goes back to the reusable offer.
            Row(
                Modifier.fillMaxWidth().padding(top = 16.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .clickable {
                        requesting = !requesting
                        if (!requesting) { invoice = null; error = null }
                    }
                    .padding(horizontal = 4.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    stringResource(Res.string.request_an_amount),
                    color = s.text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f),
                )
                SNIcon(if (requesting) SNIconName.X else SNIconName.Chevron, 14.dp, s.text3, weight = 2.2f)
            }
            if (requesting) {
                Box(
                    Modifier.fillMaxWidth().padding(top = 6.dp)
                        .clip(RoundedCornerShape(12.dp)).background(s.surface2)
                        .padding(horizontal = 14.dp, vertical = 12.dp),
                ) {
                    if (amountText.isEmpty()) {
                        Text(stringResource(Res.string.amount_in_sats), color = s.text3, fontSize = 15.sp)
                    }
                    BasicTextField(
                        value = amountText,
                        onValueChange = { typed ->
                            val digits = typed.filter { it.isDigit() }.trimStart('0')
                            // 8 digits: up to 99,999,999 sats — above any mint's limit.
                            if (digits.length <= 8) { amountText = digits; error = null }
                        },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        textStyle = TextStyle(color = s.text, fontSize = 15.sp),
                        cursorBrush = SolidColor(s.accent),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                Spacer(Modifier.height(10.dp))
                SNPrimaryButton(
                    label = stringResource(Res.string.create_invoice),
                    disabled = !canCreate,
                ) {
                    val sats = amountSats
                    creating = true
                    error = null
                    scope.launch {
                        when (val r = state.createReceiveInvoice(sats)) {
                            is WalletOutcome.Ok -> {
                                invoice = ShownInvoice(r.value.invoice, sats, r.value.paymentId)
                                copied = false
                            }
                            is WalletOutcome.Failed -> error = receiveInvoiceErrorMessage(r.kind)
                        }
                        creating = false
                    }
                }
                error?.let {
                    Text(
                        stringResource(it),
                        color = s.danger, fontSize = 12.5.sp, lineHeight = 17.sp, textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                    )
                }
            }
            Spacer(Modifier.height(4.dp))
        }
    }
}

/** keyshare-keyrow's short form: head…tail, so both ends stay checkable. */
internal fun middleTruncated(value: String): String =
    if (value.length > 28) value.take(18) + "…" + value.takeLast(8) else value

/**
 * The message for a refused invoice, by typed kind: the wallet's shared
 * copy where it fits a receive, else "Couldn't create the invoice". Never
 * the send-side "you were not charged", which reads wrong on a receive.
 */
internal fun receiveInvoiceErrorMessage(kind: SendErrorKind): StringResource = when (kind) {
    SendErrorKind.Offline -> Res.string.mint_offline_retrying
    SendErrorKind.Busy -> Res.string.your_wallet_is_busy_try_again_in_a
    SendErrorKind.NotReady -> Res.string.your_wallet_is_still_starting_try_again
    SendErrorKind.Unsupported -> Res.string.this_kind_of_payment_isn_t_supported_yet
    SendErrorKind.InsufficientFunds,
    SendErrorKind.InvalidDestination,
    SendErrorKind.Failed -> Res.string.couldn_t_create_the_invoice_try_again
}

/** .wallet-txrow — icon bubble, "To/From <who>", "<status> · <rail> · <time>", signed amount. */
@Composable
private fun ActivityRow(entry: WalletActivityItem, state: SonarAppState, divider: Boolean) {
    val s = sonar
    val sent = entry.sent
    val failed = entry.status == SonarPaymentActivity.Status.Failed

    // Design pay.jsx WalletActivity: send glyph out, download glyph in.
    val icon = if (sent) SNIconName.Send else SNIconName.Download
    // .wallet-txicon.out = net-soft/net-deep, .in = green-soft/green-deep
    val tileBg = if (sent) s.netSoft else s.greenSoft
    val tileFg = if (sent) s.netDeep else s.greenDeep

    // Design status words. The app has no separate "confirmed" state — a
    // settled outgoing payment is "Sent", a settled incoming one "Received".
    val statusLabel = when (entry.status) {
        SonarPaymentActivity.Status.Pending -> "Pending"
        SonarPaymentActivity.Status.Failed -> "Failed"
        SonarPaymentActivity.Status.Paid -> if (sent) "Sent" else "Received"
    }
    val rail = if (entry.via == "mesh") "Bluetooth" else "Lightning"
    // Same label the chat list uses: today → HH:MM, this week → weekday,
    // older → date. Matches the design's `tx.time` ("18:06" / "Mon").
    val time = rowTimeLabel(entry.sortSecs)
    val meta = if (time.isEmpty()) "$statusLabel · $rail" else "$statusLabel · $rail · $time"

    Box(Modifier.fillMaxWidth()) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 11.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier.size(36.dp).clip(CircleShape).background(tileBg),
                contentAlignment = Alignment.Center,
            ) {
                SNIcon(icon, 16.dp, tileFg, weight = 2.2f)
            }
            Spacer(Modifier.width(12.dp))

            Column(Modifier.weight(1f)) {
                // .wallet-txwho: 15.5/650. `who` is null only for chat ⚡PAY
                // receipts, which do not persist a peer key — the design uses
                // the same "unknown" fallback.
                Text(
                    (if (sent) "To " else "From ") + (entry.who ?: "unknown"),
                    color = s.text,
                    fontSize = 15.5.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.height(1.dp))
                // .wallet-txmeta: 12.5px, text2 — not status-colored in the design.
                Text(meta, color = s.text2, fontSize = 12.5.sp, maxLines = 1)
            }
            Spacer(Modifier.width(12.dp))

            // .wallet-txamt: 15/700; .in green-deep; .failed text3 + strikethrough
            Text(
                (if (sent) "−" else "+") + state.money(entry.sats),
                color = if (failed) s.text3 else if (sent) s.text else s.greenDeep,
                fontSize = 15.sp,
                fontWeight = FontWeight.Bold,
                textDecoration = if (failed) TextDecoration.LineThrough else null,
            )
        }
        // .wallet-txrow::after — hairline inset to 64px, hidden on the last row
        if (divider) {
            Box(
                Modifier.fillMaxWidth().padding(start = 64.dp, end = 18.dp)
                    .align(Alignment.BottomStart).height(1.dp).background(s.hairline)
            )
        }
    }
}

/**
 * Under the balance: "mint offline — retrying" while an open wallet cannot
 * reach the mint, and what is in flight once the mint has answered.
 */
@Composable
private fun WalletStatusLine(state: SonarAppState) {
    val s = sonar
    val details = state.walletBalanceDetails
    val line = when {
        state.walletState is chat.bitchat.sonar.wallet.WalletState.Failed -> stringResource(Res.string.not_ready)
        !state.walletOnline -> stringResource(Res.string.mint_offline_retrying)
        details != null && (details.pendingReceiveSats > 0 || details.pendingSendSats > 0) -> buildList {
            if (details.pendingReceiveSats > 0) add(stringResource(Res.string.arriving, state.money(details.pendingReceiveSats)))
            if (details.pendingSendSats > 0) add(stringResource(Res.string.leaving, state.money(details.pendingSendSats)))
        }.joinToString(" · ")
        else -> null
    } ?: return
    Spacer(Modifier.height(2.dp))
    Text(line, color = s.text3, fontSize = 12.5.sp)
}

/**
 * The legacy Breez wallet ("Old Lightning wallet"): balance + pending, send
 * its sats out through the normal send flow, and delete it — only when the
 * delete gate proves it is empty (re-checked at the moment of deletion).
 * Hidden once it is gone.
 */
@Composable
private fun LegacyWalletCard(state: SonarAppState) {
    val s = sonar
    val legacy = state.legacyWallet
    val gate = state.legacyDeleteGate
    var confirming by remember { mutableStateOf(false) }
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 8.dp)
            .clip(RoundedCornerShape(16.dp)).background(s.surface)
            .padding(horizontal = 16.dp, vertical = 14.dp),
    ) {
        Text(
            stringResource(Res.string.old_lightning_wallet),
            color = s.text, fontSize = 15.5.sp, fontWeight = FontWeight.SemiBold,
        )
        Text(stringResource(Res.string.your_wallet_from_before_sonar_moved_to), color = s.text3, fontSize = 12.5.sp)
        Spacer(Modifier.height(4.dp))
        Text(
            if (legacy.connected) state.money(legacy.balanceSats) else stringResource(Res.string.setting_up),
            color = s.text, fontSize = 22.sp, fontWeight = FontWeight.ExtraBold,
        )
        if (legacy.pendingReceiveSats > 0) {
            Text(stringResource(Res.string.arriving, state.money(legacy.pendingReceiveSats)), color = s.text3, fontSize = 12.5.sp)
        }
        if (legacy.pendingSendSats > 0) {
            Text(stringResource(Res.string.leaving, state.money(legacy.pendingSendSats)), color = s.text3, fontSize = 12.5.sp)
        }
        Spacer(Modifier.height(10.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (legacy.connected && legacy.balanceSats > 0) {
                LegacyAction(stringResource(Res.string.send_from_old_wallet), primary = true) {
                    state.push(Screen.SendPaymentFromLegacy)
                }
            }
            val safe = confirming && gate == LegacyDeleteGate.Safe
            LegacyAction(
                if (state.legacyDeleteChecking) stringResource(Res.string.checking)
                else stringResource(Res.string.delete_old_wallet),
                danger = safe,
            ) {
                if (state.legacyDeleteChecking) return@LegacyAction
                if (safe) {
                    // Second tap, after the gate said it is empty: delete
                    // (deleteIfSafe re-checks the gate itself).
                    confirming = false
                    state.deleteLegacyWallet()
                } else {
                    confirming = true
                    state.checkLegacyDeleteGate()
                }
            }
        }
        if (confirming && !state.legacyDeleteChecking) {
            when (gate) {
                LegacyDeleteGate.Safe -> {
                    Spacer(Modifier.height(8.dp))
                    Text(stringResource(Res.string.it_s_empty_safe_to_remove), color = s.text, fontSize = 12.5.sp, fontWeight = FontWeight.SemiBold)
                    Text(stringResource(Res.string.sonar_checked_the_old_wallet_it_holds), color = s.text3, fontSize = 12.5.sp)
                }
                is LegacyDeleteGate.Blocked -> {
                    Spacer(Modifier.height(8.dp))
                    Text(
                        stringResource(legacyDeleteBlockMessage(gate.reason), state.money(legacy.balanceSats)),
                        color = s.text3, fontSize = 12.5.sp,
                    )
                }
                null -> Unit
            }
        }
        // Which wallet the public address pays: the old one until the user
        // moves it (and back, while the old wallet is here).
        if (handleAddressNoticeVisible(state)) {
            Spacer(Modifier.height(12.dp))
            HandleAddressNotice(state)
        }
    }
}

@Composable
private fun LegacyAction(label: String, primary: Boolean = false, danger: Boolean = false, onClick: () -> Unit) {
    val s = sonar
    val bg = when {
        danger -> s.danger
        primary -> s.goldFill
        else -> s.surface2
    }
    val fg = when {
        danger -> s.bg
        primary -> s.onGold
        else -> s.text
    }
    Box(
        Modifier.clip(RoundedCornerShape(999.dp)).background(bg)
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 8.dp),
    ) {
        Text(label, color = fg, fontSize = 13.sp, fontWeight = FontWeight.Bold)
    }
}
