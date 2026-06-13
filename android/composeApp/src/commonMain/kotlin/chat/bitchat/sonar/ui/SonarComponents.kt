package chat.bitchat.sonar.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.remember
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

/** bc-header with a back button + bold title (Settings/Profile/sub screens). */
@Composable
fun SNNavHeader(title: String, hairline: Boolean = true, onBack: () -> Unit) {
    val s = sonar
    Column {
        Row(
            Modifier.fillMaxWidth().padding(start = 6.dp, end = 12.dp, top = 10.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            SNIconButton(SNIconName.Back, onClick = onBack)
            Box(Modifier.width(2.dp))
            Text(title, color = s.text, fontSize = 17.sp, fontWeight = FontWeight.Bold)
        }
        if (hairline) Box(Modifier.fillMaxWidth().height(1.dp).background(s.hairline))
    }
}

enum class SNTone { Default, Cyan, Gold, Red }
enum class SNTrail { Chevron, None }

/** st-card — a rounded grouped card wrapping settings rows. */
@Composable
fun SNSettingsCard(content: @Composable () -> Unit) {
    val s = sonar
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 14.dp)
            .clip(RoundedCornerShape(18.dp)).background(s.surface)
    ) { content() }
}

/** st-row — icon tile + label/sub + value + trailing, with a hairline divider. */
@Composable
fun SNSettingsRow(
    icon: SNIconName,
    label: String,
    tone: SNTone = SNTone.Default,
    sub: String? = null,
    value: String? = null,
    valueMono: Boolean = false,
    trail: SNTrail = SNTrail.Chevron,
    danger: Boolean = false,
    divider: Boolean = true,
    onClick: () -> Unit = {},
) {
    val s = sonar
    val (tileBg, tileFg) = when (tone) {
        SNTone.Cyan -> s.accentSoft to s.accentDeep
        SNTone.Gold -> s.goldSoft to s.goldDeep
        SNTone.Red -> Color(s.danger.value).copy(alpha = 0.14f) to s.danger
        SNTone.Default -> s.surface2 to s.text2
    }
    Column {
        Row(
            Modifier.fillMaxWidth().clickable(onClick = onClick)
                .padding(horizontal = 14.dp, vertical = 11.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                Modifier.size(34.dp).clip(RoundedCornerShape(10.dp)).background(tileBg),
                contentAlignment = Alignment.Center
            ) { SNIcon(icon, 18.dp, tileFg) }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(label, color = if (danger) s.danger else s.text, fontSize = 16.sp, fontWeight = FontWeight.Medium)
                if (sub != null) Text(sub, color = s.text3, fontSize = 12.5.sp, lineHeight = 16.sp)
            }
            if (value != null) {
                if (valueMono) Text(value, color = s.text2, style = SonarType.mono(12.0))
                else Text(value, color = s.text2, fontSize = 14.sp)
                Spacer(Modifier.width(6.dp))
            }
            if (trail == SNTrail.Chevron) SNIcon(SNIconName.Chevron, 14.dp, s.text3, weight = 2.2f)
        }
        if (divider) Box(Modifier.fillMaxWidth().padding(start = 60.dp).height(1.dp).background(s.hairline))
    }
}

/**
 * Deterministic QR-style share code from a seed (npub/fingerprint) — mirrors
 * iOS SNShareCode: not a scannable QR, a stable identicon-grid the design uses.
 */
@Composable
fun SNShareCode(seed: String, size: Dp) {
    val s = sonar
    val n = 13
    val bits = remember(seed) {
        val h = snHash(seed)
        // Symmetric fill pattern from a simple LCG seeded by the hash.
        var state = (h.toLong() and 0xffffffffL) or 1L
        fun next(): Boolean { state = (state * 1103515245L + 12345L) and 0x7fffffffL; return (state shr 16) and 1L == 1L }
        Array(n) { r -> BooleanArray(n) { c -> if (c <= n / 2) next() else false } }.also { grid ->
            for (r in 0 until n) for (c in (n / 2 + 1) until n) grid[r][c] = grid[r][n - 1 - c]
        }
    }
    Box(
        Modifier.size(size).clip(RoundedCornerShape(16.dp)).background(s.surface2)
            .padding(14.dp)
    ) {
        androidx.compose.foundation.Canvas(Modifier.fillMaxSize()) {
            val cell = this.size.minDimension / n
            for (r in 0 until n) for (c in 0 until n) {
                val finder = isFinder(r, c, n)
                if (bits[r][c] || finder) {
                    drawRectCompat(
                        if (finder) s.accent else s.text,
                        c * cell, r * cell, cell * 0.86f
                    )
                }
            }
        }
    }
}

private fun isFinder(r: Int, c: Int, n: Int): Boolean {
    fun corner(rr: Int, cc: Int) = (rr in 0..2 && cc in 0..2)
    return corner(r, c) || corner(r, n - 1 - c) || corner(n - 1 - r, c)
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawRectCompat(
    color: Color, x: Float, y: Float, s: Float
) {
    drawRoundRect(
        color = color,
        topLeft = androidx.compose.ui.geometry.Offset(x, y),
        size = androidx.compose.ui.geometry.Size(s, s),
        cornerRadius = androidx.compose.ui.geometry.CornerRadius(s * 0.25f)
    )
}

