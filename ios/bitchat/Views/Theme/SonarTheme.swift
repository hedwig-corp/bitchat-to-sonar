//
// SonarTheme.swift
// bitchat
//
// Sonar design tokens, ported from design/handoff/project/sonar/theme.css
// ("quiet" base direction, default radius 18, default density).
// Light + dark palettes are exposed as dynamic Colors that follow the
// system appearance automatically.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// MARK: - Dynamic color support

extension Color {
    /// Creates a Color that resolves to `light` in light mode and `dark` in dark mode.
    init(light: Color, dark: Color) {
        #if os(iOS)
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #else
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? NSColor(dark) : NSColor(light)
        })
        #endif
    }

    /// Creates a Color from a 24-bit hex value (0xRRGGBB) with optional opacity.
    init(sonarHex hex: UInt32, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: opacity
        )
    }
}

// MARK: - Sonar design tokens

enum SonarTheme {
    // ── Surfaces ──
    static let bg = Color(light: Color(sonarHex: 0xF8FAFB), dark: Color(sonarHex: 0x060809))
    static let surface = Color(light: Color(sonarHex: 0xFFFFFF), dark: Color(sonarHex: 0x15191C))
    static let surface2 = Color(light: Color(sonarHex: 0xEAF0F2), dark: Color(sonarHex: 0x1F2529))

    // ── Text ──
    static let text = Color(light: Color(sonarHex: 0x14191B), dark: Color(sonarHex: 0xEFF3F4))
    static let text2 = Color(light: Color(sonarHex: 0x5B666B), dark: Color(sonarHex: 0x9AA6AB))
    static let text3 = Color(light: Color(sonarHex: 0x8C979C), dark: Color(sonarHex: 0x657177))

    // ── Lines & states ──
    static let hairline = Color(
        light: Color(sonarHex: 0x162C36, opacity: 0.13),
        dark: Color(sonarHex: 0xFFFFFF, opacity: 0.09)
    )
    static let press = Color(
        light: Color(sonarHex: 0x162C36, opacity: 0.06),
        dark: Color(sonarHex: 0xFFFFFF, opacity: 0.07)
    )

    // ── Accent (cyan · Bluetooth mesh transport) ──
    static let accent = Color(light: Color(sonarHex: 0x0891B2), dark: Color(sonarHex: 0x22D3EE))
    static let accentDeep = Color(light: Color(sonarHex: 0x0E7490), dark: Color(sonarHex: 0x67E2F4))
    static let accentFill = Color(light: Color(sonarHex: 0x0891B2), dark: Color(sonarHex: 0x1FC0DE))
    static let onAccent = Color(light: Color(sonarHex: 0xF5FDFF), dark: Color(sonarHex: 0x04222B))
    static let accentSoft = Color(
        light: Color(sonarHex: 0x0891B2, opacity: 0.12),
        dark: Color(sonarHex: 0x22D3EE, opacity: 0.15)
    )

    // ── Net (indigo · Nostr/internet transport) ──
    static let net = Color(light: Color(sonarHex: 0x5856D6), dark: Color(sonarHex: 0x7B79F7))
    static let netDeep = Color(light: Color(sonarHex: 0x4341B5), dark: Color(sonarHex: 0xA5A3FA))
    static let netFill = Color(light: Color(sonarHex: 0x5856D6), dark: Color(sonarHex: 0x5E5CE6))
    static let onNet = Color(light: Color(sonarHex: 0xF7F7FF), dark: Color(sonarHex: 0xF2F2FF))
    static let netSoft = Color(
        light: Color(sonarHex: 0x5856D6, opacity: 0.12),
        dark: Color(sonarHex: 0x7B79F7, opacity: 0.18)
    )

    // ── Status ──
    static let green = Color(light: Color(sonarHex: 0x2E9D5C), dark: Color(sonarHex: 0x41BC76))
    static let greenDeep = Color(light: Color(sonarHex: 0x1E7546), dark: Color(sonarHex: 0x84DCAA))
    static let greenSoft = Color(
        light: Color(sonarHex: 0x2E9D5C, opacity: 0.14),
        dark: Color(sonarHex: 0x41BC76, opacity: 0.17)
    )
    static let danger = Color(light: Color(sonarHex: 0xD43A3E), dark: Color(sonarHex: 0xF16A6A))

    // ── Gold (bitcoin payments) ──
    static let goldFill = Color(light: Color(sonarHex: 0xE0941C), dark: Color(sonarHex: 0xF0B03A))
    static let onGold = Color(light: Color(sonarHex: 0x241500), dark: Color(sonarHex: 0x241500))
    static let goldSoft = Color(
        light: Color(sonarHex: 0xE0941C, opacity: 0.14),
        dark: Color(sonarHex: 0xF0B03A, opacity: 0.16)
    )
    static let goldDeep = Color(light: Color(sonarHex: 0xA66A08), dark: Color(sonarHex: 0xF5C56B))

    // ── Bubbles ──
    static let bubbleOther = Color(light: Color(sonarHex: 0xFFFFFF), dark: Color(sonarHex: 0x1F2529))
    static let scrim = Color(
        light: Color(sonarHex: 0x08141A, opacity: 0.42),
        dark: Color(sonarHex: 0x000000, opacity: 0.6)
    )

    // ── Radar ──
    static let radarRing = Color(
        light: Color(sonarHex: 0x0891B2, opacity: 0.28),
        dark: Color(sonarHex: 0x22D3EE, opacity: 0.25)
    )
    static let radarDot = Color(
        light: Color(sonarHex: 0x162C36, opacity: 0.16),
        dark: Color(sonarHex: 0x8CD2E6, opacity: 0.16)
    )
    static let sweep = Color(
        light: Color(sonarHex: 0x0891B2, opacity: 0.30),
        dark: Color(sonarHex: 0x22D3EE, opacity: 0.30)
    )
    static let sweepSoft = Color(
        light: Color(sonarHex: 0x0891B2, opacity: 0.06),
        dark: Color(sonarHex: 0x22D3EE, opacity: 0.05)
    )

    // ── Radii & metrics (quiet · default density) ──
    static let bubbleRadius: CGFloat = 18
    static let cardRadius: CGFloat = 18
    static let rowVerticalPadding: CGFloat = 11

    // ── Typography (humanist sans for UI, mono only for technical bits) ──
    static func uiFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static func monoFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Transport

/// How a message travels (or would travel): BLE mesh vs Nostr/internet.
/// Drives the iMessage-style transport-colored bubbles and indicators.
enum SonarTransport {
    case mesh
    case internet

    /// Filled bubble background for own messages.
    var fill: Color {
        switch self {
        case .mesh: return SonarTheme.accentFill
        case .internet: return SonarTheme.netFill
        }
    }

    /// Foreground color on top of `fill`.
    var onFill: Color {
        switch self {
        case .mesh: return SonarTheme.onAccent
        case .internet: return SonarTheme.onNet
        }
    }

    /// Accent color used for small indicators.
    var tint: Color {
        switch self {
        case .mesh: return SonarTheme.accent
        case .internet: return SonarTheme.net
        }
    }

    var iconName: String {
        switch self {
        case .mesh: return "dot.radiowaves.left.and.right"
        case .internet: return "globe"
        }
    }

    /// Plain-language description of the transport.
    var label: String {
        switch self {
        case .mesh: return "Bluetooth"
        case .internet: return "internet"
        }
    }
}

// MARK: - Avatar

/// Deterministic identicon avatar: hue + mirrored pixel grid from a name hash,
/// matching the prototype's Avatar component.
struct SonarAvatar: View {
    let name: String
    var size: CGFloat = 44
    var presence: Bool = false
    /// Optional deterministic seed for the hue + identicon grid. Defaults to
    /// `name`; pass a stable per-peer id (e.g. a Unify peripheral id) so two
    /// peers that share a display name (both "Sonar user") still look distinct.
    var seed: String? = nil

    private static func hash(_ s: String) -> UInt32 {
        var h: UInt32 = 2166136261
        for scalar in s.unicodeScalars {
            h ^= scalar.value
            h = h &* 16777619
        }
        return h
    }

    var body: some View {
        let key = seed ?? name
        let h = Self.hash(key.isEmpty ? "?" : key)
        let hue = Double(h % 360)
        ZStack(alignment: .bottomTrailing) {
            Canvas { context, canvasSize in
                let unit = canvasSize.width / 66.0
                // Background: hsl(hue 40% 36%) — exact CSS values from components.jsx
                context.fill(
                    Path(CGRect(origin: .zero, size: canvasSize)),
                    with: .color(Color(snHue: hue, saturation: 0.40, lightness: 0.36))
                )
                let lite = Color(snHue: hue, saturation: 0.64, lightness: 0.70)
                let liter = Color(snHue: hue, saturation: 0.72, lightness: 0.82)
                var any = false
                for r in 0..<5 {
                    for c in 0..<3 {
                        if (h >> UInt32(r * 3 + c)) & 1 == 1 {
                            any = true
                            let fill = ((h >> UInt32(r + c + 4)) & 1 == 1) ? lite : liter
                            let rect = CGRect(
                                x: (8 + CGFloat(c) * 10) * unit,
                                y: (8 + CGFloat(r) * 10) * unit,
                                width: 10 * unit, height: 10 * unit
                            )
                            context.fill(Path(rect), with: .color(fill))
                            if c < 2 {
                                let mirror = CGRect(
                                    x: (8 + CGFloat(4 - c) * 10) * unit,
                                    y: (8 + CGFloat(r) * 10) * unit,
                                    width: 10 * unit, height: 10 * unit
                                )
                                context.fill(Path(mirror), with: .color(fill))
                            }
                        }
                    }
                }
                if !any {
                    let rect = CGRect(x: 28 * unit, y: 8 * unit, width: 10 * unit, height: 50 * unit)
                    context.fill(Path(rect), with: .color(lite))
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())

            if presence {
                // bc-presence: fixed 13px dot, 2.5px ring, offset -1/-1
                Circle()
                    .fill(SonarTheme.green)
                    .frame(width: 13, height: 13)
                    .overlay(Circle().stroke(SonarTheme.bg, lineWidth: 2.5))
                    .offset(x: 1, y: 1)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
