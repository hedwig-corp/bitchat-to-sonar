package chat.bitchat.sonar

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
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
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.bitchat.sonar.ui.SNIcon
import chat.bitchat.sonar.ui.SNIconName
import chat.bitchat.sonar.ui.SonarAvatar
import chat.bitchat.sonar.ui.SonarType
import chat.bitchat.sonar.ui.bcHue
import chat.bitchat.sonar.ui.sonar
import kotlin.math.abs

/** m:ss timer label (design `fmtCall`). */
private fun fmtCall(sec: Int): String = "${sec / 60}:${(sec % 60).toString().padStart(2, '0')}"

// Always-dark call palette (design: .call is dark regardless of app theme).
private val CallText = Color(0xFFEFF3F4)
private val CallDanger = Color(0xFFF16A6A)
private val CallEncBg = Color(0x2941BC76)   // rgba(65,188,118,0.16)
private val CallEncFg = Color(0xFF84DCAA)
private val CallCtlBg = Color(0x1FFFFFFF)    // rgba(255,255,255,0.12)
private val CallCyan = Color(0xFF22D3EE)

/**
 * Full-screen voice call (design: call.jsx CallView + theme.css .call*).
 * State is driven by the real call engine via [SonarAppState.activeCall].
 */
@Composable
fun CallScreen(state: SonarAppState, screen: Screen.Call) {
    // Driven by the real call engine via state.activeCall (the controller pops
    // this screen when the call ends). Fall back to the route args if it's
    // momentarily null during teardown.
    val call = state.activeCall
    val video = call?.video ?: screen.video
    val name = call?.peerName ?: screen.name.ifBlank { "secure chat" }
    val incoming = call?.incoming == true
    val phase = call?.phase ?: SonarCallState.Ringing
    val secs = call?.connectedSecs ?: 0
    val muted = call?.muted == true
    val speakerOn = call?.speakerOn == true
    val connected = phase == SonarCallState.Connected
    val ringing = phase == SonarCallState.Ringing || phase == SonarCallState.Connecting
    // Transport line (Bluetooth in range / internet otherwise) — same as the DM.
    val chatId = call?.chatId ?: screen.peerId
    val isMeshRoute = chatId.startsWith("mesh:")
    val rawPeer = chatId.removePrefix("mesh:")
    val mesh = run { state.payVersion; isMeshRoute && state.dmInRange(rawPeer) }

    val camOn = call?.camOn ?: false

    val status = when {
        connected -> fmtCall(secs)
        phase == SonarCallState.Connecting -> "Connecting…"
        incoming -> if (video) "Incoming video call" else "Incoming call"
        else -> if (video) "Ringing…" else "Calling…"
    }
    val encLine = if (mesh) "Bluetooth" else "internet"

    Box(
        Modifier.fillMaxSize().background(
            if (video) Brush.verticalGradient(listOf(Color(0xFF05070A), Color(0xFF05070A)))
            else Brush.verticalGradient(listOf(Color(0xFF0B1418), Color(0xFF060809)))
        )
    ) {
        // VIDEO remote feed: drifting gradient when connected+camera on, else avatar.
        if (video) {
            if (connected && camOn) {
                CallFeed(hue = bcHue(name), Modifier.fillMaxSize())
            } else {
                Box(
                    Modifier.fillMaxSize().background(Brush.linearGradient(listOf(Color(0xFF11171C), Color(0xFF06080A)))),
                    contentAlignment = Alignment.Center
                ) { SonarAvatar(name, 120.dp) }
            }
            // vignette
            Box(
                Modifier.fillMaxSize().background(
                    Brush.verticalGradient(
                        0f to Color(0x73000000), 0.22f to Color.Transparent,
                        0.6f to Color.Transparent, 1f to Color(0x99000000)
                    )
                )
            )
        }

        Column(
            Modifier.fillMaxSize().statusBarsPadding(),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Spacer(Modifier.height(40.dp))
            // enc pill
            Row(
                Modifier.clip(CircleShape).background(CallEncBg).padding(horizontal = 14.dp, vertical = 7.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                SNIcon(SNIconName.Lock, 12.dp, CallEncFg, weight = 2.4f)
                Spacer(Modifier.width(7.dp))
                Text("End-to-end encrypted · $encLine", color = CallEncFg, fontSize = 12.5.sp, fontWeight = FontWeight.SemiBold)
            }
            if (video) {
                Spacer(Modifier.height(12.dp))
                Text(name, color = CallText, fontSize = 22.sp, fontWeight = FontWeight.Black, maxLines = 1)
                Text(status, color = Color(0xCCFFFFFF), style = SonarType.mono(14.0))
            }

            if (!video) {
                // VOICE: centered avatar (ring pulse while ringing) + name + status.
                Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        CallAvatar(name, ringing = ringing)
                        Spacer(Modifier.height(22.dp))
                        Text(name, color = CallText, fontSize = 30.sp, fontWeight = FontWeight.Black, maxLines = 1)
                        Spacer(Modifier.height(8.dp))
                        Text(status, color = Color(0xB3FFFFFF), style = SonarType.mono(16.0))
                    }
                }
            } else {
                Spacer(Modifier.weight(1f))
            }

            // controls row (58px round buttons + label)
            Row(
                Modifier.fillMaxWidth().padding(start = 18.dp, end = 18.dp, top = 22.dp, bottom = 46.dp),
                horizontalArrangement = Arrangement.spacedBy(14.dp, Alignment.CenterHorizontally),
                verticalAlignment = Alignment.Top
            ) {
                if (incoming && phase == SonarCallState.Ringing) {
                    // Incoming call: Decline (red) + Accept (green).
                    CallBtn(SNIconName.PhoneDown, "Decline", active = false, end = true) { state.declineCall() }
                    CallBtn(SNIconName.Phone, "Accept", active = false, accept = true) { state.acceptCall() }
                } else {
                    CallBtn(if (muted) SNIconName.MicOff else SNIconName.Mic, if (muted) "Unmute" else "Mute", active = muted) { state.toggleCallMute() }
                    if (video) {
                        CallBtn(if (camOn) SNIconName.Videocam else SNIconName.VideoOff, if (camOn) "Stop video" else "Start video", active = !camOn) { state.toggleCallCam() }
                        CallBtn(SNIconName.CameraFlip, "Flip", active = false) { /* flip camera — not yet wired */ }
                    } else {
                        CallBtn(SNIconName.Speaker, "Speaker", active = speakerOn) { state.toggleCallSpeaker() }
                        CallBtn(SNIconName.Videocam, "Video", active = false) { /* upgrade to video — not yet wired */ }
                    }
                    CallBtn(SNIconName.PhoneDown, "End", active = false, end = true) { state.hangupCall() }
                }
            }
        }

        // VIDEO PiP self-feed (bottom-right above the controls).
        if (video && connected && camOn) {
            Box(
                Modifier.align(Alignment.BottomEnd).padding(end = 16.dp, bottom = 168.dp)
                    .size(width = 104.dp, height = 150.dp).clip(RoundedCornerShape(18.dp))
            ) {
                CallFeed(hue = bcHue(state.nick.ifBlank { "you" }), Modifier.fillMaxSize())
                Text(
                    "you", color = Color(0xD9FFFFFF), fontSize = 11.sp, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.align(Alignment.BottomStart).padding(start = 8.dp, bottom = 7.dp)
                )
            }
        }
    }
}

/** One round control button (58dp) with a label below (design: .call-btn). */
@Composable
private fun CallBtn(icon: SNIconName, label: String, active: Boolean, end: Boolean = false, accept: Boolean = false, onClick: () -> Unit) {
    val green = Color(0xFF41BC76)
    val bg = when { accept -> green; end -> CallDanger; active -> Color.White; else -> CallCtlBg }
    val fg = when { accept || end -> Color.White; active -> Color(0xFF0B1418); else -> Color.White }
    Column(
        Modifier.width(64.dp).clickable(onClick = onClick),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Box(Modifier.size(58.dp).clip(CircleShape).background(bg), contentAlignment = Alignment.Center) {
            SNIcon(icon, 23.dp, fg, weight = 1.9f)
        }
        Spacer(Modifier.height(7.dp))
        Text(label, color = Color(0xD9FFFFFF), fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
    }
}

/** Avatar (132dp) with the cyan ring pulse while ringing (design: callRing). */
@Composable
private fun CallAvatar(name: String, ringing: Boolean) {
    Box(contentAlignment = Alignment.Center) {
        if (ringing) {
            val t = rememberInfiniteTransition(label = "ring")
            val p by t.animateFloat(
                0f, 1f, infiniteRepeatable(tween(1800, easing = LinearEasing)), label = "ring"
            )
            Box(
                Modifier.size(132.dp)
                    .graphicsLayer { val sc = 1f + p * 0.4f; scaleX = sc; scaleY = sc; alpha = (1f - p) * 0.55f }
                    .clip(CircleShape).background(CallCyan)
            )
        }
        SonarAvatar(name, 132.dp)
    }
}

/** Mocked "video feed": a slowly drifting hsl gradient keyed off [hue]
 *  (design: .call-feed / .call-pipfeed, the callDrift animation). */
@Composable
private fun CallFeed(hue: Float, modifier: Modifier = Modifier) {
    val t = rememberInfiniteTransition(label = "feed")
    val drift by t.animateFloat(
        0f, 1f, infiniteRepeatable(tween(9000, easing = LinearEasing), RepeatMode.Reverse), label = "drift"
    )
    val sc = 1.04f + 0.08f * drift
    Box(
        modifier.graphicsLayer { scaleX = sc; scaleY = sc; translationX = -drift * 6f; translationY = -drift * 6f }
            .background(
                Brush.linearGradient(
                    listOf(hslColor(hue, 0.34f, 0.30f), hslColor(hue + 40f, 0.32f, 0.24f), Color(0xFF06080A))
                )
            )
    )
}

/** Mocked in-chat call record (design: call.jsx CallLog + theme.css .call-log). */
@Composable
fun CallLogRow(rec: CallRecord) {
    val s = sonar
    val green = Color(0xFF41BC76)
    val label = when {
        rec.missed -> if (rec.video) "Missed video call" else "Missed call"
        else -> (if (rec.mine) "Outgoing " else "Incoming ") + (if (rec.video) "video call" else "call")
    }
    Box(Modifier.fillMaxWidth().padding(vertical = 5.dp), contentAlignment = Alignment.Center) {
        Row(
            Modifier.clip(RoundedCornerShape(14.dp)).background(s.surface2).padding(horizontal = 14.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(9.dp)
        ) {
            SNIcon(if (rec.video) SNIconName.Videocam else SNIconName.Phone, 15.dp, if (rec.missed) CallDanger else green, weight = 2f)
            Text(label, color = s.text, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            if (!rec.missed && rec.durSecs > 0) Text("· ${fmtCall(rec.durSecs)}", color = s.text2, fontSize = 13.sp)
            Text(SonarClock.hourMinute(rec.tsSecs), color = s.text3, fontSize = 11.5.sp)
        }
    }
}

/** HSL→Color (Compose has only HSV); for the mocked call gradients. */
private fun hslColor(hDeg: Float, s: Float, l: Float): Color {
    val h = ((hDeg % 360f) + 360f) % 360f
    val c = (1f - abs(2f * l - 1f)) * s
    val hp = h / 60f
    val x = c * (1f - abs(hp % 2f - 1f))
    val (r, g, b) = when {
        hp < 1f -> Triple(c, x, 0f)
        hp < 2f -> Triple(x, c, 0f)
        hp < 3f -> Triple(0f, c, x)
        hp < 4f -> Triple(0f, x, c)
        hp < 5f -> Triple(x, 0f, c)
        else -> Triple(c, 0f, x)
    }
    val m = l - c / 2f
    return Color(r + m, g + m, b + m)
}
