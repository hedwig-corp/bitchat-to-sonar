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

/**
 * Wallet — 1:1 with the design's `WalletScreen` + `WalletActivity`
 * (design/handoff/project/sonar/settings.jsx and pay.jsx): the balance block,
 * then the transaction log. It is a log only; there are no send/receive
 * actions here — paying starts from the new-chat sheet or inside a chat.
 */
@Composable
fun SonarWalletActivityScreen(state: SonarAppState) {
    val s = sonar
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
