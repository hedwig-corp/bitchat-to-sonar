package chat.bitchat.sonar.ui

import androidx.compose.ui.graphics.Color

/**
 * Sonar design tokens (dark-first), ported from the iOS SwiftUI theme
 * (bitchat/Views/Theme/SonarTheme.swift → design/handoff theme.css). Cyan =
 * BLE/local, indigo = Nostr/internet, gold = money. This is the shared subset
 * the first Compose Multiplatform screens need; it grows toward 1:1.
 */
object SonarColors {
    // Dark surfaces
    val bg = Color(0xFF060809)
    val surface = Color(0xFF15191C)
    val surface2 = Color(0xFF1F2529)
    val hairline = Color(0x14FFFFFF)

    // Text
    val text = Color(0xFFEFF3F4)
    val text2 = Color(0xFF9AA6AB)
    val text3 = Color(0xFF657177)

    // Accent — BLE / cyan
    val accent = Color(0xFF22D3EE)
    val accentFill = Color(0xFF1FC0DE)
    val onAccent = Color(0xFF04222B)

    // Net — Nostr / indigo
    val net = Color(0xFF7B79F7)
    val netFill = Color(0xFF5E5CE6)
    val onNet = Color(0xFFFFFFFF)

    // Status
    val green = Color(0xFF41BC76)
    val danger = Color(0xFFF16A6A)
    val gold = Color(0xFFE2B33C)

    // Bubble (other party)
    val bubbleOther = surface2
}
