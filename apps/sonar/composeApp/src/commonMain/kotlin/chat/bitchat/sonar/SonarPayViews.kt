package chat.bitchat.sonar

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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.bitchat.sonar.ui.SNIcon
import chat.bitchat.sonar.ui.SNIconName
import chat.bitchat.sonar.ui.sonar

/** Grouped sats, like the prototype's payFmt (en-US thousands separators). */
internal fun payFmt(sats: Long): String =
    sats.toString().reversed().chunked(3).joinToString(",").reversed()

private const val COIN = "₿" // ₿

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
) {
    val s = sonar
    var v by remember { mutableStateOf("") }
    val sats = v.toLongOrNull() ?: 0L
    val over = sats > balanceSats
    val can = sats > 0 && !over
    fun tap(k: String) {
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
                            if (v.isNotEmpty()) payFmt(sats) else "0",
                            color = if (over) s.danger else s.text,
                            fontSize = 42.sp, fontWeight = FontWeight.ExtraBold
                        )
                        Spacer(Modifier.width(7.dp))
                        Text("sats", color = s.text3, fontSize = 15.sp, fontWeight = FontWeight.Bold,
                            modifier = Modifier.padding(bottom = 6.dp))
                    }
                    Box(Modifier.height(20.dp).padding(top = 3.dp)) {
                        Text(
                            if (over) "Not enough sats" else (fiatOf(sats) ?: ""),
                            color = if (over) s.danger else s.text3, fontSize = 13.5.sp
                        )
                    }
                }

                // pay-chips
                Row(
                    Modifier.fillMaxWidth().padding(top = 10.dp, bottom = 2.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally)
                ) {
                    listOf(1000L, 10000L, 21000L).forEach { c ->
                        Box(
                            Modifier.clip(RoundedCornerShape(999.dp)).background(s.goldSoft)
                                .clickable { v = c.toString() }.padding(horizontal = 14.dp, vertical = 7.dp)
                        ) { Text(payFmt(c), color = s.goldDeep, fontSize = 13.sp, fontWeight = FontWeight.Bold) }
                    }
                    // "Max" = the entire spendable balance (to drain the wallet to
                    // this recipient). Filled gold to stand out from the presets.
                    if (balanceSats > 0) {
                        Box(
                            Modifier.clip(RoundedCornerShape(999.dp)).background(s.goldFill)
                                .clickable { v = balanceSats.toString() }.padding(horizontal = 16.dp, vertical = 7.dp)
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

                // bc-sheetactions
                Column(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp)) {
                    SendButton(mesh = mesh, enabled = can) { if (can) { onSend(sats); onClose() } }
                    Spacer(Modifier.height(6.dp))
                    Text(
                        if (mesh) "Chat can stay on Bluetooth. The payment goes straight to $peerName's wallet over Lightning."
                        else "Payment goes straight to $peerName's wallet over Lightning.",
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

/** ₿ coin disc — 40dp, inset highlight/shadow like .pay-coin. */
@Composable
private fun PayCoin(pulse: Boolean) {
    val s = sonar
    Box(
        Modifier.size(40.dp).clip(CircleShape).background(s.onGold.copy(alpha = 0.16f)),
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
