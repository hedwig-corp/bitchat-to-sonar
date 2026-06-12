//
// SonarRadarScreen.swift
// bitchat
//
// Sonar discovery screen: radar + list views (SonarScreen in
// design/handoff/project/sonar/screens.jsx), showing real peers from
// UnifiedPeerService — direct links on the inner ring, mesh relays on the
// middle ring, unreachable mutual favorites (internet ghosts) outside.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct SonarRadarScreen: View {
    @EnvironmentObject private var store: SonarAppStore

    private enum ViewMode { case radar, list }
    @State private var mode: ViewMode = .radar
    /// Selected radar node — shows the sn-peercard (Message / Send sats).
    @State private var psel: SNPeerItem?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var inRange: [SNPeerItem] { store.nearbyPeers.filter(\.inRange) }
    private var far: [SNPeerItem] { store.nearbyPeers.filter { !$0.inRange } }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                SNNavHeader(hairline: false, onBack: { store.pop() }) {
                    SNHeaderTitle(name: "Sonar") {
                        SNDot(color: SonarTheme.green, small: true)
                        Text(verbatim: "\(inRange.count) in range · scanning")
                    }
                }

                segControl

                if mode == .radar {
                    radarView
                } else {
                    listView
                }
            }

            if mode == .radar, let p = psel {
                peerCard(p)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .timingCurve(0.25, 0.9, 0.3, 1, duration: 0.25), value: psel?.id)
        .background(SonarTheme.bg.ignoresSafeArea())
    }

    // sn-peercard: quick actions for the tapped node. "Send sats" only for
    // counterparts that speak ⚡PAY (Sonar payments capability).
    private func peerCard(_ p: SNPeerItem) -> some View {
        HStack(spacing: 12) {
            SonarAvatar(name: p.name, size: 44, presence: p.inRange)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: p.name)
                    .font(SonarTheme.uiFont(size: 15.5, weight: .bold))
                    .foregroundColor(SonarTheme.text)
                Text(verbatim: p.inRange ? "\(p.hint) · over Bluetooth" : "Out of range · over the internet")
                    .font(SonarTheme.uiFont(size: 12))
                    .foregroundColor(SonarTheme.text2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SNSmallButton(label: "Message", expand: false) {
                openMeshDM(p.id)
            }
            if store.paymentCapable(p.id) {
                SNSmallButton(label: "Send sats", primary: true, expand: false) {
                    store.quickPay(p.id)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(SonarTheme.surface)
                .shadow(color: Color.black.opacity(0.3), radius: 15, y: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(SonarTheme.hairline, lineWidth: 1)
        )
        .padding(.horizontal, 14)
        .padding(.bottom, 38)
    }

    // sn-seg
    private var segControl: some View {
        HStack(spacing: 2) {
            segButton(label: "Radar", icon: .rings, selected: mode == .radar) { mode = .radar }
            segButton(label: "List", icon: .list, selected: mode == .list) { mode = .list }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(SonarTheme.surface2))
        .padding(EdgeInsets(top: 6, leading: 16, bottom: 4, trailing: 16))
    }

    private func segButton(label: String, icon: SNIconName, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                SNIcon(name: icon, size: 15, weight: 2)
                Text(verbatim: label)
                    .font(SonarTheme.uiFont(size: 13.5, weight: .semibold))
            }
            .foregroundColor(selected ? SonarTheme.text : SonarTheme.text2)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                    .fill(selected ? SonarTheme.surface : Color.clear)
                    .shadow(color: selected ? Color.black.opacity(0.10) : .clear, radius: 1, y: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Radar node tap selects the peer card (screens.jsx setPsel).
    private func open(_ p: SNPeerItem) {
        psel = p
    }

    private func openMeshDM(_ id: String) {
        store.openedDM(id)
        store.push(.dm(id))
    }

    // ── Radar view ──
    private var radarView: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            SNRadarField(
                nick: store.nick,
                inRange: inRange,
                far: far,
                onTapPeer: { open($0) }
            )
            Text(inRange.isEmpty && far.isEmpty
                ? "Looking for people around you\u{2026}"
                : "Tap someone to chat")
                .font(SonarTheme.uiFont(size: 12.5))
                .foregroundColor(SonarTheme.text3)
                .padding(.top, 4)
            HStack(spacing: 18) {
                legendItem(color: SonarTheme.accent, label: "nearby · Bluetooth")
                legendItem(color: SonarTheme.net, label: "far · internet")
            }
            .padding(EdgeInsets(top: 12, leading: 0, bottom: 2, trailing: 0))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(verbatim: label)
                .font(SonarTheme.uiFont(size: 12))
                .foregroundColor(SonarTheme.text2)
        }
    }

    // ── List view ──
    private var listView: some View {
        ScrollView {
            VStack(spacing: 0) {
                if inRange.isEmpty && far.isEmpty {
                    SNEmptyState(
                        icon: .rings,
                        iconSize: 26,
                        title: "Nobody in range yet",
                        desc: "Keep Sonar open while you move around — people appear here as soon as Bluetooth finds them."
                    )
                    .padding(.vertical, 60)
                } else {
                    SNSectionLabel("In range · Bluetooth")
                    VStack(spacing: 0) {
                        ForEach(Array(inRange.enumerated()), id: \.element.id) { i, p in
                            SNConvRow(
                                title: p.name,
                                verified: store.isVerified(p.id),
                                divider: i < inRange.count - 1,
                                action: { openMeshDM(p.id) },
                                avatar: { sonarBadged(p) { SonarAvatar(name: p.name, size: 44, presence: true) } },
                                sub: {
                                    HStack(spacing: 6) {
                                        SNBars(n: p.bars)
                                        Text(verbatim: "\(p.hint) · \(p.detail)")
                                            .font(SonarTheme.uiFont(size: 13.5))
                                            .foregroundColor(SonarTheme.text2)
                                    }
                                }
                            )
                        }
                        if inRange.isEmpty {
                            sectionNote("Nobody in Bluetooth range right now.")
                        }
                    }
                    SNSectionLabel("Out of range · internet")
                    VStack(spacing: 0) {
                        ForEach(Array(far.enumerated()), id: \.element.id) { i, p in
                            SNConvRow(
                                title: p.name,
                                divider: i < far.count - 1,
                                action: { openMeshDM(p.id) },
                                avatar: { sonarBadged(p) { SonarAvatar(name: p.name, size: 44) } },
                                sub: {
                                    HStack(spacing: 6) {
                                        SNIcon(name: .globe, size: 12, weight: 2.2)
                                            .foregroundColor(SonarTheme.net)
                                        Text(verbatim: p.detail)
                                            .font(SonarTheme.uiFont(size: 13.5))
                                            .foregroundColor(SonarTheme.text2)
                                    }
                                }
                            )
                        }
                        if far.isEmpty {
                            sectionNote("Mutual favorites appear here when they leave Bluetooth range.")
                        }
                    }
                }
            }
            .padding(.bottom, 40)
        }
    }

    private func sectionNote(_ text: String) -> some View {
        Text(verbatim: text)
            .font(SonarTheme.uiFont(size: 13))
            .foregroundColor(SonarTheme.text3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 4, leading: 18, bottom: 10, trailing: 18))
    }

    /// Small indigo dot (net-color language) marking peers that announced a
    /// Sonar discovery profile.
    @ViewBuilder
    private func sonarBadged<Avatar: View>(_ p: SNPeerItem, @ViewBuilder avatar: () -> Avatar) -> some View {
        if p.sonar {
            ZStack(alignment: .bottomTrailing) {
                avatar()
                Circle()
                    .fill(SonarTheme.net)
                    .frame(width: 13, height: 13)
                    .overlay(Circle().strokeBorder(SonarTheme.bg, lineWidth: 2))
                    .offset(x: 2, y: 2)
            }
        } else {
            avatar()
        }
    }
}

// MARK: - Radar field (348×348: rings, dotted rings, sweep, pulses, nodes)

private struct SNRadarField: View {
    let nick: String
    let inRange: [SNPeerItem]
    let far: [SNPeerItem]
    let onTapPeer: (SNPeerItem) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let C: CGFloat = 174 // radar center

    private func pos(_ p: SNPeerItem) -> CGPoint {
        let a = p.angle * .pi / 180
        return CGPoint(x: C + p.r * cos(a), y: C + p.r * sin(a))
    }

    var body: some View {
        ZStack {
            // rings + dotted rings
            Canvas { ctx, _ in
                for r in [66.0, 112.0, 158.0] {
                    let rect = CGRect(x: C - r, y: C - r, width: r * 2, height: r * 2)
                    ctx.stroke(Path(ellipseIn: rect), with: .color(SonarTheme.radarRing), lineWidth: 1)
                }
                for r in [40.0, 88.0, 134.0, 170.0] {
                    let n = Int((2 * .pi * r) / 17)
                    for i in 0..<n {
                        let a = Double(i) / Double(n) * 2 * .pi
                        let dot = CGRect(
                            x: C + r * cos(a) - 1.2,
                            y: C + r * sin(a) - 1.2,
                            width: 2.4, height: 2.4
                        )
                        ctx.fill(Path(ellipseIn: dot), with: .color(SonarTheme.radarDot))
                    }
                }
            }

            // sweep (conic gradient, 4.5 s linear spin) + two expanding pulses
            // (2.6 s ease-out, second delayed 1.3 s). Driven by TimelineView so
            // no animation transaction can leak into the navigation push.
            if !reduceMotion {
                TimelineView(.animation) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let sweepAngle = t.truncatingRemainder(dividingBy: 4.5) / 4.5 * 360
                    ZStack {
                        Circle()
                            .fill(
                                AngularGradient(
                                    stops: [
                                        .init(color: .clear, location: 0),
                                        .init(color: .clear, location: 285.0 / 360.0),
                                        .init(color: SonarTheme.sweepSoft, location: 330.0 / 360.0),
                                        .init(color: SonarTheme.sweep, location: 358.0 / 360.0),
                                        .init(color: .clear, location: 1),
                                    ],
                                    center: .center
                                )
                            )
                            .rotationEffect(.degrees(sweepAngle))
                        pulseRing(phase: t.truncatingRemainder(dividingBy: 2.6) / 2.6)
                        pulseRing(phase: (t + 1.3).truncatingRemainder(dividingBy: 2.6) / 2.6)
                    }
                }
                .allowsHitTesting(false)
            }

            // you, center
            radarNode(name: nick.isEmpty ? "you" : nick, label: "you", avatarSize: 52, you: true)
                .position(x: C, y: C)

            ForEach(inRange) { p in
                Button(action: { onTapPeer(p) }) {
                    radarNodeLabel(label: p.name) {
                        ZStack(alignment: .bottomTrailing) {
                            SonarAvatar(name: p.name, size: 44, presence: true)
                            if p.sonar {
                                Circle()
                                    .fill(SonarTheme.net)
                                    .frame(width: 13, height: 13)
                                    .overlay(Circle().strokeBorder(SonarTheme.bg, lineWidth: 2))
                                    .offset(x: 2, y: 2)
                            }
                        }
                    }
                }
                .buttonStyle(SNScaleStyle(scale: 0.94))
                .position(pos(p))
            }
            ForEach(far) { p in
                Button(action: { onTapPeer(p) }) {
                    radarNodeLabel(label: p.name) {
                        ZStack(alignment: .bottomTrailing) {
                            SonarAvatar(name: p.name, size: 34)
                            Circle()
                                .fill(SonarTheme.net)
                                .frame(width: 16, height: 16)
                                .overlay(
                                    SNIcon(name: .globe, size: 9, weight: 2.4)
                                        .foregroundColor(SonarTheme.onNet)
                                )
                                .overlay(Circle().strokeBorder(SonarTheme.bg, lineWidth: 2))
                                .offset(x: 3, y: 3)
                        }
                    }
                    .opacity(0.55)
                }
                .buttonStyle(SNScaleStyle(scale: 0.94))
                .position(pos(p))
            }
        }
        .frame(width: 348, height: 348)
    }

    /// snPulse keyframes: scale 0.7 → 2.4, opacity 0.55 → 0, ease-out.
    private func pulseRing(phase: Double) -> some View {
        let eased = 1 - pow(1 - phase, 2)
        return Circle()
            .strokeBorder(SonarTheme.accent, lineWidth: 2)
            .frame(width: 70, height: 70)
            .scaleEffect(0.7 + (2.4 - 0.7) * eased)
            .opacity(0.55 * (1 - eased))
    }

    private func radarNode(name: String, label: String, avatarSize: CGFloat, you: Bool) -> some View {
        VStack(spacing: 4) {
            SonarAvatar(name: name, size: avatarSize)
            Text(verbatim: label)
                .font(SonarTheme.uiFont(size: 11.5, weight: .semibold))
                .foregroundColor(you ? SonarTheme.text3 : SonarTheme.text2)
                .padding(EdgeInsets(top: 1, leading: 7, bottom: 1, trailing: 7))
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SonarTheme.bg))
                .lineLimit(1)
                .fixedSize()
        }
    }

    private func radarNodeLabel<Avatar: View>(label: String, @ViewBuilder avatar: () -> Avatar) -> some View {
        VStack(spacing: 4) {
            avatar()
            Text(verbatim: label)
                .font(SonarTheme.uiFont(size: 11.5, weight: .semibold))
                .foregroundColor(SonarTheme.text2)
                .padding(EdgeInsets(top: 1, leading: 7, bottom: 1, trailing: 7))
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SonarTheme.bg))
                .lineLimit(1)
                .fixedSize()
        }
    }
}
