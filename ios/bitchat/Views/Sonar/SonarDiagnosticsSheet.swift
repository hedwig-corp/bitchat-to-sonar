//
// SonarDiagnosticsSheet.swift
// bitchat
//
// Settings → Diagnostics: live relay/sync status, the verbose-capture
// opt-in, and "Share debug bundle" (zips the on-device core + app log
// files plus a sync-state snapshot for user-initiated export).
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Minimal decoded view of the core's `sync_state_snapshot` JSON — only the
/// fields the sheet renders. Unknown fields are ignored on purpose so the
/// core can grow the snapshot without breaking this screen.
private struct DiagnosticsSnapshot: Decodable {
    struct Relay: Decodable {
        let url: String
        let status: String
    }

    let watermarkSecs: UInt64
    let liveMarmotEnabled: Bool
    let subscribedGroupCount: Int
    let relays: [Relay]

    enum CodingKeys: String, CodingKey {
        case watermarkSecs = "watermark_secs"
        case liveMarmotEnabled = "live_marmot_enabled"
        case subscribedGroupCount = "subscribed_group_count"
        case relays
    }
}

struct SNDiagnosticsSheetContent: View {
    @EnvironmentObject private var store: SonarAppStore

    @State private var snapshot: DiagnosticsSnapshot?
    @State private var snapshotLoaded = false
    @State private var verbose = false
    @State private var building = false
    @State private var bundleURL: URL?
    @State private var shareSheet = false

    var body: some View {
        VStack(spacing: 0) {
            relayStatusCard

            // Verbose capture opt-in.
            Button {
                verbose.toggle()
                store.setDiagnosticsVerbose(verbose)
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Verbose logs")
                            .font(SonarTheme.uiFont(size: 14.5, weight: .semibold))
                            .foregroundColor(SonarTheme.text)
                        Text("Adds debug detail to captured logs. Never includes your private key.")
                            .font(SonarTheme.uiFont(size: 12))
                            .foregroundColor(SonarTheme.text3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    SNIcon(name: verbose ? .check : .eyeOff, size: 17, weight: 2)
                        .foregroundColor(verbose ? SonarTheme.green : SonarTheme.text3)
                }
                .padding(EdgeInsets(top: 12, leading: 15, bottom: 12, trailing: 15))
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SonarTheme.surface2))
                .contentShape(Rectangle())
            }
            .buttonStyle(SNScaleStyle(scale: 0.99))
            .padding(EdgeInsets(top: 0, leading: 8, bottom: 12, trailing: 8))

            // Share debug bundle.
            Button(action: shareBundle) {
                HStack(spacing: 7) {
                    SNIcon(name: .copy, size: 17, weight: 2.2)
                    Text(verbatim: building ? "Preparing\u{2026}" : "Share debug bundle")
                        .font(SonarTheme.uiFont(size: 14.5, weight: .bold))
                }
                .foregroundColor(SonarTheme.onAccent)
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(SonarTheme.accentFill))
            }
            .buttonStyle(SNScaleStyle(scale: 0.97))
            .disabled(building)
            .padding(.horizontal, 8)

            Text("Logs stay on this device until you share them. They contain relay and sync events — no message text and no keys.")
                .font(SonarTheme.uiFont(size: 13))
                .lineSpacing(13 * 0.5)
                .foregroundColor(SonarTheme.text3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(EdgeInsets(top: 12, leading: 18, bottom: 4, trailing: 18))
        }
        .task {
            verbose = store.diagnosticsVerbose
            await loadSnapshot()
        }
        #if os(iOS)
        .sheet(isPresented: $shareSheet) {
            if let bundleURL {
                SNDiagnosticsActivityView(items: [bundleURL])
            }
        }
        #endif
    }

    private var relayStatusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Relay sync")
                .font(SonarTheme.uiFont(size: 13, weight: .bold))
                .foregroundColor(SonarTheme.text2)
            if let snapshot {
                ForEach(snapshot.relays, id: \.url) { relay in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(relay.status == "Connected" ? SonarTheme.green : SonarTheme.danger)
                            .frame(width: 7, height: 7)
                        Text(verbatim: relay.url)
                            .font(SonarTheme.monoFont(size: 12))
                            .foregroundColor(SonarTheme.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(verbatim: relay.status)
                            .font(SonarTheme.uiFont(size: 12))
                            .foregroundColor(SonarTheme.text3)
                    }
                }
                HStack(spacing: 8) {
                    Text(verbatim: "Last sync: \(Self.format(watermark: snapshot.watermarkSecs))")
                    Spacer(minLength: 4)
                    Text(verbatim: snapshot.liveMarmotEnabled
                         ? "Live · \(snapshot.subscribedGroupCount) chats"
                         : "Not subscribed")
                }
                .font(SonarTheme.uiFont(size: 12))
                .foregroundColor(SonarTheme.text3)
            } else {
                Text(snapshotLoaded ? "Relay not connected yet" : "Loading\u{2026}")
                    .font(SonarTheme.uiFont(size: 13))
                    .foregroundColor(SonarTheme.text3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 13, leading: 15, bottom: 13, trailing: 15))
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SonarTheme.surface2))
        .padding(EdgeInsets(top: 2, leading: 8, bottom: 12, trailing: 8))
    }

    private func loadSnapshot() async {
        let json = await store.diagnosticsSnapshotJson()
        if let json, let data = json.data(using: .utf8) {
            snapshot = try? JSONDecoder().decode(DiagnosticsSnapshot.self, from: data)
        }
        snapshotLoaded = true
    }

    private func shareBundle() {
        guard !building else { return }
        building = true
        Task {
            let url = await store.buildDiagnosticsBundle()
            await MainActor.run {
                building = false
                if let url {
                    bundleURL = url
                    #if os(iOS)
                    shareSheet = true
                    #elseif os(macOS)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    #endif
                } else {
                    store.toast = "Nothing to share yet — no logs captured"
                }
            }
        }
    }

    private static func format(watermark secs: UInt64) -> String {
        guard secs > 0 else { return "never" }
        let date = Date(timeIntervalSince1970: TimeInterval(secs))
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

#if os(iOS)
private struct SNDiagnosticsActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
