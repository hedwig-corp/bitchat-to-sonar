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
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.bitchat.sonar.SonarAppState
import chat.bitchat.sonar.ui.SNIcon
import chat.bitchat.sonar.ui.SNIconName
import chat.bitchat.sonar.ui.SNNavHeader
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
 * Profile — 1:1 reproduction of design/handoff/project/sonar/settings.jsx
 * ProfileScreen: pf-head (avatar, name + pencil, key pill), the "Your key"
 * KeyShareCard (QR + tap-to-expand key + Copy key / Share), the Safety
 * fingerprint row, and the nickname note. The Payments (BIP-353) card is a
 * platform addition with no design counterpart.
 */
@Composable
fun SonarProfileScreen(state: SonarAppState) {
    val s = sonar
    var editing by remember { mutableStateOf(false) }
    var draft by remember { mutableStateOf(state.nick) }
    var payDraft by remember { mutableStateOf(state.bip353) }
    val displayNick = state.nick.ifBlank { "you" }

    Column(Modifier.fillMaxSize().background(s.bg)) {
        SNNavHeader("Profile", hairline = false, onBack = { state.back() })
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            // pf-head
            Column(
                Modifier.fillMaxWidth().padding(top = 14.dp, start = 28.dp, end = 28.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                SonarAvatar(if (editing) draft.ifBlank { "you" } else displayNick, 96.dp)
                Spacer(Modifier.height(8.dp))
                if (editing) {
                    // pf-editrow: input + Save
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Box(
                            Modifier.weight(1f).clip(RoundedCornerShape(16.dp)).background(s.surface2)
                                .padding(horizontal = 14.dp, vertical = 11.dp)
                        ) {
                            if (draft.isEmpty()) Text("nickname", color = s.text3, fontSize = 18.sp)
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
                    // pf-name: 24/800 + 30dp pencil icon button
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
                // pf-key pill
                Box(Modifier.clip(RoundedCornerShape(999.dp)).background(s.surface2).padding(horizontal = 11.dp, vertical = 4.dp)) {
                    Text(shortKey(state.npub), color = s.text3, style = SonarType.mono(12.0))
                }
            }

            SNSectionLabel("Your key")
            // st-card wrapping the KeyShareCard
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
                "Your nickname is just what people see — your key never leaves this phone.",
                color = s.text3, fontSize = 12.sp, lineHeight = 18.sp,
                modifier = Modifier.padding(start = 24.dp, end = 24.dp, bottom = 4.dp),
            )

            // Platform addition (no design counterpart): BIP-353 payment address.
            SNSectionLabel("Payments")
            Column(
                Modifier.fillMaxWidth().padding(horizontal = 14.dp)
                    .clip(RoundedCornerShape(18.dp)).background(s.surface).padding(14.dp)
            ) {
                Text("Payment address (BIP-353)", color = s.text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(4.dp))
                Text(
                    "Shared with Sonar peers nearby so they can pay you. Optional.",
                    color = s.text3, fontSize = 12.5.sp, lineHeight = 16.sp
                )
                Spacer(Modifier.height(10.dp))
                Box(
                    Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(s.surface2)
                        .padding(horizontal = 12.dp, vertical = 11.dp)
                ) {
                    if (payDraft.isEmpty()) Text("you@example.com", color = s.text3, fontSize = 14.sp)
                    BasicTextField(
                        value = payDraft,
                        onValueChange = { payDraft = it; state.updateBip353(it) },
                        singleLine = true,
                        textStyle = TextStyle(color = s.text, fontSize = 14.sp),
                        cursorBrush = SolidColor(s.goldDeep),
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            }
            Spacer(Modifier.height(40.dp))
        }
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
