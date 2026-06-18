package chat.bitchat.sonar.screens

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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.bitchat.sonar.PayEntry
import chat.bitchat.sonar.PayStatus
import chat.bitchat.sonar.SonarAppState
import chat.bitchat.sonar.ToastBar
import chat.bitchat.sonar.payFmt
import chat.bitchat.sonar.wallet.WalletState
import chat.bitchat.sonar.ui.SNEmptyState
import chat.bitchat.sonar.ui.SNIcon
import chat.bitchat.sonar.ui.SNIconName
import chat.bitchat.sonar.ui.SNNavHeader
import chat.bitchat.sonar.ui.SNSectionLabel
import chat.bitchat.sonar.ui.sonar

@Composable
fun SonarWalletActivityScreen(state: SonarAppState) {
    val s = sonar
    // Subscribe to pay-ledger changes so the list recomposes on new entries.
    state.payVersion

    val balanceSats = state.walletBalanceSats()
    val fiat = state.fiatOrNull(balanceSats)
    val entries = state.walletPayEntries()

    Column(Modifier.fillMaxSize().background(s.bg)) {
        SNNavHeader("Wallet", hairline = false, onBack = { state.back() })

        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState())
                .padding(bottom = 40.dp)
        ) {
            // ── Balance card ──
            Column(
                Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp)
                    .clip(RoundedCornerShape(20.dp)).background(s.goldSoft)
                    .padding(20.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                SNIcon(SNIconName.Coin, 32.dp, s.goldDeep)
                Spacer(Modifier.height(10.dp))
                Row(verticalAlignment = Alignment.Bottom) {
                    Text(
                        payFmt(balanceSats),
                        color = s.text,
                        fontSize = 36.sp,
                        fontWeight = FontWeight.ExtraBold,
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(
                        "sats",
                        color = s.text3,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.padding(bottom = 5.dp),
                    )
                }
                if (fiat != null) {
                    Spacer(Modifier.height(4.dp))
                    Text(fiat, color = s.text2, fontSize = 14.sp)
                }
                Spacer(Modifier.height(6.dp))
                Text(
                    "Lightning wallet",
                    color = s.text3,
                    fontSize = 12.sp,
                )
            }

            // ── Quick actions ──
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                // Send button
                Box(
                    Modifier.weight(1f).height(48.dp)
                        .clip(RoundedCornerShape(999.dp)).background(s.goldFill)
                        .clickable { state.toast = "Open a chat to send or receive bitcoin" },
                    contentAlignment = Alignment.Center,
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        SNIcon(SNIconName.Bolt, 18.dp, s.onGold)
                        Spacer(Modifier.width(6.dp))
                        Text(
                            "Send",
                            color = s.onGold,
                            fontSize = 15.sp,
                            fontWeight = FontWeight.Bold,
                        )
                    }
                }
                // Receive button
                Box(
                    Modifier.weight(1f).height(48.dp)
                        .clip(RoundedCornerShape(999.dp)).background(s.surface)
                        .clickable { state.toast = "Open a chat to send or receive bitcoin" },
                    contentAlignment = Alignment.Center,
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        SNIcon(SNIconName.Coin, 18.dp, s.text)
                        Spacer(Modifier.width(6.dp))
                        Text(
                            "Receive",
                            color = s.text,
                            fontSize = 15.sp,
                            fontWeight = FontWeight.Bold,
                        )
                    }
                }
            }

            // ── Activity section ──
            SNSectionLabel("Activity")

            if (entries.isEmpty()) {
                SNEmptyState(
                    icon = SNIconName.Activity,
                    title = "No activity yet",
                    desc = "Send or receive bitcoin in any chat to see your transaction history here.",
                )
            } else {
                Column(Modifier.fillMaxWidth()) {
                    entries.asReversed().forEach { entry ->
                        PayEntryRow(entry, state)
                    }
                }
            }
        }
    }

    state.toast?.let { ToastBar(it) { state.toast = null } }
}

@Composable
private fun PayEntryRow(entry: PayEntry, state: SonarAppState) {
    val s = sonar
    val sent = entry.mine
    val icon = if (sent) SNIconName.Bolt else SNIconName.Coin

    val statusLabel = when (entry.status) {
        PayStatus.Claimed -> "Completed"
        PayStatus.Sealed, PayStatus.Claiming, PayStatus.Settling -> "Pending"
        PayStatus.Failed -> "Failed"
    }
    val statusColor = when (entry.status) {
        PayStatus.Claimed -> s.green
        PayStatus.Sealed, PayStatus.Claiming, PayStatus.Settling -> s.goldDeep
        PayStatus.Failed -> s.danger
    }

    val amountPrefix = if (sent) "" else "+"
    val amountColor = if (sent) s.text else s.green
    val fiat = state.fiatOrNull(entry.sats)

    Row(
        Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // Icon tile
        Box(
            Modifier.size(38.dp).clip(RoundedCornerShape(11.dp)).background(s.goldSoft),
            contentAlignment = Alignment.Center,
        ) {
            SNIcon(icon, 18.dp, s.goldDeep)
        }
        Spacer(Modifier.width(12.dp))

        // Title + status
        Column(Modifier.weight(1f)) {
            Text(
                if (sent) "Sent" else "Received",
                color = s.text,
                fontSize = 15.5.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    statusLabel,
                    color = statusColor,
                    fontSize = 12.5.sp,
                )
                Text(
                    " · Lightning",
                    color = s.text3,
                    fontSize = 12.5.sp,
                )
            }
        }

        // Amount + fiat
        Column(horizontalAlignment = Alignment.End) {
            Text(
                "$amountPrefix${payFmt(entry.sats)} sats",
                color = amountColor,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
            )
            if (fiat != null) {
                Text(
                    fiat,
                    color = s.text3,
                    fontSize = 12.sp,
                )
            }
        }
    }
}
