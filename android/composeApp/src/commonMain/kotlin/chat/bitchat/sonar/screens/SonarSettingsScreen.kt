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
import androidx.compose.foundation.rememberScrollState
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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.bitchat.sonar.Screen
import chat.bitchat.sonar.SonarAppState
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
import chat.bitchat.sonar.ui.sonar

@Composable
fun SonarSettingsScreen(state: SonarAppState) {
    val s = sonar
    var wipeAsk by remember { mutableStateOf(false) }

    Column(Modifier.fillMaxSize().background(s.bg)) {
        SNNavHeader("Settings", hairline = false, onBack = { state.back() })
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            // profile card → Profile
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 8.dp)
                    .clip(RoundedCornerShape(20.dp)).background(s.surface)
                    .clickable { state.push(Screen.Profile) }
                    .padding(14.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                SonarAvatar(state.nick.ifBlank { "you" }, 56.dp)
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f)) {
                    Text(state.nick.ifBlank { "you" }, color = s.text, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                    Text(shortKey(state.npub), color = s.text3, fontSize = 12.sp)
                }
                SNIcon(SNIconName.Chevron, 15.dp, s.text3, weight = 2.2f)
            }

            SNSectionLabel("App")
            SNSettingsCard {
                SNSettingsRow(
                    icon = SNIconName.Moon, label = "Appearance",
                    value = if (state.dark) "Dark" else "Light",
                    trail = SNTrail.None, divider = false
                ) { state.toggleDark() }
            }

            SNSectionLabel("Network")
            SNSettingsCard {
                SNSettingsRow(
                    icon = SNIconName.Mesh, tone = SNTone.Cyan, label = "Connection",
                    sub = if (state.started) "Internet" else "Connecting…",
                    value = if (state.started) "Online" else "—",
                    trail = SNTrail.None, divider = false
                ) {}
            }

            SNSectionLabel("Privacy & safety")
            SNSettingsCard {
                SNSettingsRow(
                    icon = SNIconName.Trash, tone = SNTone.Red, label = "Emergency wipe",
                    sub = "Deletes your key, chats and nickname",
                    danger = true, trail = SNTrail.None, divider = false
                ) { wipeAsk = true }
            }

            SNSectionLabel("About")
            SNSettingsCard {
                SNSettingsRow(
                    icon = SNIconName.Info, label = "About Sonar",
                    sub = "Open protocols — Bluetooth mesh + Nostr",
                    trail = SNTrail.None, divider = false
                ) {}
            }
            Spacer(Modifier.height(40.dp))
        }
    }

    if (wipeAsk) {
        WipeSheet(onWipe = { wipeAsk = false; state.wipe() }, onClose = { wipeAsk = false })
    }
}

@Composable
private fun WipeSheet(onWipe: () -> Unit, onClose: () -> Unit) {
    val s = sonar
    Box(
        Modifier.fillMaxSize().background(s.scrim).clickable(onClick = onClose),
        contentAlignment = Alignment.BottomCenter
    ) {
        androidx.compose.material3.Surface(color = s.surface, shape = RoundedCornerShape(topStart = 22.dp, topEnd = 22.dp)) {
            Column(Modifier.fillMaxWidth().padding(20.dp)) {
                Text("Emergency wipe", color = s.text, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.height(6.dp))
                Text(
                    "This deletes your identity, all chats and your nickname from this phone. It can’t be undone.",
                    color = s.text2, fontSize = 13.5.sp, lineHeight = 18.sp
                )
                Spacer(Modifier.height(16.dp))
                SNPrimaryButton("Wipe everything", net = false) { onWipe() }
                Spacer(Modifier.height(8.dp))
                Box(Modifier.fillMaxWidth().height(44.dp).clickable(onClick = onClose), contentAlignment = Alignment.Center) {
                    Text("Cancel", color = s.text2, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
}

internal fun shortKey(npub: String?): String {
    val k = npub ?: return "connecting…"
    return if (k.length > 18) k.take(12) + "…" + k.takeLast(4) else k
}
