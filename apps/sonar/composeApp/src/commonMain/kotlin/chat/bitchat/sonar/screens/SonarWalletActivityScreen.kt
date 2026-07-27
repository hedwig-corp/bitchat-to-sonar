package chat.bitchat.sonar.screens

import androidx.compose.foundation.background
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.bitchat.sonar.SonarAppState
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
    val entries = state.walletActivity()

    Column(Modifier.fillMaxSize().background(s.bg)) {
        SNNavHeader("Wallet", hairline = false, onBack = { state.back() })

        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState())
                .padding(bottom = 40.dp)
        ) {
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
            }

            SNSectionLabel("Activity")

            if (entries.isEmpty()) {
                // .wallet-empty: centered text3, 14px, 30px/20px padding
                Text(
                    "No transactions yet.",
                    color = s.text3,
                    fontSize = 14.sp,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 30.dp),
                )
            } else {
                Column(Modifier.fillMaxWidth()) {
                    entries.forEachIndexed { i, entry ->
                        ActivityRow(entry, state, divider = i < entries.lastIndex)
                    }
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
