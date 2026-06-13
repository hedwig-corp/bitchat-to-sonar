package chat.bitchat.sonar.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/**
 * Sonar design tokens — a 1:1 port of design/handoff/project/sonar/theme.css
 * and the iOS bitchat/Views/Theme/SonarTheme.swift. Cyan = BLE/local, indigo =
 * Nostr/internet, gold = money. Light + dark, provided dynamically via
 * [LocalSonar] so the whole UI flips with the appearance toggle (as on iOS).
 */
data class SonarPalette(
    val isDark: Boolean,
    val bg: Color,
    val surface: Color,
    val surface2: Color,
    val text: Color,
    val text2: Color,
    val text3: Color,
    val hairline: Color,
    val press: Color,
    val accent: Color,
    val accentDeep: Color,
    val accentFill: Color,
    val onAccent: Color,
    val accentSoft: Color,
    val net: Color,
    val netDeep: Color,
    val netFill: Color,
    val onNet: Color,
    val netSoft: Color,
    val green: Color,
    val greenDeep: Color,
    val greenSoft: Color,
    val danger: Color,
    val bubbleOther: Color,
    val scrim: Color,
    val radarRing: Color,
    val radarDot: Color,
    val sweep: Color,
    val sweepSoft: Color,
    val goldFill: Color,
    val onGold: Color,
    val goldSoft: Color,
    val goldDeep: Color,
)

val SonarLight = SonarPalette(
    isDark = false,
    bg = Color(0xFFF8FAFB),
    surface = Color(0xFFFFFFFF),
    surface2 = Color(0xFFEAF0F2),
    text = Color(0xFF14191B),
    text2 = Color(0xFF5B666B),
    text3 = Color(0xFF8C979C),
    hairline = Color(0x21162C36),
    press = Color(0x0F162C36),
    accent = Color(0xFF0891B2),
    accentDeep = Color(0xFF0E7490),
    accentFill = Color(0xFF0891B2),
    onAccent = Color(0xFFF5FDFF),
    accentSoft = Color(0x1F0891B2),
    net = Color(0xFF5856D6),
    netDeep = Color(0xFF4341B5),
    netFill = Color(0xFF5856D6),
    onNet = Color(0xFFF7F7FF),
    netSoft = Color(0x1F5856D6),
    green = Color(0xFF2E9D5C),
    greenDeep = Color(0xFF1E7546),
    greenSoft = Color(0x242E9D5C),
    danger = Color(0xFFD43A3E),
    bubbleOther = Color(0xFFFFFFFF),
    scrim = Color(0x6B08141A),
    radarRing = Color(0x470891B2),
    radarDot = Color(0x29162C36),
    sweep = Color(0x4D0891B2),
    sweepSoft = Color(0x0F0891B2),
    goldFill = Color(0xFFE0941C),
    onGold = Color(0xFF241500),
    goldSoft = Color(0x24E0941C),
    goldDeep = Color(0xFFA66A08),
)

val SonarDark = SonarPalette(
    isDark = true,
    bg = Color(0xFF060809),
    surface = Color(0xFF15191C),
    surface2 = Color(0xFF1F2529),
    text = Color(0xFFEFF3F4),
    text2 = Color(0xFF9AA6AB),
    text3 = Color(0xFF657177),
    hairline = Color(0x17FFFFFF),
    press = Color(0x12FFFFFF),
    accent = Color(0xFF22D3EE),
    accentDeep = Color(0xFF67E2F4),
    accentFill = Color(0xFF1FC0DE),
    onAccent = Color(0xFF04222B),
    accentSoft = Color(0x2622D3EE),
    net = Color(0xFF7B79F7),
    netDeep = Color(0xFFA5A3FA),
    netFill = Color(0xFF5E5CE6),
    onNet = Color(0xFFF2F2FF),
    netSoft = Color(0x2E7B79F7),
    green = Color(0xFF41BC76),
    greenDeep = Color(0xFF84DCAA),
    greenSoft = Color(0x2B41BC76),
    danger = Color(0xFFF16A6A),
    bubbleOther = Color(0xFF1F2529),
    scrim = Color(0x99000000),
    radarRing = Color(0x4022D3EE),
    radarDot = Color(0x298CD2E6),
    sweep = Color(0x4D22D3EE),
    sweepSoft = Color(0x0D22D3EE),
    goldFill = Color(0xFFF0B03A),
    onGold = Color(0xFF241500),
    goldSoft = Color(0x29F0B03A),
    goldDeep = Color(0xFFF5C56B),
)

val LocalSonar = staticCompositionLocalOf { SonarDark }

/** Convenience accessor used across the Sonar UI. */
val sonar: SonarPalette
    @Composable get() = LocalSonar.current

object SonarType {
    fun ui(size: Double, weight: FontWeight = FontWeight.Normal) =
        TextStyle(fontSize = size.sp, fontWeight = weight)

    fun mono(size: Double, weight: FontWeight = FontWeight.Normal) =
        TextStyle(fontSize = size.sp, fontWeight = weight, fontFamily = FontFamily.Monospace)
}

const val SonarBubbleRadius = 18

@Composable
fun SonarTheme(dark: Boolean = true, content: @Composable () -> Unit) {
    val palette = if (dark) SonarDark else SonarLight
    val scheme = if (dark) {
        darkColorScheme(
            primary = palette.accent, onPrimary = palette.onAccent,
            background = palette.bg, onBackground = palette.text,
            surface = palette.surface, onSurface = palette.text, error = palette.danger,
        )
    } else {
        lightColorScheme(
            primary = palette.accent, onPrimary = palette.onAccent,
            background = palette.bg, onBackground = palette.text,
            surface = palette.surface, onSurface = palette.text, error = palette.danger,
        )
    }
    CompositionLocalProvider(LocalSonar provides palette) {
        MaterialTheme(colorScheme = scheme, content = content)
    }
}
