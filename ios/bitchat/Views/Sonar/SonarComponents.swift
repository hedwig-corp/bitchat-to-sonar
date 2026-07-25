//
// SonarComponents.swift
// bitchat
//
// Shared building blocks for the Sonar prototype reproduction, ported from
// design/handoff/project/sonar/components.jsx + theme.css (quiet direction,
// pill status chip, filled bubbles, radius 18, regular density).
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Combine
import ImageIO
import SwiftUI
import TranscriptEngine
import WebKit
import QuickLook
import SonarCore
#if SONAR_KEYBOARD_BENCH
import os.log
#endif
#if canImport(BitLogger)
import BitLogger
#endif
#if os(iOS)
import UIKit
import AVFoundation
import Photos
#else
import AppKit
import AVFoundation
#endif

// MARK: - bcHash (FNV-1a, identical to components.jsx)

func snHash(_ s: String) -> UInt32 {
    var h: UInt32 = 2166136261
    for scalar in s.unicodeScalars {
        h ^= scalar.value
        h = h &* 16777619
    }
    return h
}

// MARK: - CSS hsl() → SwiftUI Color (exact HSL→HSB conversion)

extension Color {
    /// CSS `hsl(hue, saturation%, lightness%)`.
    init(snHue hue: Double, saturation: Double, lightness: Double) {
        let brightness = lightness + saturation * min(lightness, 1 - lightness)
        let hsbSaturation = brightness == 0 ? 0 : 2 * (1 - lightness / brightness)
        self.init(hue: hue / 360, saturation: hsbSaturation, brightness: brightness)
    }
}

extension SonarTheme {
    /// Author name color in the channel transcript:
    /// hsl(hash(author)%360, 45%, 36%) light · hsl(…, 45%, 70%) dark.
    static func authorColor(_ author: String) -> Color {
        let hue = Double(snHash(author) % 360)
        return Color(
            light: Color(snHue: hue, saturation: 0.45, lightness: 0.36),
            dark: Color(snHue: hue, saturation: 0.45, lightness: 0.70)
        )
    }
}

// MARK: - Button styles (CSS :active feedback)

/// Scales down while pressed (e.g. chips, FABs, primary buttons).
struct SNScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Row-style press highlight (background turns var(--press)).
struct SNRowPressStyle: ButtonStyle {
    var cornerRadius: CGFloat = 0

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(configuration.isPressed ? SonarTheme.press : Color.clear)
            )
    }
}

/// 38×38 circular icon button (bc-iconbtn): press = background + scale 0.94.
struct SNIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Circle().fill(configuration.isPressed ? SonarTheme.press : Color.clear))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct SNIconButton: View {
    var size: CGFloat = 38
    let action: () -> Void
    private let label: AnyView

    init<Content: View>(size: CGFloat = 38, action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.size = size
        self.action = action
        self.label = AnyView(content())
    }

    var body: some View {
        Button(action: action) {
            label
                .foregroundColor(SonarTheme.text2)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(SNIconButtonStyle())
    }
}

// MARK: - PlaceTile

struct SNPlaceTile: View {
    var size: CGFloat = 44
    var icon: SNIconName = .pin

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.31, style: .continuous)
            .fill(SonarTheme.accentSoft)
            .frame(width: size, height: size)
            .overlay(
                SNIcon(name: icon, size: (size * 0.46).rounded())
                    .foregroundColor(SonarTheme.accentDeep)
            )
    }
}

// MARK: - Status chip (pill variant — tap shows the real connectivity sheet)

struct SNStatusChip: View {
    let online: Bool
    let meshCount: Int
    var syncing: Bool = false
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var subtitle: String {
        guard online else { return "\(meshCount) nearby on Bluetooth" }
        return syncing ? "Catching up…" : "reaches anyone"
    }

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Button(action: onTap) {
                HStack(spacing: 8) {
                    dot
                    (
                        Text(online ? "Online" : "Offline")
                            .fontWeight(.bold)
                            .foregroundColor(SonarTheme.text)
                        + Text(verbatim: " · \(subtitle)")
                    )
                    .font(SonarTheme.uiFont(size: 13))
                    .foregroundColor(SonarTheme.text2)
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 14)
                .background(
                    Capsule()
                        .fill(SonarTheme.surface)
                        .shadow(color: Color(sonarHex: 0x061820, opacity: 0.07), radius: 1.5, y: 1)
                )
                .overlay(Capsule().strokeBorder(SonarTheme.hairline, lineWidth: 1))
            }
            .buttonStyle(SNScaleStyle(scale: 0.96))
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 4, leading: 16, bottom: 10, trailing: 16))
    }

    private var dot: some View {
        Circle()
            .fill(online ? SonarTheme.green : SonarTheme.accent)
            .frame(width: 9, height: 9)
            .background {
                // bcPulse: soft cyan halo breathing out to a 5px spread while
                // offline (2.2 s cycle). TimelineView avoids leaking animation
                // transactions into navigation transitions.
                if !online && !reduceMotion {
                    TimelineView(.animation) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        let phase = t.truncatingRemainder(dividingBy: 2.2) / 2.2
                        let spread = 5 * sin(.pi * phase)
                        Circle()
                            .fill(SonarTheme.accentSoft)
                            .frame(width: 9 + 2 * spread, height: 9 + 2 * spread)
                    }
                }
            }
    }
}

// MARK: - Section label

struct SNSectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(verbatim: text.uppercased())
            .font(SonarTheme.uiFont(size: 12.5, weight: .bold))
            .kerning(12.5 * 0.06)
            .foregroundColor(SonarTheme.text3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 16, leading: 18, bottom: 7, trailing: 18))
    }
}

// MARK: - Transcript day chip (Signal / Compose bc-datechip)

/// Centered day marker in the transcript (bc-datechip).
struct SNDateChip: View {
    let label: String

    var body: some View {
        Text(verbatim: label)
            .font(SonarTheme.uiFont(size: 11.5, weight: .semibold))
            .foregroundColor(SonarTheme.text3)
            .frame(maxWidth: .infinity)
            .padding(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10))
    }
}

// MARK: - Conversation / list row (bc-row)

struct SNConvRow<Avatar: View, Sub: View>: View {
    let avatar: Avatar
    let title: String
    var verified: Bool = false
    let sub: Sub
    var time: String = ""
    var unread: Bool = false
    /// Muted chat: a bell-slash replaces the unread dot.
    var muted: Bool = false
    var divider: Bool = true
    let action: () -> Void

    init(
        title: String,
        verified: Bool = false,
        time: String = "",
        unread: Bool = false,
        muted: Bool = false,
        divider: Bool = true,
        action: @escaping () -> Void,
        @ViewBuilder avatar: () -> Avatar,
        @ViewBuilder sub: () -> Sub
    ) {
        self.title = title
        self.verified = verified
        self.time = time
        self.unread = unread
        self.muted = muted
        self.divider = divider
        self.action = action
        self.avatar = avatar()
        self.sub = sub()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(verbatim: title)
                            .font(SonarTheme.uiFont(size: 16.5, weight: .semibold))
                            .kerning(-16.5 * 0.01)
                            .foregroundColor(SonarTheme.text)
                            .lineLimit(1)
                        if verified {
                            SNIcon(name: .shieldCheck, size: 14, weight: 2.1)
                                .foregroundColor(SonarTheme.green)
                        }
                    }
                    sub
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 5) {
                    if !time.isEmpty {
                        Text(verbatim: time)
                            .font(SonarTheme.uiFont(size: 12))
                            .foregroundColor(SonarTheme.text3)
                    }
                    if muted {
                        SNIcon(name: .bellOff, size: 14, weight: 2)
                            .foregroundColor(SonarTheme.text3)
                    } else if unread {
                        Circle()
                            .fill(SonarTheme.accent)
                            .frame(width: 11, height: 11)
                    }
                }
            }
            .padding(.vertical, SonarTheme.rowVerticalPadding)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if divider {
                    Rectangle()
                        .fill(SonarTheme.hairline)
                        .frame(height: 1)
                        .padding(.leading, 72)
                }
            }
        }
        .buttonStyle(SNRowPressStyle())
    }
}

/// Default DM-row subtitle: small lock + preview text.
struct SNLockedPreview: View {
    let preview: String

    var body: some View {
        HStack(spacing: 4) {
            SNIcon(name: .lock, size: 12, weight: 2.2)
                .foregroundColor(SonarTheme.text3)
            Text(verbatim: preview)
                .font(SonarTheme.uiFont(size: 14))
                .foregroundColor(SonarTheme.text2)
        }
    }
}

// MARK: - Nav header (bc-header)

struct SNNavHeader<Content: View, Trailing: View>: View {
    var hairline: Bool = true
    let onBack: () -> Void
    let content: Content
    let trailing: Trailing

    init(
        hairline: Bool = true,
        onBack: @escaping () -> Void,
        @ViewBuilder content: () -> Content,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.hairline = hairline
        self.onBack = onBack
        self.content = content()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 6) {
            SNIconButton(action: onBack) {
                SNIcon(name: .back, size: 21, weight: 2.1)
            }
            HStack(spacing: 10) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        .background(SonarTheme.bg)
        .overlay(alignment: .bottom) {
            if hairline {
                Rectangle().fill(SonarTheme.hairline).frame(height: 1)
            }
        }
    }
}

extension SNNavHeader where Trailing == EmptyView {
    init(hairline: Bool = true, onBack: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.init(hairline: hairline, onBack: onBack, content: content, trailing: { EmptyView() })
    }
}

/// bc-hname + bc-hsub stack used inside nav headers.
struct SNHeaderTitle<Sub: View>: View {
    let name: String
    var verified: Bool = false
    let sub: Sub

    init(name: String, verified: Bool = false, @ViewBuilder sub: () -> Sub) {
        self.name = name
        self.verified = verified
        self.sub = sub()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Text(verbatim: name)
                    .font(SonarTheme.uiFont(size: 17, weight: .bold))
                    .kerning(-17 * 0.01)
                    .lineLimit(1)
                    .foregroundColor(SonarTheme.text)
                if verified {
                    SNIcon(name: .shieldCheck, size: 15, weight: 2.1)
                        .foregroundColor(SonarTheme.green)
                }
            }
            HStack(spacing: 5) {
                sub
            }
            .font(SonarTheme.uiFont(size: 12))
            .foregroundColor(SonarTheme.text2)
        }
    }
}

/// Small status dot (bc-dot). `sm` = 7px.
struct SNDot: View {
    var color: Color = SonarTheme.green
    var small: Bool = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: small ? 7 : 9, height: small ? 7 : 9)
    }
}

// MARK: - Banner (bc-banner)

enum SNBannerTone {
    case neutral, publicRoom, enc, net

    var background: Color {
        switch self {
        case .neutral: return SonarTheme.surface2
        case .publicRoom: return SonarTheme.accentSoft
        case .enc: return SonarTheme.greenSoft
        case .net: return SonarTheme.netSoft
        }
    }

    var foreground: Color {
        switch self {
        case .neutral: return SonarTheme.text2
        case .publicRoom: return SonarTheme.accentDeep
        case .enc: return SonarTheme.greenDeep
        case .net: return SonarTheme.netDeep
        }
    }
}

struct SNBanner<Action: View>: View {
    let icon: SNIconName
    let tone: SNBannerTone
    let bold: String
    let rest: String
    let action: Action

    init(icon: SNIconName, tone: SNBannerTone, bold: String, rest: String, @ViewBuilder action: () -> Action) {
        self.icon = icon
        self.tone = tone
        self.bold = bold
        self.rest = rest
        self.action = action()
    }

    var body: some View {
        HStack(spacing: 9) {
            SNIcon(name: icon, size: 16, weight: 2)
            (Text(verbatim: bold).fontWeight(.bold) + Text(verbatim: rest))
                .font(SonarTheme.uiFont(size: 12.5))
                .lineSpacing(12.5 * 0.15)
                .frame(maxWidth: .infinity, alignment: .leading)
            action
        }
        .foregroundColor(tone.foreground)
        .padding(EdgeInsets(top: 9, leading: 13, bottom: 9, trailing: 13))
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(tone.background))
        .padding(EdgeInsets(top: 8, leading: 14, bottom: 0, trailing: 14))
    }
}

extension SNBanner where Action == EmptyView {
    init(icon: SNIconName, tone: SNBannerTone, bold: String, rest: String) {
        self.init(icon: icon, tone: tone, bold: bold, rest: rest, action: { EmptyView() })
    }
}

/// Pill button inside banners ("Verify").
struct SNBannerButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: label)
                .font(SonarTheme.uiFont(size: 12.5, weight: .bold))
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(
                    Capsule()
                        .fill(SonarTheme.surface)
                        .shadow(color: Color.black.opacity(0.07), radius: 1, y: 1)
                )
        }
        .buttonStyle(SNScaleStyle(scale: 0.96))
    }
}

// MARK: - Message bubble + list

private struct SNMessageStatusFooter: View {
    let stateText: String
    let via: SNVia?
    var onRetry: (() -> Void)? = nil

    private var isPending: Bool {
        stateText == "Sending" || stateText == "Uploading"
    }

    private var isFailed: Bool {
        stateText == "Couldn't send"
    }

    var body: some View {
        HStack(spacing: 3) {
            if isPending {
                ProgressView()
                    .scaleEffect(0.55)
                    .frame(width: 11, height: 11)
            } else {
                SNIcon(name: isFailed ? .x : .check, size: 11, weight: 2.6)
            }
            Text(verbatim: "\(stateText) · \(via?.label ?? "")")
                .font(SonarTheme.uiFont(size: 11))
            if isFailed, let onRetry {
                Button(action: onRetry) {
                    Text(verbatim: "Retry")
                        .font(SonarTheme.uiFont(size: 11, weight: .bold))
                        .padding(.vertical, 7)
                        .padding(.horizontal, 7)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry sending message")
            }
        }
        .foregroundColor(isFailed ? SonarTheme.danger : SonarTheme.text3)
    }
}

/// Signal-style quick tapback choices, shown before the full emoji picker.
let snQuickReactions = ["❤️", "👍", "👎", "😂", "😮", "😢"]

/// Compact `emoji count` chip row under a bubble (count hidden when 1, the
/// local user's reaction highlighted with the accent). Tap a chip to toggle
/// that emoji.
struct SNReactionChips: View {
    let reactions: [MessageReaction]
    let mine: Bool
    var onToggle: ((String) -> Void)? = nil

    var body: some View {
        HStack(spacing: 4) {
            ForEach(reactions, id: \.self) { reaction in
                Button {
                    onToggle?(reaction.emoji)
                } label: {
                    HStack(spacing: 3) {
                        Text(verbatim: reaction.emoji)
                            .font(.system(size: 13))
                        if reaction.count > 1 {
                            Text(verbatim: "\(reaction.count)")
                                .font(SonarTheme.uiFont(size: 11, weight: .semibold))
                                .foregroundColor(reaction.mine ? SonarTheme.accentDeep : SonarTheme.text2)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(
                        Capsule()
                            .fill(reaction.mine ? SonarTheme.accentSoft : SonarTheme.surface2)
                            .overlay(
                                Capsule().strokeBorder(
                                    reaction.mine ? SonarTheme.accent : SonarTheme.hairline,
                                    lineWidth: 1
                                )
                            )
                    )
                }
                .buttonStyle(SNScaleStyle(scale: 0.94))
                .disabled(onToggle == nil)
                .accessibilityLabel("\(reaction.emoji), \(reaction.count) \(reaction.count == 1 ? "reaction" : "reactions")")
            }
        }
        .padding(.top, 3)
        .padding(mine ? .trailing : .leading, 6)
    }
}

struct SNMsgBubble: View {
    let m: SNMessage
    let preview: SonarTranscriptTextPreview
    @Binding var expandedMessageIDs: Set<String>
    var showAuthor: Bool = false
    var cont: Bool = false
    var showState: Bool = false
    var onRetry: (() -> Void)? = nil
    let maxBubbleWidth: CGFloat
    /// Tap another participant's name/bubble to open a private DM (channels).
    var onTapAuthor: ((SNMessage) -> Void)? = nil
    /// Toggle an emoji reaction on this message (nil = reactions unavailable,
    /// e.g. public channels). Also enables the tapback row in the long-press menu.
    var onToggleReaction: ((String) -> Void)? = nil
    /// Open the full emoji picker to react ("+" in the tapback row).
    var onMoreReactions: (() -> Void)? = nil

    @Environment(\.openURL) private var openURL

    private var mine: Bool { m.mine }
    /// Only other participants' names in a channel context are tappable.
    private var tappable: Bool { onTapAuthor != nil && !mine }
    private var isExpanded: Bool { expandedMessageIDs.contains(m.id) }
    private var visibleText: String { isExpanded ? m.text : preview.text }

    /// Message text with detected URLs turned into tappable, underlined links.
    private var linkified: AttributedString {
        SonarMessageTextFormatter.attributedBubbleText(
            visibleText,
            baseColor: bubbleText,
            linkColor: mine ? bubbleText : SonarTheme.accentDeep,
            detectBareDomains: true,
            excludeLinkBeforeTrailingEllipsis: preview.isTruncated && !isExpanded
        )
    }

    /// The first URL in the message, if any (drives the "Open link" action).
    private var firstURL: URL? {
        let text = visibleText
        let ns = text as NSString
        guard ns.length > 0, let detector = MessageFormattingEngine.Patterns.linkDetector else { return nil }
        for match in detector.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
            if preview.isTruncated, !isExpanded,
               NSMaxRange(match.range) < ns.length,
               ns.substring(from: NSMaxRange(match.range)) == SonarTranscriptDisplayPolicy.ellipsis {
                continue
            }
            return match.url
        }
        return nil
    }

    static func copyToClipboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        #endif
    }
    private var bubbleFill: Color {
        guard mine else { return SonarTheme.bubbleOther }
        return m.via == .internet ? SonarTheme.netFill : SonarTheme.accentFill
    }
    private var bubbleText: Color {
        guard mine else { return SonarTheme.text }
        return m.via == .internet ? SonarTheme.onNet : SonarTheme.onAccent
    }
    private var metaColor: Color {
        guard mine else { return SonarTheme.text3 }
        return m.via == .internet ? SonarTheme.onNet.opacity(0.75) : SonarTheme.onAccent.opacity(0.72)
    }

    private var bubbleShape: UnevenRoundedRectangle {
        let r = SonarTheme.bubbleRadius
        let tail = r * 0.28
        return UnevenRoundedRectangle(
            topLeadingRadius: r,
            bottomLeadingRadius: mine ? r : tail,
            bottomTrailingRadius: mine ? tail : r,
            topTrailingRadius: r,
            style: .continuous
        )
    }

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 0) {
            if showAuthor, let author = m.author {
                Text(verbatim: author)
                    .font(SonarTheme.uiFont(size: 12, weight: .bold))
                    .foregroundColor(SonarTheme.authorColor(author))
                    .padding(.leading, 12)
                    .padding(.bottom, 3)
                    .contentShape(Rectangle())
                    .onTapGesture { if tappable { onTapAuthor?(m) } }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Text(linkified)
                    .font(SonarTheme.uiFont(size: 16))
                    .lineSpacing(16 * 0.2)
                    .foregroundColor(bubbleText)
                    .tint(mine ? bubbleText : SonarTheme.accentDeep)
                    // Text selection's own long-press would swallow the
                    // tapback long-press, so the two are mutually exclusive
                    // (Compose mirrors this): Copy moves into the bubble-wide
                    // context menu below whenever reactions are available.
                    .textSelection(onToggleReaction == nil ? .enabled : .disabled)
                HStack(spacing: 3) {
                    Text(verbatim: m.time)
                        .font(SonarTheme.uiFont(size: 10.5))
                    if let via = m.via {
                        SNIcon(name: via == .mesh ? .mesh : .globe, size: 11, weight: 2.2)
                    }
                }
                .foregroundColor(metaColor)
                .padding(.bottom, 1.5)
                // Keep the message Text free for native selection and targeted
                // inline-link taps. The metadata owns the whole-message actions
                // so Copy still uses the untruncated source text.
                .contextMenu {
                    Button {
                        SNMsgBubble.copyToClipboard(m.text)
                    } label: {
                        Label("Copy message", systemImage: "doc.on.doc")
                    }
                    if let url = firstURL {
                        Button {
                            openURL(url)
                        } label: {
                            Label("Open link", systemImage: "safari")
                        }
                    }
                }
            }
            .padding(EdgeInsets(top: 8, leading: 12, bottom: 9, trailing: 12))
            .background(
                bubbleShape
                    .fill(bubbleFill)
                    .shadow(color: mine ? .clear : Color(sonarHex: 0x0A232D, opacity: 0.07), radius: 0.75, y: 1)
            )
            .contentShape(bubbleShape)
            .contextMenu {
                // Tapback row: quick emoji + full picker, on the platform
                // long-press affordance (keeps link taps + copy intact).
                if let onToggleReaction {
                    if #available(iOS 17.0, macOS 14.0, *) {
                        ControlGroup {
                            ForEach(snQuickReactions, id: \.self) { emoji in
                                Button { onToggleReaction(emoji) } label: { Text(verbatim: emoji) }
                            }
                        }
                        .controlGroupStyle(.palette)
                    } else {
                        ForEach(snQuickReactions, id: \.self) { emoji in
                            Button { onToggleReaction(emoji) } label: { Text(verbatim: emoji) }
                        }
                    }
                    if let onMoreReactions {
                        Button {
                            onMoreReactions()
                        } label: {
                            Label("More reactions…", systemImage: "face.smiling")
                        }
                    }
                    Divider()
                    Button {
                        SNMsgBubble.copyToClipboard(m.text)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    if let url = firstURL {
                        Button {
                            openURL(url)
                        } label: {
                            Label("Open link", systemImage: "safari")
                        }
                    }
                }
            }
            if preview.isTruncated {
                Button(isExpanded
                       ? String(localized: "content.message.show_less")
                       : String(localized: "content.message.show_more")) {
                    if isExpanded { expandedMessageIDs.remove(m.id) }
                    else { expandedMessageIDs.insert(m.id) }
                }
                .font(SonarTheme.uiFont(size: 12, weight: .semibold))
                .foregroundColor(SonarTheme.accentDeep)
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .padding(.horizontal, 6)
            }
            if !m.reactions.isEmpty {
                SNReactionChips(reactions: m.reactions, mine: mine, onToggle: onToggleReaction)
            }
            if showState, let stateText = m.state {
                SNMessageStatusFooter(stateText: stateText, via: m.via, onRetry: onRetry)
                .padding(EdgeInsets(top: 3, leading: 4, bottom: 0, trailing: 4))
            }
        }
        .frame(maxWidth: maxBubbleWidth, alignment: mine ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .padding(.top, cont ? 2 : 9)
    }
}

struct SNMediaPipeline {
    var state: (SNMediaItem) -> SNMediaTransferState
    var prepare: (SNMediaItem, Bool) -> Void
    var request: (SNMediaItem) -> Void
    var cancel: (SNMediaItem) -> Void
    var loadLocal: (SNMediaItem) async -> Data?

    static let unavailable = SNMediaPipeline(
        state: { _ in .notDownloaded },
        prepare: { _, _ in },
        request: { _ in },
        cancel: { _ in },
        loadLocal: { _ in nil }
    )
}

/// O(1) identity for transcript changes that can affect the live edge.
/// Defined in TranscriptEngine; Sonar keeps the SN* name via TranscriptEngineSonarCompat.

/// Reference-semantic height scratchpad. Mutating `last` does not invalidate
/// SwiftUI the way `@State CGFloat` would, so keyboard animation can update
/// the previous-height sample without rebuilding the transcript.
final class SNViewportHeightTracker {
    var last: CGFloat = 0
}

/// Distinguishes scrolls that can move the reader away from the tail from
/// layout/programmatic moves toward it. UIKit does not set its drag flags for
/// status-bar scroll-to-top or accessibility paging, but both move the content
/// offset toward the top. Tail-following scrolls move in the opposite direction.
enum SNUserScrollActivity: Equatable {
    case none
    case towardHistory
    case towardTail
}

/// Signal `updateContentInsets` non-pinned branch — implemented in TranscriptEngine
/// (`transcriptRestingOffsetOvershootCorrection` / `snRestingOffsetOvershootCorrection` shim).

/// Signal owns the conversation scroll view's bottom inset itself
/// (`newInsets.bottom = bottomBarContainer.frame.height - safeAreaInsets.bottom`)
/// and never lets UIKit's keyboard automatic adjustment add a second band.
/// Sonar's composer is a VStack sibling below the transcript (not an overlay
/// inside the scroll view), so the owned bottom inset is always 0 — any
/// leftover keyboard `contentInset.bottom` is exactly the phantom empty band
/// above the composer on short chats like GIAN after dismiss.
func snOwnedTranscriptBottomContentInset(
    automaticBottomInset: CGFloat
) -> CGFloat {
    // Composer is outside the scroll view; never keep UIKit keyboard inset.
    _ = automaticBottomInset
    return 0
}

/// Signal `scrollToBottomOfLoadWindow` — implemented in TranscriptEngine
/// (`transcriptScrollToBottomOfLoadWindowOffsetY` / `snScrollToBottomOfLoadWindowOffsetY` shim).

/// iOS 17+ / macOS 14+: start (and keep) the scroll view at the live edge —
/// Signal `scrollToInitialPosition` → `scrollToBottomOfLoadWindow` for
/// fully-read opens. Avoids LazyVStack `contentSize`-based top insets that
/// under-measure and open DMs away from the last message.
private struct SNTranscriptScrollAnchor: ViewModifier {
    let bottomAligned: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if bottomAligned {
            if #available(iOS 17.0, macOS 14.0, *) {
                content.defaultScrollAnchor(.bottom)
            } else {
                content
            }
        } else {
            content
        }
    }
}

struct SNUserScrollOffsetClassifier {
    private var previousY: CGFloat?
    private var previousViewportHeight: CGFloat?
    private var previousBottomInset: CGFloat?

    mutating func reset(
        y: CGFloat,
        viewportHeight: CGFloat,
        bottomInset: CGFloat
    ) {
        previousY = y
        previousViewportHeight = viewportHeight
        previousBottomInset = bottomInset
    }

    mutating func observe(
        y: CGFloat,
        viewportHeight: CGFloat,
        bottomInset: CGFloat,
        isAtBottom: Bool,
        isTouchScrolling: Bool,
        isViewportTransitioning: Bool = false
    ) -> SNUserScrollActivity {
        defer {
            previousY = y
            previousViewportHeight = viewportHeight
            previousBottomInset = bottomInset
        }
        guard let previousY,
              let previousViewportHeight,
              let previousBottomInset else { return .none }
        let layoutChanged = abs(viewportHeight - previousViewportHeight) > 0.5
            || abs(bottomInset - previousBottomInset) > 0.5
        if y < previousY - 0.5 {
            // UIKit can publish the keyboard-driven offset clamp before its
            // bounds/inset update. The keyboard frame notification brackets
            // that ordering gap; never turn it into a synthetic user scroll.
            if !isTouchScrolling && isViewportTransitioning { return .none }
            // A keyboard/composer dismissal expands the viewport (or reduces
            // its inset) and clamps the bottom offset upward without user
            // input. Status-bar and accessibility scrolling keep both stable.
            return !isTouchScrolling && layoutChanged && isAtBottom
                ? .none
                : .towardHistory
        }
        if isTouchScrolling, y > previousY + 0.5 { return .towardTail }
        return .none
    }
}

#if SONAR_KEYBOARD_BENCH && os(iOS)
/// Opt-in, content-free counters for the keyboard/tail benchmark. Normal
/// builds contain none of this probe; benchmark builds also require
/// `SONAR_BENCH_KEYBOARD_TAIL=1` at launch.
final class SNKeyboardTailBenchmark {
    static let shared = SNKeyboardTailBenchmark()
    private static let log = OSLog(subsystem: "sh.hedwig.sonar", category: "keyboard-bench")

    private let enabled = ProcessInfo.processInfo.environment["SONAR_BENCH_KEYBOARD_TAIL"] == "1"
    private var generation = 0
    private var startedAt: TimeInterval?
    private var animationDurationMs = 0.0
    private var messageRevisionEvaluations = 0
    private var messageIDsVisited = 0
    private var observerAttachRequests = 0
    private var observerAncestorScans = 0
    private var offsetSamples = 0
    private var viewportShrinks = 0
    private var tailRequests = 0
    private var tailExecutions = 0

    private init() {}

    func begin(_ notification: Notification) {
        guard enabled else { return }
        if startedAt != nil { finish(overlapped: true) }
        generation &+= 1
        startedAt = ProcessInfo.processInfo.systemUptime
        animationDurationMs = ((notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey]
            as? NSNumber)?.doubleValue ?? 0.25) * 1_000
        messageRevisionEvaluations = 0
        messageIDsVisited = 0
        observerAttachRequests = 0
        observerAncestorScans = 0
        offsetSamples = 0
        viewportShrinks = 0
        tailRequests = 0
        tailExecutions = 0

        let currentGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + max(animationDurationMs / 1_000, 0.25) + 0.15) {
            [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.finish(overlapped: false)
        }
    }

    func recordMessageRevision(idsVisited: Int) {
        guard enabled, startedAt != nil else { return }
        messageRevisionEvaluations += 1
        messageIDsVisited += idsVisited
    }

    func recordObserverAttachRequest() {
        guard enabled, startedAt != nil else { return }
        observerAttachRequests += 1
    }

    func recordObserverAncestorScan() {
        guard enabled, startedAt != nil else { return }
        observerAncestorScans += 1
    }

    func recordOffsetSample() {
        guard enabled, startedAt != nil else { return }
        offsetSamples += 1
    }

    func recordViewportShrink() {
        guard enabled, startedAt != nil else { return }
        viewportShrinks += 1
    }

    func recordTailRequest() {
        guard enabled, startedAt != nil else { return }
        tailRequests += 1
    }

    func recordTailExecution() {
        guard enabled, startedAt != nil else { return }
        tailExecutions += 1
    }

    private func finish(overlapped: Bool) {
        guard enabled, let startedAt else { return }
        let wallMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        let marker = "SONAR_BENCH keyboard_tail generation=\(generation) wall_ms=\(String(format: "%.2f", wallMs)) "
                + "animation_ms=\(String(format: "%.2f", animationDurationMs)) revisions=\(messageRevisionEvaluations) "
                + "ids_visited=\(messageIDsVisited) attach_requests=\(observerAttachRequests) "
                + "ancestor_scans=\(observerAncestorScans) offset_samples=\(offsetSamples) "
                + "viewport_shrinks=\(viewportShrinks) tail_requests=\(tailRequests) "
                + "tail_executions=\(tailExecutions) overlapped=\(overlapped ? 1 : 0)"
        os_log("%{public}@", log: Self.log, type: .info, marker)
        SecureLogger.info(marker, category: .session)
        self.startedAt = nil
    }
}
#endif

func snShouldRecordUserScroll(
    _ activity: SNUserScrollActivity,
    isNearBottom: Bool
) -> Bool {
    switch activity {
    case .none:
        return false
    case .towardHistory:
        return true
    case .towardTail:
        // The sentinel can appear before deceleration ends. Ignore remaining
        // downward frames after it has synchronously re-armed the tail.
        return !isNearBottom
    }
}

#if os(iOS)
/// Holds the enclosing UIScrollView for ContinuityToken capture/restore on the
/// SNMsgList fallback path (Phase 2 collection host has its own).
@MainActor
final class SNScrollContinuityBridge {
    weak var scrollView: UIScrollView?

    func capture(anchorId: String) -> SNTranscriptContinuityToken {
        guard let scrollView else {
            return SNTranscriptScrollPolicy.continuityToken(anchorId: anchorId, pixelOffset: 0)
        }
        let maxY = snScrollToBottomOfLoadWindowOffsetY(
            boundsHeight: scrollView.bounds.height,
            contentHeight: scrollView.contentSize.height,
            topInset: scrollView.adjustedContentInset.top,
            bottomInset: scrollView.adjustedContentInset.bottom
        )
        let edgeDistance = maxY - scrollView.contentOffset.y
        return SNTranscriptScrollPolicy.continuityToken(
            anchorId: anchorId,
            edgeDistance: edgeDistance
        )
    }

    func restore(_ token: SNTranscriptContinuityToken) {
        guard let scrollView else { return }
        scrollView.layoutIfNeeded()
        switch token.edge {
        case .edgeDistance(let distance):
            let contentHeight = scrollView.contentSize.height
            if contentHeight < 1 { return }
            let maxY = snScrollToBottomOfLoadWindowOffsetY(
                boundsHeight: scrollView.bounds.height,
                contentHeight: contentHeight,
                topInset: scrollView.adjustedContentInset.top,
                bottomInset: scrollView.adjustedContentInset.bottom
            )
            let minY = -scrollView.adjustedContentInset.top
            let y = max(minY, maxY - distance)
            scrollView.setContentOffset(
                CGPoint(x: scrollView.contentOffset.x, y: y),
                animated: false
            )
        case .pixelOffset(let y):
            let minY = -scrollView.adjustedContentInset.top
            scrollView.setContentOffset(
                CGPoint(x: scrollView.contentOffset.x, y: max(minY, y)),
                animated: false
            )
        }
    }
}

/// Bridges the underlying scroll view's user-driven offset changes without
/// taking over its delegate. Programmatic `scrollTo` calls and keyboard layout
/// adjustments toward the tail do not report as user scrolling. Offset moves
/// toward the top also cover status-bar and accessibility scrolling, whose
/// UIKit drag flags remain false.
private struct SNUserScrollObserver: UIViewRepresentable {
    let onUserScroll: (SNUserScrollActivity) -> Void
    let onViewportWillChange: (Notification) -> Void
    /// Fires when `contentSize.height` grows (media decode, self-sizing cells).
    /// Hosts re-pin the live edge — Signal keeps the tail across content growth.
    var onContentSizeGrow: (() -> Void)? = nil
    var continuityBridge: SNScrollContinuityBridge?

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onUserScroll = onUserScroll
        view.onViewportWillChange = onViewportWillChange
        view.onContentSizeGrow = onContentSizeGrow
        view.continuityBridge = continuityBridge
        return view
    }

    func updateUIView(_ uiView: ObserverView, context: Context) {
        uiView.onUserScroll = onUserScroll
        uiView.onViewportWillChange = onViewportWillChange
        uiView.onContentSizeGrow = onContentSizeGrow
        uiView.continuityBridge = continuityBridge
        // Only scan/attach when we are not already observing. Calling this on
        // every keyboard-driven body pass was a major agent-DM cost (bench:
        // attach_requests≈revisions per transition).
        #if SONAR_KEYBOARD_BENCH
        if !uiView.isAttached {
            SNKeyboardTailBenchmark.shared.recordObserverAttachRequest()
        }
        #endif
        uiView.attachWhenNeeded()
    }

    final class ObserverView: UIView {
        var onUserScroll: (SNUserScrollActivity) -> Void = { _ in }
        var onViewportWillChange: (Notification) -> Void = { _ in }
        var onContentSizeGrow: (() -> Void)?
        var continuityBridge: SNScrollContinuityBridge?
        private weak var observedScrollView: UIScrollView?
        private var contentOffsetObservation: NSKeyValueObservation?
        private var contentSizeObservation: NSKeyValueObservation?
        private var lastContentHeight: CGFloat = 0
        private var offsetClassifier = SNUserScrollOffsetClassifier()
        private var keyboardFrameObserver: NSObjectProtocol?
        private var viewportTransitionDeadline: TimeInterval = 0
        private var attachmentScheduled = false

        var isAttached: Bool { observedScrollView != nil }

        deinit {
            if let keyboardFrameObserver {
                NotificationCenter.default.removeObserver(keyboardFrameObserver)
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attachWhenReady()
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            attachWhenReady()
        }

        func attachWhenReady() {
            observeKeyboardFramesIfNeeded()
            scheduleAttachment()
        }

        func attachWhenNeeded() {
            observeKeyboardFramesIfNeeded()
            guard observedScrollView == nil else { return }
            scheduleAttachment()
        }

        private func scheduleAttachment() {
            guard !attachmentScheduled else { return }
            attachmentScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.attachmentScheduled = false
                self.attachToEnclosingScrollView()
            }
        }

        private func observeKeyboardFramesIfNeeded() {
            guard keyboardFrameObserver == nil else { return }
            keyboardFrameObserver = NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillChangeFrameNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self else { return }
                let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey]
                    as? NSNumber)?.doubleValue ?? 0.25
                self.viewportTransitionDeadline = Date.timeIntervalSinceReferenceDate
                    + max(duration, 0.25)
                    + 0.1
                self.onViewportWillChange(notification)
                // Apply Signal's inset ownership immediately (clear any
                // automatic keyboard bottom inset), then again after the
                // animation so a late UIKit write cannot leave a phantom band.
                self.applyOwnedInsetsAndSettleOffset()
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + max(duration, 0.25) + 0.05
                ) { [weak self] in
                    self?.applyOwnedInsetsAndSettleOffset()
                }
            }
        }

        /// Signal `updateContentInsets` for our layout: own bottom inset
        /// (always 0 — composer is a sibling), never leave a keyboard
        /// `contentInset.bottom`, then stay at `maxContentOffsetY` or clamp
        /// overshoot. Do **not** derive a top inset from LazyVStack
        /// `contentSize` — it under-measures and opens DMs away from the tail.
        func applyOwnedInsetsAndSettleOffset() {
            guard let scrollView = observedScrollView,
                  !scrollView.isTracking,
                  !scrollView.isDragging,
                  !scrollView.isDecelerating else { return }

            if scrollView.contentInsetAdjustmentBehavior != .never {
                scrollView.contentInsetAdjustmentBehavior = .never
            }
            let ownedBottom = snOwnedTranscriptBottomContentInset(
                automaticBottomInset: scrollView.contentInset.bottom
            )
            let insetChanged =
                abs(scrollView.contentInset.bottom - ownedBottom) > 0.5
                || abs(scrollView.contentInset.top) > 0.5
            if insetChanged {
                var inset = scrollView.contentInset
                inset.top = 0
                inset.bottom = ownedBottom
                UIView.performWithoutAnimation {
                    let offset = scrollView.contentOffset
                    scrollView.contentInset = inset
                    scrollView.scrollIndicatorInsets.top = 0
                    scrollView.scrollIndicatorInsets.bottom = ownedBottom
                    scrollView.setContentOffset(offset, animated: false)
                }
            }

            let topInset = scrollView.adjustedContentInset.top
            let bottomInset = scrollView.adjustedContentInset.bottom
            let maxY = snScrollToBottomOfLoadWindowOffsetY(
                boundsHeight: scrollView.bounds.height,
                contentHeight: scrollView.contentSize.height,
                topInset: topInset,
                bottomInset: bottomInset
            )
            let nearBottom = scrollView.contentOffset.y >= maxY - 5
            let targetY: CGFloat?
            if nearBottom {
                targetY = abs(scrollView.contentOffset.y - maxY) > 1 ? maxY : nil
            } else {
                targetY = snRestingOffsetOvershootCorrection(
                    offsetY: scrollView.contentOffset.y,
                    boundsHeight: scrollView.bounds.height,
                    contentHeight: scrollView.contentSize.height,
                    topInset: topInset,
                    bottomInset: bottomInset
                )
            }
            guard let targetY else { return }
            scrollView.setContentOffset(
                CGPoint(x: scrollView.contentOffset.x, y: targetY),
                animated: false
            )
        }

        private func attachToEnclosingScrollView() {
            #if SONAR_KEYBOARD_BENCH
            SNKeyboardTailBenchmark.shared.recordObserverAncestorScan()
            #endif
            var ancestor = superview
            while let view = ancestor, !(view is UIScrollView) {
                ancestor = view.superview
            }
            guard let scrollView = ancestor as? UIScrollView,
                  scrollView !== observedScrollView else { return }
            observedScrollView = scrollView
            continuityBridge?.scrollView = scrollView
            // Signal owns conversation insets; disable UIKit keyboard
            // automatic adjustment so it cannot leave a phantom bottom band.
            scrollView.contentInsetAdjustmentBehavior = .never
            if scrollView.contentInset.top != 0 || scrollView.contentInset.bottom != 0 {
                var inset = scrollView.contentInset
                inset.top = 0
                inset.bottom = 0
                scrollView.contentInset = inset
                scrollView.scrollIndicatorInsets.top = 0
                scrollView.scrollIndicatorInsets.bottom = 0
            }
            offsetClassifier.reset(
                y: scrollView.contentOffset.y,
                viewportHeight: scrollView.bounds.height,
                bottomInset: scrollView.adjustedContentInset.bottom
            )
            lastContentHeight = scrollView.contentSize.height
            contentSizeObservation = scrollView.observe(\.contentSize, options: [.new]) {
                [weak self] scrollView, _ in
                guard let self else { return }
                let height = scrollView.contentSize.height
                // Only growth: media thumbs / self-sizing cells lengthening the
                // transcript. Shrink/no-op must not yank the reader.
                guard height > self.lastContentHeight + 0.5 else {
                    self.lastContentHeight = height
                    return
                }
                self.lastContentHeight = height
                self.onContentSizeGrow?()
            }
            contentOffsetObservation = scrollView.observe(\.contentOffset, options: [.new]) {
                [weak self] scrollView, _ in
                guard let self else { return }
                #if SONAR_KEYBOARD_BENCH
                SNKeyboardTailBenchmark.shared.recordOffsetSample()
                #endif
                let isTouchScrolling = scrollView.isTracking
                    || scrollView.isDragging
                    || scrollView.isDecelerating
                let minimumY = -scrollView.adjustedContentInset.top
                let maximumY = max(
                    minimumY,
                    scrollView.contentSize.height
                        - scrollView.bounds.height
                        + scrollView.adjustedContentInset.bottom
                )
                let activity = self.offsetClassifier.observe(
                    y: scrollView.contentOffset.y,
                    viewportHeight: scrollView.bounds.height,
                    bottomInset: scrollView.adjustedContentInset.bottom,
                    isAtBottom: scrollView.contentOffset.y >= maximumY - 1,
                    isTouchScrolling: isTouchScrolling,
                    isViewportTransitioning: !isTouchScrolling
                        && Date.timeIntervalSinceReferenceDate < self.viewportTransitionDeadline
                )
                guard activity != .none else { return }
                self.onUserScroll(activity)
            }
        }
    }
}
#else
private struct SNUserScrollObserver: NSViewRepresentable {
    let onUserScroll: () -> Void
    let onViewportWillChange: (Notification) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onUserScroll = onUserScroll
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onUserScroll = onUserScroll
        nsView.attachWhenReady()
    }

    final class ObserverView: NSView {
        var onUserScroll: () -> Void = {}
        private weak var observedScrollView: NSScrollView?
        private var liveScrollObserver: NSObjectProtocol?

        deinit {
            if let liveScrollObserver { NotificationCenter.default.removeObserver(liveScrollObserver) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachWhenReady()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            attachWhenReady()
        }

        func attachWhenReady() {
            DispatchQueue.main.async { [weak self] in self?.attachToEnclosingScrollView() }
        }

        private func attachToEnclosingScrollView() {
            guard let scrollView = enclosingScrollView,
                  scrollView !== observedScrollView else { return }
            if let liveScrollObserver { NotificationCenter.default.removeObserver(liveScrollObserver) }
            observedScrollView = scrollView
            liveScrollObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.didLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                self?.onUserScroll()
            }
        }
    }
}
#endif

struct SNMsgList: View {
    let msgs: [SNMessage]
    let showAuthors: Bool
    /// Counterpart name, used by pay bubbles ("Payment from X", "Claimed by X").
    var peerName: String = ""
    /// Primary money string for pay bubbles (fiat or sats, unit included).
    var money: (Int64) -> String = { sonarFormatSats($0) }
    /// Secondary detail line for pay bubbles; nil result = line not rendered.
    var fiatText: (Int64) -> String? = { _ in nil }
    /// Tap on another participant's bubble/name (geohash channels) to DM them.
    var onTapAuthor: ((SNMessage) -> Void)? = nil
    /// Signal-style attachment lifecycle owned by the app store.
    var mediaPipeline: SNMediaPipeline = .unavailable
    var loadSticker: ((MarmotService.MarmotStickerRef, Bool) async -> Data?)? = nil
    var onTapPack: ((String) -> Void)? = nil
    /// Retry one failed outgoing message without rebuilding the transcript.
    var onRetry: ((SNMessage) -> Void)? = nil
    /// Cancel an in-flight Blossom upload for an optimistic media bubble.
    var onCancelUpload: ((SNMessage) -> Void)? = nil
    /// Live Blossom upload fractions (collection-host / Compose parity).
    var uploadProgressSource: SNMediaUploadProgressSource? = nil
    /// Load one older local database page. Nil for non-paged channel surfaces.
    var loadOlder: (() async -> Bool)? = nil
    /// Restore a movable historical window to its newest local page.
    var loadNewest: (() async -> Void)? = nil
    /// Unread count captured at open time (before read-marking zeroed the core
    /// counter). `nil` means capture has not settled yet — do not treat as
    /// fully-read. Non-zero opens anchored at the first unread row with a
    /// divider, Signal-style, instead of pinning the tail.
    var unreadCountAtOpen: UInt64? = nil
    /// Newest known message date across the chat's folded sources. The unread
    /// anchor may only be resolved once the visible rows have caught up to
    /// this — hydration can publish one transport leg before the folded White
    /// Noise groups merge in, and the missing rows are exactly the unread ones.
    var expectedNewestDate: Date? = nil
    /// Toggle an emoji reaction on a message (nil = reactions unavailable).
    var onToggleReaction: ((SNMessage, String) -> Void)? = nil
    /// Open the full emoji picker to react to a message.
    var onMoreReactions: ((SNMessage) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isNearBottom = true
    @State private var hasReachedBottomOnce = false
    @State private var hasLeftBottom = false
    @State private var isLoadingOlder = false
    @State private var isLoadingNewest = false
    @State private var expandedMessageIDs: Set<String> = []
    /// Frozen ID of the oldest unread row: live incoming messages (already
    /// marked read on open) must not drift the divider down the transcript.
    @State private var unreadAnchorId: String?
    /// True when a caught-up feed could not place a divider (e.g. every unread
    /// event is a call/pay control row). Ends the pending-anchor state so tail
    /// following is not suppressed for the rest of the open.
    @State private var unreadAnchorAbandoned = false
    /// Carries the prior pinned state across viewport/content layout changes.
    @State private var tailPin = SNTailPinLatch()
    /// At most one non-animated tail correction per Signal-style 10 ms window.
    @State private var tailSnapCoalescer = SNTailSnapCoalescer()
    /// Previous GeometryReader height for pin decisions. Stored off the
    /// `@State` value path so keyboard-animation frames do not write SwiftUI
    /// state (each write would rebuild the LazyVStack again).
    @State private var viewportHeightTracker = SNViewportHeightTracker()
    @State private var isUserScrolling = false
    @State private var userScrollGeneration = 0
    /// Fully-read open: keep snapping to the live edge until `sn-bottom`
    /// appears (or the user scrolls away / unread takes over). Clears the
    /// alpha.11 race where one async `scrollTo` lost to LazyVStack layout.
    @State private var needsLiveEdgeOpen = false
    #if os(iOS)
    @State private var continuityBridge = SNScrollContinuityBridge()
    #endif

    /// The live-edge identity must participate in change detection. Once the
    /// bounded transcript reaches capacity, a send replaces an old row and
    /// keeps `msgs.count` constant; observing only the count strands the new
    /// tail below the keyboard until the user scrolls manually.
    private var messageRevision: SNTailRevision {
        SNTailRevision(itemCount: msgs.count, tailID: msgs.last?.id)
    }

    /// True once the visible rows have caught up with the newest message the
    /// core index knows across the chat's folded sources. A mesh chat paints
    /// the BLE window before the White Noise leg merges async, so before this
    /// is true the feed is missing its newest (and unread) rows.
    private var feedCaughtUp: Bool {
        guard let expected = expectedNewestDate else { return true }
        // Visible feed is chronological; prefer O(1) at the live edge. Fall
        // back to a scan only when the tail row lacks a sortDate.
        if let newest = msgs.last?.sortDate { return newest >= expected }
        guard let newest = msgs.lazy.compactMap(\.sortDate).max() else { return false }
        return newest >= expected
    }

    private var usesBottomScrollAnchor: Bool {
        SNTranscriptScrollPolicy.usesBottomScrollAnchor(
            unreadAnchorId: unreadAnchorId,
            unreadCountAtOpen: unreadCountAtOpen,
            unreadAnchorAbandoned: unreadAnchorAbandoned
        )
    }

    /// Signal `scrollToInitialPosition` vocabulary for this open.
    private var transcriptOpenAction: SNTranscriptOpenAction {
        SNTranscriptScrollPolicy.openAction(
            unreadAnchorId: unreadAnchorId,
            unreadCountAtOpen: unreadCountAtOpen,
            unreadAnchorAbandoned: unreadAnchorAbandoned
        )
    }

    /// The [unreadCountAtOpen]-th non-mine message from the tail — core
    /// unread_count increments only for incoming messages, so own sends
    /// interleave without consuming budget. Re-resolves only when the frozen
    /// row leaves the loaded window (e.g. replaced by a fresh local page).
    private func resolveUnreadAnchor() {
        guard let unreadCountAtOpen, unreadCountAtOpen > 0 else { return }
        if let current = unreadAnchorId, msgs.contains(where: { $0.id == current }) { return }
        // Wait for the rows to catch up with the newest known message before
        // counting from the tail; freezing against a partially merged feed
        // would anchor the divider on the wrong row.
        if let expected = expectedNewestDate,
           let newest = msgs.compactMap(\.sortDate).max(),
           newest < expected {
            return
        }
        var remaining = unreadCountAtOpen
        var anchor: String? = nil
        for m in msgs.reversed() where !m.mine && m.call == nil {
            anchor = m.id
            remaining -= 1
            if remaining == 0 { break }
        }
        unreadAnchorId = anchor
        if anchor == nil {
            // Caught-up feed cannot place a divider — fall back to live edge
            // (agent/control-only unread budgets). Hosts must start open recovery.
            unreadAnchorAbandoned = true
        }
    }

    #if os(iOS)
    private func noteUserScroll(_ activity: SNUserScrollActivity) {
        guard snShouldRecordUserScroll(activity, isNearBottom: isNearBottom) else { return }
        recordUserScroll()
    }
    #else
    private func noteUserScroll() {
        recordUserScroll()
    }
    #endif

    private func recordUserScroll() {
        isUserScrolling = true
        // Genuine user scroll abandons fully-read open recovery even when the
        // bottom sentinel never appeared (isNearBottom can still be the
        // initial `true` while the list is mid-history).
        needsLiveEdgeOpen = false
        tailPin.userScrolled(isNearBottom: isNearBottom)
        userScrollGeneration &+= 1
        let generation = userScrollGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard userScrollGeneration == generation else { return }
            isUserScrolling = false
        }
    }

    /// Signal `scrollToBottomOfLoadWindow` for a fully-read open: last row +
    /// sentinel. Safe to call repeatedly while `needsLiveEdgeOpen` is set.
    private func snapFullyReadOpen(proxy: ScrollViewProxy) {
        guard SNTranscriptScrollPolicy.shouldResnapFullyReadOpen(
            usesBottomScrollAnchor: usesBottomScrollAnchor,
            needsLiveEdgeOpen: needsLiveEdgeOpen,
            hasLeftBottom: hasLeftBottom,
            userScrolling: isUserScrolling,
            hasTailRow: msgs.last?.id != nil
        ) else { return }
        tailPin.tailVisible(itemCount: msgs.count, tailID: msgs.last?.id)
        followTail(.snap, proxy: proxy, animateAppends: false)
        if let tailID = msgs.last?.id {
            DispatchQueue.main.async {
                proxy.scrollTo(tailID, anchor: .bottom)
            }
        }
    }

    private func followTail(
        _ action: SNTailPinAction,
        proxy: ScrollViewProxy,
        animateAppends: Bool = true
    ) {
        // Latch already applied SNTranscriptScrollPolicy inset decisions;
        // `.none` is lockstep or ignore — do not programmatic-scroll.
        guard action != .none else { return }
        #if SONAR_KEYBOARD_BENCH && os(iOS)
        SNKeyboardTailBenchmark.shared.recordTailRequest()
        #endif
        if action == .snap {
            guard tailSnapCoalescer.request() else { return }
            DispatchQueue.main.asyncAfter(
                deadline: .now() + SNTranscriptScrollPolicy.snapCoalesceSeconds
            ) {
                guard tailSnapCoalescer.consume() else { return }
                #if SONAR_KEYBOARD_BENCH && os(iOS)
                SNKeyboardTailBenchmark.shared.recordTailExecution()
                #endif
                proxy.scrollTo("sn-bottom", anchor: .bottom)
            }
            return
        }
        DispatchQueue.main.async {
            #if SONAR_KEYBOARD_BENCH && os(iOS)
            SNKeyboardTailBenchmark.shared.recordTailExecution()
            #endif
            if action == .animate, animateAppends, !reduceMotion {
                withAnimation { proxy.scrollTo("sn-bottom", anchor: .bottom) }
            } else {
                proxy.scrollTo("sn-bottom", anchor: .bottom)
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    // Keep chat open proportional to the visible viewport. Agent
                    // conversations can contain a page of long command output;
                    // eagerly building every attributed-text bubble here stalls
                    // first paint even though the database read is already bounded.
                    LazyVStack(spacing: 0) {
                        ForEach(Array(msgs.enumerated()), id: \.element.id) { i, m in
                            // Day chip when the local calendar day flips (not a
                            // hardcoded "Today" at the top of the window).
                            let prevDate = i > 0 ? msgs[i - 1].sortDate : nil
                            if snTranscriptShowsDayChip(previous: prevDate, current: m.sortDate),
                               let day = m.sortDate
                            {
                                SNDateChip(label: snTranscriptDayLabel(for: day))
                            }
                            // Signal-style unread marker above the oldest unread row.
                            if m.id == unreadAnchorId {
                                SNUnreadDivider().id("sn-unread")
                            }
                            Group {
                            if let call = m.call {
                                SNCallLogRow(call: call, mine: m.mine, time: m.time)
                            } else if m.trill {
                                SNNudgeRow(m: m, peerName: peerName, group: showAuthors)
                            } else if m.pay != nil {
                                SNPayBubble(
                                    m: m,
                                    peerName: peerName,
                                    money: money,
                                    fiatText: fiatText,
                                    maxBubbleWidth: geo.size.width * 0.78
                                )
                            } else if !m.media.isEmpty {
                                let showDeliveryState = m.mine && (i == msgs.count - 1 || m.state == "Couldn't send")
                                let canRetry = snCanRetryFailedMessage(m)
                                SNMediaBubble(
                                    m: m,
                                    maxBubbleWidth: geo.size.width * 0.72,
                                    showState: showDeliveryState,
                                    onRetry: canRetry ? { onRetry?(m) } : nil,
                                    onCancelUpload: m.state == "Uploading" ? { onCancelUpload?(m) } : nil,
                                    uploadProgressSource: uploadProgressSource,
                                    pipeline: mediaPipeline
                                )
                            } else if m.stickerRef != nil {
                                let showDeliveryState = m.mine && (i == msgs.count - 1 || m.state == "Couldn't send")
                                let canRetry = snCanRetryFailedMessage(m)
                                SNStickerBubble(
                                    m: m,
                                    showAuthor: showAuthors && !m.mine,
                                    showState: showDeliveryState,
                                    onRetry: canRetry ? { onRetry?(m) } : nil,
                                    load: loadSticker,
                                    onTapPack: onTapPack
                                )
                            } else if m.action {
                                Text(verbatim: m.text)
                                    .font(SonarTheme.uiFont(size: 13).italic())
                                    .foregroundColor(SonarTheme.text3)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 9)
                                    .padding(.horizontal, 20)
                            } else {
                                let prev = i > 0 ? msgs[i - 1] : nil
                                let cont = prev != nil && !(prev!.action) && prev!.author == m.author && prev!.mine == m.mine
                                SNMsgBubble(
                                    m: m,
                                    preview: SonarTranscriptDisplayPolicy.preview(m.text),
                                    expandedMessageIDs: $expandedMessageIDs,
                                    showAuthor: showAuthors && !m.mine && !cont,
                                    cont: cont,
                                    showState: m.mine && (i == msgs.count - 1 || m.state == "Couldn't send"),
                                    onRetry: snCanRetryFailedMessage(m) ? { onRetry?(m) } : nil,
                                    maxBubbleWidth: geo.size.width * 0.78,
                                    onTapAuthor: onTapAuthor,
                                    onToggleReaction: onToggleReaction == nil
                                        ? nil
                                        : { emoji in onToggleReaction?(m, emoji) },
                                    onMoreReactions: onMoreReactions == nil
                                        ? nil
                                        : { onMoreReactions?(m) }
                                )
                            }
                            }
                            .onAppear {
                                // An unread-anchored open starts in history without
                                // ever having visited the bottom sentinel; older
                                // pages must still load when the reader scrolls up.
                                guard i == 0, hasLeftBottom || unreadAnchorId != nil,
                                      let loadOlder, !isLoadingOlder else { return }
                                let preserveID = m.id
                                #if os(iOS)
                                let token = continuityBridge.capture(anchorId: preserveID)
                                #endif
                                isLoadingOlder = true
                                Task { @MainActor in
                                    let added = await loadOlder()
                                    isLoadingOlder = false
                                    guard added else { return }
                                    await Task.yield()
                                    #if os(iOS)
                                    if continuityBridge.scrollView != nil {
                                        continuityBridge.restore(token)
                                    } else {
                                        proxy.scrollTo(token.anchorId, anchor: .top)
                                    }
                                    #else
                                    proxy.scrollTo(preserveID, anchor: .top)
                                    #endif
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id("sn-bottom")
                            .onAppear {
                                isNearBottom = true
                                hasReachedBottomOnce = true
                                // Live edge is on screen — fully-read open
                                // recovery can stop re-snapping.
                                needsLiveEdgeOpen = false
                                // Reaching the tail consumes any transient
                                // drag/deceleration marker. Without this, a
                                // composer tap inside the 0.2-second debounce
                                // can make the keyboard shrink look like the
                                // user's scroll-away and incorrectly unpin.
                                isUserScrolling = false
                                userScrollGeneration &+= 1
                                tailPin.tailVisible(itemCount: msgs.count, tailID: msgs.last?.id)
                                guard hasLeftBottom, let loadNewest, !isLoadingNewest else { return }
                                isLoadingNewest = true
                                Task { @MainActor in
                                    await loadNewest()
                                    isLoadingNewest = false
                                }
                            }
                            .onDisappear {
                                isNearBottom = false
                                let action = tailPin.tailHidden(
                                    itemCount: msgs.count,
                                    tailID: msgs.last?.id,
                                    userScrolling: isUserScrolling,
                                    isPrepending: isLoadingOlder
                                )
                                if !tailPin.wasPinned, hasReachedBottomOnce { hasLeftBottom = true }
                                followTail(action, proxy: proxy, animateAppends: feedCaughtUp)
                            }
                    }
                    .padding(EdgeInsets(top: 6, leading: 14, bottom: 10, trailing: 14))
                    // This representable must live inside the scroll content.
                    // A modifier on ScrollView itself is a native sibling, so
                    // ancestor lookup cannot reach UIScrollView/NSScrollView.
                    .background(
                        Group {
                            #if os(iOS)
                            SNUserScrollObserver(
                                onUserScroll: noteUserScroll,
                                onViewportWillChange: { notification in
                                    #if SONAR_KEYBOARD_BENCH
                                    SNKeyboardTailBenchmark.shared.begin(notification)
                                    #endif
                                    let action = tailPin.viewportWillChange(
                                        isNearBottom: isNearBottom,
                                        userScrolling: isUserScrolling,
                                        isPrepending: isLoadingOlder
                                    )
                                    followTail(action, proxy: proxy)
                                },
                                onContentSizeGrow: {
                                    // Long-chat gap: last bubble grows (ImageIO
                                    // thumb / self-size) after sn-bottom already
                                    // cleared open recovery — re-pin while at tail.
                                    guard !isUserScrolling, !isLoadingOlder else { return }
                                    guard needsLiveEdgeOpen || isNearBottom || tailPin.wasPinned else {
                                        return
                                    }
                                    followTail(.snap, proxy: proxy)
                                    if needsLiveEdgeOpen {
                                        snapFullyReadOpen(proxy: proxy)
                                    }
                                },
                                continuityBridge: continuityBridge
                            )
                            #else
                            SNUserScrollObserver(
                                onUserScroll: noteUserScroll,
                                onViewportWillChange: { _ in
                                    let action = tailPin.viewportWillChange(
                                        isNearBottom: isNearBottom,
                                        userScrolling: isUserScrolling,
                                        isPrepending: isLoadingOlder
                                    )
                                    followTail(action, proxy: proxy)
                                }
                            )
                            #endif
                        }
                            .frame(width: 0, height: 0)
                            .accessibilityHidden(true)
                    )
                }
                // Signal fully-read open → bottom of load window. Without this,
                // SwiftUI ScrollView starts at the top and async scrollTo often
                // loses to LazyVStack layout (DM opens mid-history).
                .modifier(SNTranscriptScrollAnchor(bottomAligned: usesBottomScrollAnchor))
                .onAppear {
                    viewportHeightTracker.last = geo.size.height
                    // Signal `scrollToInitialPosition` via shared open policy.
                    resolveUnreadAnchor()
                    switch transcriptOpenAction {
                    case .unreadDivider:
                        needsLiveEdgeOpen = false
                        // Pending unread without a resolved divider id must
                        // not scroll yet (same as pre-policy: neither branch).
                        guard unreadAnchorId != nil else { break }
                        isNearBottom = false
                        tailPin.openInHistory(itemCount: msgs.count, tailID: msgs.last?.id)
                        // The divider enters the hierarchy on the render pass
                        // that applies the state set above; scroll after it.
                        DispatchQueue.main.async {
                            proxy.scrollTo("sn-unread", anchor: .top)
                        }
                    case .liveEdge:
                        // Latch the live edge *before* the first scroll so
                        // hydration / LazyVStack growth can re-snap even when
                        // the first `scrollTo` races an under-measured size.
                        needsLiveEdgeOpen = true
                        snapFullyReadOpen(proxy: proxy)
                        // Second pass after layout; still gated by
                        // `needsLiveEdgeOpen` until `sn-bottom` appears.
                        DispatchQueue.main.async {
                            snapFullyReadOpen(proxy: proxy)
                        }
                    case .jump(let id):
                        needsLiveEdgeOpen = false
                        isNearBottom = false
                        tailPin.openInHistory(itemCount: msgs.count, tailID: msgs.last?.id)
                        DispatchQueue.main.async {
                            proxy.scrollTo(id, anchor: .top)
                        }
                    }
                }
                .onChange(of: unreadCountAtOpen) { _ in
                    // Capture settled (was nil → 0 or N). Drive open from
                    // policy only — never chase the live edge while unset.
                    resolveUnreadAnchor()
                    switch transcriptOpenAction {
                    case .unreadDivider:
                        guard unreadAnchorId != nil else { return }
                        needsLiveEdgeOpen = false
                        isNearBottom = false
                        tailPin.openInHistory(itemCount: msgs.count, tailID: msgs.last?.id)
                        DispatchQueue.main.async {
                            proxy.scrollTo("sn-unread", anchor: .top)
                        }
                    case .liveEdge:
                        needsLiveEdgeOpen = true
                        snapFullyReadOpen(proxy: proxy)
                        DispatchQueue.main.async {
                            snapFullyReadOpen(proxy: proxy)
                        }
                    case .jump(let id):
                        needsLiveEdgeOpen = false
                        isNearBottom = false
                        tailPin.openInHistory(itemCount: msgs.count, tailID: msgs.last?.id)
                        DispatchQueue.main.async {
                            proxy.scrollTo(id, anchor: .top)
                        }
                    }
                }
                .onChange(of: messageRevision) { _ in
                    #if SONAR_KEYBOARD_BENCH && os(iOS)
                    SNKeyboardTailBenchmark.shared.recordMessageRevision(
                        idsVisited: msgs.isEmpty ? 0 : 1
                    )
                    #endif
                    let hadAnchor = unreadAnchorId != nil
                    let wasAbandoned = unreadAnchorAbandoned
                    resolveUnreadAnchor()
                    if !hadAnchor, unreadAnchorId != nil {
                        // A late-merged transport leg just made the divider
                        // resolvable: it owns this scroll, not the tail.
                        needsLiveEdgeOpen = false
                        isNearBottom = false
                        tailPin.openInHistory(itemCount: msgs.count, tailID: msgs.last?.id)
                        DispatchQueue.main.async {
                            proxy.scrollTo("sn-unread", anchor: .top)
                        }
                        return
                    }
                    if !wasAbandoned, unreadAnchorAbandoned {
                        // Unread budget could not place a divider — Signal falls
                        // back to the live edge; start open recovery.
                        needsLiveEdgeOpen = true
                        snapFullyReadOpen(proxy: proxy)
                        return
                    }
                    // While a settled unread divider is still pending, don't
                    // follow merged rows to the bottom — the anchor scroll
                    // would lose the race. Unset capture is provisional live
                    // edge (keep resnapping). Abandoned anchor is not pending.
                    if let unreadCountAtOpen, unreadCountAtOpen > 0,
                       unreadAnchorId == nil, !unreadAnchorAbandoned
                    {
                        return
                    }
                    // Fully-read open recovery: re-snap across hydration and
                    // LazyVStack growth until the sentinel is on screen.
                    if SNTranscriptScrollPolicy.shouldResnapFullyReadOpen(
                        usesBottomScrollAnchor: usesBottomScrollAnchor,
                        needsLiveEdgeOpen: needsLiveEdgeOpen,
                        hasLeftBottom: hasLeftBottom,
                        userScrolling: isUserScrolling,
                        hasTailRow: msgs.last?.id != nil
                    ) {
                        snapFullyReadOpen(proxy: proxy)
                        return
                    }
                    let action = tailPin.itemsChanged(
                        itemCount: msgs.count,
                        tailID: msgs.last?.id,
                        isNearBottom: isNearBottom,
                        userScrolling: isUserScrolling,
                        isPrepending: isLoadingOlder
                    )
                    // Hydration is not a new message: absorb it instantly so a
                    // folded chat never visibly chases its late local rows.
                    followTail(action, proxy: proxy, animateAppends: feedCaughtUp)
                }
                .onChange(of: feedCaughtUp) { caughtUp in
                    guard caughtUp else { return }
                    snapFullyReadOpen(proxy: proxy)
                }
                // Viewport shrink (keyboard/composer) and expand (keyboard
                // dismiss / phantom safe-area clear) both re-anchor while
                // pinned — Signal keeps the tail across either inset change.
                // Only the user's scroll unpins.
                .onChange(of: geo.size.height) { newHeight in
                    let previous = viewportHeightTracker.last
                    viewportHeightTracker.last = newHeight
                    guard previous > 0, abs(newHeight - previous) > 0.5 else { return }
                    // Layout settle during fully-read open (under-measured
                    // LazyVStack growing into the viewport). Still run the
                    // R-009 latch so keyboard during open recovery pins.
                    let action: SNTailPinAction
                    if newHeight < previous {
                        #if SONAR_KEYBOARD_BENCH && os(iOS)
                        SNKeyboardTailBenchmark.shared.recordViewportShrink()
                        #endif
                        action = tailPin.viewportShrank(
                            userScrolling: isUserScrolling,
                            isPrepending: isLoadingOlder
                        )
                    } else {
                        action = tailPin.viewportExpanded(
                            userScrolling: isUserScrolling,
                            isPrepending: isLoadingOlder
                        )
                    }
                    followTail(action, proxy: proxy)
                    if needsLiveEdgeOpen {
                        snapFullyReadOpen(proxy: proxy)
                    }
                }
            }
        }
    }
}

/// Signal-style unread marker: hairlines around a centered label, anchored
/// above the oldest unread row captured at chat-open time.
struct SNUnreadDivider: View {
    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(SonarTheme.text3.opacity(0.25))
                .frame(height: 1)
            Text(verbatim: "Unread messages")
                .font(SonarTheme.uiFont(size: 11.5, weight: .semibold))
                .foregroundColor(SonarTheme.text2)
                .fixedSize()
            Rectangle()
                .fill(SonarTheme.text3.opacity(0.25))
                .frame(height: 1)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Nudge row (components.jsx NudgeMsg / theme.css .bc-nudgemsg)

/// Centered pill for a ⚡TRILL nudge (docs/SONAR-TRILL.md): accent-soft
/// capsule, nudge bell (wiggle on appear), copy per direction:
/// mine "You sent a nudge"; theirs "<peer/author> nudged you — 👋".
struct SNNudgeRow: View {
    let m: SNMessage
    let peerName: String
    /// Multi-member group: attribute the nudge to the message author.
    let group: Bool

    @State private var wiggle = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var label: String {
        if m.mine { return "You sent a nudge" }
        let who = group ? (m.author ?? peerName) : peerName
        return "\(who) nudged you \u{2014} 👋"
    }

    var body: some View {
        HStack(spacing: 7) {
            SNIcon(name: .bell, size: 14, weight: 2.2)
                .foregroundColor(SonarTheme.accentDeep)
                .rotationEffect(.degrees(wiggle ? 0 : -16))
            Text(verbatim: label)
                .font(SonarTheme.uiFont(size: 13, weight: .semibold))
                .foregroundColor(SonarTheme.accentDeep)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .background(Capsule().fill(SonarTheme.accentSoft))
        .frame(maxWidth: .infinity)
        .padding(.top, 9)
        .padding(.horizontal, 20)
        .onAppear {
            if reduceMotion {
                wiggle = true
            } else {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.35)) {
                    wiggle = true
                }
            }
        }
    }
}

// MARK: - Call log row (call.jsx CallLog / theme.css .call-log)

/// Compact, centered surface2 pill shown inline after a call ends. Green
/// phone/videocam glyph (red when missed), label, optional ` · {dur}`, and the
/// time on the right — a 1:1 reproduction of the prototype's CallLog.
struct SNCallLogRow: View {
    let call: SNCallInfo
    let mine: Bool
    let time: String

    private var icon: SNIconName { call.kind == .video ? .videocam : .phone }

    private var label: String {
        if call.missed {
            return call.kind == .video ? "Missed video call" : "Missed call"
        }
        return (mine ? "Outgoing " : "Incoming ") + (call.kind == .video ? "video call" : "call")
    }

    var body: some View {
        HStack(spacing: 9) {
            SNIcon(name: icon, size: 15, weight: 2)
                .foregroundColor(call.missed ? SonarTheme.danger : SonarTheme.green)
            HStack(spacing: 0) {
                Text(verbatim: label)
                    .font(SonarTheme.uiFont(size: 13, weight: .semibold))
                    .foregroundColor(SonarTheme.text)
                if !call.missed, let dur = call.dur {
                    Text(verbatim: " · \(dur)")
                        .font(SonarTheme.uiFont(size: 13))
                        .foregroundColor(SonarTheme.text2)
                }
            }
            Text(verbatim: time)
                .font(SonarTheme.uiFont(size: 11.5))
                .foregroundColor(SonarTheme.text3)
        }
        .padding(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SonarTheme.surface2))
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 10)
    }
}

// MARK: - Composer with "+" actions and "/" command layer

let snCommands: [(String, String)] = [
    ("who", "See who\u{2019}s nearby"),
    ("msg", "Message someone"),
    ("slap", "Classic IRC slap"),
]

let snQuickEmojis: [String] = ["👍", "❤️", "😂", "🔥", "🙏", "👏", "🎉", "👀", "💯", "⚡"]

private struct SNDecodedPlatformImage {
    let image: Image
    let size: CGSize
}

/// Carrier so ImageIO can run off-main without requiring `Image` to be Sendable.
private final class SNThumbBox: @unchecked Sendable {
    let value: SNDecodedPlatformImage?
    init(_ value: SNDecodedPlatformImage?) { self.value = value }
}

/// Longest edge for transcript list thumbnails (Compose `TRANSCRIPT_THUMB_MAX_EDGE_PX`,
/// Signal ThumbnailView parity). Full capture resolution stays for the viewer.
let snTranscriptThumbMaxEdgePx: CGFloat = 1024

/// Decode a platform image (UIImage on iOS, NSImage on macOS) from raw bytes.
/// Prefer [snDecodeTranscriptThumbnail] for list cells — full decode stalls open.
private func snDecodedPlatformImage(_ data: Data) -> SNDecodedPlatformImage? {
    #if canImport(UIKit)
    guard let uiImage = UIImage(data: data) else { return nil }
    return SNDecodedPlatformImage(image: Image(uiImage: uiImage), size: uiImage.size)
    #elseif canImport(AppKit)
    guard let nsImage = NSImage(data: data) else { return nil }
    return SNDecodedPlatformImage(image: Image(nsImage: nsImage), size: nsImage.size)
    #else
    return nil
    #endif
}

func snPlatformImage(_ data: Data) -> Image? {
    snDecodedPlatformImage(data)?.image
}

/// Signal/Compose-style bounded thumbnail: ImageIO never materialises the full
/// ARGB bitmap. Safe to call off the main actor.
private func snDecodeTranscriptThumbnail(
    url: URL,
    maxEdge: CGFloat = snTranscriptThumbMaxEdgePx
) -> SNDecodedPlatformImage? {
    let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
    guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
        return nil
    }
    return snThumbnail(from: source, maxEdge: maxEdge)
}

/// Bounded thumbnail from in-memory bytes (fallback when only `Data` is available).
private func snDecodeTranscriptThumbnail(
    data: Data,
    maxEdge: CGFloat = snTranscriptThumbMaxEdgePx
) -> SNDecodedPlatformImage? {
    let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
    guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
        return nil
    }
    return snThumbnail(from: source, maxEdge: maxEdge)
}

private func snThumbnail(from source: CGImageSource, maxEdge: CGFloat) -> SNDecodedPlatformImage? {
    let thumbOpts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: max(64, Int(maxEdge)),
        kCGImageSourceShouldCacheImmediately: true
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary) else {
        return nil
    }
    let size = CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
    #if canImport(UIKit)
    let ui = UIImage(cgImage: cgImage)
    return SNDecodedPlatformImage(image: Image(uiImage: ui), size: size)
    #elseif canImport(AppKit)
    let ns = NSImage(cgImage: cgImage, size: size)
    return SNDecodedPlatformImage(image: Image(nsImage: ns), size: size)
    #else
    return nil
    #endif
}

private func snFittedMediaSize(_ size: CGSize, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
    guard size.width > 0, size.height > 0 else {
        return CGSize(width: maxWidth * 0.62, height: 150)
    }
    let scale = min(maxWidth / size.width, maxHeight / size.height)
    return CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
}

/// Signal pre-sizes media cells from stored attachment dimensions (Signal-Android
/// ThumbnailView measures from DB width/height; Signal-iOS CVMediaAlbumView from
/// sourceMediaSizePixels) so the decoded image never reflows the transcript.
/// Reserve the exact box the decoded image will occupy; dimension-less media
/// keeps the legacy fixed skeleton box. The decoded thumbnail is rendered INTO
/// this same box (aspect-fit), so a media row's height is a pure function of
/// message data — required by the pre-measured collection host.
func snReservedMediaSize(_ item: SNMediaItem, maxWidth: CGFloat) -> CGSize {
    if item.isGif { return CGSize(width: maxWidth, height: 220) }
    guard let w = item.width, let h = item.height, w > 0, h > 0 else {
        return CGSize(width: maxWidth * 0.62, height: 150)
    }
    return snFittedMediaSize(
        CGSize(width: CGFloat(w), height: CGFloat(h)),
        maxWidth: maxWidth,
        maxHeight: 300
    )
}

private extension Data {
    var snLooksLikeGif: Bool {
        count >= 6 &&
        self[startIndex] == 0x47 &&
        self[index(startIndex, offsetBy: 1)] == 0x49 &&
        self[index(startIndex, offsetBy: 2)] == 0x46 &&
        self[index(startIndex, offsetBy: 3)] == 0x38 &&
        (self[index(startIndex, offsetBy: 4)] == 0x37 || self[index(startIndex, offsetBy: 4)] == 0x39) &&
        self[index(startIndex, offsetBy: 5)] == 0x61
    }
}

private let snGenericAttachmentMime = "application/octet-stream"
private let snPdfAttachmentMime = "application/pdf"

/// MIME used for local presentation and native actions. The encrypted Blossom
/// object intentionally remains application/octet-stream; this only refines
/// decrypted attachment metadata when filename and plaintext signature agree.
func snEffectiveAttachmentMime(declaredMime: String, filename: String, plaintext: Data) -> String {
    let normalized = declaredMime
        .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        .first
        .map(String.init)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? ""
    // Sender-declared application/pdf must still pass the plaintext signature
    // check. Other explicit MIME types remain authoritative for non-PDF media.
    if normalized == snPdfAttachmentMime {
        return snIsVerifiedPDFAttachment(declaredMime: declaredMime, filename: filename, plaintext: plaintext)
            ? snPdfAttachmentMime
            : snGenericAttachmentMime
    }
    if !normalized.isEmpty && normalized != snGenericAttachmentMime { return normalized }
    return snIsVerifiedPDFAttachment(declaredMime: declaredMime, filename: filename, plaintext: plaintext)
        ? snPdfAttachmentMime
        : (normalized.isEmpty ? snGenericAttachmentMime : normalized)
}

/// A PDF declaration or extension is never trusted without matching plaintext.
func snIsVerifiedPDFAttachment(declaredMime: String, filename: String, plaintext: Data) -> Bool {
    let normalized = declaredMime
        .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        .first
        .map(String.init)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? ""
    let hasPDFMetadata = normalized == snPdfAttachmentMime ||
        (filename as NSString).pathExtension.caseInsensitiveCompare("pdf") == .orderedSame
    return hasPDFMetadata && MimeType.pdf.matches(data: plaintext)
}

private struct SNStagedAttachmentPreview: Sendable {
    let fileURL: URL
    let directoryURL: URL
}

/// Write a decrypted native-preview copy off the UI thread. A per-preview
/// directory keeps the visible filename clean while preserving uniqueness.
private func snStageAttachmentPreview(_ data: Data, filename: String) -> SNStagedAttachmentPreview? {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("sonar-media-previews", isDirectory: true)
    let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let file = directory.appendingPathComponent(snSafeAttachmentFilename(filename), isDirectory: false)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: file, options: .atomic)
        #endif
        return SNStagedAttachmentPreview(fileURL: file, directoryURL: directory)
    } catch {
        try? FileManager.default.removeItem(at: directory)
        return nil
    }
}

/// Stage an already-local decrypted attachment under its user-visible filename
/// without round-tripping the payload through `Data`. A hard link is preferred;
/// filesystems that do not support it fall back to a file-to-file copy.
private func snStageAttachmentPreview(sourceURL: URL, filename: String) -> SNStagedAttachmentPreview? {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("sonar-media-previews", isDirectory: true)
    let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let file = directory.appendingPathComponent(snSafeAttachmentFilename(filename), isDirectory: false)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try FileManager.default.linkItem(at: sourceURL, to: file)
        } catch {
            try FileManager.default.copyItem(at: sourceURL, to: file)
        }
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: file.path
        )
        #endif
        return SNStagedAttachmentPreview(fileURL: file, directoryURL: directory)
    } catch {
        try? FileManager.default.removeItem(at: directory)
        return nil
    }
}

func snSafeAttachmentFilename(_ filename: String) -> String {
    let basename = (filename as NSString).lastPathComponent
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let cleaned = String(basename.unicodeScalars.filter {
        !CharacterSet.controlCharacters.contains($0)
    })
    guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return "attachment" }
    return cleaned
}

private func snLogMediaWarning(_ message: String) {
    #if canImport(BitLogger)
    SecureLogger.warning(message, category: .session)
    #else
    print(message)
    #endif
}

private func snLogRecoveredUndecodableImage(_ item: SNMediaItem, bytes: Data) {
    #if os(iOS)
    if item.isImage {
        if item.isGif, !bytes.snLooksLikeGif, UIImage(data: bytes) == nil {
            snLogMediaWarning("SonarMediaView: image bytes recovered but GIF signature and UIImage decode failed bytes=\(bytes.count) name=\(item.filename) mime=\(item.mime); showing original file chip")
        } else if !item.isGif, UIImage(data: bytes) == nil {
            snLogMediaWarning("SonarMediaView: image bytes recovered but UIImage decode failed bytes=\(bytes.count) name=\(item.filename) mime=\(item.mime); showing original file chip")
        }
    }
    #endif
}

struct SNStickerBubble: View {
    let m: SNMessage
    var showAuthor: Bool = false
    var showState: Bool = false
    var onRetry: (() -> Void)? = nil
    /// `(ref, userInitiated)` — userInitiated marks an explicit retry tap.
    var load: ((MarmotService.MarmotStickerRef, Bool) async -> Data?)? = nil
    var onTapPack: ((String) -> Void)? = nil

    @State private var image: PlatformImage?
    @State private var failed = false
    @State private var retryToken = 0

    private var mine: Bool { m.mine }

    private var loadTaskID: String {
        "\(m.stickerRef?.plaintextSha256 ?? "")#\(retryToken)"
    }

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
            if showAuthor, let author = m.author {
                Text(verbatim: author)
                    .font(SonarTheme.uiFont(size: 12, weight: .bold))
                    .foregroundColor(SonarTheme.authorColor(author))
                    .padding(.leading, 6)
            }
            Group {
                if let image {
                    #if os(iOS)
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 120, height: 120)
                    #else
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 120, height: 120)
                    #endif
                } else if failed {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(SonarTheme.surface2)
                            .frame(width: 120, height: 120)
                        Text(verbatim: m.stickerRef?.shortcode ?? "sticker")
                            .font(SonarTheme.uiFont(size: 12))
                            .foregroundColor(SonarTheme.text3)
                    }
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(SonarTheme.surface2)
                            .frame(width: 120, height: 120)
                        ProgressView()
                            .tint(SonarTheme.text3)
                    }
                }
            }
            .onTapGesture {
                if failed, image == nil {
                    // A failed load retries on tap instead of opening the pack
                    // preview: the placeholder is the only recovery affordance.
                    retryToken += 1
                } else if let coord = m.stickerRef?.packCoordinate {
                    onTapPack?(coord)
                }
            }
            if showState, let stateText = m.state {
                SNMessageStatusFooter(stateText: stateText, via: m.via, onRetry: onRetry)
                    .padding(EdgeInsets(top: 1, leading: 4, bottom: 0, trailing: 4))
            }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .padding(.vertical, 3)
        .task(id: loadTaskID) {
            guard let ref = m.stickerRef else { return }
            image = nil
            failed = false
            // The failed placeholder shows after the first miss, but keep
            // retrying on a short bounded schedule: cold opens race the relay
            // connection and receive-time prefetch may land moments later.
            var attempt = 0
            while !Task.isCancelled {
                if let data = await load?(ref, retryToken > 0),
                   let decoded = PlatformImage(data: data) {
                    image = decoded
                    failed = false
                    return
                }
                failed = true
                guard let delay = MarmotChatModel.stickerLoadRetryDelaySeconds(attempt: attempt)
                else { return }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                attempt += 1
            }
        }
    }
}

#if os(iOS)
private typealias PlatformImage = UIImage
#else
private typealias PlatformImage = NSImage
#endif

/// XChat-style thin horizontal bar along the bottom edge of an uploading media bubble.
/// Tap cancels when [onCancel] is set.
private struct SNMediaUploadBar: View {
    let progress: Double
    var onCancel: (() -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.28))
                Capsule()
                    .fill(SonarTheme.accent)
                    .frame(width: max(4, geo.size.width * min(1, max(0, progress))))
            }
        }
        .frame(height: 3)
        .clipShape(Capsule())
        .contentShape(Capsule())
        .onTapGesture { onCancel?() }
        .allowsHitTesting(onCancel != nil)
    }
}

/// Observes the live progress map so UICollectionView cells advance without a
/// heightKey-driven reconfigure (progress is not part of that key).
private struct SNLiveMediaUploadBar: View {
    @ObservedObject var source: SNMediaUploadProgressSource
    let messageId: String
    var fallback: Double? = nil
    var onCancel: (() -> Void)? = nil

    var body: some View {
        if let progress = source.fractions[messageId] ?? fallback {
            SNMediaUploadBar(progress: progress, onCancel: onCancel)
        }
    }
}

struct SNMediaBubble: View {
    let m: SNMessage
    let maxBubbleWidth: CGFloat
    var showState: Bool = false
    var onRetry: (() -> Void)? = nil
    var onCancelUpload: (() -> Void)? = nil
    /// Live progress map; preferred over baked `m.uploadProgress` for cells.
    var uploadProgressSource: SNMediaUploadProgressSource? = nil
    var pipeline: SNMediaPipeline = .unavailable

    @State private var bytes: Data?
    /// Bounded transcript thumbnail (Signal/Compose parity). Body paints this;
    /// full bytes are only kept for GIF / native preview.
    @State private var thumb: SNDecodedPlatformImage?
    @State private var failed = false
    @State private var viewerOpen = false
    @State private var viewerIndex = 0
    @State private var loadAttempt = 0
    @State private var nativePreviewURL: URL?
    @State private var nativePreviewDirectory: URL?

    private var item: SNMediaItem? { m.media.first }
    /// Album = more than one attachment, all images ⇒ render a swipeable card
    /// deck. A mixed image+audio/file message keeps the single-first rendering
    /// (so audio still gets its player), matching pre-album behavior.
    private var isDeck: Bool { m.media.count > 1 && m.media.allSatisfy { $0.isImage } }
    /// Horizontal Blossom bar is photo/album-only (Compose + Signal voice parity).
    private var showsHorizontalUploadBar: Bool {
        m.state == "Uploading" && (isDeck || (item?.isImage == true))
    }
    private var isOutboundPending: Bool {
        m.mine && (m.state == "Sending" || m.state == "Uploading")
    }
    private var prepareKey: String {
        guard let item else { return "" }
        return [item.url, item.groupId, item.localPath ?? ""].joined(separator: "|")
    }
    /// Identity for reload: url + on-disk path (+ gif). Phase-only churn must
    /// not clear an already-decoded thumb (Signal skip-reload).
    private var loadKey: String {
        guard let item else { return "" }
        let state = pipeline.state(item)
        return [
            item.url,
            state.localURL?.path ?? item.localPath ?? "",
            item.isGif ? "gif" : "img",
            String(loadAttempt)
        ].joined(separator: "|")
    }

    var body: some View {
        Group {
            #if os(iOS)
            bubble
                .fullScreenCover(isPresented: $viewerOpen) { viewer }
                .quickLookPreview($nativePreviewURL)
            #else
            bubble
                .sheet(isPresented: $viewerOpen) {
                    viewer.frame(minWidth: 620, minHeight: 520)
                }
                .quickLookPreview($nativePreviewURL)
            #endif
        }
            .onChange(of: nativePreviewURL) { url in
                if url == nil { cleanupNativePreview() }
            }
            .onDisappear { cleanupNativePreview() }
    }

    @ViewBuilder private var viewer: some View {
        if isDeck {
            SNMediaGalleryViewer(
                items: m.media,
                startIndex: viewerIndex,
                caption: m.text,
                load: pipeline.loadLocal
            )
        } else if let item {
            SNMediaViewer(item: item, caption: m.text, initialBytes: bytes, load: pipeline.loadLocal)
        }
    }

    private var bubble: some View {
        HStack(spacing: 0) {
            if m.mine { Spacer(minLength: 40) }
            VStack(alignment: m.mine ? .trailing : .leading, spacing: 4) {
                content
                    .overlay(alignment: .bottom) {
                        // XChat under-image bar is for photos/albums only.
                        // Voice notes use Signal-style Sending + control spinner.
                        if showsHorizontalUploadBar {
                            Group {
                                if let source = uploadProgressSource {
                                    SNLiveMediaUploadBar(
                                        source: source,
                                        messageId: m.id,
                                        fallback: m.uploadProgress,
                                        onCancel: onCancelUpload
                                    )
                                } else if let progress = m.uploadProgress {
                                    SNMediaUploadBar(progress: progress, onCancel: onCancelUpload)
                                }
                            }
                            .padding(.horizontal, 2)
                            .padding(.bottom, 2)
                        }
                    }
                if !m.text.isEmpty {
                    Text(verbatim: m.text)
                        .font(SonarTheme.uiFont(size: 14.5))
                        .foregroundColor(SonarTheme.text)
                        .frame(maxWidth: maxBubbleWidth, alignment: m.mine ? .trailing : .leading)
                }
                Text(verbatim: m.time)
                    .font(SonarTheme.uiFont(size: 10.5))
                    .foregroundColor(SonarTheme.text3)
                if showState, let stateText = m.state {
                    SNMessageStatusFooter(stateText: stateText, via: m.via, onRetry: onRetry)
                }
            }
            if !m.mine { Spacer(minLength: 40) }
        }
        .padding(.horizontal, 2)
        .padding(.top, 7)
        .task(id: prepareKey) {
            guard !isDeck, let item else { return }
            pipeline.prepare(item, item.isImage || item.mime.hasPrefix("audio/"))
        }
        .task(id: loadKey) {
            // Keep an existing thumb across loadKey restarts when the URL is
            // unchanged — only clear when we have nothing to paint yet.
            let keepThumb = thumb != nil
            if !keepThumb {
                bytes = nil
                thumb = nil
            }
            failed = false
            // A deck loads each card's bytes itself (lazy, only visible pages),
            // so the bubble skips the single-item load path.
            guard !isDeck, let item else { return }
            let transfer = pipeline.state(item)
            failed = transfer.phase == .failed
            guard transfer.phase == .available else { return }
            if keepThumb { return }
            if item.isImage, !(item.isGif) {
                // Signal-style: bounded ImageIO thumbnail off-main; never
                // UIImage(data:) full-res in the list body.
                let localURL = transfer.localURL
                let box = await Task.detached(priority: .userInitiated) {
                    if let localURL {
                        return SNThumbBox(snDecodeTranscriptThumbnail(url: localURL))
                    }
                    return SNThumbBox(nil)
                }.value
                if let decoded = box.value {
                    thumb = decoded
                    return
                }
                if let d = await pipeline.loadLocal(item) {
                    let tBox = await Task.detached(priority: .userInitiated) {
                        SNThumbBox(snDecodeTranscriptThumbnail(data: d))
                    }.value
                    if let t = tBox.value {
                        thumb = t
                    } else {
                        snLogRecoveredUndecodableImage(item, bytes: d)
                        failed = true
                    }
                } else {
                    failed = true
                }
                return
            }
            // GIF / audio / file: still need original bytes.
            if let d = await pipeline.loadLocal(item) {
                bytes = d
                if item.isImage { snLogRecoveredUndecodableImage(item, bytes: d) }
            } else {
                failed = true
            }
        }
    }

    @ViewBuilder private var content: some View {
        if isDeck {
            SNMediaDeck(items: m.media, maxBubbleWidth: maxBubbleWidth, pipeline: pipeline) { idx in
                viewerIndex = idx
                viewerOpen = true
            }
        } else if let item, item.isImage {
            if let bytes, item.isGif, bytes.snLooksLikeGif {
                SNGifView(data: bytes)
                    .frame(width: maxBubbleWidth, height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(alignment: .topTrailing) {
                        SNGifBadge().padding(8)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 18))
                    .onTapGesture { viewerOpen = true }
            } else if let thumb {
                // Stable transcript geometry: render into the reserved box
                // (stored dims / fixed skeleton), never the decoded size —
                // decode must not reflow rows under the pre-measured host.
                let size = snReservedMediaSize(item, maxWidth: maxBubbleWidth)
                thumb.image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width, height: size.height)
                    .background(SonarTheme.surface2)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(Color.black.opacity(0.08), lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 18))
                    .onTapGesture { viewerOpen = true }
            } else if failed, pipeline.state(item).phase == .available {
                fileChip(for: item)
            } else {
                let reserved = snReservedMediaSize(item, maxWidth: maxBubbleWidth)
                RoundedRectangle(cornerRadius: 18)
                    .fill(SonarTheme.surface2)
                    .frame(width: reserved.width, height: reserved.height)
                    .overlay {
                        if failed {
                            VStack(spacing: 8) {
                                Text(verbatim: "Couldn't load image")
                                    .font(SonarTheme.uiFont(size: 12))
                                    .foregroundColor(SonarTheme.text3)
                                Button {
                                    if pipeline.state(item).phase == .failed {
                                        pipeline.request(item)
                                    } else {
                                        loadAttempt += 1
                                    }
                                } label: {
                                    Text(verbatim: "Retry")
                                        .font(SonarTheme.uiFont(size: 12, weight: .semibold))
                                        .foregroundColor(SonarTheme.accent)
                                }
                                .buttonStyle(.plain)
                            }
                        } else if pipeline.state(item).phase == .notDownloaded {
                            VStack(spacing: 6) {
                                Image(systemName: "arrow.down.circle")
                                    .font(.system(size: 24, weight: .medium))
                                    .foregroundColor(SonarTheme.accent)
                                Text(verbatim: "Tap to download")
                                    .font(SonarTheme.uiFont(size: 11.5, weight: .semibold))
                                    .foregroundColor(SonarTheme.text3)
                            }
                        } else {
                            ProgressView()
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if item.isGif {
                            SNGifBadge().padding(8)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 18))
                    .onTapGesture { handleTap(item) }
            }
        } else if let item, item.mime.hasPrefix("audio/") {
            SNAudioBubble(
                bytes: bytes,
                seed: item.filename,
                mine: m.mine,
                via: m.via ?? .mesh,
                transfer: pipeline.state(item),
                isSending: isOutboundPending,
                onRequest: { pipeline.request(item) },
                onCancel: { pipeline.cancel(item) }
            )
        } else if let item {
            fileChip(for: item)
        }
    }

    private func fileChip(for item: SNMediaItem) -> some View {
        let transfer = pipeline.state(item)
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8)
                .fill(SonarTheme.accent.opacity(0.18))
                .frame(width: 34, height: 34)
                .overlay(Text(verbatim: "·").font(SonarTheme.uiFont(size: 18, weight: .bold)).foregroundColor(SonarTheme.accent))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: item.filename)
                    .font(SonarTheme.uiFont(size: 13.5, weight: .semibold))
                    .foregroundColor(SonarTheme.text)
                    .lineLimit(1)
                Text(verbatim: transferLabel(transfer, fallback: item.mime))
                    .font(SonarTheme.uiFont(size: 11))
                    .foregroundColor(SonarTheme.text3)
            }
            Spacer(minLength: 6)
            transferIndicator(transfer)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: maxBubbleWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(SonarTheme.surface2))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { handleTap(item) }
    }

    @ViewBuilder
    private func transferIndicator(_ transfer: SNMediaTransferState) -> some View {
        switch transfer.phase {
        case .notDownloaded:
            Image(systemName: "arrow.down.circle")
                .foregroundColor(SonarTheme.accent)
        case .downloading:
            ZStack {
                if let progress = transfer.progress {
                    Circle().stroke(SonarTheme.text3.opacity(0.25), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(SonarTheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                } else {
                    ProgressView().controlSize(.small)
                }
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(SonarTheme.text2)
            }
            .frame(width: 22, height: 22)
        case .available:
            Image(systemName: "arrow.up.right.square")
                .foregroundColor(SonarTheme.accent)
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .foregroundColor(.red)
        }
    }

    private func transferLabel(_ transfer: SNMediaTransferState, fallback: String) -> String {
        switch transfer.phase {
        case .notDownloaded: return "Tap to download"
        case .downloading:
            if let progress = transfer.progress { return "Downloading \(Int(progress * 100))%"
            }
            return "Downloading"
        case .available: return fallback
        case .failed: return "Download failed · tap to retry"
        }
    }

    private func handleTap(_ item: SNMediaItem) {
        switch pipeline.state(item).phase {
        case .notDownloaded, .failed:
            pipeline.request(item)
        case .downloading:
            pipeline.cancel(item)
        case .available:
            if item.isImage {
                viewerOpen = true
            } else {
                openNativePreview(item)
            }
        }
    }

    private func openNativePreview(_ item: SNMediaItem) {
        guard let sourceURL = pipeline.state(item).localURL else { return }
        let filename = item.filename
        Task { @MainActor in
            let staged = await Task.detached(priority: .userInitiated) {
                snStageAttachmentPreview(sourceURL: sourceURL, filename: filename)
            }.value
            guard let staged else { return }
            cleanupNativePreview()
            nativePreviewDirectory = staged.directoryURL
            nativePreviewURL = staged.fileURL
        }
    }

    private func cleanupNativePreview() {
        if let nativePreviewDirectory {
            try? FileManager.default.removeItem(at: nativePreviewDirectory)
        }
        nativePreviewURL = nil
        nativePreviewDirectory = nil
    }
}

/// One image card in a media deck: loads + decodes its own bytes and renders
/// the image FILL-CROPPED into the deck's uniform card frame (every card in
/// the pile shares the exact same size, so the peeks line up like a real photo
/// stack). `dim` darkens peek cards slightly so the front card reads on top.
/// Each card loads lazily so a deck only decodes visited + peeked pages.
private struct SNMediaCardImage: View {
    let item: SNMediaItem
    let width: CGFloat
    let height: CGFloat
    var dim: Double = 0
    var pipeline: SNMediaPipeline

    @State private var bytes: Data?
    @State private var thumb: SNDecodedPlatformImage?
    @State private var failed = false
    @State private var loadAttempt = 0

    private var prepareKey: String {
        [item.url, item.groupId, item.localPath ?? ""].joined(separator: "|")
    }

    private var loadKey: String {
        let transfer = pipeline.state(item)
        return [
            item.url,
            transfer.localURL?.path ?? item.localPath ?? "",
            item.isGif ? "gif" : "img",
            String(loadAttempt)
        ].joined(separator: "|")
    }

    var body: some View {
        cardContent
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
            )
            .overlay(
                // Peek cards get a soft dim so depth reads without hiding the photo.
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.black.opacity(dim))
            )
            .task(id: prepareKey) {
                pipeline.prepare(item, true)
            }
            .task(id: loadKey) {
                let keepThumb = thumb != nil || bytes != nil
                if !keepThumb {
                    bytes = nil
                    thumb = nil
                }
                let transfer = pipeline.state(item)
                failed = transfer.phase == .failed
                guard transfer.phase == .available else { return }
                if keepThumb { return }
                if item.isGif {
                    if let d = await pipeline.loadLocal(item) {
                        bytes = d
                    } else {
                        failed = true
                    }
                    return
                }
                let localURL = transfer.localURL
                let box = await Task.detached(priority: .userInitiated) {
                    if let localURL {
                        return SNThumbBox(snDecodeTranscriptThumbnail(url: localURL))
                    }
                    return SNThumbBox(nil)
                }.value
                if let decoded = box.value {
                    thumb = decoded
                    return
                }
                if let d = await pipeline.loadLocal(item) {
                    let tBox = await Task.detached(priority: .userInitiated) {
                        SNThumbBox(snDecodeTranscriptThumbnail(data: d))
                    }.value
                    if let t = tBox.value { thumb = t } else { failed = true }
                } else {
                    failed = true
                }
            }
    }

    @ViewBuilder private var cardContent: some View {
        if item.isImage, let bytes, item.isGif, bytes.snLooksLikeGif {
            SNGifView(data: bytes)
                .frame(width: width, height: height)
                .overlay(alignment: .topTrailing) { SNGifBadge().padding(8) }
        } else if item.isImage, let thumb {
            thumb.image
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: height)
                .clipped()
        } else if item.isImage, failed, pipeline.state(item).phase == .available {
            // Bytes/thumb failed (corrupt / mislabeled MIME). Fall back to a
            // chip instead of an endless spinner.
            deckFileChip
        } else if item.isImage {
            RoundedRectangle(cornerRadius: 18)
                .fill(SonarTheme.surface2)
                .overlay {
                    if failed, dim == 0 {
                        Button {
                            if pipeline.state(item).phase == .failed {
                                pipeline.request(item)
                            } else {
                                loadAttempt += 1
                            }
                        } label: {
                            Text(verbatim: "Retry")
                                .font(SonarTheme.uiFont(size: 12, weight: .semibold))
                                .foregroundColor(SonarTheme.accent)
                        }
                        .buttonStyle(.plain)
                    } else if pipeline.state(item).phase == .notDownloaded, dim == 0 {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(SonarTheme.accent)
                    } else if !failed {
                        ProgressView()
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if item.isGif { SNGifBadge().padding(8) }
                }
        } else {
            deckFileChip
        }
    }

    private var deckFileChip: some View {
        VStack(spacing: 6) {
            Text(verbatim: item.filename)
                .font(SonarTheme.uiFont(size: 13, weight: .semibold))
                .foregroundColor(SonarTheme.text)
                .lineLimit(1)
            Text(verbatim: item.mime)
                .font(SonarTheme.uiFont(size: 11))
                .foregroundColor(SonarTheme.text3)
        }
        .frame(width: width, height: height)
        .background(RoundedRectangle(cornerRadius: 18).fill(SonarTheme.surface2))
    }
}

/// xChat-style album deck: the front photo card rests on the ACTUAL next
/// photos, peeking out offset + dimmed + shadowed like a real stack of prints.
/// Every card shares one uniform frame so the pile edges line up. Drag the
/// front card left/right to page; tap to open the fullscreen gallery. Paints
/// from the already-loaded local `media` list — the only extra work is the 1–2
/// peeked thumbnails, which are the pages the user swipes to next anyway.
private struct SNMediaDeck: View {
    let items: [SNMediaItem]
    let maxBubbleWidth: CGFloat
    var pipeline: SNMediaPipeline
    var onOpen: (Int) -> Void

    @State private var index = 0
    /// Last page direction: +1 advanced (card slides out left, next in from the
    /// right), -1 went back. Drives the asymmetric slide transition so paging
    /// feels like the xChat "slide the card away" gesture, not a swap.
    @State private var slideDirection: CGFloat = 1
    @GestureState private var dragX: CGFloat = 0

    var body: some View {
        let count = items.count
        let current = min(max(index, 0), count - 1)
        let cardW = maxBubbleWidth * 0.78
        let cardH: CGFloat = 240
        let depths = peekDepths(count: count, current: current)
        // Reserve the deepest-possible overhang so the deck's footprint (and the
        // row below) stays constant while paging, even as the peek count shrinks.
        let maxDepth = min(2, count - 1)
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                // Real next-photo thumbnails behind the front card, deepest first.
                ForEach(Array(depths.reversed()), id: \.self) { depth in
                    SNMediaCardImage(
                        item: items[current + depth],
                        width: cardW,
                        height: cardH,
                        dim: 0.12 + 0.10 * Double(depth),
                        pipeline: pipeline
                    )
                    .scaleEffect(1 - CGFloat(depth) * 0.03, anchor: .topLeading)
                    .offset(x: CGFloat(depth) * 12, y: CGFloat(depth) * 9)
                    .shadow(color: Color.black.opacity(0.10), radius: 4, x: 0, y: 2)
                    .allowsHitTesting(false)
                }
                SNMediaCardImage(item: items[current], width: cardW, height: cardH, pipeline: pipeline)
                    .id(current)
                    // Directional slide: outgoing card exits toward the drag,
                    // incoming enters from the opposite edge. Only animated
                    // paging triggers it (transcript inserts are not animated).
                    .transition(.asymmetric(
                        insertion: .move(edge: slideDirection > 0 ? .trailing : .leading)
                            .combined(with: .opacity),
                        removal: .move(edge: slideDirection > 0 ? .leading : .trailing)
                            .combined(with: .opacity)
                    ))
                    .zIndex(1)
                    .shadow(color: Color.black.opacity(0.14), radius: 6, x: 0, y: 3)
                    .offset(x: dragX)
                    .contentShape(RoundedRectangle(cornerRadius: 18))
                    .onTapGesture { handleTap(current) }
                    .gesture(
                        DragGesture(minimumDistance: 12)
                            .updating($dragX) { value, state, _ in state = value.translation.width }
                            .onEnded { value in
                                let threshold: CGFloat = 56
                                if value.translation.width <= -threshold, current < count - 1 {
                                    slideDirection = 1
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                                        index = current + 1
                                    }
                                } else if value.translation.width >= threshold, current > 0 {
                                    slideDirection = -1
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                                        index = current - 1
                                    }
                                }
                            }
                    )
            }
            // Reserve room for the deepest peek's overhang so following rows
            // don't sit on top of the pile (stable across paging).
            .padding(.trailing, CGFloat(maxDepth) * 12)
            .padding(.bottom, CGFloat(maxDepth) * 9)
            SNDeckDots(count: count, index: current)
        }
    }

    /// Depths (1…2) of peek cards to draw behind the front card, capped by how
    /// many items remain — so the pile visibly shrinks toward the last photo.
    private func peekDepths(count: Int, current: Int) -> [Int] {
        let remaining = count - 1 - current
        let visible = min(2, max(0, remaining))
        return visible == 0 ? [] : Array(1...visible)
    }

    private func handleTap(_ index: Int) {
        let item = items[index]
        switch pipeline.state(item).phase {
        case .notDownloaded, .failed:
            pipeline.request(item)
        case .downloading:
            pipeline.cancel(item)
        case .available:
            onOpen(index)
        }
    }
}

/// Compact page-position dots under a media deck.
private struct SNDeckDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(0..<max(count, 0)), id: \.self) { i in
                Circle()
                    .fill(i == index ? SonarTheme.accent : SonarTheme.text3.opacity(0.4))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.leading, 4)
    }
}

/// Fullscreen, swipeable gallery across a message's album. Each page is a full
/// [SNMediaViewer] (lazy load, pinch-zoom, share, save); paging is native. Opens
/// at the tapped card's index.
struct SNMediaGalleryViewer: View {
    let items: [SNMediaItem]
    let startIndex: Int
    let caption: String
    var load: ((SNMediaItem) async -> Data?)? = nil

    // Seeded in init (not onAppear) so the pager opens ON the tapped photo
    // instead of flashing page 0 for a frame.
    @State private var selection: Int

    init(
        items: [SNMediaItem],
        startIndex: Int,
        caption: String,
        load: ((SNMediaItem) async -> Data?)? = nil
    ) {
        self.items = items
        self.startIndex = startIndex
        self.caption = caption
        self.load = load
        _selection = State(initialValue: min(max(startIndex, 0), max(items.count - 1, 0)))
    }

    private var safeIndex: Int { min(max(selection, 0), max(items.count - 1, 0)) }

    var body: some View {
        #if os(iOS)
        TabView(selection: $selection) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                SNMediaViewer(item: item, caption: caption, initialBytes: nil, load: load)
                    .tag(idx)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .background(Color.black.ignoresSafeArea())
        #else
        ZStack {
            Color.black
            SNMediaViewer(item: items[safeIndex], caption: caption, initialBytes: nil, load: load)
            HStack {
                Button { selection = max(safeIndex - 1, 0) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 22, weight: .semibold))
                }
                .disabled(safeIndex == 0)
                Spacer()
                Button { selection = min(safeIndex + 1, items.count - 1) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 22, weight: .semibold))
                }
                .disabled(safeIndex >= items.count - 1)
            }
            .padding(.horizontal, 18)
            .buttonStyle(.plain)
            .foregroundColor(.white)
            VStack {
                Spacer()
                SNDeckDots(count: items.count, index: safeIndex).padding(.bottom, 12)
            }
        }
        #endif
    }
}

/// Fullscreen media viewer: tap inline media to inspect it, pinch/double-tap to
/// zoom images, then share or save the decrypted bytes with native OS surfaces.
struct SNMediaViewer: View {
    let item: SNMediaItem
    let caption: String
    let initialBytes: Data?
    var load: ((SNMediaItem) async -> Data?)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var bytes: Data?
    @State private var failed = false
    @State private var chrome = true
    @State private var status: String?
    @State private var tempURLs: [URL] = []
    @State private var loadAttempt = 0
    @State private var previewURL: URL?
    @State private var previewFileURL: URL?
    @State private var previewDirectoryURL: URL?
    @State private var autoPreviewedPDF = false

    #if os(iOS)
    @State private var shareItems: [Any] = []
    @State private var showShare = false
    @State private var exportURL: URL?
    @State private var showExport = false
    #else
    @State private var shareURL: URL?
    #endif

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if chrome {
                viewerChrome
                    .transition(.opacity)
            }
        }
        .task(id: [item.url, item.groupId, item.localPath ?? "", String(loadAttempt)].joined(separator: "|")) {
            failed = false
            status = nil
            autoPreviewedPDF = false
            if let initialBytes {
                bytes = initialBytes
                await previewPDFIfNeeded(initialBytes)
                return
            }
            bytes = nil
            guard let load else {
                failed = true
                return
            }
            if let data = await load(item) {
                bytes = data
                await previewPDFIfNeeded(data)
            } else {
                failed = true
            }
        }
        .quickLookPreview($previewURL)
        .onChange(of: previewURL) { url in
            if url == nil { cleanupNativePreview() }
        }
        .onDisappear {
            cleanupNativePreview()
            tempURLs.forEach { try? FileManager.default.removeItem(at: $0) }
            tempURLs = []
        }
        #if os(iOS)
        .sheet(isPresented: $showShare) {
            SNActivityView(items: shareItems)
        }
        .sheet(isPresented: $showExport) {
            if let exportURL {
                SNDocumentExportView(url: exportURL)
            }
        }
        #else
        .background(SNMacSharePicker(url: $shareURL))
        #endif
    }

    @ViewBuilder private var content: some View {
        if let bytes, item.isImage, let image = snPlatformImage(bytes) {
            SNZoomableMediaImage(image: image) {
                withAnimation(.easeInOut(duration: 0.16)) { chrome.toggle() }
            }
            .padding(.horizontal, 4)
        } else if bytes != nil {
            VStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.10))
                    .frame(width: 74, height: 74)
                    .overlay(
                        Text(verbatim: effectiveMime.hasPrefix("video/") ? "▶" : "·")
                            .font(SonarTheme.uiFont(size: 30, weight: .bold))
                            .foregroundColor(.white.opacity(0.86))
                    )
                Text(verbatim: item.filename)
                    .font(SonarTheme.uiFont(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 28)
                Text(verbatim: effectiveMime)
                    .font(SonarTheme.uiFont(size: 12))
                    .foregroundColor(.white.opacity(0.62))
                Button {
                    openMedia()
                } label: {
                    Text(verbatim: "Open")
                        .font(SonarTheme.uiFont(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Color.white.opacity(0.16)))
                }
                .buttonStyle(.plain)
            }
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.16)) { chrome.toggle() }
            }
        } else {
            VStack(spacing: 12) {
                if failed {
                    Text(verbatim: "Couldn't load media")
                        .font(SonarTheme.uiFont(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.82))
                    Button {
                        loadAttempt += 1
                    } label: {
                        Text(verbatim: "Retry")
                            .font(SonarTheme.uiFont(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .background(Capsule().fill(Color.white.opacity(0.16)))
                    }
                    .buttonStyle(.plain)
                } else {
                    ProgressView()
                }
            }
        }
    }

    private var viewerChrome: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: item.filename)
                        .font(SonarTheme.uiFont(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if !caption.isEmpty {
                        Text(verbatim: caption)
                            .font(SonarTheme.uiFont(size: 12))
                            .foregroundColor(.white.opacity(0.62))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Button("Share") { shareMedia() }
                    .font(SonarTheme.uiFont(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .disabled(bytes == nil)
                Button("Save") { saveMedia() }
                    .font(SonarTheme.uiFont(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .disabled(bytes == nil)
            }
            .padding(EdgeInsets(top: 12, leading: 12, bottom: 10, trailing: 12))
            .background(Color.black.opacity(0.58))
            Spacer()
            if let status {
                Text(verbatim: status)
                    .font(SonarTheme.uiFont(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.black.opacity(0.62)))
                    .padding(.bottom, 22)
            }
        }
    }

    private func shareMedia() {
        guard let url = writeTempFile() else { return }
        #if os(iOS)
        shareItems = [url]
        showShare = true
        #else
        shareURL = url
        #endif
    }

    private func saveMedia() {
        #if os(iOS)
        if item.mime.hasPrefix("image/"), let data = bytes {
            guard UIImage(data: data) != nil else {
                snLogMediaWarning("SonarMediaView: Photos save skipped because image decode failed bytes=\(data.count) name=\(item.filename) mime=\(item.mime); exporting original file")
                exportOriginalFile()
                return
            }
            let resourceOptions = PHAssetResourceCreationOptions()
            resourceOptions.originalFilename = safeFilename
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: resourceOptions)
            }) { ok, _ in
                DispatchQueue.main.async {
                    if ok {
                        status = "Saved to Photos"
                    } else {
                        snLogMediaWarning("SonarMediaView: Photos image save failed name=\(item.filename) mime=\(item.mime); exporting original file")
                        exportOriginalFile()
                    }
                }
            }
        } else if item.mime.hasPrefix("video/"), let url = writeTempFile(track: false) {
            let resourceOptions = PHAssetResourceCreationOptions()
            resourceOptions.originalFilename = safeFilename
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: url, options: resourceOptions)
            }) { ok, _ in
                try? FileManager.default.removeItem(at: url)
                DispatchQueue.main.async {
                    if ok {
                        status = "Saved to Photos"
                    } else {
                        snLogMediaWarning("SonarMediaView: Photos video save failed name=\(item.filename) mime=\(item.mime); exporting original file")
                        exportOriginalFile()
                    }
                }
            }
        } else {
            exportMedia()
        }
        #else
        guard let data = bytes else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = safeFilename
        panel.prompt = "Save"
        if panel.runModal() == .OK, let destination = panel.url {
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try data.write(to: destination, options: .atomic)
                status = "Saved"
            } catch {
                status = "Couldn't save media"
            }
        }
        #endif
    }

    private func exportMedia() {
        #if os(iOS)
        guard let url = writeTempFile() else { return }
        exportURL = url
        showExport = true
        #else
        saveMedia()
        #endif
    }

    private func exportOriginalFile() {
        status = "Choose where to save"
        exportMedia()
    }

    private func openMedia() {
        guard let data = bytes else { return }
        Task { @MainActor in
            await presentNativePreview(data)
        }
    }

    private var effectiveMime: String {
        guard let bytes else {
            return item.mime.split(separator: ";", maxSplits: 1).first.map(String.init) ?? item.mime
        }
        return snEffectiveAttachmentMime(
            declaredMime: item.mime,
            filename: item.filename,
            plaintext: bytes
        )
    }

    @MainActor
    private func previewPDFIfNeeded(_ data: Data) async {
        guard !autoPreviewedPDF,
              snIsVerifiedPDFAttachment(
                declaredMime: item.mime,
                filename: item.filename,
                plaintext: data
              ) else { return }
        autoPreviewedPDF = true
        await presentNativePreview(data)
    }

    @MainActor
    private func presentNativePreview(_ data: Data) async {
        if let previewFileURL, FileManager.default.fileExists(atPath: previewFileURL.path) {
            previewURL = previewFileURL
            return
        }
        let filename = safeFilename
        let staged = await Task.detached(priority: .userInitiated) {
            snStageAttachmentPreview(data, filename: filename)
        }.value
        guard let staged else {
            status = "Couldn't prepare media"
            return
        }
        previewFileURL = staged.fileURL
        previewDirectoryURL = staged.directoryURL
        previewURL = staged.fileURL
    }

    private func cleanupNativePreview() {
        if let previewDirectoryURL {
            try? FileManager.default.removeItem(at: previewDirectoryURL)
        }
        previewURL = nil
        previewFileURL = nil
        previewDirectoryURL = nil
    }

    private var safeFilename: String {
        snSafeAttachmentFilename(item.filename)
    }

    private func writeTempFile(track: Bool = true) -> URL? {
        guard let data = bytes else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonar-media-exports", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(UUID().uuidString)-\(safeFilename)")
            #if os(iOS)
            let options: Data.WritingOptions = [.atomic, .completeFileProtection]
            #else
            let options: Data.WritingOptions = .atomic
            #endif
            try data.write(to: url, options: options)
            if track {
                tempURLs.append(url)
            }
            return url
        } catch {
            status = "Couldn't prepare media"
            return nil
        }
    }
}

private struct SNZoomableMediaImage: View {
    let image: Image
    let onSingleTap: () -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        image
            .resizable()
            .aspectRatio(contentMode: .fit)
            .scaleEffect(scale)
            .offset(offset)
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        scale = min(max(lastScale * value, 1), 8)
                    }
                    .onEnded { _ in
                        lastScale = scale
                        if scale <= 1.01 { resetZoom(animated: true) }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        guard scale > 1 else { return }
                        offset = CGSize(
                            width: lastOffset.width + value.translation.width,
                            height: lastOffset.height + value.translation.height
                        )
                    }
                    .onEnded { _ in
                        lastOffset = offset
                    }
            )
            .gesture(
                TapGesture(count: 2)
                    .onEnded {
                        if scale > 1 {
                            resetZoom(animated: true)
                        } else {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                scale = 2.5
                                lastScale = 2.5
                            }
                        }
                    }
                    .exclusively(before: TapGesture(count: 1).onEnded { onSingleTap() })
            )
    }

    private func resetZoom(animated: Bool) {
        let changes = {
            scale = 1
            lastScale = 1
            offset = .zero
            lastOffset = .zero
        }
        if animated {
            withAnimation(.easeInOut(duration: 0.18), changes)
        } else {
            changes()
        }
    }
}

#if os(iOS)
private struct SNActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct SNDocumentExportView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: [url])
        controller.shouldShowFileExtensions = true
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
}
#else
private struct SNMacSharePicker: NSViewRepresentable {
    @Binding var url: URL?

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let url else { return }
        DispatchQueue.main.async {
            NSSharingServicePicker(items: [url])
                .show(relativeTo: nsView.bounds, of: nsView, preferredEdge: .minY)
            self.url = nil
        }
    }
}
#endif

struct SNGifBadge: View {
    var body: some View {
        Text(verbatim: "GIF")
            .font(SonarTheme.monoFont(size: 10, weight: .black))
            .foregroundColor(SonarTheme.onNet)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(SonarTheme.netFill))
    }
}

struct SNGifView: View {
    let data: Data

    var body: some View {
        SNGifWebView(data: data)
    }
}

#if os(iOS)
struct SNGifWebView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        view.loadHTMLString(html, baseURL: nil)
    }

    private var html: String {
        let base64 = data.base64EncodedString()
        return """
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>html,body{margin:0;width:100%;height:100%;background:transparent;overflow:hidden;}body{display:flex;align-items:center;justify-content:center;}img{max-width:100%;max-height:100%;object-fit:contain;}</style>
        </head><body><img src="data:image/gif;base64,\(base64)" /></body></html>
        """
    }
}
#elseif os(macOS)
struct SNGifWebView: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero)
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        view.loadHTMLString(html, baseURL: nil)
    }

    private var html: String {
        let base64 = data.base64EncodedString()
        return """
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>html,body{margin:0;width:100%;height:100%;background:transparent;overflow:hidden;}body{display:flex;align-items:center;justify-content:center;}img{max-width:100%;max-height:100%;object-fit:contain;}</style>
        </head><body><img src="data:image/gif;base64,\(base64)" /></body></html>
        """
    }
}
#endif

/// "Around you" card (design: screens.jsx HereCard) — collapses the geohash
/// precision ladder (+ Mesh) into ONE row plus a tier picker. The main row enters
/// the selected channel; the ladder ticks pick precision (live green dot when
/// someone's there). Deviation: Mesh is included as the first tick (a real
/// "around you" channel on this platform; the web ladder is geohash-only).
struct SNHereCard: View {
    let channels: [SNChannelItem]
    let onEnter: (SNChannelItem) -> Void
    @State private var idx: Int = 0

    private var defaultIdx: Int {
        channels.firstIndex(where: { $0.count > 0 }) ?? max(0, channels.count - 1)
    }

    var body: some View {
        if channels.isEmpty {
            SNEmptyState(icon: .pin, iconSize: 22,
                         title: "Nothing around you yet",
                         desc: "Grant location to see public channels nearby, or use the radar to find people over Bluetooth.")
                .padding(.vertical, 18)
        } else {
            let sel = channels[min(idx, channels.count - 1)]
            VStack(spacing: 0) {
                Button { onEnter(sel) } label: {
                    HStack(spacing: 12) {
                        SNPlaceTile(size: 52, icon: sel.id == "mesh" ? .mesh : .pin)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: sel.name)
                                .font(SonarTheme.uiFont(size: 16.5, weight: .semibold))
                                .foregroundColor(SonarTheme.text).lineLimit(1)
                            Text(verbatim: "\(sel.tier) · \(sel.count) here now")
                                .font(SonarTheme.uiFont(size: 14))
                                .foregroundColor(SonarTheme.text2).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        SNIcon(name: .chevron, size: 15, weight: 2.2).foregroundColor(SonarTheme.text3)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SNScaleStyle(scale: 0.99))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(channels.enumerated()), id: \.element.id) { i, ch in
                            Button { idx = i } label: {
                                HStack(spacing: 4) {
                                    Text(verbatim: ch.tier.isEmpty ? ch.name : ch.tier)
                                        .font(SonarTheme.uiFont(size: 12.5, weight: i == idx ? .semibold : .regular))
                                        .foregroundColor(i == idx ? SonarTheme.text : SonarTheme.text3)
                                    if ch.count > 0 {
                                        Circle().fill(SonarTheme.green).frame(width: 5, height: 5)
                                    }
                                }
                                .padding(.horizontal, 11).padding(.vertical, 6)
                                .background(Capsule().fill(i == idx ? SonarTheme.surface2 : Color.clear))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14).padding(.bottom, 6)
                }
            }
            .onAppear { idx = defaultIdx }
        }
    }
}

/// Audio / voice-note bubble (design: MediaBubble `media-audio` — play button +
/// `MediaWave` + duration). Plays the decrypted bytes via AVAudioPlayer.
/// Deviation: the flat play triangle uses an SF Symbol (`play.fill`/`pause.fill`),
/// the platform idiom for a media transport control.
struct SNAudioBubble: View {
    let bytes: Data?
    let seed: String
    let mine: Bool
    var via: SNVia = .mesh
    var transfer: SNMediaTransferState = .notDownloaded
    /// Outbound Blossom/mesh send in flight — Signal-style spinner on the play control.
    var isSending: Bool = false
    var onRequest: () -> Void = {}
    var onCancel: () -> Void = {}

    @StateObject private var player = SNAudioPlayer()

    private var tint: Color { via == .internet ? SonarTheme.netFill : SonarTheme.accentFill }

    var body: some View {
        HStack(spacing: 11) {
            Button {
                guard !isSending else { return }
                switch transfer.phase {
                case .notDownloaded, .failed:
                    onRequest()
                case .downloading:
                    onCancel()
                case .available:
                    player.toggle(bytes)
                }
            } label: {
                Circle().fill(mine ? tint : SonarTheme.surface)
                    .frame(width: 34, height: 34)
                    .overlay { audioControl }
            }
            .buttonStyle(SNScaleStyle(scale: 0.92))
            .disabled(isSending)
            SNMediaWave(seed: seed).frame(width: 124, height: 22)
            Text(verbatim: durationText)
                .font(SonarTheme.monoFont(size: 11.5))
                .foregroundColor(SonarTheme.text3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 18).fill(mine ? tint.opacity(0.15) : SonarTheme.surface2))
    }

    private var isPlaying: Bool { player.playing }
    private var durationText: String { snFmtDur(Int(player.duration.rounded())) }

    @ViewBuilder private var audioControl: some View {
        let color = mine
            ? (via == .internet ? SonarTheme.onNet : SonarTheme.onAccent)
            : SonarTheme.accent
        if isSending {
            ProgressView().controlSize(.small).tint(color)
        } else {
            switch transfer.phase {
            case .notDownloaded:
                Image(systemName: "arrow.down")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(color)
            case .downloading:
                ZStack {
                    if let progress = transfer.progress {
                        Circle().stroke(color.opacity(0.28), lineWidth: 2)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    } else {
                        ProgressView().controlSize(.small).tint(color)
                    }
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(color)
                }
                .padding(5)
            case .available:
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(color)
            case .failed:
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(color)
            }
        }
    }
}

/// Static waveform (design: `MediaWave` — deterministic hash bars).
struct SNMediaWave: View {
    let seed: String
    private func bars() -> [CGFloat] {
        var h: UInt32 = 2166136261
        for b in seed.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return (0..<34).map { i in
            let v = (h >> UInt32(i % 28)) ^ (h &* UInt32(i + 3))
            return 0.22 + CGFloat(v & 15) / 15 * 0.78
        }
    }
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(Array(bars().enumerated()), id: \.offset) { _, v in
                    Capsule().fill(SonarTheme.text2.opacity(0.5)).frame(width: 2, height: geo.size.height * v)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }
}

/// Minimal AVAudioPlayer wrapper for the audio bubble (iOS + native macOS Sonar.app).
@MainActor
final class SNAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playing = false
    @Published private(set) var duration: TimeInterval = 0
    private var player: AVAudioPlayer?

    func toggle(_ bytes: Data?) {
        if playing { player?.pause(); playing = false; return }
        if player == nil, let bytes {
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            #endif
            player = try? AVAudioPlayer(data: bytes)
            player?.delegate = self
            duration = player?.duration ?? 0
        }
        guard player?.play() == true else {
            playing = false
            return
        }
        playing = true
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playing = false }
    }
}

/// Prepare a composer send: trim payload and require an empty draft before the
/// send/command callback runs. The UIKit transcript host refreshes the hosted
/// composer synchronously inside that callback; clearing after can re-bind the
/// pre-send text. Compose already clears draft before send.
func snPrepareComposerSend(text: String) -> String? {
    let payload = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return payload.isEmpty ? nil : payload
}

/// Session-scoped per-chat draft map update. Empty text removes the entry so
/// navigating away and back restores only real in-progress drafts.
func snUpdatedComposerDrafts(
    drafts: [String: String],
    chatId: String,
    text: String
) -> [String: String] {
    var next = drafts
    if text.isEmpty {
        next.removeValue(forKey: chatId)
    } else {
        next[chatId] = text
    }
    return next
}

/// Boundary mirror for the composer send/mic toggle: true while the chat's
/// draft trims to non-empty. Returns the input unchanged off the boundary so
/// callers can avoid publishing on every keystroke (see composerDrafts).
/// Single source of truth for "draft counts as text" -- shared by the
/// composer's send/mic toggle (SNComposer.hasText) and the published boundary
/// mirror so the two can never diverge.
func snComposerHasText(_ text: String) -> Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

func snUpdatedComposerDraftHasText(
    flags: [String: Bool],
    chatId: String,
    text: String
) -> [String: Bool] {
    let hasText = snComposerHasText(text)
    guard (flags[chatId] ?? false) != hasText else { return flags }
    var next = flags
    next[chatId] = hasText
    return next
}

struct SNComposer: View {
    @Binding var text: String
    let placeholder: String
    let transport: SNVia
    let onSend: (String) -> Void
    let onPlus: () -> Void
    let onCommand: (String) -> Void
    var onSticker: (StickerInfo, String) -> Void = { _, _ in }
    var loadStickerPack: (String, String, [String]) async -> StickerPackInfo? = { _, _, _ in nil }
    var loadStickerImage: (String, String) async -> Data? = { _, _ in nil }
    var fetchInstalledPacks: () async -> [String]? = { [] }
    var cachedStickerPacks: () -> [StickerPackInfo] = { [] }
    var voiceEnabled: Bool = true
    /// Hold-to-record produced a voice note at this file URL (audio/mp4 .m4a).
    var onVoice: (URL) -> Void = { _ in }

    @State private var showEmojiTray = false
    @State private var stickerPacks: [StickerPackInfo] = []
    @FocusState private var composerFocused: Bool
    #if os(iOS)
    @StateObject private var voice = VoiceNoteRecorder()
    @State private var recording = false
    @State private var dragX: CGFloat = 0
    @State private var voiceError: String?
    @State private var recordingStartTask: Task<Bool, Never>?
    private var cancelArmed: Bool { dragX < -100 }
    #endif

    private var slash: Bool { text.hasPrefix("/") }
    private var hasText: Bool { snComposerHasText(text) }
    /// Soft-IME platforms only. macOS shares `SNComposer` but has no system
    /// keyboard occupying the transcript — do not steal hardware-keyboard focus.
    private var usesSoftKeyboard: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    private func dismissKeyboardForEmojiTray() {
        #if os(iOS)
        composerFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        #endif
    }

    private func toggleEmojiTray() {
        let opening = !showEmojiTray
        if snShouldDismissKeyboardWhenOpeningEmojiTray(
            openingTray: opening,
            usesSoftKeyboard: usesSoftKeyboard
        ) {
            dismissKeyboardForEmojiTray()
        }
        if opening {
            stickerPacks = cachedStickerPacks()
        }
        showEmojiTray = opening
    }

    private func send() {
        guard let tx = snPrepareComposerSend(text: text) else { return }
        // Clear before the send callback (see snPrepareComposerSend).
        text = ""
        showEmojiTray = false
        if tx.hasPrefix("/") {
            let cmd = tx.dropFirst().split(separator: " ").first.map(String.init)?.lowercased() ?? ""
            onCommand(cmd)
        } else {
            onSend(tx)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if slash {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(snCommands, id: \.0) { cmd, desc in
                            Button {
                                text = ""
                                onCommand(cmd)
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: "/" + cmd)
                                        .font(SonarTheme.monoFont(size: 13, weight: .medium))
                                        .foregroundColor(SonarTheme.accentDeep)
                                    Text(verbatim: desc)
                                        .font(SonarTheme.uiFont(size: 11))
                                        .foregroundColor(SonarTheme.text2)
                                }
                                .padding(EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12))
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SonarTheme.surface2))
                            }
                            .buttonStyle(SNScaleStyle(scale: 0.97))
                        }
                    }
                    .padding(EdgeInsets(top: 8, leading: 12, bottom: 2, trailing: 12))
                }
            }
            if showEmojiTray && !slash {
                SonarEmojiPickerView(
                    onEmoji: { text += $0 },
                    onSticker: { sticker, coord in
                        showEmojiTray = false
                        onSticker(sticker, coord)
                    },
                    loadStickerPack: loadStickerPack,
                    loadStickerImage: loadStickerImage,
                    fetchInstalledPacks: fetchInstalledPacks,
                    onClose: { showEmojiTray = false },
                    stickerPacks: $stickerPacks
                )
            }
            #if os(iOS)
            if let voiceError {
                HStack {
                    Text(verbatim: voiceError)
                        .font(SonarTheme.uiFont(size: 12.5, weight: .medium))
                        .foregroundColor(SonarTheme.danger)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            #endif
            inputRow
        }
        .background(SonarTheme.bg)
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            #if os(iOS)
            if recording {
                recordingStatus
            } else {
                composeFields
            }
            if hasText && !recording {
                sendButton
            } else if voiceEnabled {
                micButton
            } else {
                sendButton
            }
            #else
            composeFields
            sendButton
            #endif
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
    }

    private var composeFields: some View {
        Group {
            Button(action: onPlus) {
                Circle()
                    .fill(SonarTheme.surface2)
                    .frame(width: 36, height: 36)
                    .overlay(
                        SNIcon(name: .plus, size: 19, weight: 2.1)
                            .foregroundColor(SonarTheme.text2)
                    )
            }
            .buttonStyle(SNScaleStyle(scale: 0.92))

            HStack {
                SNMessageComposerField(
                    text: $text,
                    prompt: Text(verbatim: placeholder).foregroundColor(SonarTheme.text3),
                    onSend: send
                )
                    .textFieldStyle(.plain)
                    .font(SonarTheme.uiFont(size: 16))
                    .foregroundColor(SonarTheme.text)
                    .focused($composerFocused)
                    .onChange(of: composerFocused) { focused in
                        if snShouldCloseEmojiTrayOnComposerFocus(
                            composerFocused: focused,
                            trayOpen: showEmojiTray,
                            usesSoftKeyboard: usesSoftKeyboard
                        ) {
                            showEmojiTray = false
                        }
                    }
                    .accessibilityIdentifier("sonar-message-composer")
                Button(action: toggleEmojiTray) {
                    SNIcon(name: .smile, size: 19, weight: 2)
                        .foregroundColor(showEmojiTray ? SonarTheme.accent : SonarTheme.text3)
                }
                .buttonStyle(SNScaleStyle(scale: 0.94))
                .accessibilityIdentifier("sonar-emoji-tray-toggle")
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(SonarTheme.surface2))
        }
    }

    private var sendButton: some View {
        Button(action: send) {
            Circle()
                .fill(hasText ? (transport == .internet ? SonarTheme.netFill : SonarTheme.accentFill) : SonarTheme.surface2)
                .frame(width: 34, height: 34)
                .overlay(
                    SNIcon(name: .send, size: 17, weight: 2.3)
                        .foregroundColor(hasText ? (transport == .internet ? SonarTheme.onNet : SonarTheme.onAccent) : SonarTheme.text3)
                )
                .padding(.bottom, 1)
        }
        .buttonStyle(SNScaleStyle(scale: 0.92))
        .accessibilityIdentifier("sonar-message-send")
        .disabled(!hasText)
    }

    #if os(iOS)
    /// Hold-to-record mic (design: bc-sendbtn mic). Press starts recording; drag
    /// left past the threshold cancels; release sends the note.
    private var micButton: some View {
        let net = transport == .internet
        return Circle()
            .fill(recording ? (net ? SonarTheme.netFill : SonarTheme.accentFill) : SonarTheme.surface2)
            .frame(width: 34, height: 34)
            .overlay(
                SNIcon(name: .mic, size: 18, weight: 2)
                    .foregroundColor(recording ? (net ? SonarTheme.onNet : SonarTheme.onAccent) : SonarTheme.text2)
            )
            .padding(.bottom, 1)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !recording {
                            beginVoiceRecording()
                        } else {
                            dragX = min(0, g.translation.width)
                        }
                    }
                    .onEnded { _ in
                        endVoiceRecording(send: true)
                    }
            )
    }

    private func beginVoiceRecording() {
        recording = true
        dragX = 0
        voiceError = nil
        recordingStartTask = Task { await voice.start() }
    }

    private func endVoiceRecording(send: Bool) {
        let cancel = cancelArmed || !send
        let startTask = recordingStartTask
        recordingStartTask = nil
        Task { @MainActor in
            let started: Bool
            if let startTask {
                started = await startTask.value
            } else {
                started = false
            }
            recording = false
            dragX = 0
            guard started else {
                voice.cancel()
                showVoiceError("Microphone access is needed for voice notes.")
                return
            }
            if cancel {
                voice.cancel()
            } else if let url = voice.finish() {
                onVoice(url)
            }
        }
    }

    private func showVoiceError(_ message: String) {
        voiceError = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            if voiceError == message {
                voiceError = nil
            }
        }
    }

    /// The Telegram/Signal-style recording status (design: VoiceRecorder): trash,
    /// rec dot, timer, live waveform and slide-to-cancel hint.
    private var recordingStatus: some View {
        HStack(alignment: .center, spacing: 8) {
            Button { endVoiceRecording(send: false) } label: {
                SNIcon(name: .trash, size: 19, weight: 2).foregroundColor(SonarTheme.danger)
            }
            HStack(spacing: 9) {
                Circle().fill(SonarTheme.danger).frame(width: 9, height: 9)
                Text(verbatim: snFmtDur(voice.elapsed))
                    .font(SonarTheme.monoFont(size: 13, weight: .medium))
                    .foregroundColor(SonarTheme.text)
                    .frame(width: 38, alignment: .leading)
                SNLiveWave(level: voice.level)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
                HStack(spacing: 3) {
                    SNIcon(name: .chevron, size: 12, weight: 2.4).foregroundColor(SonarTheme.text3)
                        .rotationEffect(.degrees(180))
                    Text(verbatim: cancelArmed ? "release to cancel" : "slide to cancel")
                        .font(SonarTheme.uiFont(size: 12))
                        .foregroundColor(cancelArmed ? SonarTheme.danger : SonarTheme.text3)
                }
                .opacity(1 + dragX / 110)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(SonarTheme.surface2))
        }
    }
    #endif
}

/// Live recording waveform (design: VoiceLive) — bars driven off the mic level.
struct SNLiveWave: View {
    let level: CGFloat
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<22, id: \.self) { i in
                    let phase = t * 6 + Double(i) * 0.5
                    let v = (sin(phase * 0.7) + sin(phase * 1.9 + Double(i))) * 0.5
                    let h = 4 + abs(CGFloat(v)) * 14 * max(0.25, level)
                    Capsule().fill(SonarTheme.text2.opacity(0.55)).frame(width: 2, height: h)
                }
            }
            .frame(height: 20)
        }
    }
}

/// Shared Apple message field.
///
/// - iOS: Return inserts a newline; the adjacent send button owns sending.
/// - macOS: Return sends the draft. Desktop multiline shortcuts (Shift/Option+Return)
///   are intentionally deferred — see #334.
struct SNMessageComposerField: View {
    @Binding var text: String
    let prompt: Text
    var onSend: (() -> Void)? = nil

    var body: some View {
        TextField("", text: $text, prompt: prompt, axis: .vertical)
            .lineLimit(1...5)
            #if os(iOS)
            .submitLabel(.return)
            #else
            .submitLabel(.send)
            // Vertical TextField on macOS often neither inserts a newline nor
            // fires onSubmit for bare Return — claim the key for send.
            // NB: the `keys:` overload is the one whose action receives the
            // KeyPress (the KeyEquivalent overload takes a zero-arg closure
            // and did not compile — the unnoticed macOS break).
            .onKeyPress(keys: [.return]) { press in
                // Shift/Option+Return stay available for newline until #334.
                if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                    return .ignored
                }
                onSend?()
                return .handled
            }
            .onSubmit { onSend?() }
            #endif
            .accessibilityLabel(prompt)
    }
}

/// m:ss like the design's fmtDur.
func snFmtDur(_ sec: Int) -> String {
    String(format: "%d:%02d", sec / 60, sec % 60)
}

// MARK: - Bottom sheet (bc-scrim / bc-sheet)

struct SNSheetModifier<SheetContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let title: String?
    @ViewBuilder let sheetContent: () -> SheetContent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                ZStack(alignment: .bottom) {
                    if isPresented {
                        SonarTheme.scrim
                            .ignoresSafeArea()
                            .onTapGesture { isPresented = false }
                            .transition(.opacity)
                        VStack(spacing: 0) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(SonarTheme.hairline)
                                .frame(width: 38, height: 4.5)
                                .padding(.top, 8)
                                .padding(.bottom, 8)
                            if let title {
                                Text(verbatim: title.uppercased())
                                    .font(SonarTheme.uiFont(size: 12.5, weight: .bold))
                                    .kerning(12.5 * 0.05)
                                    .foregroundColor(SonarTheme.text3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(EdgeInsets(top: 2, leading: 10, bottom: 8, trailing: 10))
                            }
                            sheetContent()
                        }
                        .padding(EdgeInsets(top: 4, leading: 10, bottom: 14, trailing: 10))
                        .background(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .fill(SonarTheme.surface)
                        )
                        .padding(EdgeInsets(top: 0, leading: 10, bottom: 12, trailing: 10))
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? nil : .timingCurve(0.25, 0.9, 0.3, 1, duration: 0.3), value: isPresented)
            }
    }
}

extension View {
    func snSheet<SheetContent: View>(
        isPresented: Binding<Bool>,
        title: String? = nil,
        @ViewBuilder content: @escaping () -> SheetContent
    ) -> some View {
        modifier(SNSheetModifier(isPresented: isPresented, title: title, sheetContent: content))
    }
}

// MARK: - Sheet action row (bc-actionrow)

struct SNActionRow: View {
    let icon: SNIconName
    /// Gold icon tile for the bitcoin payment action.
    var gold: Bool = false
    let label: String
    var desc: String?
    /// Dimmed, non-tappable state (e.g. nudge sender cooldown).
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: { if !disabled { action() } }) {
            HStack(spacing: 13) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(gold ? SonarTheme.goldSoft : SonarTheme.accentSoft)
                    .frame(width: 38, height: 38)
                    .overlay(
                        SNIcon(name: icon, size: 19)
                            .foregroundColor(gold ? SonarTheme.goldDeep : SonarTheme.accentDeep)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: label)
                        .font(SonarTheme.uiFont(size: 16, weight: .semibold))
                        .foregroundColor(SonarTheme.text)
                    if let desc {
                        Text(verbatim: desc)
                            .font(SonarTheme.uiFont(size: 12.5))
                            .foregroundColor(SonarTheme.text2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SNIcon(name: .chevron, size: 14, weight: 2.2)
                    .foregroundColor(SonarTheme.text3)
            }
            .padding(EdgeInsets(top: 11, leading: 10, bottom: 11, trailing: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(SNRowPressStyle(cornerRadius: 14))
        .opacity(disabled ? 0.45 : 1)
    }
}

struct SNGroupContactRow: View {
    let contact: SNGroupContact
    var selected: Bool = false
    var divider: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                SonarAvatar(name: contact.title, size: 38, presence: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: contact.title)
                        .font(SonarTheme.uiFont(size: 15.5, weight: .semibold))
                        .foregroundColor(SonarTheme.text)
                        .lineLimit(1)
                    Text(verbatim: contact.subtitle)
                        .font(SonarTheme.uiFont(size: 12.5))
                        .foregroundColor(SonarTheme.text2)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ZStack {
                    Circle()
                        .fill(selected ? SonarTheme.accent : SonarTheme.surface2)
                        .frame(width: 24, height: 24)
                    if selected {
                        SNIcon(name: .check, size: 13, weight: 2.6)
                            .foregroundColor(SonarTheme.onAccent)
                    }
                }
            }
            .padding(EdgeInsets(top: 9, leading: 10, bottom: 9, trailing: 10))
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if divider {
                    Rectangle()
                        .fill(SonarTheme.hairline)
                        .frame(height: 1)
                        .padding(.leading, 60)
                }
            }
        }
        .buttonStyle(SNRowPressStyle(cornerRadius: 14))
    }
}

// MARK: - Signal bars (bc-bars)

struct SNBars: View {
    let n: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            bar(height: 4, on: n >= 1)
            bar(height: 7.5, on: n >= 2)
            bar(height: 11, on: n >= 3)
        }
        .frame(height: 11, alignment: .bottom)
    }

    private func bar(height: CGFloat, on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(on ? SonarTheme.green : SonarTheme.hairline)
            .frame(width: 3, height: height)
    }
}

// MARK: - Primary / ghost buttons

struct SNPrimaryButton: View {
    let label: String
    var danger: Bool = false
    /// bc-primary.net — indigo internet-transport variant.
    var net: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    private var fill: Color {
        if danger { return SonarTheme.danger }
        return net ? SonarTheme.netFill : SonarTheme.accentFill
    }

    private var foreground: Color {
        if danger { return Color(sonarHex: 0xFFF6F6) }
        return net ? SonarTheme.onNet : SonarTheme.onAccent
    }

    var body: some View {
        Button(action: action) {
            Text(verbatim: label)
                .font(SonarTheme.uiFont(size: 17, weight: .bold))
                .foregroundColor(foreground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(fill)
                )
                .opacity(disabled ? 0.4 : 1)
        }
        .buttonStyle(SNScaleStyle(scale: 0.98))
        .disabled(disabled)
    }
}

struct SNGhostButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: label)
                .font(SonarTheme.uiFont(size: 15, weight: .semibold))
                .foregroundColor(SonarTheme.text2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
        }
        .buttonStyle(SNRowPressStyle(cornerRadius: 12))
    }
}

// MARK: - Settings building blocks (st-card / st-row / st-icon / st-switch)

struct SNSettingsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(SonarTheme.surface)
                .shadow(color: Color(sonarHex: 0x081E28, opacity: 0.04), radius: 1, y: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(EdgeInsets(top: 4, leading: 14, bottom: 8, trailing: 14))
    }
}

enum SNSettingsTone {
    case neutral, cyan, red, gold

    var background: Color {
        switch self {
        case .neutral: return SonarTheme.surface2
        case .cyan: return SonarTheme.accentSoft
        case .red: return Color(
            light: Color(sonarHex: 0xD43A3E, opacity: 0.12),
            dark: Color(sonarHex: 0xD43A3E, opacity: 0.12)
        )
        case .gold: return SonarTheme.goldSoft
        }
    }

    var foreground: Color {
        switch self {
        case .neutral: return SonarTheme.text2
        case .cyan: return SonarTheme.accentDeep
        case .red: return SonarTheme.danger
        case .gold: return SonarTheme.goldDeep
        }
    }
}

enum SNSettingsTrail {
    case chevron
    case arrowOut
    case toggle(Bool)
    case none
}

struct SNSettingsRow: View {
    let icon: SNIconName
    var tone: SNSettingsTone = .neutral
    let label: String
    var sub: String?
    var value: String?
    var valueMono: Bool = false
    var danger: Bool = false
    var trail: SNSettingsTrail = .chevron
    var divider: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tone.background)
                    .frame(width: 30, height: 30)
                    .overlay(
                        SNIcon(name: icon, size: 17)
                            .foregroundColor(tone.foreground)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: label)
                        .font(SonarTheme.uiFont(size: 16, weight: .semibold))
                        .foregroundColor(danger ? SonarTheme.danger : SonarTheme.text)
                    if let sub {
                        Text(verbatim: sub)
                            .font(SonarTheme.uiFont(size: 12.5, weight: .medium))
                            .foregroundColor(SonarTheme.text2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let value, !value.isEmpty {
                    Text(verbatim: value)
                        .font(valueMono ? SonarTheme.monoFont(size: 12.5) : SonarTheme.uiFont(size: 14))
                        .foregroundColor(SonarTheme.text3)
                }
                switch trail {
                case .chevron:
                    SNIcon(name: .chevron, size: 14, weight: 2.2)
                        .foregroundColor(SonarTheme.text3)
                case .arrowOut:
                    SNIcon(name: .arrowOut, size: 14, weight: 2.2)
                        .foregroundColor(SonarTheme.text3)
                case .toggle(let on):
                    SNSwitch(on: on)
                case .none:
                    EmptyView()
                }
            }
            .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if divider {
                    Rectangle()
                        .fill(SonarTheme.hairline)
                        .frame(height: 1)
                        .padding(.leading, 56)
                }
            }
        }
        .buttonStyle(SNRowPressStyle())
    }
}

struct SNSwitch: View {
    let on: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(on ? SonarTheme.green : SonarTheme.surface2)
            .frame(width: 46, height: 28)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(on ? Color.clear : SonarTheme.hairline, lineWidth: 1)
            )
            .overlay(alignment: on ? .trailing : .leading) {
                Circle()
                    .fill(Color.white)
                    .frame(width: 24, height: 24)
                    .shadow(color: Color.black.opacity(0.25), radius: 1.5, y: 1)
                    .padding(2)
            }
            .animation(.easeOut(duration: 0.2), value: on)
    }
}

// MARK: - Small pill button (pf-smallbtn)

struct SNSmallButton: View {
    let label: String
    var primary: Bool = false
    var expand: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: label)
                .font(SonarTheme.uiFont(size: 14, weight: .bold))
                .foregroundColor(primary ? SonarTheme.onAccent : SonarTheme.text)
                .frame(maxWidth: expand ? .infinity : nil)
                .padding(.vertical, 11)
                .padding(.horizontal, 14)
                .background(Capsule().fill(primary ? SonarTheme.accentFill : SonarTheme.surface2))
        }
        .buttonStyle(SNScaleStyle(scale: 0.97))
    }
}

// MARK: - Empty conversation state (bc-empty)

struct SNEmptyState: View {
    let icon: SNIconName
    var iconSize: CGFloat = 24
    var amber: Bool = false
    let title: String
    let desc: String

    var body: some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(amber ? SonarTheme.accentSoft : SonarTheme.greenSoft)
                .frame(width: 56, height: 56)
                .overlay(
                    SNIcon(name: icon, size: iconSize)
                        .foregroundColor(amber ? SonarTheme.accentDeep : SonarTheme.greenDeep)
                )
                .padding(.bottom, 8)
            Text(verbatim: title)
                .font(SonarTheme.uiFont(size: 17, weight: .bold))
                .foregroundColor(SonarTheme.text)
            Text(verbatim: desc)
                .font(SonarTheme.uiFont(size: 13.5))
                .lineSpacing(13.5 * 0.3)
                .foregroundColor(SonarTheme.text2)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 44)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Wipe confirmation sheet content (shared by Home + Settings)

/// Currency picker for the money-display setting. Lists the supported fiat
/// currencies; tap to select (persisted by the SDK).
struct SNCurrencyPickerContent: View {
    let currencies: [SonarCurrency]
    let selected: String
    let onPick: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if currencies.isEmpty {
                Text("Set up your wallet to choose a currency.")
                    .font(SonarTheme.uiFont(size: 13.5))
                    .foregroundColor(SonarTheme.text2)
                    .multilineTextAlignment(.center)
                    .padding(14)
            } else {
                SNSettingsCard {
                    ForEach(Array(currencies.enumerated()), id: \.element.id) { idx, c in
                        SNSettingsRow(
                            icon: .coin, tone: .gold,
                            label: "\(c.code) \u{00B7} \(c.symbol)",
                            value: c.code == selected ? "Selected" : nil,
                            trail: c.code == selected ? .none : .chevron,
                            divider: idx < currencies.count - 1
                        ) {
                            onPick(c.code)
                        }
                    }
                }
            }
            SNGhostButton(label: "Done", action: onClose)
                .padding(EdgeInsets(top: 6, leading: 8, bottom: 0, trailing: 8))
        }
    }
}

/// Confirmation for "Erase all chats" — clears conversations but keeps the
/// identity (unlike the full Emergency wipe).
struct SNEraseChatsSheetContent: View {
    let onErase: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("This deletes every conversation from this phone — Bluetooth chats and White Noise secure chats. Your identity, nickname and wallet stay, so you can start fresh without setting up again.")
                .font(SonarTheme.uiFont(size: 13.5))
                .lineSpacing(13.5 * 0.3)
                .foregroundColor(SonarTheme.text2)
                .multilineTextAlignment(.center)
                .padding(EdgeInsets(top: 8, leading: 14, bottom: 2, trailing: 14))
            VStack(spacing: 6) {
                SNPrimaryButton(label: "Erase all chats", danger: true, action: onErase)
                SNGhostButton(label: "Cancel", action: onClose)
            }
            .padding(EdgeInsets(top: 6, leading: 8, bottom: 0, trailing: 8))
        }
    }
}

struct SNWipeSheetContent: View {
    let onWipe: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("This deletes your key, your nickname and every conversation from this phone. There is no account to recover — gone is gone.")
                .font(SonarTheme.uiFont(size: 13.5))
                .lineSpacing(13.5 * 0.3)
                .foregroundColor(SonarTheme.text2)
                .multilineTextAlignment(.center)
                .padding(EdgeInsets(top: 8, leading: 14, bottom: 2, trailing: 14))
            VStack(spacing: 6) {
                SNPrimaryButton(label: "Wipe everything", danger: true, action: onWipe)
                SNGhostButton(label: "Cancel", action: onClose)
            }
            .padding(EdgeInsets(top: 6, leading: 8, bottom: 0, trailing: 8))
        }
    }
}
