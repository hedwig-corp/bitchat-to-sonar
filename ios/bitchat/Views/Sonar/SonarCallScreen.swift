//
// SonarCallScreen.swift
// bitchat
//
// MOCKED voice/video call screen — a 1:1 reproduction of CallView in
// design/handoff/project/sonar/call.jsx + the .call* styles in theme.css.
// There is NO real microphone/camera/audio/video/WebRTC here: the call merely
// transitions ringing → connected after 2s, ticks a seconds counter, and on
// "End" appends an in-memory CallLog record to the DM transcript (the next
// step swaps this mock for real P2P signalling). The screen is always dark,
// matching the design's `.call` surface, regardless of app appearance.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct SonarCallScreen: View {
    @EnvironmentObject private var store: SonarAppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let peerId: String
    let video: Bool

    private enum Phase { case ringing, connected }

    @State private var phase: Phase = .ringing
    @State private var secs: Int = 0
    @State private var muted = false
    @State private var speaker: Bool
    @State private var camOn = true

    init(peerId: String, video: Bool) {
        self.peerId = peerId
        self.video = video
        // call.jsx: speaker defaults on for video calls.
        _speaker = State(initialValue: video)
    }

    // MARK: Derived

    private var peerName: String { store.peerItem(peerId).name }
    private var mesh: Bool { store.dmTransport(peerId) == .mesh }
    private var encLine: String { mesh ? "Bluetooth" : "internet" }
    private var hue: Double { Double(snHash(peerName) % 360) }

    private var status: String {
        phase == .ringing
            ? (video ? "Ringing\u{2026}" : "Calling\u{2026}")
            : SonarAppStore.fmtCall(secs)
    }

    // MARK: Body

    var body: some View {
        ZStack {
            if video {
                Color(sonarHex: 0x05070A).ignoresSafeArea()
                remoteFeed
            } else {
                voiceBackground
            }

            VStack(spacing: 0) {
                callTop
                if video {
                    Spacer(minLength: 0)
                } else {
                    voiceCenter.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                controls
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if video && phase == .connected && camOn {
                pip
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 16)
                    .padding(.bottom, 168)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .task { await runCallTimers() }
    }

    // MARK: Timing (call.jsx useEffects — ringing→connected@2s, +1s tick)

    private func runCallTimers() async {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard !Task.isCancelled else { return }
        await MainActor.run { phase = .connected }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { break }
            await MainActor.run { secs += 1 }
        }
    }

    // MARK: Backgrounds

    private var voiceBackground: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: Color(sonarHex: 0x0B1418), location: 0),
                    .init(color: Color(sonarHex: 0x060809), location: 0.6),
                ]),
                startPoint: .top, endPoint: .bottom
            )
            RadialGradient(
                gradient: Gradient(colors: [Color(sonarHex: 0x22D3EE, opacity: 0.10), .clear]),
                center: UnitPoint(x: 0.5, y: -0.05),
                startRadius: 0, endRadius: 520
            )
        }
        .ignoresSafeArea()
    }

    private var remoteFeed: some View {
        ZStack {
            if phase == .connected && camOn {
                SNCallFeed(hue: hue, animate: !reduceMotion)
            } else {
                LinearGradient(
                    colors: [Color(sonarHex: 0x11171C), Color(sonarHex: 0x06080A)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                SonarAvatar(name: peerName, size: 120)
            }
            // call-vignette
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .black.opacity(0.45), location: 0),
                    .init(color: .clear, location: 0.22),
                    .init(color: .clear, location: 0.60),
                    .init(color: .black.opacity(0.6), location: 1.0),
                ]),
                startPoint: .top, endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    // MARK: Top bar (enc pill + — video — name/status)

    private var callTop: some View {
        VStack(spacing: 12) {
            encPill
            if video {
                VStack(spacing: 2) {
                    Text(verbatim: peerName)
                        .font(SonarTheme.uiFont(size: 22, weight: .heavy))
                        .kerning(-22 * 0.01)
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.5), radius: 12, y: 1)
                    Text(verbatim: status)
                        .font(SonarTheme.uiFont(size: 14))
                        .foregroundColor(.white.opacity(0.8))
                }
            }
        }
        .padding(.top, 62)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
    }

    private var encPill: some View {
        HStack(spacing: 7) {
            SNIcon(name: .lock, size: 12, weight: 2.4)
            Text(verbatim: "End-to-end encrypted \u{00B7} \(encLine)")
                .font(SonarTheme.uiFont(size: 12.5, weight: .semibold))
        }
        .foregroundColor(Color(sonarHex: 0x84DCAA))
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color(sonarHex: 0x41BC76, opacity: 0.16)))
    }

    // MARK: Voice center (avatar + name + status)

    private var voiceCenter: some View {
        VStack(spacing: 0) {
            SNRingingAvatar(name: peerName, ringing: phase == .ringing, reduceMotion: reduceMotion)
            Text(verbatim: peerName)
                .font(SonarTheme.uiFont(size: 30, weight: .heavy))
                .kerning(-30 * 0.02)
                .foregroundColor(.white)
                .padding(.top, 30)
            Text(verbatim: status)
                .font(SonarTheme.uiFont(size: 16))
                .foregroundColor(.white.opacity(0.7))
                .padding(.top, 8)
        }
    }

    // MARK: Picture-in-picture self feed (video, connected, camera on)

    private var pip: some View {
        ZStack(alignment: .bottomLeading) {
            let sh = Double(snHash(store.nick.isEmpty ? "you" : store.nick) % 360)
            ZStack {
                LinearGradient(
                    colors: [Color(snHue: sh, saturation: 0.32, lightness: 0.26), Color(sonarHex: 0x06080A)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                RadialGradient(
                    gradient: Gradient(colors: [Color(snHue: sh, saturation: 0.40, lightness: 0.42), .clear]),
                    center: UnitPoint(x: 0.5, y: 0.35),
                    startRadius: 0, endRadius: 110
                )
            }
            Text(verbatim: "you")
                .font(SonarTheme.uiFont(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .shadow(color: .black.opacity(0.6), radius: 4, y: 1)
                .padding(.leading, 8)
                .padding(.bottom, 7)
        }
        .frame(width: 104, height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 13, y: 8)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(alignment: .top, spacing: 14) {
            SNCallButton(
                icon: muted ? .micOff : .mic,
                label: muted ? "Unmute" : "Mute",
                active: muted
            ) { muted.toggle() }

            if video {
                SNCallButton(
                    icon: camOn ? .videocam : .videoOff,
                    label: camOn ? "Stop video" : "Start video",
                    active: !camOn
                ) { camOn.toggle() }
                // Flip camera — no-op in the mock.
                SNCallButton(icon: .cameraFlip, label: "Flip") {}
            } else {
                SNCallButton(icon: .speaker, label: "Speaker", active: speaker) { speaker.toggle() }
                // Upgrade to video — no-op in the mock (call.jsx).
                SNCallButton(icon: .videocam, label: "Video") {}
            }

            SNCallButton(icon: .phoneDown, label: "End", end: true) {
                store.endCall(peerId, video: video, seconds: phase == .connected ? secs : 0)
            }
        }
        .padding(EdgeInsets(top: 22, leading: 18, bottom: 46, trailing: 18))
        .frame(maxWidth: .infinity)
        .background(controlsBackground)
    }

    @ViewBuilder
    private var controlsBackground: some View {
        if video {
            LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
        } else {
            Color.clear
        }
    }
}

// MARK: - Round control button (.call-btn)

private struct SNCallButton: View {
    let icon: SNIconName
    let label: String
    var active: Bool = false
    var end: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                SNIcon(name: icon, size: 23, weight: 1.9)
                    .foregroundColor(iconColor)
                    .frame(width: 58, height: 58)
                    .background(Circle().fill(circleColor))
                Text(verbatim: label)
                    .font(SonarTheme.uiFont(size: 11.5, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
            }
            .frame(width: 64)
        }
        .buttonStyle(SNScaleStyle(scale: 0.92))
    }

    private var circleColor: Color {
        if end { return Color(sonarHex: 0xF16A6A) }       // var(--danger), dark
        return active ? .white : Color.white.opacity(0.12)
    }

    private var iconColor: Color {
        if end { return .white }
        return active ? Color(sonarHex: 0x0B1418) : .white  // .call-btn.active color
    }
}

// MARK: - Ringing avatar pulse (.call-avatar.ringing → @keyframes callRing)

/// The voice-call avatar with the cyan box-shadow pulse, driven by
/// TimelineView (NOT `withAnimation(.repeatForever)`, which would hijack the
/// NavigationStack push transition — see CLAUDE.md). Disabled under Reduce
/// Motion, mirroring the prototype's `prefers-reduced-motion` rule.
private struct SNRingingAvatar: View {
    let name: String
    let ringing: Bool
    let reduceMotion: Bool

    private static let period: Double = 1.8

    var body: some View {
        ZStack {
            if ringing && !reduceMotion {
                TimelineView(.animation) { tl in
                    // p ∈ [0,1] over the 1.8s cycle; the ring grows + fades to
                    // 0 by 70%, then rests (callRing keyframes).
                    let p = tl.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: Self.period) / Self.period
                    let prog = min(p / 0.7, 1)
                    Circle()
                        .fill(Color(sonarHex: 0x22D3EE))
                        .opacity(p < 0.7 ? 0.4 * (1 - prog) : 0)
                        .scaleEffect(1 + 0.39 * prog)
                }
                .frame(width: 132, height: 132)
            }
            SonarAvatar(name: name, size: 132)
        }
        .frame(width: 132, height: 132)
    }
}

// MARK: - Drifting video feed (.call-feed → @keyframes callDrift)

/// The remote "video" placeholder: a layered hsl gradient keyed off the peer
/// name's hue, slowly drifting (callDrift, 9s ease-in-out alternate). Drift is
/// disabled under Reduce Motion.
private struct SNCallFeed: View {
    let hue: Double
    let animate: Bool

    private var feed: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(snHue: hue, saturation: 0.30, lightness: 0.22),
                    Color(sonarHex: 0x06080A),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            RadialGradient(
                gradient: Gradient(colors: [Color(snHue: hue, saturation: 0.38, lightness: 0.38), .clear]),
                center: UnitPoint(x: 0.6, y: 0.35),
                startRadius: 0, endRadius: 420
            )
            RadialGradient(
                gradient: Gradient(colors: [
                    Color(snHue: (hue + 40).truncatingRemainder(dividingBy: 360), saturation: 0.36, lightness: 0.30),
                    .clear,
                ]),
                center: UnitPoint(x: 0.3, y: 0.8),
                startRadius: 0, endRadius: 460
            )
        }
    }

    var body: some View {
        GeometryReader { geo in
            if animate {
                TimelineView(.animation) { tl in
                    // Smooth 0→1→0 over 18s (ease-in-out alternate of the 9s
                    // keyframe): scale 1.04→1.12, translate 0→(-2%,-2%).
                    let t = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 18)
                    let p = 0.5 - 0.5 * cos(.pi / 9 * t)
                    feed
                        .scaleEffect(1.04 + 0.08 * p)
                        .offset(x: -0.02 * p * geo.size.width, y: -0.02 * p * geo.size.height)
                }
            } else {
                feed.scaleEffect(1.08)
            }
        }
        .ignoresSafeArea()
    }
}
