package chat.bitchat.sonar.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.offset
import androidx.compose.ui.geometry.Offset
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
fun SonarAvatar(name: String, size: Dp, presence: Boolean? = null, seed: String? = null) {
    val s = sonar
    val key = (seed ?: name).ifBlank { "?" }
    val h = avatarHash(key)
    val hue = (h % 360L).toFloat()
    // Identicon palette — exact CSS values from the prototype Avatar (components.jsx).
    val bg = Color.hsl(hue, 0.40f, 0.36f)
    val lite = Color.hsl(hue, 0.64f, 0.70f)
    val liter = Color.hsl(hue, 0.72f, 0.82f)
    Box(contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(size).clip(CircleShape)) {
            drawRect(bg)
            val unit = this.size.width / 66f
            var any = false
            for (r in 0 until 5) {
                for (c in 0 until 3) {
                    if ((h shr (r * 3 + c)) and 1L == 1L) {
                        any = true
                        val fill = if ((h shr (r + c + 4)) and 1L == 1L) lite else liter
                        fun cell(col: Int) = drawRect(
                            fill,
                            topLeft = Offset((8 + col * 10) * unit, (8 + r * 10) * unit),
                            size = androidx.compose.ui.geometry.Size(10 * unit, 10 * unit),
                        )
                        cell(c)
                        if (c < 2) cell(4 - c) // mirror to the right half
                    }
                }
            }
            if (!any) drawRect(
                lite,
                topLeft = Offset(28 * unit, 8 * unit),
                size = androidx.compose.ui.geometry.Size(10 * unit, 50 * unit),
            )
        }
        // bc-presence: green dot with a bg-colored ring, only when present.
        if (presence == true) {
            Box(
                Modifier.align(Alignment.BottomEnd).offset(x = 1.dp, y = 1.dp)
                    .size(size * 0.30f).clip(CircleShape).background(s.bg),
                contentAlignment = Alignment.Center
            ) {
                Box(Modifier.size(size * 0.30f - 4.dp).clip(CircleShape).background(s.green))
            }
        }
    }
}

/** FNV-1a 32-bit (matches the iOS SonarAvatar hash). */
private fun avatarHash(str: String): Long {
    var h = 2166136261L
    for (ch in str) { h = h xor ch.code.toLong(); h = (h * 16777619L) and 0xFFFFFFFFL }
    return h
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

enum class SNBannerTone { Enc, Net, Neutral, Public }

/** bc-banner: tinted strip with an icon + bold + rest text + optional action. */
@Composable
fun SNBanner(
    icon: SNIconName,
    tone: SNBannerTone,
    bold: String,
    rest: String,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
) {
    val s = sonar
    val (bg, fg) = when (tone) {
        SNBannerTone.Enc -> s.greenSoft to s.green
        SNBannerTone.Net -> s.netSoft to s.net
        SNBannerTone.Public -> s.accentSoft to s.accentDeep
        SNBannerTone.Neutral -> s.surface2 to s.text2
    }
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 6.dp)
            .clip(RoundedCornerShape(12.dp)).background(bg)
            .padding(horizontal = 12.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        SNIcon(icon, 15.dp, fg, weight = 2.2f)
        Spacer(Modifier.width(8.dp))
        Text(
            buildAnnotatedSimple(bold, rest),
            color = s.text2, fontSize = 13.sp, lineHeight = 17.sp,
            modifier = Modifier.weight(1f)
        )
        if (actionLabel != null && onAction != null) {
            Spacer(Modifier.width(8.dp))
            Box(
                Modifier.clip(RoundedCornerShape(9.dp)).background(s.surface)
                    .clickable(onClick = onAction).padding(horizontal = 12.dp, vertical = 6.dp)
            ) { Text(actionLabel, color = fg, fontSize = 12.5.sp, fontWeight = FontWeight.Bold) }
        }
    }
}

@Composable
private fun buildAnnotatedSimple(bold: String, rest: String) =
    androidx.compose.ui.text.buildAnnotatedString {
        pushStyle(androidx.compose.ui.text.SpanStyle(fontWeight = FontWeight.Bold, color = sonar.text))
        append(bold)
        pop()
        append(rest)
    }

/** An empty-state block: icon + title + description, centered. */
@Composable
fun SNEmptyState(icon: SNIconName, title: String, desc: String, iconSize: Dp = 24.dp) {
    val s = sonar
    Column(
        Modifier.fillMaxWidth().padding(top = 80.dp, start = 24.dp, end = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        SNIcon(icon, iconSize, s.text3)
        Spacer(Modifier.height(10.dp))
        Text(title, color = s.text2, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(4.dp))
        Text(desc, color = s.text3, fontSize = 13.sp, lineHeight = 18.sp, textAlign = TextAlign.Center)
    }
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
    toggle: Boolean? = null,
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
            when {
                toggle != null -> SNSwitch(toggle)
                trail == SNTrail.Chevron -> SNIcon(SNIconName.Chevron, 14.dp, s.text3, weight = 2.2f)
                else -> {}
            }
        }
        if (divider) Box(Modifier.fillMaxWidth().padding(start = 60.dp).height(1.dp).background(s.hairline))
    }
}

/** iOS-style toggle (st-switch): cyan track when on, neutral when off. */
@Composable
fun SNSwitch(on: Boolean) {
    val s = sonar
    Box(
        Modifier.size(width = 44.dp, height = 26.dp).clip(RoundedCornerShape(13.dp))
            .background(if (on) s.accentFill else s.surface2),
        contentAlignment = if (on) Alignment.CenterEnd else Alignment.CenterStart
    ) {
        Box(Modifier.padding(horizontal = 3.dp).size(20.dp).clip(RoundedCornerShape(10.dp)).background(Color.White))
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

