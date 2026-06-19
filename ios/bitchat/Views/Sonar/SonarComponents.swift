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

import SwiftUI
import WebKit
import SonarCore
#if canImport(BitLogger)
import BitLogger
#endif
#if os(iOS)
import UIKit
import AVFoundation
import Photos
#else
import AppKit
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
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                        + Text(verbatim: " · \(online ? "reaches anyone" : "\(meshCount) nearby on Bluetooth")")
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

// MARK: - Conversation / list row (bc-row)

struct SNConvRow<Avatar: View, Sub: View>: View {
    let avatar: Avatar
    let title: String
    var verified: Bool = false
    let sub: Sub
    var time: String = ""
    var unread: Bool = false
    var divider: Bool = true
    let action: () -> Void

    init(
        title: String,
        verified: Bool = false,
        time: String = "",
        unread: Bool = false,
        divider: Bool = true,
        action: @escaping () -> Void,
        @ViewBuilder avatar: () -> Avatar,
        @ViewBuilder sub: () -> Sub
    ) {
        self.title = title
        self.verified = verified
        self.time = time
        self.unread = unread
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
                    if unread {
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
        }
        .foregroundColor(isFailed ? SonarTheme.danger : SonarTheme.text3)
    }
}

struct SNMsgBubble: View {
    let m: SNMessage
    var showAuthor: Bool = false
    var cont: Bool = false
    var showState: Bool = false
    let maxBubbleWidth: CGFloat
    /// Tap another participant's name/bubble to open a private DM (channels).
    var onTapAuthor: ((SNMessage) -> Void)? = nil

    @Environment(\.openURL) private var openURL

    private var mine: Bool { m.mine }
    /// Only other participants' names in a channel context are tappable.
    private var tappable: Bool { onTapAuthor != nil && !mine }

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Message text with detected URLs turned into tappable, underlined links.
    private var linkified: AttributedString {
        var result = AttributedString(m.text)
        result.foregroundColor = bubbleText
        let ns = m.text as NSString
        guard ns.length > 0, let detector = Self.linkDetector else { return result }
        let matches = detector.matches(in: m.text, options: [], range: NSRange(location: 0, length: ns.length))
        for match in matches {
            guard let r = Range(match.range, in: m.text),
                  let ar = Range(r, in: result) else { continue }
            // Style only (underline + accent color); the tap is handled by the
            // bubble's onTapGesture so opening is deterministic.
            result[ar].underlineStyle = .single
            if !mine { result[ar].foregroundColor = SonarTheme.accentDeep }
        }
        return result
    }

    /// The first URL in the message, if any (drives the "Open link" action).
    private var firstURL: URL? {
        let ns = m.text as NSString
        guard ns.length > 0, let detector = Self.linkDetector else { return nil }
        return detector.firstMatch(in: m.text, options: [], range: NSRange(location: 0, length: ns.length))?.url
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
                HStack(spacing: 3) {
                    Text(verbatim: m.time)
                        .font(SonarTheme.uiFont(size: 10.5))
                    if let via = m.via {
                        SNIcon(name: via == .mesh ? .mesh : .globe, size: 11, weight: 2.2)
                    }
                }
                .foregroundColor(metaColor)
                .padding(.bottom, 1.5)
            }
            .padding(EdgeInsets(top: 8, leading: 12, bottom: 9, trailing: 12))
            .background(
                bubbleShape
                    .fill(bubbleFill)
                    .shadow(color: mine ? .clear : Color(sonarHex: 0x0A232D, opacity: 0.07), radius: 0.75, y: 1)
            )
            .contentShape(bubbleShape)
            // Tap a bubble that contains a link → open it in the browser.
            // (Deterministic: we don't rely on SwiftUI's inline link tap, which
            // is flaky next to the context menu.)
            .onTapGesture { if let url = firstURL { openURL(url) } }
            .contextMenu {
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
            if showState, let stateText = m.state {
                SNMessageStatusFooter(stateText: stateText, via: m.via)
                .padding(EdgeInsets(top: 3, leading: 4, bottom: 0, trailing: 4))
            }
        }
        .frame(maxWidth: maxBubbleWidth, alignment: mine ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .padding(.top, cont ? 2 : 9)
    }
}

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
    /// Download + decrypt a media attachment to raw bytes (cached by the store).
    var loadMedia: ((SNMediaItem) async -> Data?)? = nil
    var loadSticker: ((MarmotService.MarmotStickerRef) async -> Data?)? = nil

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Text("Today")
                            .font(SonarTheme.uiFont(size: 11.5, weight: .semibold))
                            .foregroundColor(SonarTheme.text3)
                            .padding(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10))
                        ForEach(Array(msgs.enumerated()), id: \.element.id) { i, m in
                            if let call = m.call {
                                SNCallLogRow(call: call, mine: m.mine, time: m.time)
                            } else if m.pay != nil {
                                SNPayBubble(
                                    m: m,
                                    peerName: peerName,
                                    money: money,
                                    fiatText: fiatText,
                                    maxBubbleWidth: geo.size.width * 0.78
                                )
                            } else if !m.media.isEmpty {
                                SNMediaBubble(
                                    m: m,
                                    maxBubbleWidth: geo.size.width * 0.72,
                                    showState: m.mine && i == msgs.count - 1,
                                    load: loadMedia
                                )
                            } else if m.stickerRef != nil {
                                SNStickerBubble(
                                    m: m,
                                    showAuthor: showAuthors && !m.mine,
                                    showState: m.mine && i == msgs.count - 1,
                                    load: loadSticker
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
                                    showAuthor: showAuthors && !m.mine && !cont,
                                    cont: cont,
                                    showState: m.mine && i == msgs.count - 1,
                                    maxBubbleWidth: geo.size.width * 0.78,
                                    onTapAuthor: onTapAuthor
                                )
                            }
                        }
                        Color.clear.frame(height: 1).id("sn-bottom")
                    }
                    .padding(EdgeInsets(top: 6, leading: 14, bottom: 10, trailing: 14))
                }
                .onAppear { proxy.scrollTo("sn-bottom", anchor: .bottom) }
                .onChange(of: msgs.count) { _ in
                    withAnimation { proxy.scrollTo("sn-bottom", anchor: .bottom) }
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

/// Decode a platform image (UIImage on iOS, NSImage on macOS) from raw bytes.
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

private func snFittedMediaSize(_ size: CGSize, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
    guard size.width > 0, size.height > 0 else {
        return CGSize(width: maxWidth * 0.62, height: 150)
    }
    let scale = min(maxWidth / size.width, maxHeight / size.height)
    return CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
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
    var load: ((MarmotService.MarmotStickerRef) async -> Data?)? = nil

    @State private var image: PlatformImage?
    @State private var failed = false

    private var mine: Bool { m.mine }

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
            if showAuthor, let author = m.author {
                Text(verbatim: author)
                    .font(SonarTheme.uiFont(size: 12, weight: .bold))
                    .foregroundColor(SonarTheme.authorColor(author))
                    .padding(.leading, 6)
            }
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
            if showState, let stateText = m.state {
                SNMessageStatusFooter(stateText: stateText, via: m.via)
                    .padding(EdgeInsets(top: 1, leading: 4, bottom: 0, trailing: 4))
            }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .padding(.vertical, 3)
        .task(id: m.stickerRef?.plaintextSha256) {
            guard let ref = m.stickerRef else { return }
            image = nil
            failed = false
            guard let data = await load?(ref),
                  let decoded = PlatformImage(data: data)
            else {
                failed = true
                return
            }
            image = decoded
        }
    }
}

#if os(iOS)
private typealias PlatformImage = UIImage
#else
private typealias PlatformImage = NSImage
#endif

struct SNMediaBubble: View {
    let m: SNMessage
    let maxBubbleWidth: CGFloat
    var showState: Bool = false
    var load: ((SNMediaItem) async -> Data?)? = nil

    @State private var bytes: Data?
    @State private var failed = false
    @State private var viewerOpen = false
    @State private var loadAttempt = 0

    private var item: SNMediaItem? { m.media.first }
    private var loadKey: String {
        guard let item else { return "" }
        return [item.url, item.groupId, item.localPath ?? "", String(loadAttempt)].joined(separator: "|")
    }

    var body: some View {
        #if os(iOS)
        bubble
            .fullScreenCover(isPresented: $viewerOpen) {
                if let item {
                    SNMediaViewer(item: item, caption: m.text, initialBytes: bytes, load: load)
                }
            }
        #else
        bubble
            .sheet(isPresented: $viewerOpen) {
                if let item {
                    SNMediaViewer(item: item, caption: m.text, initialBytes: bytes, load: load)
                        .frame(minWidth: 620, minHeight: 520)
                }
            }
        #endif
    }

    private var bubble: some View {
        HStack(spacing: 0) {
            if m.mine { Spacer(minLength: 40) }
            VStack(alignment: m.mine ? .trailing : .leading, spacing: 4) {
                content
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
                    SNMessageStatusFooter(stateText: stateText, via: m.via)
                }
            }
            if !m.mine { Spacer(minLength: 40) }
        }
        .padding(.horizontal, 2)
        .padding(.top, 7)
        .task(id: loadKey) {
            bytes = nil
            failed = false
            guard let item else { return }
            guard let load else {
                failed = true
                return
            }
            if let d = await load(item) {
                bytes = d
                snLogRecoveredUndecodableImage(item, bytes: d)
            } else {
                failed = true
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let item, item.isImage {
            if let bytes, item.isGif, bytes.snLooksLikeGif {
                SNGifView(data: bytes)
                    .frame(width: maxBubbleWidth, height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(alignment: .topTrailing) {
                        SNGifBadge().padding(8)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 18))
                    .onTapGesture { viewerOpen = true }
            } else if let bytes, let decoded = snDecodedPlatformImage(bytes) {
                let size = snFittedMediaSize(decoded.size, maxWidth: maxBubbleWidth, maxHeight: 300)
                decoded.image
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
            } else if bytes != nil {
                fileChip(for: item)
            } else {
                RoundedRectangle(cornerRadius: 18)
                    .fill(SonarTheme.surface2)
                    .frame(width: maxBubbleWidth * 0.62, height: 150)
                    .overlay {
                        if failed {
                            VStack(spacing: 8) {
                                Text(verbatim: "Couldn't load image")
                                    .font(SonarTheme.uiFont(size: 12))
                                    .foregroundColor(SonarTheme.text3)
                                Button {
                                    loadAttempt += 1
                                } label: {
                                    Text(verbatim: "Retry")
                                        .font(SonarTheme.uiFont(size: 12, weight: .semibold))
                                        .foregroundColor(SonarTheme.accent)
                                }
                                .buttonStyle(.plain)
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
                    .onTapGesture { viewerOpen = true }
            }
        } else if let item, item.mime.hasPrefix("audio/") {
            SNAudioBubble(bytes: bytes, seed: item.filename, mine: m.mine, via: m.via ?? .mesh)
        } else if let item {
            fileChip(for: item)
        }
    }

    private func fileChip(for item: SNMediaItem) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8)
                .fill(SonarTheme.accent.opacity(0.18))
                .frame(width: 34, height: 34)
                .overlay(Text(verbatim: "·").font(SonarTheme.uiFont(size: 18, weight: .bold)).foregroundColor(SonarTheme.accent))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: item.filename)
                    .font(SonarTheme.uiFont(size: 13.5, weight: .semibold))
                    .foregroundColor(SonarTheme.text)
                    .lineLimit(1)
                Text(verbatim: item.mime)
                    .font(SonarTheme.uiFont(size: 11))
                    .foregroundColor(SonarTheme.text3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: maxBubbleWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(SonarTheme.surface2))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { viewerOpen = true }
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
            if let initialBytes {
                bytes = initialBytes
                return
            }
            bytes = nil
            guard let load else {
                failed = true
                return
            }
            if let data = await load(item) {
                bytes = data
            } else {
                failed = true
            }
        }
        .onDisappear {
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
                        Text(verbatim: item.mime.hasPrefix("video/") ? "▶" : "·")
                            .font(SonarTheme.uiFont(size: 30, weight: .bold))
                            .foregroundColor(.white.opacity(0.86))
                    )
                Text(verbatim: item.filename)
                    .font(SonarTheme.uiFont(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 28)
                Text(verbatim: item.mime)
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
        guard let url = writeTempFile() else { return }
        #if os(iOS)
        shareItems = [url]
        showShare = true
        #else
        NSWorkspace.shared.open(url)
        #endif
    }

    private var safeFilename: String {
        let name = (item.filename as NSString).lastPathComponent
        return name.isEmpty ? "attachment" : name
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

    #if os(iOS)
    @StateObject private var player = SNAudioPlayer()
    #endif

    private var tint: Color { via == .internet ? SonarTheme.netFill : SonarTheme.accentFill }

    var body: some View {
        HStack(spacing: 11) {
            Button {
                #if os(iOS)
                player.toggle(bytes)
                #endif
            } label: {
                Circle().fill(mine ? tint : SonarTheme.surface)
                    .frame(width: 34, height: 34)
                    .overlay(
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(mine ? (via == .internet ? SonarTheme.onNet : SonarTheme.onAccent) : SonarTheme.accent)
                    )
            }
            .buttonStyle(SNScaleStyle(scale: 0.92))
            SNMediaWave(seed: seed).frame(width: 124, height: 22)
            Text(verbatim: durationText)
                .font(SonarTheme.monoFont(size: 11.5))
                .foregroundColor(SonarTheme.text3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 18).fill(mine ? tint.opacity(0.15) : SonarTheme.surface2))
    }

    private var isPlaying: Bool {
        #if os(iOS)
        return player.playing
        #else
        return false
        #endif
    }
    private var durationText: String {
        #if os(iOS)
        return snFmtDur(Int(player.duration.rounded()))
        #else
        return "0:00"
        #endif
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

#if os(iOS)
/// Minimal AVAudioPlayer wrapper for the audio bubble.
@MainActor
final class SNAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playing = false
    @Published private(set) var duration: TimeInterval = 0
    private var player: AVAudioPlayer?

    func toggle(_ bytes: Data?) {
        if playing { player?.pause(); playing = false; return }
        if player == nil, let bytes {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
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
#endif

struct SNComposer: View {
    let placeholder: String
    let transport: SNVia
    let onSend: (String) -> Void
    let onPlus: () -> Void
    let onCommand: (String) -> Void
    var onSticker: (StickerInfo, String) -> Void = { _, _ in }
    var loadStickerPack: (String, String, [String]) async -> StickerPackInfo? = { _, _, _ in nil }
    var loadStickerImage: (String) async -> Data? = { _ in nil }
    var voiceEnabled: Bool = true
    /// Hold-to-record produced a voice note at this file URL (audio/mp4 .m4a).
    var onVoice: (URL) -> Void = { _ in }

    @State private var text = ""
    @State private var showEmojiTray = false
    #if os(iOS)
    @StateObject private var voice = VoiceNoteRecorder()
    @State private var recording = false
    @State private var dragX: CGFloat = 0
    @State private var voiceError: String?
    @State private var recordingStartTask: Task<Bool, Never>?
    private var cancelArmed: Bool { dragX < -100 }
    #endif

    private var slash: Bool { text.hasPrefix("/") }
    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        let tx = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tx.isEmpty else { return }
        if tx.hasPrefix("/") {
            let cmd = tx.dropFirst().split(separator: " ").first.map(String.init)?.lowercased() ?? ""
            onCommand(cmd)
        } else {
            onSend(tx)
        }
        text = ""
        showEmojiTray = false
    }

    var body: some View {
        VStack(spacing: 0) {
            if slash {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(snCommands, id: \.0) { cmd, desc in
                            Button {
                                onCommand(cmd)
                                text = ""
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
                    onClose: { showEmojiTray = false }
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
                TextField("", text: $text, prompt: Text(verbatim: placeholder).foregroundColor(SonarTheme.text3), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(SonarTheme.uiFont(size: 16))
                    .lineLimit(1...5)
                    .foregroundColor(SonarTheme.text)
                    .submitLabel(.send)
                    .onSubmit(send)
                Button {
                    showEmojiTray.toggle()
                } label: {
                    SNIcon(name: .smile, size: 19, weight: 2)
                        .foregroundColor(showEmojiTray ? SonarTheme.accent : SonarTheme.text3)
                }
                .buttonStyle(SNScaleStyle(scale: 0.94))
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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
