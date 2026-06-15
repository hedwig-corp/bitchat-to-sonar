//
// SonarNearbyView.swift
// bitchat
//
// The Sonar discovery screen: BLE peer discovery as a feature, not plumbing.
// Radar-first (concentric dotted rings, rotating sweep, expanding pulse,
// peers positioned by how directly we can reach them) with a segmented
// toggle to a plain-language list. Out-of-range mutual favorites appear as
// ghost nodes with an indigo internet badge.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct SonarNearbyView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var mode: Mode = .radar
    @State private var sweepAngle: Double = 0
    @State private var pulse1 = false
    @State private var pulse2 = false

    enum Mode: Hashable {
        case radar
        case list
    }

    // MARK: - Peer buckets

    private struct NearbyPeer: Identifiable {
        let peer: BitchatPeer
        let inRange: Bool
        /// 0 = directly connected, 1 = reachable through the mesh, 2 = internet only
        let tier: Int
        var id: String { peer.peerID.id }
    }

    private var nearbyPeers: [NearbyPeer] {
        let myPeerID = viewModel.meshService.myPeerID
        return viewModel.allPeers.compactMap { peer in
            guard peer.peerID != myPeerID else { return nil }
            if peer.isConnected {
                return NearbyPeer(peer: peer, inRange: true, tier: 0)
            }
            if peer.isReachable {
                return NearbyPeer(peer: peer, inRange: true, tier: 1)
            }
            if peer.isMutualFavorite {
                // Out of Bluetooth range, but reachable over Nostr — ghost node
                return NearbyPeer(peer: peer, inRange: false, tier: 2)
            }
            return nil
        }
    }

    private var inRangePeers: [NearbyPeer] { nearbyPeers.filter { $0.inRange } }
    private var ghostPeers: [NearbyPeer] { nearbyPeers.filter { !$0.inRange } }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            segmentedControl
            if mode == .radar {
                radarView
            } else {
                listView
            }
        }
        .background(SonarTheme.bg)
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 560)
        #endif
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Nearby")
                    .font(SonarTheme.uiFont(size: 17, weight: .bold))
                    .foregroundColor(SonarTheme.text)
                HStack(spacing: 5) {
                    Circle()
                        .fill(SonarTheme.green)
                        .frame(width: 7, height: 7)
                    Text("\(inRangePeers.count) in range · scanning")
                        .font(SonarTheme.uiFont(size: 12))
                        .foregroundColor(SonarTheme.text2)
                }
            }
            .padding(.leading, 8)

            Spacer()

            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(SonarTheme.text2)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(SonarTheme.surface2))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "common.close", comment: "Accessibility label for close buttons"))
        }
        .padding(.horizontal, 12)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Segmented control (radar / list)

    private var segmentedControl: some View {
        HStack(spacing: 2) {
            segmentButton(.radar, label: "Radar", icon: "circle.circle")
            segmentButton(.list, label: "List", icon: "list.bullet")
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(SonarTheme.surface2))
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private func segmentButton(_ value: Mode, label: String, icon: String) -> some View {
        let isOn = mode == value
        return Button(action: { mode = value }) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(label)
                    .font(SonarTheme.uiFont(size: 13.5, weight: .semibold))
            }
            .foregroundColor(isOn ? SonarTheme.text : SonarTheme.text2)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                    .fill(isOn ? SonarTheme.surface : Color.clear)
                    .shadow(color: isOn ? Color.black.opacity(0.10) : .clear, radius: 1, y: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: - Radar

    private var radarView: some View {
        VStack(spacing: 4) {
            Spacer(minLength: 0)
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                ZStack {
                    radarBackdrop(side: side)
                    if !reduceMotion {
                        sweepView(side: side)
                        pulseView(side: side)
                    }
                    radarNodes(side: side)
                }
                .frame(width: side, height: side)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .aspectRatio(1, contentMode: .fit)
            .padding(.horizontal, 14)
            .onAppear { startMotion() }

            Text("Tap someone to chat")
                .font(SonarTheme.uiFont(size: 12.5))
                .foregroundColor(SonarTheme.text3)

            HStack(spacing: 18) {
                HStack(spacing: 6) {
                    Circle().fill(SonarTheme.accent).frame(width: 8, height: 8)
                    Text("nearby · Bluetooth")
                }
                HStack(spacing: 6) {
                    Circle().fill(SonarTheme.net).frame(width: 8, height: 8)
                    Text("far · internet")
                }
            }
            .font(SonarTheme.uiFont(size: 12))
            .foregroundColor(SonarTheme.text2)
            .padding(.top, 8)
            .padding(.bottom, 24)
            Spacer(minLength: 0)
        }
    }

    /// Concentric rings + dotted texture, drawn relative to the prototype's 348pt frame.
    private func radarBackdrop(side: CGFloat) -> some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let scale = side / 348.0

            // Solid faint rings (66 / 112 / 158 in the prototype)
            for r in [66.0, 112.0, 158.0] {
                let radius = r * scale
                let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                context.stroke(Path(ellipseIn: rect), with: .color(SonarTheme.radarRing), lineWidth: 1)
            }

            // Dotted rings (40 / 88 / 134 / 170)
            for r in [40.0, 88.0, 134.0, 170.0] {
                let radius = r * scale
                let count = max(8, Int((2 * .pi * radius) / (17.0 * scale)))
                for i in 0..<count {
                    let a = (Double(i) / Double(count)) * 2 * .pi
                    let dotRect = CGRect(
                        x: center.x + radius * Darwin.cos(a) - 1.2,
                        y: center.y + radius * Darwin.sin(a) - 1.2,
                        width: 2.4, height: 2.4
                    )
                    context.fill(Path(ellipseIn: dotRect), with: .color(SonarTheme.radarDot))
                }
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }

    private func sweepView(side: CGFloat) -> some View {
        Circle()
            .fill(
                AngularGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .clear, location: 0.79),
                        .init(color: SonarTheme.sweepSoft, location: 0.92),
                        .init(color: SonarTheme.sweep, location: 0.995),
                        .init(color: .clear, location: 1.0),
                    ],
                    center: .center
                )
            )
            .frame(width: side, height: side)
            .rotationEffect(.degrees(sweepAngle))
            .accessibilityHidden(true)
    }

    private func pulseView(side: CGFloat) -> some View {
        ZStack {
            Circle()
                .stroke(SonarTheme.accent, lineWidth: 2)
                .frame(width: 70, height: 70)
                .scaleEffect(pulse1 ? 2.4 : 0.7)
                .opacity(pulse1 ? 0 : 0.55)
            Circle()
                .stroke(SonarTheme.accent, lineWidth: 2)
                .frame(width: 70, height: 70)
                .scaleEffect(pulse2 ? 2.4 : 0.7)
                .opacity(pulse2 ? 0 : 0.55)
        }
        .accessibilityHidden(true)
    }

    private func radarNodes(side: CGFloat) -> some View {
        let half = side / 2
        return ZStack {
            // You, at the center
            VStack(spacing: 4) {
                SonarAvatar(name: viewModel.nickname, size: 52)
                nodeName("you", color: SonarTheme.text3)
            }
            .position(x: half, y: half)
            .accessibilityLabel("You, at the center of the radar")

            // In-range mesh peers — closer to the center the more direct the link
            ForEach(inRangePeers) { item in
                let p = position(for: item, half: half)
                Button(action: { open(item) }) {
                    VStack(spacing: 4) {
                        SonarAvatar(name: item.peer.displayName, size: 44, presence: true)
                        nodeName(item.peer.displayName, color: SonarTheme.text2)
                    }
                }
                .buttonStyle(.plain)
                .position(x: p.x, y: p.y)
                .accessibilityLabel("\(item.peer.displayName), nearby over Bluetooth. Tap to chat.")
            }

            // Out-of-range favorites — ghost nodes with an internet badge
            ForEach(ghostPeers) { item in
                let p = position(for: item, half: half)
                Button(action: { open(item) }) {
                    VStack(spacing: 4) {
                        ZStack(alignment: .bottomTrailing) {
                            SonarAvatar(name: item.peer.displayName, size: 34)
                            Circle()
                                .fill(SonarTheme.net)
                                .frame(width: 16, height: 16)
                                .overlay(
                                    Image(systemName: "globe")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundColor(SonarTheme.onNet)
                                )
                                .overlay(Circle().stroke(SonarTheme.bg, lineWidth: 2))
                                .offset(x: 3, y: 3)
                        }
                        nodeName(item.peer.displayName, color: SonarTheme.text2)
                    }
                    .opacity(0.55)
                }
                .buttonStyle(.plain)
                .position(x: p.x, y: p.y)
                .accessibilityLabel("\(item.peer.displayName), out of range, reachable over the internet. Tap to chat.")
            }
        }
        .frame(width: side, height: side)
    }

    private func nodeName(_ name: String, color: Color) -> some View {
        Text(name)
            .font(SonarTheme.uiFont(size: 11.5, weight: .semibold))
            .foregroundColor(color)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Capsule().fill(SonarTheme.bg))
    }

    /// Deterministic polar placement: angle from the peer ID hash,
    /// radius from how directly we can reach them.
    private func position(for item: NearbyPeer, half: CGFloat) -> CGPoint {
        var hash: UInt32 = 2166136261
        for scalar in item.peer.peerID.id.unicodeScalars {
            hash ^= scalar.value
            hash = hash &* 16777619
        }
        let angle = (Double(hash % 360) / 360.0) * 2 * .pi
        let radiusFraction: Double
        switch item.tier {
        case 0: radiusFraction = 0.38  // direct BLE link → inner ring
        case 1: radiusFraction = 0.64  // mesh relay → middle ring
        default: radiusFraction = 0.91 // internet ghost → outer ring
        }
        let r = half * radiusFraction
        return CGPoint(
            x: half + r * Darwin.cos(angle),
            y: half + r * Darwin.sin(angle)
        )
    }

    private func startMotion() {
        guard !reduceMotion else { return }
        sweepAngle = 0
        withAnimation(.linear(duration: 4.5).repeatForever(autoreverses: false)) {
            sweepAngle = 360
        }
        pulse1 = false
        withAnimation(.easeOut(duration: 2.6).repeatForever(autoreverses: false)) {
            pulse1 = true
        }
        pulse2 = false
        withAnimation(.easeOut(duration: 2.6).repeatForever(autoreverses: false).delay(1.3)) {
            pulse2 = true
        }
    }

    // MARK: - List

    private var listView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sectionLabel("In range · Bluetooth")
                if inRangePeers.isEmpty {
                    emptyHint("Nobody in Bluetooth range right now. Keep Sonar open — phones find each other automatically.")
                } else {
                    ForEach(inRangePeers) { item in
                        peerRow(item)
                    }
                }

                if !ghostPeers.isEmpty {
                    sectionLabel("Out of range · internet")
                    ForEach(ghostPeers) { item in
                        peerRow(item)
                    }
                }
            }
            .padding(.bottom, 40)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(SonarTheme.uiFont(size: 12.5, weight: .bold))
            .foregroundColor(SonarTheme.text3)
            .kerning(0.6)
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 7)
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(SonarTheme.uiFont(size: 13.5))
            .foregroundColor(SonarTheme.text2)
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
    }

    private func peerRow(_ item: NearbyPeer) -> some View {
        Button(action: { open(item) }) {
            HStack(spacing: 12) {
                SonarAvatar(name: item.peer.displayName, size: 44, presence: item.inRange)
                    .opacity(item.inRange ? 1 : 0.6)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.peer.displayName)
                        .font(SonarTheme.uiFont(size: 16.5, weight: .semibold))
                        .foregroundColor(SonarTheme.text)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if item.inRange {
                            signalBars(item.tier == 0 ? 3 : 2)
                        } else {
                            Image(systemName: "globe")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(SonarTheme.net)
                        }
                        Text(detailText(for: item))
                            .font(SonarTheme.uiFont(size: 13.5))
                            .foregroundColor(SonarTheme.text2)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(SonarTheme.text3)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, SonarTheme.rowVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(SonarTheme.hairline)
                .frame(height: 1)
                .padding(.leading, 72)
        }
    }

    private func detailText(for item: NearbyPeer) -> String {
        switch item.tier {
        case 0: return "1 hop · strong signal"
        case 1: return "A few hops · through the mesh"
        default: return "Out of range · messages go encrypted over the internet"
        }
    }

    private func signalBars(_ n: Int) -> some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(i < n ? SonarTheme.green : SonarTheme.hairline)
                    .frame(width: 3, height: [4.0, 7.5, 11.0][i])
            }
        }
        .accessibilityLabel("Signal strength \(n) of 3")
    }

    // MARK: - Actions

    private func open(_ item: NearbyPeer) {
        dismiss()
        // Defer until the sheet dismissal settles so the DM sheet can present.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            viewModel.startPrivateChat(with: item.peer.peerID)
        }
    }
}
