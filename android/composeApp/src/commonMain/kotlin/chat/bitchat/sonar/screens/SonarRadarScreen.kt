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
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
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

/** RSSI → 1..4 signal strength (BLE: ~-40 close, ~-95 far). */
internal fun rssiBars(rssi: Int): Int = when {
    rssi >= -55 -> 4
    rssi >= -70 -> 3
    rssi >= -85 -> 2
    else -> 1
}

internal fun rssiLabel(rssi: Int): String = when (rssiBars(rssi)) {
    4 -> "Very close"
    3 -> "Nearby"
    2 -> "In range"
    else -> "Far"
}

@Composable
fun SonarRadarScreen(state: SonarAppState) {
    val s = sonar
    var listMode by remember { mutableStateOf(false) }
    var card by remember { mutableStateOf<chat.bitchat.sonar.MeshPeer?>(null) }

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
                    Text("${state.meshPeers.size} in range · scanning", color = s.text2, fontSize = 12.sp)
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
            if (state.meshPeers.isEmpty()) ListEmpty()
            else LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(vertical = 8.dp)) {
                items(state.meshPeers, key = { it.id }) { p -> PeerRow(p) { card = p } }
            }
        } else {
            Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally) {
                Spacer(Modifier.weight(1f))
                RadarField(state.nick.ifBlank { "you" }, state.meshPeers)
                Text(
                    if (state.meshPeers.isEmpty()) "Looking for people around you…" else "Tap someone to chat",
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

    card?.let { PeerCard(it, onClose = { card = null }) }
}

@Composable
private fun PeerRow(p: chat.bitchat.sonar.MeshPeer, onClick: () -> Unit) {
    val s = sonar
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        SonarAvatar(p.name, 44.dp, presence = true)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(p.name, color = s.text, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            Row(verticalAlignment = Alignment.CenterVertically) {
                SNDot(s.accent, 6.dp)
                Spacer(Modifier.width(5.dp))
                Text("Bluetooth · ${rssiLabel(p.rssi)}", color = s.text3, fontSize = 12.5.sp)
            }
        }
        SignalBars(rssiBars(p.rssi), s.accent)
    }
}

/** 4 stepped bars, [filled] of them in [color], the rest faint. */
@Composable
private fun SignalBars(filled: Int, color: Color) {
    val s = sonar
    Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        for (i in 1..4) {
            Box(
                Modifier.width(3.dp).height((4 + i * 3).dp).clip(RoundedCornerShape(1.dp))
                    .background(if (i <= filled) color else s.surface2)
            )
        }
    }
}

@Composable
private fun PeerCard(p: chat.bitchat.sonar.MeshPeer, onClose: () -> Unit) {
    val s = sonar
    Box(
        Modifier.fillMaxSize().background(s.scrim).clickable(onClick = onClose),
        contentAlignment = Alignment.BottomCenter
    ) {
        androidx.compose.material3.Surface(color = s.surface, shape = RoundedCornerShape(topStart = 22.dp, topEnd = 22.dp)) {
            Column(Modifier.fillMaxWidth().padding(20.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                SonarAvatar(p.name, 64.dp, presence = true)
                Spacer(Modifier.height(10.dp))
                Text(p.name, color = s.text, fontSize = 19.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.height(4.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    SignalBars(rssiBars(p.rssi), s.accent)
                    Spacer(Modifier.width(8.dp))
                    Text("Bluetooth · ${rssiLabel(p.rssi)}", color = s.text2, fontSize = 13.sp)
                }
                Spacer(Modifier.height(18.dp))
                // Mesh DM goes live with the BLE link (Phase 8); honest until then.
                Box(
                    Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(s.surface2)
                        .padding(vertical = 13.dp),
                    contentAlignment = Alignment.Center
                ) { Text("Reachable over Bluetooth mesh", color = s.text2, fontSize = 14.sp, fontWeight = FontWeight.SemiBold) }
                Spacer(Modifier.height(8.dp))
                Box(Modifier.fillMaxWidth().height(44.dp).clickable(onClick = onClose), contentAlignment = Alignment.Center) {
                    Text("Close", color = s.text2, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                }
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
private fun RadarField(nick: String, peers: List<chat.bitchat.sonar.MeshPeer>) {
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
        // mesh peer nodes, placed on the inner ring by a deterministic angle
        peers.forEachIndexed { i, p ->
            val ang = (chat.bitchat.sonar.ui.snHash(p.id) % 360).toDouble() * PI / 180.0
            val radius = 84f + (i % 2) * 34f
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier.align(Alignment.Center).offset(
                    x = (radius * cos(ang)).dp, y = (radius * sin(ang)).dp
                )
            ) {
                SonarAvatar(p.name, 40.dp, presence = true)
                Spacer(Modifier.height(3.dp))
                Box(Modifier.clip(RoundedCornerShape(8.dp)).background(s.bg).padding(horizontal = 6.dp, vertical = 1.dp)) {
                    Text(p.name, color = s.text2, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
                }
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
