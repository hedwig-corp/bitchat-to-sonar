package chat.bitchat.sonar.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.abs

/** Deterministic hash used for author/avatar colors (mirrors iOS snHash). */
fun snHash(s: String): Int {
    var h = 0
    for (c in s) h = (h * 31 + c.code) and 0x7fffffff
    return h
}

/** hsl(hash%360, 45%, l) author/avatar color, like the iOS identicon palette. */
fun authorColor(name: String, dark: Boolean): Color {
    val hue = (snHash(name) % 360).toFloat()
    val l = if (dark) 0.70f else 0.36f
    return Color.hsl(hue, 0.45f, l)
}

@Composable
fun SonarAvatar(name: String, size: Dp, presence: Boolean? = null) {
    val s = sonar
    val seed = name.ifBlank { "?" }
    val hue = (snHash(seed) % 360).toFloat()
    val c1 = Color.hsl(hue, 0.52f, if (s.isDark) 0.55f else 0.5f)
    val c2 = Color.hsl((hue + 26f) % 360f, 0.5f, if (s.isDark) 0.42f else 0.62f)
    Box(contentAlignment = Alignment.Center) {
        Box(
            Modifier.size(size).clip(CircleShape)
                .background(Brush.linearGradient(listOf(c1, c2)))
        ) {
            Text(
                initials(seed),
                color = Color.White,
                fontSize = (size.value * 0.38f).sp,
                fontWeight = FontWeight.Bold,
                modifier = Modifier.align(Alignment.Center)
            )
        }
        if (presence != null) {
            Box(
                Modifier.align(Alignment.BottomEnd)
                    .size(size * 0.30f).clip(CircleShape).background(s.bg)
                    .padding(2.dp)
            ) {
                Box(
                    Modifier.size(size * 0.30f).clip(CircleShape)
                        .background(if (presence) s.green else s.text3)
                )
            }
        }
    }
}

private fun initials(s: String): String {
    val cleaned = s.trim()
    if (cleaned.isEmpty() || cleaned == "?") return "?"
    return cleaned.take(1).uppercase()
}

@Composable
fun SNPrimaryButton(
    label: String,
    modifier: Modifier = Modifier,
    disabled: Boolean = false,
    net: Boolean = false,
    onClick: () -> Unit,
) {
    val s = sonar
    val fill = if (net) s.netFill else s.accentFill
    val on = if (net) s.onNet else s.onAccent
    Box(
        modifier
            .fillMaxWidth()
            .height(52.dp)
            .clip(RoundedCornerShape(15.dp))
            .background(if (disabled) s.surface2 else fill)
            .clickable(enabled = !disabled, onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Text(
            label,
            color = if (disabled) s.text3 else on,
            fontSize = 16.5.sp,
            fontWeight = FontWeight.Bold
        )
    }
}

@Composable
fun SNGhostButton(label: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val s = sonar
    Box(
        modifier.fillMaxWidth().height(48.dp).clip(RoundedCornerShape(14.dp))
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Text(label, color = s.text2, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
fun SNIconButton(
    icon: SNIconName,
    size: Dp = 21.dp,
    weight: Float = 2.1f,
    tint: Color? = null,
    onClick: () -> Unit,
) {
    val s = sonar
    Box(
        Modifier.size(38.dp).clip(CircleShape).clickable(onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        SNIcon(icon, size, tint ?: s.text2, weight)
    }
}

@Composable
fun SNFingerprintCard(label: String, value: String) {
    val s = sonar
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(s.surface2)
            .padding(horizontal = 16.dp, vertical = 13.dp)
    ) {
        Text(
            label.uppercase(),
            color = s.text3, fontSize = 12.sp, fontWeight = FontWeight.Bold,
            letterSpacing = 0.6.sp
        )
        Box(Modifier.height(4.dp))
        Text(
            value, color = s.text,
            style = SonarType.mono(15.0),
            letterSpacing = 1.2.sp
        )
    }
}

/** Section label (bc-sect): uppercase, tracked, text3. */
@Composable
fun SNSectionLabel(text: String) {
    Text(
        text.uppercase(),
        color = sonar.text3,
        fontSize = 12.5.sp,
        fontWeight = FontWeight.Bold,
        letterSpacing = 0.75.sp,
        modifier = Modifier.padding(start = 18.dp, end = 18.dp, top = 16.dp, bottom = 7.dp)
    )
}

/** A small colored status dot. */
@Composable
fun SNDot(color: Color, size: Dp = 7.dp) {
    Box(Modifier.size(size).clip(CircleShape).background(color))
}
