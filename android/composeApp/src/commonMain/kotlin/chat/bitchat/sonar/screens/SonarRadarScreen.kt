package chat.bitchat.sonar.screens

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.drawscope.rotate as drawRotate
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.bitchat.sonar.SonarAppState
import chat.bitchat.sonar.ui.SNDot
import chat.bitchat.sonar.ui.SNIcon
import chat.bitchat.sonar.ui.SNIconName
import chat.bitchat.sonar.ui.SNNavHeader
import chat.bitchat.sonar.ui.SonarAvatar
import chat.bitchat.sonar.ui.sonar
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

@Composable
fun SonarRadarScreen(state: SonarAppState) {
    val s = sonar
    var listMode by remember { mutableStateOf(false) }

    Column(Modifier.fillMaxSize().background(s.bg)) {
        // header (back + title + status)
        Row(
            Modifier.fillMaxWidth().padding(start = 6.dp, end = 16.dp, top = 10.dp, bottom = 6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            chat.bitchat.sonar.ui.SNIconButton(SNIconName.Back, onClick = { state.back() })
            Column {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Sonar", color = s.text, fontSize = 17.sp, fontWeight = FontWeight.Bold)
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    SNDot(s.green, 6.dp)
                    Spacer(Modifier.width(5.dp))
                    Text("0 in range · scanning", color = s.text2, fontSize = 12.sp)
                }
            }
        }

        // segmented control
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp)
                .clip(RoundedCornerShape(11.dp)).background(s.surface2).padding(3.dp)
        ) {
            SegButton("Radar", SNIconName.Rings, !listMode, Modifier.weight(1f)) { listMode = false }
            SegButton("List", SNIconName.People, listMode, Modifier.weight(1f)) { listMode = true }
        }

        if (listMode) {
            ListEmpty()
        } else {
            Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally) {
                Spacer(Modifier.weight(1f))
                RadarField(state.nick.ifBlank { "you" })
                Text(
                    "Looking for people around you…",
                    color = s.text3, fontSize = 12.5.sp, modifier = Modifier.padding(top = 4.dp)
                )
                Row(Modifier.padding(top = 12.dp), horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                    Legend(s.accent, "nearby · Bluetooth")
                    Legend(s.net, "far · internet")
                }
                Spacer(Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun SegButton(label: String, icon: SNIconName, selected: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val s = sonar
    Row(
        modifier.clip(RoundedCornerShape(8.5.dp))
            .background(if (selected) s.surface else Color.Transparent)
            .clickable(onClick = onClick).padding(vertical = 7.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically
    ) {
        SNIcon(icon, 15.dp, if (selected) s.text else s.text2, weight = 2f)
        Spacer(Modifier.width(6.dp))
        Text(label, color = if (selected) s.text else s.text2, fontSize = 13.5.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun Legend(color: Color, label: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        SNDot(color, 8.dp)
        Spacer(Modifier.width(6.dp))
        Text(label, color = sonar.text2, fontSize = 12.sp)
    }
}

@Composable
private fun ListEmpty() {
    val s = sonar
    Column(
        Modifier.fillMaxSize().padding(top = 80.dp, start = 24.dp, end = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        SNIcon(SNIconName.Rings, 26.dp, s.text3)
        Spacer(Modifier.height(10.dp))
        Text("Nobody in range yet", color = s.text2, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(4.dp))
        Text(
            "Keep Sonar open while you move around — people appear here as soon as Bluetooth finds them.",
            color = s.text3, fontSize = 13.sp, lineHeight = 18.sp
        )
    }
}

@Composable
private fun RadarField(nick: String) {
    val s = sonar
    val transition = rememberInfiniteTransition(label = "radar")
    val sweep by transition.animateFloat(
        0f, 360f, infiniteRepeatable(tween(4500, easing = LinearEasing), RepeatMode.Restart), label = "sweep"
    )
    val pulse by transition.animateFloat(
        0f, 1f, infiniteRepeatable(tween(2600, easing = LinearEasing), RepeatMode.Restart), label = "pulse"
    )

    Box(Modifier.size(348.dp), contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize()) {
            val c = size.minDimension / 2f
            val k = size.minDimension / 348f
            // solid rings
            for (r in listOf(66f, 112f, 158f)) {
                drawCircle(s.radarRing, radius = r * k, center = Offset(c, c), style = androidx.compose.ui.graphics.drawscope.Stroke(width = 1f))
            }
            // dotted rings
            for (r in listOf(40f, 88f, 134f, 170f)) {
                val n = ((2 * PI * r) / 17).toInt()
                for (i in 0 until n) {
                    val a = i.toDouble() / n * 2 * PI
                    drawCircle(
                        s.radarDot, radius = 1.2f * k,
                        center = Offset(c + (r * k * cos(a)).toFloat(), c + (r * k * sin(a)).toFloat())
                    )
                }
            }
            // sweep (rotating sweep gradient)
            drawRotate(sweep, pivot = Offset(c, c)) {
                drawCircle(
                    brush = Brush.sweepGradient(
                        0.0f to Color.Transparent,
                        0.79f to Color.Transparent,
                        0.92f to s.sweepSoft,
                        0.99f to s.sweep,
                        1.0f to Color.Transparent,
                        center = Offset(c, c)
                    ),
                    radius = c, center = Offset(c, c)
                )
            }
            // expanding pulses (two, offset by half)
            for (ph in listOf(pulse, (pulse + 0.5f) % 1f)) {
                val eased = 1f - (1f - ph) * (1f - ph)
                val scale = 0.7f + (2.4f - 0.7f) * eased
                drawCircle(
                    s.accent.copy(alpha = 0.55f * (1f - eased)),
                    radius = 35f * k * scale, center = Offset(c, c),
                    style = androidx.compose.ui.graphics.drawscope.Stroke(width = 2f)
                )
            }
        }
        // you, center
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            SonarAvatar(nick, 52.dp)
            Spacer(Modifier.height(4.dp))
            Box(Modifier.clip(RoundedCornerShape(8.dp)).background(s.bg).padding(horizontal = 7.dp, vertical = 1.dp)) {
                Text("you", color = s.text3, fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold)
            }
        }
    }
}
