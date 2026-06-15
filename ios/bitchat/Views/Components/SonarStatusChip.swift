//
// SonarStatusChip.swift
// bitchat
//
// "Make the network legible in plain language": a pill that says
// "Online · reaches anyone" (green dot) when Nostr relays are connected, or
// "Offline · N nearby on mesh" (pulsing cyan dot) when running on BLE only.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct SonarStatusChip: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @ObservedObject private var relayManager = NostrRelayManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    private var isOnline: Bool {
        relayManager.isConnected
    }

    private var meshCount: Int {
        let myPeerID = viewModel.meshService.myPeerID
        return viewModel.allPeers.filter { $0.peerID != myPeerID && ($0.isConnected || $0.isReachable) }.count
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isOnline ? SonarTheme.green : SonarTheme.accent)
                .frame(width: 9, height: 9)
                .background(
                    Circle()
                        .stroke(SonarTheme.accent.opacity(0.45), lineWidth: 2)
                        .scaleEffect(pulsing ? 1.9 : 1.0)
                        .opacity(pulsing ? 0 : (isOnline ? 0 : 0.8))
                )

            Group {
                if isOnline {
                    Text("Online").fontWeight(.bold).foregroundColor(SonarTheme.text)
                    + Text(" · reaches anyone").foregroundColor(SonarTheme.text2)
                } else {
                    Text("Offline").fontWeight(.bold).foregroundColor(SonarTheme.text)
                    + Text(" · \(meshCount) nearby on mesh").foregroundColor(SonarTheme.text2)
                }
            }
            .font(SonarTheme.uiFont(size: 13))
            .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(SonarTheme.surface)
                .shadow(color: Color.black.opacity(0.07), radius: 1.5, y: 1)
        )
        .overlay(Capsule().stroke(SonarTheme.hairline, lineWidth: 1))
        .onAppear { updatePulse() }
        .onChange(of: isOnline) { _ in updatePulse() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            isOnline
            ? "Online. Messages reach anyone."
            : "Offline. \(meshCount) people nearby on the Bluetooth mesh."
        )
    }

    private func updatePulse() {
        guard !reduceMotion, !isOnline else {
            pulsing = false
            return
        }
        pulsing = false
        withAnimation(.easeOut(duration: 2.2).repeatForever(autoreverses: false)) {
            pulsing = true
        }
    }
}
