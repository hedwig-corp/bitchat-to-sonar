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

struct SNMsgBubble: View {
    let m: SNMessage
    var showAuthor: Bool = false
    var cont: Bool = false
    var showState: Bool = false
    let maxBubbleWidth: CGFloat

    private var mine: Bool { m.mine }
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
            }
            HStack(alignment: .bottom, spacing: 8) {
                Text(verbatim: m.text)
                    .font(SonarTheme.uiFont(size: 16))
                    .lineSpacing(16 * 0.2)
                    .foregroundColor(bubbleText)
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
            if showState, let stateText = m.state {
                HStack(spacing: 3) {
                    SNIcon(name: .check, size: 11, weight: 2.6)
                    Text(verbatim: "\(stateText) · \(m.via?.label ?? "")")
                        .font(SonarTheme.uiFont(size: 11))
                }
                .foregroundColor(SonarTheme.text3)
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
    /// Tap-to-claim on a sealed incoming payment (uuid).
    var onClaim: ((String) -> Void)? = nil

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
                            if m.pay != nil {
                                SNPayBubble(
                                    m: m,
                                    peerName: peerName,
                                    money: money,
                                    fiatText: fiatText,
                                    maxBubbleWidth: geo.size.width * 0.78,
                                    onClaim: onClaim
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
                                    maxBubbleWidth: geo.size.width * 0.78
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

// MARK: - Composer with "+" actions and "/" command layer

let snCommands: [(String, String)] = [
    ("who", "See who\u{2019}s nearby"),
    ("msg", "Message someone"),
    ("slap", "Classic IRC slap"),
]

struct SNComposer: View {
    let placeholder: String
    let transport: SNVia
    let onSend: (String) -> Void
    let onPlus: () -> Void
    let onCommand: (String) -> Void

    @State private var text = ""

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
            HStack(alignment: .bottom, spacing: 8) {
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
                    TextField("", text: $text, prompt: Text(verbatim: placeholder).foregroundColor(SonarTheme.text3))
                        .textFieldStyle(.plain)
                        .font(SonarTheme.uiFont(size: 16))
                        .foregroundColor(SonarTheme.text)
                        .onSubmit(send)
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(SonarTheme.surface2))

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
            }
            .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        }
        .background(SonarTheme.bg)
    }
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
