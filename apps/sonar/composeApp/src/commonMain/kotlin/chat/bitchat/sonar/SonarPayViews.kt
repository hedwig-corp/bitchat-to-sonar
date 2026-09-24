package chat.bitchat.sonar

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.bitchat.sonar.ui.SNIcon
import chat.bitchat.sonar.ui.SNIconName
import chat.bitchat.sonar.ui.sonar
import chat.bitchat.sonar.wallet.SpendableBalance
import chat.bitchat.sonar.resources.Res
import chat.bitchat.sonar.resources.checking_the_fee
import chat.bitchat.sonar.resources.network_fee_up_to
import chat.bitchat.sonar.resources.pays_this_bolt12_offer
import chat.bitchat.sonar.resources.pays_this_lightning_invoice
import kotlinx.coroutines.delay
import org.jetbrains.compose.resources.stringResource

/** Grouped sats, like the prototype's payFmt (en-US thousands separators). */
internal fun payFmt(sats: Long): String =
    sats.toString().reversed().chunked(3).joinToString(",").reversed()

private const val COIN = "₿" // ₿

/**
 * How the pay sheet's fee line writes the fee: always sats, like the amount
 * above it. A fee reserve is a few sats, which the fiat formatter rounded to
 * "CHF 0.00" (QA, #614).
 */
internal fun feeLineAmount(sats: Long): String = "${payFmt(sats)} sats"

/** Keystrokes inside this window re-quote once, not once per key. */
private const val FEE_QUOTE_DEBOUNCE_MS = 400L

/**
 * What the send sheet's footer says about where the money goes. A raw
 * invoice or offer names no person — "Pays lnbc5u1p4tg7…'s wallet" read as if
 * the invoice were someone's name — so those get their own copy; contacts,
 * usernames and Lightning addresses keep the "<name>'s wallet" line.
 */
internal sealed interface PayFooter {
    data object LightningInvoice : PayFooter
    data object Bolt12Offer : PayFooter
    data class Named(val name: String, val mesh: Boolean) : PayFooter
}

/**
 * Pick the footer for a sheet paying [destination] (the raw string handed to
 * the wallet; null for a contact, whose offer the chat resolves).
 */
internal fun payFooter(destination: String?, peerName: String, mesh: Boolean): PayFooter {
    val raw = destination?.trim()?.lowercase()?.removePrefix("lightning:").orEmpty()
    return when {
        // name@domain is an address even when its user part looks like an invoice.
        '@' in raw -> PayFooter.Named(peerName, mesh)
        raw.startsWith("lno1") -> PayFooter.Bolt12Offer
        // lnbc (mainnet, incl. lnbcrt regtest), lntb/lntbs (testnet/signet), lnsb (simnet).
        raw.startsWith("lnbc") || raw.startsWith("lntb") || raw.startsWith("lnsb") -> PayFooter.LightningInvoice
        else -> PayFooter.Named(peerName, mesh)
    }
}

/** The fee line under the amount (Cashu wallet only). */
private sealed interface FeeLine {
    data object Hidden : FeeLine
    data object Checking : FeeLine
    data class Known(val sats: Long) : FeeLine
}

/**
 * Bitcoin amount sheet — 1:1 reproduction of pay.jsx `PaySheet`: balance line,
 * big amount with live-fiat subline, quick chips, numeric keypad, and a
 * transport-aware send button (Bluetooth ecash vs Lightning).
 *
 * Deviation from the prototype (matching the iOS reproduction): the fiat line is
 * shown only when a live rate exists ([fiatOf] returns non-null), never a fixed
 * demo rate.
 */
@Composable
fun PaySheet(
    peerName: String,
    balanceSats: Long,
    mesh: Boolean,
    fiatOf: (Long) -> String?,
    onSend: (Long) -> Unit,
    onClose: () -> Unit,
    /**
     * Amount already fixed by the destination — a scanned Lightning invoice
     * that encodes one. The design's `PaySheet` `fixed` prop: the amount is
     * shown but the chips and keypad are hidden, because there is nothing to
     * choose.
     */
    fixedSats: Long? = null,
    /**
     * What the `Max` chip proposes. The Cashu wallet passes its whole balance
     * (the send pipeline subtracts the mint's quoted fee reserve); the legacy
     * wallet keeps the 0.5% instant reserve, which is the default here.
     */
    maxSats: Long = SpendableBalance.maxSendableSats(balanceSats),
    /**
     * Called instead of [onSend] when the amount is still the `Max` proposal,
     * so the wallet may take the fee out of the amount. Null: [onSend].
     */
    onSendMax: ((Long) -> Unit)? = null,
    /**
     * The raw destination this sheet pays (an invoice, offer or address), or
     * null for a contact. Picks the footer copy — see [payFooter].
     */
    destination: String? = null,
    /**
     * The mint's fee reserve for sending the given amount, or null when there
     * is none to show. Non-null only for the Cashu (primary) wallet: the sheet
     * then shows "Checking the fee…" / "Network fee: up to …", re-quoted
     * [FEE_QUOTE_DEBOUNCE_MS] after the amount settles. It never gates Send.
     */
    feeQuote: (suspend (Long) -> Long?)? = null,
) {
    val s = sonar
    TransientBackHandler(onClose)
    var v by remember { mutableStateOf(fixedSats?.toString().orEmpty()) }
    // True only while the amount is exactly what `Max` proposed; any edit
    // clears it, so a typed amount is never shaved by a fee.
    var maxPicked by remember { mutableStateOf(false) }
    val sats = fixedSats ?: (v.toLongOrNull() ?: 0L)
    // `v` is the keypad buffer and a fixed amount hides the keypad, so the
    // display must not key off `v` alone — that is what rendered "0" on iOS for
    // an invoice that already carries its amount. Stated explicitly here too so
    // the two platforms cannot drift.
    val hasAmount = fixedSats != null || v.isNotEmpty()
    // Gate on the RAW balance. The reserve is a conservative ESTIMATE (0.5%,
    // no route knowledge), so treating it as a hard ceiling rejects payments
    // that are genuinely affordable: with 100k sats and a real 100-sat fee, a
    // 99,600-sat invoice is payable but sat above the 99,500 estimate. A fixed
    // invoice cannot be lowered, so that user simply could not pay at all.
    // `Max` proposes [maxSats], and the REAL prepared fee is enforced in the
    // send pipeline before any wallet is asked to pay (the Cashu engine's
    // quote check; the legacy SpendableBalance.insufficientAfterFee).
    val over = sats > balanceSats
    val can = sats > 0 && !over

    // Fee before confirm: quote once the amount is known and affordable. A
    // new amount cancels the pending quote (its late answer is dropped) and
    // starts the debounce again; a refused quote just hides the line.
    val quote by rememberUpdatedState(feeQuote)
    val quoting = feeQuote != null && can
    var feeLine by remember { mutableStateOf<FeeLine>(FeeLine.Hidden) }
    LaunchedEffect(sats, quoting) {
        if (!quoting) {
            feeLine = FeeLine.Hidden
            return@LaunchedEffect
        }
        feeLine = FeeLine.Checking
        delay(FEE_QUOTE_DEBOUNCE_MS)
        val fee = quote?.invoke(sats)
        feeLine = if (fee != null) FeeLine.Known(fee) else FeeLine.Hidden
    }
    fun tap(k: String) {
        maxPicked = false
        if (k == "del") { v = v.dropLast(1); return }
        val nv = (v + k).trimStart('0').ifEmpty { "0" } // strip leading zeros, keep one
        if (nv.length <= 7) v = nv
    }

    Box(
        Modifier.fillMaxSize().background(s.scrim).clickable(onClick = onClose),
        contentAlignment = Alignment.BottomCenter
    ) {
        Surface(color = s.surface, shape = RoundedCornerShape(topStart = 22.dp, topEnd = 22.dp)) {
            Column(Modifier.fillMaxWidth().padding(start = 14.dp, end = 14.dp, top = 16.dp, bottom = 20.dp)) {
                Text("Send bitcoin · $peerName", color = s.text, fontSize = 17.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.height(10.dp))

                // pay-balance
                Row(
                    Modifier.fillMaxWidth().padding(bottom = 4.dp),
                    horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically
                ) {
                    SNIcon(SNIconName.Coin, 13.dp, s.text3, weight = 2f)
                    Spacer(Modifier.width(6.dp))
                    Text("Balance · ${payFmt(balanceSats)} sats", color = s.text3, fontSize = 12.5.sp)
                }

                // pay-amountbox
                Column(
                    Modifier.fillMaxWidth().padding(top = 8.dp, bottom = 2.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Row(verticalAlignment = Alignment.Bottom) {
                        Text(
                            if (hasAmount) payFmt(sats) else "0",
                            color = if (over) s.danger else s.text,
                            fontSize = 42.sp, fontWeight = FontWeight.ExtraBold
                        )
                        Spacer(Modifier.width(7.dp))
                        Text("sats", color = s.text3, fontSize = 15.sp, fontWeight = FontWeight.Bold,
                            modifier = Modifier.padding(bottom = 6.dp))
                    }
                    Box(Modifier.height(20.dp).padding(top = 3.dp)) {
                        // Explicit no-live-rate fallback (iOS `hasLiveRate` rule):
                        // [fiatOf] returns null when no live rate exists, and the
                        // subline stays empty — the main amount above is already
                        // sats, so nothing fiat-looking is ever invented.
                        val fiatHint = if (over) "Not enough sats" else fiatOf(sats).orEmpty()
                        Text(
                            fiatHint,
                            color = if (over) s.danger else s.text3, fontSize = 13.5.sp
                        )
                    }
                    // Fixed height so the keypad does not jump as the line
                    // comes and goes.
                    if (feeQuote != null) {
                        Box(Modifier.height(18.dp).padding(top = 1.dp)) {
                            val line = when (val f = feeLine) {
                                FeeLine.Hidden -> null
                                FeeLine.Checking -> stringResource(Res.string.checking_the_fee)
                                is FeeLine.Known -> stringResource(Res.string.network_fee_up_to, feeLineAmount(f.sats))
                            }
                            if (line != null) Text(line, color = s.text3, fontSize = 12.5.sp)
                        }
                    }
                }

                if (fixedSats == null) {
                // pay-chips
                Row(
                    Modifier.fillMaxWidth().padding(top = 10.dp, bottom = 2.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally)
                ) {
                    listOf(1000L, 10000L, 21000L).forEach { c ->
                        Box(
                            Modifier.clip(RoundedCornerShape(999.dp)).background(s.goldSoft)
                                .clickable { v = c.toString(); maxPicked = false }.padding(horizontal = 14.dp, vertical = 7.dp)
                        ) { Text(payFmt(c), color = s.goldDeep, fontSize = 13.sp, fontWeight = FontWeight.Bold) }
                    }
                    // "Max" = everything that can actually settle: the balance
                    // minus a fee reserve (#141 — proposing the full balance
                    // made the send fail locally with a raw InsufficientFunds).
                    // A balance at or below the reserve offers no Max at all.
                    val maxSendable = maxSats.coerceAtMost(balanceSats)
                    if (maxSendable > 0) {
                        Box(
                            Modifier.clip(RoundedCornerShape(999.dp)).background(s.goldFill)
                                .clickable { v = maxSendable.toString(); maxPicked = true }
                                .padding(horizontal = 16.dp, vertical = 7.dp)
                        ) { Text("Max", color = s.onGold, fontSize = 13.sp, fontWeight = FontWeight.Bold) }
                    }
                }

                // pay-pad (4 rows × 3 cols)
                val keys = listOf("1", "2", "3", "4", "5", "6", "7", "8", "9", "00", "0", "del")
                Column(Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 8.dp)) {
                    keys.chunked(3).forEach { row ->
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                            row.forEach { k ->
                                Box(
                                    Modifier.weight(1f).clip(RoundedCornerShape(12.dp))
                                        .clickable { tap(k) }.padding(12.dp),
                                    contentAlignment = Alignment.Center
                                ) {
                                    if (k == "del") SNIcon(SNIconName.Back, 18.dp, s.text, weight = 2.2f)
                                    else Text(k, color = s.text, fontSize = 21.sp, fontWeight = FontWeight.SemiBold)
                                }
                            }
                        }
                    }
                }

                }

                // bc-sheetactions
                Column(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp)) {
                    SendButton(mesh = mesh, enabled = can) {
                        if (can) {
                            val viaMax = onSendMax
                            if (maxPicked && viaMax != null) viaMax(sats) else onSend(sats)
                            onClose()
                        }
                    }
                    Spacer(Modifier.height(6.dp))
                    Text(
                        when (val footer = payFooter(destination, peerName, mesh)) {
                            PayFooter.LightningInvoice -> stringResource(Res.string.pays_this_lightning_invoice)
                            PayFooter.Bolt12Offer -> stringResource(Res.string.pays_this_bolt12_offer)
                            is PayFooter.Named ->
                                if (footer.mesh) "Chat can stay on Bluetooth. The payment goes straight to ${footer.name}'s wallet over Lightning."
                                else "Payment goes straight to ${footer.name}'s wallet over Lightning."
                        },
                        color = s.text3, fontSize = 12.sp, lineHeight = 18.sp, textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp)
                    )
                }
            }
        }
    }
}

@Composable
private fun SendButton(mesh: Boolean, enabled: Boolean, onClick: () -> Unit) {
    val s = sonar
    val bg = if (mesh) s.accentFill else s.netFill
    val fg = if (mesh) s.onAccent else s.onNet
    Box(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp))
            .background(if (enabled) bg else bg.copy(alpha = 0.4f))
            .then(if (enabled) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(15.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(
            if (mesh) "Send over Bluetooth" else "Send over Lightning",
            color = fg, fontSize = 17.sp, fontWeight = FontWeight.Bold
        )
    }
}

/**
 * Payment receipt bubble. PAY is the conversation receipt and PAYDONE marks the
 * Lightning settlement complete; there is no in-chat claim step.
 */
@Composable
fun PayBubble(
    m: SonarMsg,
    pay: PayLine.Pay,
    status: PayStatus?,
    peerName: String,
    mesh: Boolean,
    fiatOf: (Long) -> String?,
) {
    val s = sonar
    val time = hhmm(m.tsSecs)
    val viaIcon = if (mesh) SNIconName.Mesh else SNIconName.Bolt
    val claimed = status == PayStatus.Claimed
    val pending = !claimed

    Column(
        Modifier.fillMaxWidth().padding(vertical = 4.dp),
        horizontalAlignment = if (m.mine) Alignment.End else Alignment.Start
    ) {
        // pay-card
        val cardShape = if (m.mine)
            RoundedCornerShape(18.dp, 18.dp, 5.dp, 18.dp) else RoundedCornerShape(18.dp, 18.dp, 18.dp, 5.dp)
        Row(
            Modifier.widthIn(min = 190.dp).clip(cardShape).background(s.goldFill)
                .padding(start = 12.dp, top = 12.dp, end = 16.dp, bottom = 12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            PayCoin(pulse = !m.mine && pending)
            Spacer(Modifier.width(12.dp))
            Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                Row(verticalAlignment = Alignment.Bottom) {
                    Text(payFmt(pay.sats), color = s.onGold, fontSize = 19.sp, fontWeight = FontWeight.ExtraBold)
                    Spacer(Modifier.width(2.dp))
                    Text("sats", color = s.onGold.copy(alpha = 0.7f), fontSize = 12.sp,
                        fontWeight = FontWeight.Bold, modifier = Modifier.padding(bottom = 2.dp))
                }
                fiatOf(pay.sats)?.let {
                    Text(it, color = s.onGold.copy(alpha = 0.72f), fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }
        // bc-state
        Spacer(Modifier.height(3.dp))
        Row(
            Modifier.padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(3.dp)
        ) {
            SNIcon(viaIcon, 11.dp, s.text3, weight = 2.4f)
            val label = when {
                m.mine && claimed -> "Paid $peerName"
                m.mine -> "Sending to $peerName"
                claimed -> "Received from $peerName"
                else -> "Incoming payment"
            }
            Text("$label · $time", color = s.text3, fontSize = 11.sp)
        }
    }
}

/** ₿ coin disc — 40dp, inset highlight/shadow like .pay-coin.
 *  When [pulse] is true (incoming pending), the disc breathes 1→1.08→1 on a
 *  2-second loop — matching the iOS `TimelineView` PayCoin pulse. */
@Composable
private fun PayCoin(pulse: Boolean) {
    val s = sonar
    val scale = if (pulse) {
        val t = rememberInfiniteTransition(label = "coinPulse")
        val p by t.animateFloat(
            1f, 1.08f,
            infiniteRepeatable(tween(1000, easing = androidx.compose.animation.core.EaseInOut), RepeatMode.Reverse),
            label = "coinPulse"
        )
        p
    } else 1f
    Box(
        Modifier.size(40.dp)
            .graphicsLayer { scaleX = scale; scaleY = scale }
            .clip(CircleShape).background(s.onGold.copy(alpha = 0.16f)),
        contentAlignment = Alignment.Center
    ) {
        Text(COIN, color = s.onGold, fontSize = 20.sp, fontWeight = FontWeight.ExtraBold)
    }
}

/** Epoch seconds → HH:MM (device-local via the platform offset is unavailable in
 *  commonMain, so this is UTC; acceptable for the relative timestamp line). */
private fun hhmm(tsSecs: Long): String {
    val mins = (tsSecs / 60) % (24 * 60)
    val h = (mins / 60).toInt()
    val mm = (mins % 60).toInt()
    return h.toString().padStart(2, '0') + ":" + mm.toString().padStart(2, '0')
}
