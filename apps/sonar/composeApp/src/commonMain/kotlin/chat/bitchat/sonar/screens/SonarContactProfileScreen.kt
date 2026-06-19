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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.bitchat.sonar.PayLine
import chat.bitchat.sonar.PaySheet
import chat.bitchat.sonar.Screen
import chat.bitchat.sonar.SonarAppState
import chat.bitchat.sonar.canonicalProfileKey
import chat.bitchat.sonar.randomPayId
import chat.bitchat.sonar.ui.SNIcon
import chat.bitchat.sonar.ui.SNIconName
import chat.bitchat.sonar.ui.SNNavHeader
import chat.bitchat.sonar.ui.SNPrimaryButton
import chat.bitchat.sonar.ui.SNSectionLabel
import chat.bitchat.sonar.ui.SNSettingsCard
import chat.bitchat.sonar.ui.SNSettingsRow
import chat.bitchat.sonar.ui.SNTone
import chat.bitchat.sonar.ui.SNTrail
import chat.bitchat.sonar.ui.SonarAvatar
import chat.bitchat.sonar.ui.SonarType
import chat.bitchat.sonar.ui.sonar

@Composable
fun SonarContactProfileScreen(state: SonarAppState, screen: Screen.ContactProfile) {
    val s = sonar
    var showVerify by remember { mutableStateOf(false) }
    var paySheet by remember { mutableStateOf(false) }

    // Derive the peer npub from the chat members list, or accept a direct
    // npub when opened from a group member tap.
    val peerNpub = remember(screen.chatId, state.chats.size) {
        if (screen.chatId.startsWith("mesh:")) {
            val peerId = screen.chatId.removePrefix("mesh:")
            state.npubStringForPeer(peerId)?.let { canonicalProfileKey(it) }
        } else if (screen.chatId.startsWith("npub1")) {
            canonicalProfileKey(screen.chatId)
        } else {
            val chat = state.chats.firstOrNull { it.id == screen.chatId }
            val mine = canonicalProfileKey(state.npub)
            chat?.members
                ?.map { canonicalProfileKey(it) }
                ?.firstOrNull { it != mine && it.isNotBlank() }
        }
    }

    // When opened from group info with an npub (or mesh with a known npub),
    // resolve to the 1:1 DM chat id so verifyInfo/isVerified/canCall work.
    val effectiveChatId = remember(screen.chatId, peerNpub, state.chats.size) {
        val resolvedNpub = when {
            screen.chatId.startsWith("npub1") -> canonicalProfileKey(screen.chatId)
            peerNpub != null -> peerNpub
            else -> null
        }
        if (resolvedNpub != null) {
            val mine = canonicalProfileKey(state.npub)
            state.chats.firstOrNull { chat ->
                val members = chat.members.map { canonicalProfileKey(it) }
                members.size == 2 && mine in members && resolvedNpub in members
            }?.id ?: screen.chatId
        } else {
            screen.chatId
        }
    }

    val verifyInfo = remember(effectiveChatId, state.payVersion) {
        state.verifyInfo(effectiveChatId)
    }
    val verified = state.isVerified(effectiveChatId)
    val canCall = state.canCall(effectiveChatId)
    val canPay = !state.isMultiMemberChat(effectiveChatId)

    // Find shared groups: multi-member groups where both the local user and this
    // contact are members.
    val sharedGroups = remember(state.chats.size, peerNpub) {
        if (peerNpub == null) emptyList()
        else {
            val mine = canonicalProfileKey(state.npub)
            state.chats.filter { chat ->
                state.isMultiMemberChat(chat.id) &&
                    chat.members.any { canonicalProfileKey(it) == mine } &&
                    chat.members.any { canonicalProfileKey(it) == peerNpub }
            }
        }
    }

    Column(Modifier.fillMaxSize().background(s.bg)) {
        SNNavHeader("", hairline = false, onBack = { state.back() })
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState())
        ) {
            // ── Profile hero ──
            Column(
                Modifier.fillMaxWidth().padding(top = 10.dp, start = 28.dp, end = 28.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                SonarAvatar(screen.name, 96.dp)
                Spacer(Modifier.height(8.dp))
                Text(
                    screen.name,
                    color = s.text,
                    fontSize = 24.sp,
                    fontWeight = FontWeight.Black
                )
                Spacer(Modifier.height(6.dp))
                Box(
                    Modifier.clip(CircleShape).background(s.surface2)
                        .padding(horizontal = 11.dp, vertical = 4.dp)
                ) {
                    Text(
                        shortKey(peerNpub),
                        color = s.text3,
                        style = SonarType.mono(12.0)
                    )
                }
            }

            Spacer(Modifier.height(18.dp))

            // ── Action buttons row ──
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 28.dp),
                horizontalArrangement = Arrangement.Center
            ) {
                ActionCircle(
                    icon = SNIconName.Lock,
                    label = "Message",
                    onClick = {
                        if (effectiveChatId != screen.chatId) {
                            val dmChat = state.chats.firstOrNull { it.id == effectiveChatId }
                            if (dmChat != null) state.openChat(dmChat)
                            else state.back()
                        } else {
                            state.back()
                        }
                    }
                )
                Spacer(Modifier.width(28.dp))
                ActionCircle(
                    icon = SNIconName.Phone,
                    label = "Call",
                    enabled = canCall,
                    onClick = {
                        if (canCall) state.placeCall(effectiveChatId, screen.name, false)
                        else state.toast = "No call route to this peer yet."
                    }
                )
                Spacer(Modifier.width(28.dp))
                ActionCircle(
                    icon = SNIconName.Coin,
                    label = "Pay",
                    enabled = canPay,
                    onClick = { paySheet = true }
                )
                Spacer(Modifier.width(28.dp))
                ActionCircle(
                    icon = if (verified) SNIconName.ShieldCheck else SNIconName.Shield,
                    label = if (verified) "Verified" else "Verify",
                    onClick = { showVerify = !showVerify }
                )
            }

            Spacer(Modifier.height(20.dp))

            // ── Verify inline section ──
            if (showVerify) {
                VerifyInline(
                    peerName = screen.name,
                    myName = state.nick.ifBlank { "you" },
                    info = verifyInfo,
                    onVerify = { state.markVerified(effectiveChatId) },
                    onDismiss = { showVerify = false }
                )
                Spacer(Modifier.height(12.dp))
            }

            // ── Identity card ──
            SNSectionLabel("Identity")
            SNSettingsCard {
                SNSettingsRow(
                    icon = SNIconName.Key,
                    tone = SNTone.Cyan,
                    label = "Public key",
                    value = shortKey(peerNpub),
                    valueMono = true,
                    trail = SNTrail.None
                ) {}
                SNSettingsRow(
                    icon = SNIconName.Lock,
                    label = "Key fingerprint",
                    value = verifyInfo.safety.firstOrNull()?.take(10)?.let { "$it..." } ?: "n/a",
                    valueMono = true,
                    trail = SNTrail.None,
                    divider = false
                ) {}
            }

            // ── Safety card ──
            SNSectionLabel("Safety")
            SNSettingsCard {
                SNSettingsRow(
                    icon = if (verified) SNIconName.ShieldCheck else SNIconName.Shield,
                    tone = if (verified) SNTone.Cyan else SNTone.Default,
                    label = "Safety number",
                    value = if (verified) "Verified" else "Not verified",
                    trail = SNTrail.Chevron
                ) { showVerify = !showVerify }
                SNSettingsRow(
                    icon = SNIconName.Lock,
                    tone = SNTone.Cyan,
                    label = "End-to-end encrypted",
                    sub = "Messages are encrypted with the Signal protocol",
                    trail = SNTrail.None,
                    divider = false
                ) {}
            }

            // ── Shared groups ──
            SNSectionLabel("Shared groups")
            if (sharedGroups.isEmpty()) {
                Text(
                    "No shared groups",
                    color = s.text3,
                    fontSize = 14.sp,
                    modifier = Modifier.padding(start = 18.dp, bottom = 8.dp)
                )
            } else {
                SNSettingsCard {
                    sharedGroups.forEachIndexed { idx, group ->
                        val groupName = state.chatTitle(group)
                        Row(
                            Modifier.fillMaxWidth()
                                .clickable { state.openChat(group) }
                                .padding(horizontal = 14.dp, vertical = 11.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            SonarAvatar(groupName, 36.dp)
                            Spacer(Modifier.width(12.dp))
                            Column(Modifier.weight(1f)) {
                                Text(
                                    groupName,
                                    color = s.text,
                                    fontSize = 16.sp,
                                    fontWeight = FontWeight.Medium
                                )
                                Text(
                                    "${group.members.size} members",
                                    color = s.text3,
                                    fontSize = 12.5.sp
                                )
                            }
                        }
                        if (idx < sharedGroups.lastIndex) {
                            Box(
                                Modifier.fillMaxWidth().padding(start = 60.dp)
                                    .height(1.dp).background(s.hairline)
                            )
                        }
                    }
                }
            }

            // ── Actions card ──
            SNSectionLabel("Actions")
            SNSettingsCard {
                SNSettingsRow(
                    icon = SNIconName.X,
                    tone = SNTone.Red,
                    label = "Block contact",
                    danger = true,
                    trail = SNTrail.None
                ) { state.toast = "Coming soon" }
                SNSettingsRow(
                    icon = SNIconName.Trash,
                    tone = SNTone.Red,
                    label = "Delete chat",
                    danger = true,
                    trail = SNTrail.None,
                    divider = false
                ) { state.toast = "Coming soon" }
            }

            Spacer(Modifier.height(40.dp))
        }
    }
    if (paySheet) {
        val isMesh = effectiveChatId.startsWith("mesh:")
        PaySheet(
            peerName = screen.name,
            balanceSats = state.walletBalanceSats(),
            mesh = isMesh,
            fiatOf = { state.fiatOrNull(it) },
            onSend = { sats ->
                state.send(effectiveChatId, PayLine.Pay(randomPayId(), sats).encoded())
            },
            onClose = { paySheet = false }
        )
    }
}

/** Circular action button with icon and label below. */
@Composable
private fun ActionCircle(
    icon: SNIconName,
    label: String,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    val s = sonar
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Box(
            Modifier.size(52.dp)
                .clip(CircleShape)
                .background(if (enabled) s.accentSoft else s.surface2)
                .clickable(enabled = enabled, onClick = onClick),
            contentAlignment = Alignment.Center
        ) {
            SNIcon(
                icon, 22.dp,
                if (enabled) s.accentDeep else s.text3,
                weight = 2.1f
            )
        }
        Spacer(Modifier.height(5.dp))
        Text(
            label,
            color = s.text2,
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium
        )
    }
}

/** Inline verify section — shows safety numbers and verify button. */
@Composable
private fun VerifyInline(
    peerName: String,
    myName: String,
    info: chat.bitchat.sonar.SonarVerify,
    onVerify: () -> Unit,
    onDismiss: () -> Unit,
) {
    val s = sonar
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 14.dp)
            .clip(RoundedCornerShape(18.dp)).background(s.surface)
            .padding(20.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text(
            "Verify safety numbers",
            color = s.text,
            fontSize = 18.sp,
            fontWeight = FontWeight.Bold
        )
        Spacer(Modifier.height(14.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(28.dp)) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                SonarAvatar(myName, 48.dp, presence = false)
                Spacer(Modifier.height(4.dp))
                Text(myName, color = s.text2, fontSize = 12.sp)
            }
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                SonarAvatar(peerName, 48.dp, presence = false)
                Spacer(Modifier.height(4.dp))
                Text(peerName, color = s.text2, fontSize = 12.sp)
            }
        }
        Spacer(Modifier.height(16.dp))
        if (info.safety.isEmpty()) {
            Text(
                info.note ?: "Safety numbers aren't available yet.",
                color = s.text2,
                fontSize = 13.5.sp,
                textAlign = TextAlign.Center
            )
        } else {
            Text(
                "Compare these numbers with $peerName in person or on a call. If they match, this chat is end-to-end encrypted and nobody is in the middle.",
                color = s.text2,
                fontSize = 13.5.sp,
                lineHeight = 18.sp,
                textAlign = TextAlign.Center
            )
            Spacer(Modifier.height(14.dp))
            // 3 rows x 4 groups, monospace.
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                listOf(0, 4, 8).forEach { row ->
                    Text(
                        info.safety.subList(row, row + 4).joinToString(" "),
                        color = s.text,
                        style = SonarType.mono(15.0),
                        modifier = Modifier.padding(vertical = 3.dp)
                    )
                }
            }
            Spacer(Modifier.height(18.dp))
            if (info.verified) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    SNIcon(SNIconName.ShieldCheck, 16.dp, s.green)
                    Spacer(Modifier.width(6.dp))
                    Text(
                        "Verified",
                        color = s.green,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.Bold
                    )
                }
            } else {
                SNPrimaryButton("They match — mark as verified") { onVerify() }
            }
        }
        Spacer(Modifier.height(8.dp))
        Box(
            Modifier.fillMaxWidth().height(44.dp).clickable(onClick = onDismiss),
            contentAlignment = Alignment.Center
        ) {
            Text(
                "Close",
                color = s.text2,
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold
            )
        }
    }
}
