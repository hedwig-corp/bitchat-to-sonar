//
// SonarCallScreen.swift
// bitchat
//
// Call screen — a 1:1 reproduction of CallView in
// design/handoff/project/sonar/call.jsx + the .call* styles in theme.css.
// The phase (ringing/connecting/connected + the seconds timer) is driven by the
// REAL call engine via `store.activeCall` (iroh transport). "End" is real
// (store.hangupCall()), and mute/speaker controls route through the
// engine/AVAudioSession instead of being visual-only toggles. Video calls use
// a real local camera preview for the self PiP and the core call kind; the
// remote panel stays explicit about missing peer frames until the core exposes
// video frame delivery to Swift.
// The screen is always dark, matching the design's `.call` surface.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import AVFoundation
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct SonarCallScreen: View {
    @EnvironmentObject private var store: SonarAppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let peerId: String
    let video: Bool

    @State private var camOn = true
    @State private var frontCamera = true

    init(peerId: String, video: Bool) {
        self.peerId = peerId
        self.video = video
    }

    // MARK: Derived (driven by the real call engine via store.activeCall)

    private var call: SNActiveCall? { store.activeCall }
    private var incoming: Bool { call?.incoming == true }
    private var connected: Bool { call?.phase == .connected }
    private var ringing: Bool { call?.phase == .ringing || call?.phase == .connecting }
    private var secs: Int { call?.connectedSecs ?? 0 }
    private var muted: Bool { call?.muted == true }
    private var speakerOn: Bool { call?.speakerOn == true }
    private var peerName: String { call?.peerName ?? store.peerItem(peerId).name }
    private var mesh: Bool { store.dmTransport(peerId) == .mesh }
    private var encLine: String { mesh ? "Bluetooth" : "internet" }
    private var hue: Double { Double(snHash(peerName) % 360) }

    private var status: String {
        if connected { return SonarAppStore.fmtCall(secs) }
        if call?.phase == .connecting { return "Connecting\u{2026}" }
        if incoming { return video ? "Incoming video call" : "Incoming call" }
        return video ? "Ringing\u{2026}" : "Calling\u{2026}"
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

            if video && connected && camOn {
                pip
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 16)
                    .padding(.bottom, 168)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
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
            if connected && camOn {
                SNRemoteVideoUnavailableFeed(peerName: peerName, hue: hue, animate: !reduceMotion)
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
            SNRingingAvatar(name: peerName, ringing: ringing, reduceMotion: reduceMotion)
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
            let baseHue = snHash(store.nick.isEmpty ? "you" : store.nick)
            let sh = Double((baseHue + (frontCamera ? 0 : 42)) % 360)
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
                SNLocalCameraPreview(frontCamera: frontCamera)
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
            if incoming && call?.phase == .ringing {
                // Incoming call: Decline (red) + Accept (green).
                SNCallButton(icon: .phoneDown, label: "Decline", end: true) { store.declineCall() }
                SNCallButton(icon: .phone, label: "Accept", accept: true) { store.acceptCall() }
            } else {
                SNCallButton(icon: .micOff, label: muted ? "Muted" : "Mute", active: muted) { store.toggleCallMute() }
                if video {
                    SNCallButton(icon: camOn ? .videocam : .videoOff, label: camOn ? "Stop video" : "Start video", active: !camOn) {
                        camOn.toggle()
                    }
                    SNCallButton(icon: .cameraFlip, label: "Flip") {
                        frontCamera.toggle()
                    }
                } else {
                    SNCallButton(icon: .speaker, label: "Speaker", active: speakerOn) { store.toggleCallSpeaker() }
                }
                SNCallButton(icon: .phoneDown, label: "End", end: true) { store.hangupCall() }
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

// MARK: - Local camera PiP

private struct SNLocalCameraPreview: View {
    let frontCamera: Bool

    var body: some View {
        SNPlatformCameraPreview(frontCamera: frontCamera)
            .background(Color.black.opacity(0.18))
    }
}

#if os(iOS)
private struct SNPlatformCameraPreview: UIViewRepresentable {
    let frontCamera: Bool

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        context.coordinator.attach(to: view)
        context.coordinator.set(frontCamera: frontCamera)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewView, context: Context) {
        context.coordinator.set(frontCamera: frontCamera)
    }

    static func dismantleUIView(_ uiView: CameraPreviewView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
}

private final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        previewLayer.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
#elseif os(macOS)
private struct SNPlatformCameraPreview: NSViewRepresentable {
    let frontCamera: Bool

    func makeNSView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        context.coordinator.attach(to: view)
        context.coordinator.set(frontCamera: frontCamera)
        return view
    }

    func updateNSView(_ nsView: CameraPreviewView, context: Context) {
        context.coordinator.set(frontCamera: frontCamera)
    }

    static func dismantleNSView(_ nsView: CameraPreviewView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
}

private final class CameraPreviewView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = previewLayer
        previewLayer.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
#endif

#if os(iOS) || os(macOS)
private extension SNPlatformCameraPreview {
    final class Coordinator {
        private weak var view: CameraPreviewView?
        private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "chat.bitchat.sonar-call-camera", qos: .userInitiated)
        private var currentFrontCamera: Bool?

        func attach(to view: CameraPreviewView) {
            self.view = view
            view.previewLayer.session = session
        }

        func set(frontCamera: Bool) {
            guard currentFrontCamera != frontCamera else { return }
            currentFrontCamera = frontCamera
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted else { return }
                self?.queue.async { self?.configure(frontCamera: frontCamera) }
            }
        }

        func stop() {
            queue.async {
                if self.session.isRunning { self.session.stopRunning() }
            }
        }

        private func configure(frontCamera: Bool) {
            session.beginConfiguration()
            session.sessionPreset = .medium
            for input in session.inputs {
                session.removeInput(input)
            }

            guard let device = cameraDevice(frontCamera: frontCamera),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                session.commitConfiguration()
                return
            }
            session.addInput(input)
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
        }

        private func cameraDevice(frontCamera: Bool) -> AVCaptureDevice? {
            #if os(iOS)
            let position: AVCaptureDevice.Position = frontCamera ? .front : .back
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
                ?? AVCaptureDevice.default(for: .video)
            #else
            return AVCaptureDevice.default(for: .video)
            #endif
        }
    }
}
#endif

// MARK: - Round control button (.call-btn)

private struct SNCallButton: View {
    let icon: SNIconName
    let label: String
    var active: Bool = false
    var end: Bool = false
    var accept: Bool = false
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
        if accept { return Color(sonarHex: 0x41BC76) }    // var(--green)
        if end { return Color(sonarHex: 0xF16A6A) }       // var(--danger), dark
        return active ? .white : Color.white.opacity(0.12)
    }

    private var iconColor: Color {
        if accept || end { return .white }
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

// MARK: - Remote video unavailable state

/// The core currently exposes video call signaling but not peer frame delivery.
/// Keep the video-call surface honest: show the connected call state and the
/// real local camera PiP, but do not fake the remote camera feed.
private struct SNRemoteVideoUnavailableFeed: View {
    let peerName: String
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
            VStack(spacing: 14) {
                SonarAvatar(name: peerName, size: 118)
                VStack(spacing: 4) {
                    Text("Remote video unavailable")
                        .font(SonarTheme.uiFont(size: 17, weight: .bold))
                        .foregroundColor(.white)
                    Text("Audio is connected")
                        .font(SonarTheme.uiFont(size: 13))
                        .foregroundColor(.white.opacity(0.72))
                }
            }
            .padding(.horizontal, 24)
            .multilineTextAlignment(.center)
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
