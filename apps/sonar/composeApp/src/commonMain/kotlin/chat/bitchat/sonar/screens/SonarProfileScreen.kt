package chat.bitchat.sonar.screens

import androidx.compose.foundation.Canvas
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.bitchat.sonar.HandleClaimState
import chat.bitchat.sonar.SonarAppState
import chat.bitchat.sonar.SonarCore
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
import kotlinx.coroutines.delay

/**
 * Profile — Name edit, key share, Safety, Username claim, and Payment address.
 * Username / payment are platform additions on top of settings.jsx ProfileScreen.
 */
@Composable
fun SonarProfileScreen(state: SonarAppState) {
    val s = sonar
    var editing by remember { mutableStateOf(false) }
    var draft by remember { mutableStateOf(state.nick) }
    var payDraft by remember { mutableStateOf(state.bip353) }
    val clipboard = LocalClipboardManager.current
    var paymentCopied by remember { mutableStateOf(false) }
    LaunchedEffect(paymentCopied) { if (paymentCopied) { delay(1700); paymentCopied = false } }
    val displayNick = state.nick.ifBlank { "you" }
    val paymentAddress = state.bip353.trim().takeIf { it.isNotEmpty() }

    Column(Modifier.fillMaxSize().background(s.bg)) {
        SNNavHeader("Profile", hairline = false, onBack = { state.back() })
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            // pf-head — Name
            Column(
                Modifier.fillMaxWidth().padding(top = 14.dp, start = 28.dp, end = 28.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                SonarAvatar(if (editing) draft.ifBlank { "you" } else displayNick, 96.dp)
                Spacer(Modifier.height(8.dp))
                if (editing) {
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Box(
                            Modifier.weight(1f).clip(RoundedCornerShape(16.dp)).background(s.surface2)
                                .padding(horizontal = 14.dp, vertical = 11.dp)
                        ) {
                            if (draft.isEmpty()) Text("Name", color = s.text3, fontSize = 18.sp)
                            BasicTextField(
                                value = draft, onValueChange = { if (it.length <= 20) draft = it }, singleLine = true,
                                textStyle = TextStyle(color = s.text, fontSize = 18.sp, fontWeight = FontWeight.Bold),
                                cursorBrush = SolidColor(s.accent),
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }
                        Spacer(Modifier.width(8.dp))
                        Box(
                            Modifier.clip(RoundedCornerShape(999.dp)).background(s.accentFill)
                                .clickable { if (draft.trim().length >= 2) state.updateNickname(draft.trim()); editing = false }
                                .padding(horizontal = 18.dp, vertical = 12.dp)
                        ) { Text("Save", color = s.onAccent, fontSize = 14.sp, fontWeight = FontWeight.Bold) }
                    }
                } else {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(displayNick, color = s.text, fontSize = 24.sp, fontWeight = FontWeight.Black)
                        Spacer(Modifier.width(6.dp))
                        Box(
                            Modifier.size(30.dp).clip(CircleShape)
                                .clickable { draft = state.nick; editing = true },
                            contentAlignment = Alignment.Center
                        ) { SNIcon(SNIconName.Pencil, 15.dp, s.text2, weight = 2f) }
                    }
                }
                Spacer(Modifier.height(8.dp))
                Box(Modifier.clip(RoundedCornerShape(999.dp)).background(s.surface2).padding(horizontal = 11.dp, vertical = 4.dp)) {
                    Text(profileCardSubtitle(state), color = s.text3, style = SonarType.mono(12.0))
                }
            }

            SNSectionLabel("Your key")
            Column(
                Modifier.fillMaxWidth().padding(horizontal = 14.dp)
                    .clip(RoundedCornerShape(18.dp)).background(s.surface)
                    .padding(start = 4.dp, end = 4.dp, top = 4.dp, bottom = 10.dp),
            ) {
                KeyShareCard(state)
            }

            SNSectionLabel("Safety")
            SNSettingsCard {
                SNSettingsRow(
                    icon = SNIconName.Key, tone = SNTone.Cyan, label = "Fingerprint",
                    sub = "Read this aloud to verify in person",
                    value = fingerprintGroups(state.fingerprint()), valueMono = true,
                    trail = SNTrail.None, divider = false,
                ) {}
            }
            Text(
                "Your name is just what people see — your key never leaves this phone.",
                color = s.text3, fontSize = 12.sp, lineHeight = 18.sp,
                modifier = Modifier.padding(start = 24.dp, end = 24.dp, bottom = 4.dp),
            )

            SNSectionLabel("Username")
            UsernameCard(state, payDraft, onDraftChange = { payDraft = it })
            Text(
                "Your username is how people find you and pay you — it's published with your profile and shared with your Sonar announce.",
                color = s.text3, fontSize = 12.sp, lineHeight = 18.sp,
                modifier = Modifier.padding(start = 24.dp, end = 24.dp, top = 4.dp, bottom = 4.dp),
            )

            if (paymentAddress != null) {
                SNSectionLabel("Payment address")
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 14.dp)
                        .clip(RoundedCornerShape(18.dp)).background(s.surface)
                        .clickable {
                            clipboard.setText(AnnotatedString(paymentAddress))
                            paymentCopied = true
                        }
                        .padding(horizontal = 14.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Box(
                        Modifier.size(38.dp).clip(RoundedCornerShape(12.dp)).background(s.goldSoft),
                        contentAlignment = Alignment.Center
                    ) { SNIcon(SNIconName.Coin, 17.dp, s.goldDeep) }
                    Spacer(Modifier.width(12.dp))
                    Text(
                        paymentAddress,
                        color = s.text,
                        style = SonarType.mono(13.0),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f)
                    )
                    Text(
                        if (paymentCopied) "Copied" else "Copy",
                        color = if (paymentCopied) s.green else s.accent,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Bold
                    )
                }
            }
            Spacer(Modifier.height(40.dp))
        }
    }
}

/**
 * Username claim card. Three shapes:
 * - claimed: address with seal + Edit
 * - editing: name field, live `name@domain` preview, Claim button
 * - external: pasted `name@other` saved as payment address only
 */
@Composable
private fun UsernameCard(
    state: SonarAppState,
    payDraft: String,
    onDraftChange: (String) -> Unit,
) {
    val s = sonar
    val claim = state.handleClaimState
    var editing by remember { mutableStateOf(false) }
    val claimed = state.bip353
    val showClaimed = claimed.isNotBlank() && !editing
    LaunchedEffect(claim) { if (claim is HandleClaimState.Claimed) editing = false }

    Column(
        Modifier.fillMaxWidth().padding(horizontal = 14.dp)
            .clip(RoundedCornerShape(18.dp)).background(s.surface).padding(14.dp)
    ) {
        Text(
            "Claim a username — friends can start a chat or pay you with it. Optional.",
            color = s.text3, fontSize = 12.5.sp, lineHeight = 16.sp
        )
        Spacer(Modifier.height(10.dp))
        if (showClaimed) {
            val isCoreClaimed = claimed == state.coreClaimedHandle
            Row(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(s.surface2)
                    .padding(horizontal = 12.dp, vertical = 11.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                if (isCoreClaimed) {
                    SNIcon(SNIconName.Check, 16.dp, s.accent, weight = 2f)
                } else {
                    SNIcon(SNIconName.Coin, 16.dp, s.text3, weight = 2f)
                }
                Spacer(Modifier.width(8.dp))
                Text(claimed, color = s.text, fontSize = 14.sp, modifier = Modifier.weight(1f))
                Text(
                    "Edit",
                    color = s.accent, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.clickable {
                        editing = true
                        state.resetHandleClaimState()
                        onDraftChange(claimed.substringBefore('@'))
                    }
                )
            }
        } else {
            val draft = payDraft.trim()
            val isExternal = '@' in draft && !draft.lowercase().endsWith("@${state.handleDomain}")
            Box(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(s.surface2)
                    .padding(horizontal = 12.dp, vertical = 11.dp)
            ) {
                if (payDraft.isEmpty()) Text("yourname", color = s.text3, fontSize = 14.sp)
                BasicTextField(
                    value = payDraft,
                    onValueChange = { onDraftChange(it); state.resetHandleClaimState() },
                    singleLine = true,
                    textStyle = TextStyle(color = s.text, fontSize = 14.sp),
                    cursorBrush = SolidColor(s.goldDeep),
                    modifier = Modifier.fillMaxWidth()
                )
            }
            Spacer(Modifier.height(8.dp))
            when {
                claim is HandleClaimState.Failed -> Text(
                    claim.message, color = s.danger, fontSize = 12.5.sp, lineHeight = 16.sp
                )
                draft.isNotEmpty() && !isExternal -> Text(
                    "${draft.lowercase().substringBefore('@')}@${state.handleDomain}",
                    color = s.text3, fontSize = 12.5.sp
                )
                isExternal -> Text(
                    "External address — saved as your payment address only.",
                    color = s.text3, fontSize = 12.5.sp, lineHeight = 16.sp
                )
            }
            Spacer(Modifier.height(10.dp))
            val claiming = claim is HandleClaimState.Claiming
            val valid = draft.isNotEmpty() && SonarCore.handleLooksValid(draft)
            SNPrimaryButton(
                label = when {
                    claiming -> "Claiming…"
                    isExternal -> "Save address"
                    else -> "Claim"
                },
                disabled = claiming || !valid,
                net = !isExternal,
            ) {
                if (isExternal) {
                    state.updateBip353(draft)
                    editing = false
                } else {
                    state.claimHandle(draft)
                }
            }
            if (editing && claimed.isNotBlank()) {
                Text(
                    "Cancel",
                    color = s.text2,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier
                        .padding(top = 8.dp)
                        .clickable(enabled = !claiming) {
                            editing = false
                            onDraftChange("")
                            state.resetHandleClaimState()
                        }
                )
            }
        }
    }
}

/** Settings/profile card subtitle: `@username` when claimed, else short npub. */
internal fun profileCardSubtitle(state: SonarAppState): String {
    val address = (state.coreClaimedHandle ?: state.bip353).trim()
    if (address.isEmpty()) return shortKey(state.npub)
    val parts = address.split("@", limit = 2)
    return if (parts.size == 2 && parts[1].equals(state.handleDomain, ignoreCase = true)) {
        "@${parts[0]}"
    } else {
        address
    }
}

/** 16-hex fingerprint → "a3f9 2c41 770e 5b2d" groups, like the design value. */
private fun fingerprintGroups(fp: String): String {
    val clean = fp.filterNot { it.isWhitespace() }.lowercase()
    if (clean.isEmpty()) return "n/a"
    return clean.take(16).chunked(4).joinToString(" ")
}

/**
 * settings.jsx KeyShareCard: QR-style share code on a white card, caption,
 * tap-to-expand key row, and Copy key / Share buttons.
 */
@Composable
private fun KeyShareCard(state: SonarAppState) {
    val s = sonar
    val clipboard = LocalClipboardManager.current
    var copied by remember { mutableStateOf(false) }
    var full by remember { mutableStateOf(false) }
    LaunchedEffect(copied) { if (copied) { delay(1700); copied = false } }
    val key = state.npub ?: state.fingerprint()
    val short = if (key.length > 28) key.take(18) + "…" + key.takeLast(8) else key
    val copy = {
        clipboard.setText(AnnotatedString(key))
        copied = true
    }

    Column(
        Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, top = 14.dp, bottom = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        // keyshare-qr: white card, 16dp padding, 20dp radius
        Box(
            Modifier.shadow(6.dp, RoundedCornerShape(20.dp))
                .clip(RoundedCornerShape(20.dp)).background(Color.White).padding(16.dp)
        ) {
            KeyShareCode(key, 184.dp)
        }
        // keyshare-caption
        Text(
            "Let someone scan this to add you — keys are exchanged directly, never through a server.",
            color = s.text2, fontSize = 12.5.sp, lineHeight = 18.sp, textAlign = TextAlign.Center,
            modifier = Modifier.widthIn(max = 260.dp).padding(top = 14.dp),
        )
        // keyshare-keyrow: tap to expand short ↔ full
        Box(
            Modifier.fillMaxWidth().padding(top = 12.dp)
                .clip(RoundedCornerShape(12.dp)).background(s.surface2)
                .clickable { full = !full }
                .padding(horizontal = 14.dp, vertical = 11.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                if (full) key else short,
                color = if (full) s.text else s.text2,
                style = SonarType.mono(if (full) 11.5 else 12.5),
                lineHeight = if (full) 18.sp else 14.sp,
                textAlign = TextAlign.Center,
            )
        }
        // keyshare-btns: Copy key (primary → green Copied) + Share
        Row(
            Modifier.fillMaxWidth().padding(top = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            KeyShareButton(
                label = if (copied) "Copied" else "Copy key",
                bg = if (copied) s.green else s.accentFill,
                fg = if (copied) Color.White else s.onAccent,
                icon = {
                    if (copied) SNIcon(SNIconName.Check, 17.dp, it, weight = 2.2f)
                    else SNXIcon(SNXIconName.Copy, 17.dp, it, weight = 2.2f)
                },
                modifier = Modifier.weight(1f),
            ) { copy() }
            KeyShareButton(
                label = "Share",
                bg = s.surface2,
                fg = s.text,
                icon = { SNXIcon(SNXIconName.Share, 17.dp, it, weight = 2f) },
                modifier = Modifier.weight(1f),
            ) {
                // No cross-platform share sheet in commonMain yet — the design's
                // own fallback when navigator.share is missing is copy().
                copy()
            }
        }
    }
}

/** keyshare-btn: 13dp radius, 12dp padding, icon + 14.5/700 label. */
@Composable
private fun KeyShareButton(
    label: String,
    bg: Color,
    fg: Color,
    icon: @Composable (Color) -> Unit,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    Row(
        modifier.clip(RoundedCornerShape(13.dp)).background(bg)
            .clickable(onClick = onClick).padding(vertical = 12.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        icon(fg)
        Spacer(Modifier.width(7.dp))
        Text(label, color = fg, fontSize = 14.5.sp, fontWeight = FontWeight.Bold)
    }
}

/** JS `bcHash` (FNV-1a 32-bit) from components.jsx, for the share-code rows. */
private fun bcHashJs(str: String): Long {
    var h = 2166136261L
    for (ch in str) {
        h = h xor ch.code.toLong()
        h = (h * 16777619L) and 0xFFFFFFFFL
    }
    return h
}

/**
 * settings.jsx ShareCode, drawn exactly: an 11×11 grid with three QR-style
 * finder corners, row fill bits from bcHash(seed + ':' + row), rounded
 * modules (#0B0E10 on the white keyshare-qr card).
 */
@Composable
private fun KeyShareCode(seed: String, size: Dp) {
    val n = 11
    val rows = remember(seed) { LongArray(n) { r -> bcHashJs("$seed:$r") } }
    Canvas(Modifier.size(size)) {
        val cs = this.size.minDimension / (n.toFloat())
        val inset = cs * (0.3f / 4f)          // 0.3 of a 4-unit cell
        val side = cs - inset * 2
        val rx = cs * (0.9f / 4f)
        val module = Color(0xFF0B0E10)
        for (r in 0 until n) {
            for (c in 0 until n) {
                val finder = (r < 3 && c < 3) || (r < 3 && c >= n - 3) || (r >= n - 3 && c < 3)
                val on = if (finder) {
                    val lr = if (r < 3) r else r - (n - 3)
                    val lc = if (c < 3) c else c - (n - 3)
                    !(lr == 1 && lc == 1)
                } else {
                    (rows[r] shr c) and 1L == 1L
                }
                if (on) {
                    drawRoundRect(
                        module,
                        topLeft = Offset(c * cs + inset, r * cs + inset),
                        size = Size(side, side),
                        cornerRadius = CornerRadius(rx, rx),
                    )
                }
            }
        }
    }
}
