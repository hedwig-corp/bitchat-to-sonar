package chat.bitchat.sonar.screens

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.bitchat.sonar.SonarAppState
import chat.bitchat.sonar.ui.SNFingerprintCard
import chat.bitchat.sonar.ui.SNIcon
import chat.bitchat.sonar.ui.SNIconButton
import chat.bitchat.sonar.ui.SNIconName
import chat.bitchat.sonar.ui.SNPrimaryButton
import chat.bitchat.sonar.ui.SonarAvatar
import chat.bitchat.sonar.ui.sonar

private val SUGGESTIONS = listOf(
    "quietfox", "tram12", "lakeswim", "verdigris", "morningstatic", "papercrane", "northpine", "softsignal"
)

@Composable
fun SonarOnboardingScreen(state: SonarAppState) {
    val s = sonar
    var step by remember { mutableStateOf(0) }
    var nick by remember { mutableStateOf("") }
    val trimmed = nick.trim()
    val can = trimmed.length >= 2

    Column(
        Modifier.fillMaxSize().background(s.bg)
            .padding(start = 28.dp, end = 28.dp, top = 10.dp, bottom = 12.dp)
    ) {
        // Top bar (back)
        Box(Modifier.fillMaxWidth().height(40.dp)) {
            if (step > 0) {
                SNIconButton(SNIconName.Back, onClick = { step -= 1 })
            }
        }

        AnimatedContent(
            targetState = step,
            transitionSpec = { fadeIn() togetherWith fadeOut() },
            modifier = Modifier.weight(1f)
        ) { st ->
            when (st) {
                0 -> StepIntro()
                1 -> StepNickname(nick, trimmed) { nick = it.take(20) }
                else -> StepDone(trimmed, state.fingerprint())
            }
        }

        // Footer
        Column(Modifier.padding(top = 18.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                repeat(3) { i ->
                    Box(
                        Modifier.size(7.dp).clip(CircleShape)
                            .background(if (step == i) s.accent else s.hairline)
                    )
                }
            }
            Spacer(Modifier.height(16.dp))
            when (step) {
                0 -> SNPrimaryButton("Get started") { step = 1 }
                1 -> SNPrimaryButton("Continue", disabled = !can) { if (can) step = 2 }
                else -> SNPrimaryButton("Start chatting") { state.completeOnboarding(trimmed) }
            }
        }
    }
}

@Composable
private fun StepIntro() {
    val s = sonar
    Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center) {
        Box(
            Modifier.size(74.dp).clip(RoundedCornerShape(23.dp)).background(s.accentFill),
            contentAlignment = Alignment.Center
        ) { SNIcon(SNIconName.Rings, 40.dp, s.onAccent, weight = 1.5f) }
        Spacer(Modifier.height(28.dp))
        Text(
            "Sense who’s nearby before you see them.",
            color = s.text, fontSize = 30.sp, fontWeight = FontWeight.Black, lineHeight = 34.sp
        )
        Spacer(Modifier.height(10.dp))
        Text(
            "Sonar connects phones directly — no phone number, no account, no servers.",
            color = s.text2, fontSize = 16.sp, lineHeight = 21.sp
        )
        Spacer(Modifier.height(22.dp))
        FeatureRow(SNIconName.Mesh, "Works without internet", "Bluetooth finds people around you, even offline.")
        FeatureRow(SNIconName.Globe, "Out of range? Still reachable", "Messages travel encrypted over the open internet instead.")
        FeatureRow(SNIconName.Lock, "Private by design", "Direct messages are end-to-end encrypted. Always.")
    }
}

@Composable
private fun FeatureRow(icon: SNIconName, title: String, desc: String) {
    val s = sonar
    Row(Modifier.fillMaxWidth().padding(vertical = 11.dp)) {
        Box(
            Modifier.size(40.dp).clip(RoundedCornerShape(13.dp)).background(s.accentSoft),
            contentAlignment = Alignment.Center
        ) { SNIcon(icon, 20.dp, s.accentDeep) }
        Spacer(Modifier.width(14.dp))
        Column {
            Text(title, color = s.text, fontSize = 16.sp, fontWeight = FontWeight.Bold)
            Text(desc, color = s.text2, fontSize = 13.5.sp, lineHeight = 17.sp)
        }
    }
}

@Composable
private fun StepNickname(nick: String, trimmed: String, onChange: (String) -> Unit) {
    val s = sonar
    Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center) {
        Text("Pick a nickname", color = s.text, fontSize = 30.sp, fontWeight = FontWeight.Black)
        Spacer(Modifier.height(10.dp))
        Text("It’s just what people see — change it anytime.", color = s.text2, fontSize = 16.sp, lineHeight = 21.sp)
        Spacer(Modifier.height(22.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            SonarAvatar(trimmed.ifEmpty { "?" }, 72.dp)
            Spacer(Modifier.width(16.dp))
            Box(
                Modifier.weight(1f).clip(RoundedCornerShape(16.dp)).background(s.surface2)
                    .padding(horizontal = 16.dp, vertical = 15.dp)
            ) {
                if (nick.isEmpty()) Text("nickname", color = s.text3, fontSize = 21.sp, fontWeight = FontWeight.Medium)
                BasicTextField(
                    value = nick,
                    onValueChange = onChange,
                    singleLine = true,
                    textStyle = TextStyle(color = s.text, fontSize = 21.sp, fontWeight = FontWeight.Bold),
                    cursorBrush = SolidColor(s.accent),
                    modifier = Modifier.fillMaxWidth()
                )
            }
        }
        Spacer(Modifier.height(18.dp))
        Row(
            Modifier.clip(CircleShape).background(s.accentSoft).clickable {
                onChange(SUGGESTIONS[(nick.hashCode() and 0x7fffffff) % SUGGESTIONS.size])
            }.padding(horizontal = 14.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            SNIcon(SNIconName.Dice, 16.dp, s.accentDeep, weight = 2f)
            Spacer(Modifier.width(7.dp))
            Text("Surprise me", color = s.accentDeep, fontSize = 14.sp, fontWeight = FontWeight.Bold)
        }
        Spacer(Modifier.height(18.dp))
        Text(
            "No signup. Your identity is a private key created on this phone — nobody else ever sees it.",
            color = s.text3, fontSize = 13.sp, lineHeight = 17.sp
        )
    }
}

@Composable
private fun StepDone(nick: String, fingerprint: String) {
    val s = sonar
    Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center) {
        SonarAvatar(nick.ifEmpty { "?" }, 92.dp)
        Spacer(Modifier.height(22.dp))
        Text("You’re in, $nick.", color = s.text, fontSize = 30.sp, fontWeight = FontWeight.Black)
        Spacer(Modifier.height(10.dp))
        Text("No account was created anywhere — your identity lives on this phone.", color = s.text2, fontSize = 16.sp, lineHeight = 21.sp)
        Spacer(Modifier.height(24.dp))
        SNFingerprintCard("Your key fingerprint", fingerprint.ifEmpty { "generating…" })
        Spacer(Modifier.height(18.dp))
        Text("Friends can verify this fingerprint in person to be sure it’s really you.", color = s.text3, fontSize = 13.sp, lineHeight = 17.sp)
    }
}
