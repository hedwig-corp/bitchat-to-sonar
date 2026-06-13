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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
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
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.bitchat.sonar.SonarAppState
import chat.bitchat.sonar.ui.SNIcon
import chat.bitchat.sonar.ui.SNIconButton
import chat.bitchat.sonar.ui.SNIconName
import chat.bitchat.sonar.ui.SNNavHeader
import chat.bitchat.sonar.ui.SNSectionLabel
import chat.bitchat.sonar.ui.SNSettingsCard
import chat.bitchat.sonar.ui.SNSettingsRow
import chat.bitchat.sonar.ui.SNShareCode
import chat.bitchat.sonar.ui.SNTone
import chat.bitchat.sonar.ui.SNTrail
import chat.bitchat.sonar.ui.SonarAvatar
import chat.bitchat.sonar.ui.SonarType
import chat.bitchat.sonar.ui.sonar

@Composable
fun SonarProfileScreen(state: SonarAppState) {
    val s = sonar
    var editing by remember { mutableStateOf(false) }
    var draft by remember { mutableStateOf(state.nick) }
    var showKey by remember { mutableStateOf(false) }
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
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(
                            Modifier.widthIn(max = 200.dp).clip(RoundedCornerShape(16.dp)).background(s.surface2)
                                .padding(horizontal = 14.dp, vertical = 11.dp)
                        ) {
                            if (draft.isEmpty()) Text("nickname", color = s.text3, fontSize = 18.sp)
                            BasicTextField(
                                value = draft, onValueChange = { if (it.length <= 20) draft = it }, singleLine = true,
                                textStyle = TextStyle(color = s.text, fontSize = 18.sp, fontWeight = FontWeight.Bold),
                                cursorBrush = SolidColor(s.accent)
                            )
                        }
                        Spacer(Modifier.width(8.dp))
                        Box(
                            Modifier.clip(CircleShape).background(s.accentFill)
                                .clickable { if (draft.trim().length >= 2) state.updateNickname(draft.trim()); editing = false }
                                .padding(horizontal = 18.dp, vertical = 12.dp)
                        ) { Text("Save", color = s.onAccent, fontSize = 14.sp, fontWeight = FontWeight.Bold) }
                    }
                } else {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(displayNick, color = s.text, fontSize = 24.sp, fontWeight = FontWeight.Black)
                        SNIconButton(SNIconName.Pencil, size = 15.dp, weight = 2f) { draft = state.nick; editing = true }
                    }
                }
                Spacer(Modifier.height(6.dp))
                Box(Modifier.clip(CircleShape).background(s.surface2).padding(horizontal = 11.dp, vertical = 4.dp)) {
                    Text(shortKey(state.npub), color = s.text3, style = SonarType.mono(12.0))
                }
            }

            // share code card
            Column(
                Modifier.fillMaxWidth().padding(14.dp).clip(RoundedCornerShape(20.dp)).background(s.surface)
                    .padding(top = 20.dp, bottom = 16.dp, start = 18.dp, end = 18.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                SNShareCode(state.npub ?: state.fingerprint(), 164.dp)
                Spacer(Modifier.height(12.dp))
                Text(
                    "Show this code to someone nearby to start an encrypted chat.",
                    color = s.text2, fontSize = 12.5.sp, textAlign = TextAlign.Center, lineHeight = 16.sp,
                    modifier = Modifier.widthIn(max = 240.dp)
                )
            }

            SNSectionLabel("Keys")
            SNSettingsCard {
                SNSettingsRow(
                    icon = SNIconName.Key, tone = SNTone.Cyan, label = "Key fingerprint",
                    value = state.fingerprint().take(14) + "…", valueMono = true, trail = SNTrail.None
                ) {}
                SNSettingsRow(
                    icon = SNIconName.Lock, label = "Public key",
                    sub = if (showKey) null else "Tap to reveal", trail = SNTrail.None, divider = false
                ) { showKey = !showKey }
            }
            if (showKey) {
                Text(
                    state.npub ?: "npub not available yet — connecting…",
                    color = s.text3, style = SonarType.mono(11.0), lineHeight = 18.sp,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 10.dp)
                )
            }
            Spacer(Modifier.height(40.dp))
        }
    }
}
