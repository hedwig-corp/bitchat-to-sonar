//
// SonarRelayStatusSheet.swift
// bitchat
//
// Connection → Internet: live Nostr + Marmot relay status and a one-tap
// latency benchmark (REQ→EOSE RTT). Free of message content / key material.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// Decoded Marmot/core sync snapshot (same shape as Diagnostics).
private struct RelaySyncSnapshot: Decodable {
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

/// Connection sheet drill-in: per-relay status + RTT benchmarks.
struct SNRelayStatusSheetContent: View {
    @EnvironmentObject private var store: SonarAppStore
    @ObservedObject private var relayManager = NostrRelayManager.shared

    let onClose: () -> Void

    @State private var marmotSnapshot: RelaySyncSnapshot?
    @State private var snapshotLoaded = false
    @State private var benchmarking = false
    @State private var lastBenchSummary: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                summaryCard
                nostrRelaysCard
                marmotRelaysCard
                actions
            }
        }
        .frame(maxHeight: 520)
        .task {
            await refreshSnapshot()
        }
    }

    // MARK: - Summary

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(store.online ? SonarTheme.green : SonarTheme.danger)
                    .frame(width: 8, height: 8)
                Text(store.online ? "Internet path up" : "Internet path down")
                    .font(SonarTheme.uiFont(size: 14.5, weight: .bold))
                    .foregroundColor(SonarTheme.text)
                Spacer(minLength: 4)
                Text(verbatim: store.connectedRelaySummary)
                    .font(SonarTheme.uiFont(size: 12))
                    .foregroundColor(SonarTheme.text3)
                    .lineLimit(1)
            }

            let connected = relayManager.relays.filter { $0.isConnected }.count
            let total = max(relayManager.relays.count, 1)
            let best = (relayManager.relays.compactMap { $0.lastRttMs } + relayManager.lastProbeByURL.values.compactMap { $0.rttMs }).min()
            HStack(spacing: 10) {
                metricChip(title: "Nostr", value: "\(connected)/\(relayManager.relays.count)")
                metricChip(title: "Best RTT", value: best.map { "\($0) ms" } ?? "—")
                metricChip(
                    title: "Marmot",
                    value: (marmotSnapshot?.liveMarmotEnabled == true) ? "live" : (snapshotLoaded ? "idle" : "…")
                )
            }

            if let lastBenchSummary {
                Text(verbatim: lastBenchSummary)
                    .font(SonarTheme.uiFont(size: 12))
                    .foregroundColor(SonarTheme.text3)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(SonarTheme.surface)
                    Capsule()
                        .fill(store.online ? SonarTheme.green : SonarTheme.accent)
                        .frame(width: max(6, geo.size.width * CGFloat(connected) / CGFloat(total)))
                }
            }
            .frame(height: 5)
        }
        .padding(EdgeInsets(top: 13, leading: 15, bottom: 13, trailing: 15))
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SonarTheme.surface2))
        .padding(EdgeInsets(top: 2, leading: 8, bottom: 10, trailing: 8))
    }

    private func metricChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title.uppercased())
                .font(SonarTheme.uiFont(size: 10.5, weight: .bold))
                .foregroundColor(SonarTheme.text3)
            Text(verbatim: value)
                .font(SonarTheme.monoFont(size: 13))
                .foregroundColor(SonarTheme.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(SonarTheme.surface))
    }

    // MARK: - Nostr relays

    private var nostrRelaysCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Nostr relays", detail: "message / favorite path")
            if relayManager.relays.isEmpty {
                Text("No relays configured yet")
                    .font(SonarTheme.uiFont(size: 13))
                    .foregroundColor(SonarTheme.text3)
            } else {
                ForEach(Array(relayManager.relays.enumerated()), id: \.element.url) { index, relay in
                    relayRow(
                        url: relay.url,
                        status: relay.isConnected ? "Connected" : statusLabel(for: relay),
                        connected: relay.isConnected,
                        rttMs: rttMs(for: relay.url),
                        error: probeError(for: relay.url) ?? relay.lastError?.localizedDescription,
                        divider: index < relayManager.relays.count - 1
                    )
                }
            }
        }
        .padding(EdgeInsets(top: 13, leading: 15, bottom: 13, trailing: 15))
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SonarTheme.surface2))
        .padding(EdgeInsets(top: 0, leading: 8, bottom: 10, trailing: 8))
    }

    // MARK: - Marmot relays

    private var marmotRelaysCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(
                "Secure chat relays",
                detail: marmotSnapshot.map {
                    $0.liveMarmotEnabled
                        ? "live · \($0.subscribedGroupCount) chats · sync \(Self.format(watermark: $0.watermarkSecs))"
                        : "sync \(Self.format(watermark: $0.watermarkSecs))"
                } ?? (snapshotLoaded ? "not connected" : "loading…")
            )
            if let marmotSnapshot, !marmotSnapshot.relays.isEmpty {
                ForEach(Array(marmotSnapshot.relays.enumerated()), id: \.element.url) { index, relay in
                    let connected = relay.status.lowercased() == "connected"
                    relayRow(
                        url: relay.url,
                        status: relay.status,
                        connected: connected,
                        rttMs: rttMs(for: relay.url),
                        error: probeError(for: relay.url),
                        divider: index < marmotSnapshot.relays.count - 1
                    )
                }
            } else {
                Text(snapshotLoaded ? "Secure chat relays not connected yet" : "Loading…")
                    .font(SonarTheme.uiFont(size: 13))
                    .foregroundColor(SonarTheme.text3)
            }
        }
        .padding(EdgeInsets(top: 13, leading: 15, bottom: 13, trailing: 15))
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SonarTheme.surface2))
        .padding(EdgeInsets(top: 0, leading: 8, bottom: 10, trailing: 8))
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 6) {
            Button(action: runBenchmark) {
                HStack(spacing: 7) {
                    SNIcon(name: .bolt, size: 16, weight: 2.2)
                    Text(verbatim: benchmarking ? "Measuring…" : "Run relay benchmark")
                        .font(SonarTheme.uiFont(size: 14.5, weight: .bold))
                }
                .foregroundColor(SonarTheme.onAccent)
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(SonarTheme.accentFill))
            }
            .buttonStyle(SNScaleStyle(scale: 0.97))
            .disabled(benchmarking)
            .padding(.horizontal, 8)

            SNGhostButton(label: "Done", action: onClose)
                .padding(.horizontal, 8)
        }
        .padding(.top, 2)
    }

    // MARK: - Rows

    private func sectionHeader(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title)
                .font(SonarTheme.uiFont(size: 13, weight: .bold))
                .foregroundColor(SonarTheme.text2)
            Text(verbatim: detail)
                .font(SonarTheme.uiFont(size: 11.5))
                .foregroundColor(SonarTheme.text3)
                .lineLimit(2)
        }
    }

    private func relayRow(
        url: String,
        status: String,
        connected: Bool,
        rttMs: Int?,
        error: String?,
        divider: Bool
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(connected ? SonarTheme.green : SonarTheme.danger)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: displayHost(url))
                        .font(SonarTheme.monoFont(size: 12.5))
                        .foregroundColor(SonarTheme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let error, !error.isEmpty, (rttMs == nil || !connected) {
                        Text(verbatim: error)
                            .font(SonarTheme.uiFont(size: 11))
                            .foregroundColor(SonarTheme.text3)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(verbatim: status)
                        .font(SonarTheme.uiFont(size: 12, weight: .semibold))
                        .foregroundColor(connected ? SonarTheme.green : SonarTheme.text3)
                    Text(verbatim: rttMs.map { "\($0) ms" } ?? "—")
                        .font(SonarTheme.monoFont(size: 12))
                        .foregroundColor(rttColor(rttMs))
                }
            }
            .padding(.vertical, 7)
            if divider {
                Rectangle().fill(SonarTheme.hairline).frame(height: 1)
            }
        }
    }

    // MARK: - Actions / helpers

    private func runBenchmark() {
        guard !benchmarking else { return }
        benchmarking = true
        lastBenchSummary = "Measuring…"
        Task { @MainActor in
            // Latest Marmot relay set (includes hedwig) + Nostr manager set.
            await refreshSnapshot()
            var results = await relayManager.runRelayBenchmarks()
            // Always measure Marmot hosts too (hedwig may only appear here).
            // Skip URLs already measured in this run.
            var measured = Set(results.map { NostrRelayManager.canonicalRelayURL($0.url) })
            if let marmotSnapshot {
                for relay in marmotSnapshot.relays {
                    let canon = NostrRelayManager.canonicalRelayURL(relay.url)
                    if measured.contains(canon) { continue }
                    let result = await relayManager.probeRelayLatency(url: relay.url)
                    results.append(result)
                    measured.insert(canon)
                }
            }
            // Hard-guarantee hedwig is measured even if snapshot has not loaded yet.
            let hedwig = NostrRelayManager.canonicalRelayURL("wss://nostr.relay.hedwig.sh")
            if !measured.contains(hedwig) {
                results.append(await relayManager.probeRelayLatency(url: hedwig))
            }
            await refreshSnapshot()
            let ok = results.filter { $0.success }
            let fail = results.count - ok.count
            if let best = ok.compactMap { $0.rttMs }.min(), let worst = ok.compactMap { $0.rttMs }.max() {
                lastBenchSummary = "Last run · \(ok.count) up / \(fail) down · best \(best) ms · worst \(worst) ms"
            } else if results.isEmpty {
                lastBenchSummary = "No relays to measure — open a chat so relays connect, then retry"
            } else {
                let sample = results.compactMap { $0.error }.prefix(2).joined(separator: "; ")
                lastBenchSummary = "Last run · all \(results.count) probes failed" + (sample.isEmpty ? "" : " · \(sample)")
            }
            benchmarking = false
        }
    }

    private func refreshSnapshot() async {
        let json = await store.diagnosticsSnapshotJson()
        if let json, let data = json.data(using: .utf8) {
            marmotSnapshot = try? JSONDecoder().decode(RelaySyncSnapshot.self, from: data)
        }
        snapshotLoaded = true
    }

    private func statusLabel(for relay: NostrRelayManager.Relay) -> String {
        if let next = relay.nextReconnectTime, next > Date() {
            let secs = max(1, Int(next.timeIntervalSinceNow))
            return "Retry in \(secs)s"
        }
        if relay.reconnectAttempts > 0 {
            return "Reconnecting"
        }
        if relay.lastError != nil {
            return "Error"
        }
        return "Disconnected"
    }

    private func displayHost(_ url: String) -> String {
        if let host = URL(string: url)?.host, !host.isEmpty { return host }
        return url
            .replacingOccurrences(of: "wss://", with: "")
            .replacingOccurrences(of: "ws://", with: "")
    }

    private func rttColor(_ ms: Int?) -> Color {
        guard let ms else { return SonarTheme.text3 }
        if ms < 250 { return SonarTheme.green }
        if ms < 800 { return SonarTheme.text2 }
        return SonarTheme.danger
    }

    private func rttMs(for url: String) -> Int? {
        let canon = NostrRelayManager.canonicalRelayURL(url)
        if let direct = relayManager.lastProbeByURL[canon]?.rttMs { return direct }
        if let relay = relayManager.relays.first(where: { $0.url == canon }) {
            return relay.lastRttMs
        }
        // Host-level match for trailing-slash / port variants.
        if let hit = relayManager.lastProbeByURL.first(where: { Self.hostsMatch($0.key, url) })?.value.rttMs {
            return hit
        }
        return relayManager.relays.first(where: { Self.hostsMatch($0.url, url) })?.lastRttMs
    }

    private func probeError(for url: String) -> String? {
        let canon = NostrRelayManager.canonicalRelayURL(url)
        if let direct = relayManager.lastProbeByURL[canon]?.error, !(direct.isEmpty) { return direct }
        if let relay = relayManager.relays.first(where: { $0.url == canon }) {
            return relay.lastProbeError
        }
        if let hit = relayManager.lastProbeByURL.first(where: { Self.hostsMatch($0.key, url) })?.value.error {
            return hit
        }
        return relayManager.relays.first(where: { Self.hostsMatch($0.url, url) })?.lastProbeError
    }

    private static func hostsMatch(_ a: String, _ b: String) -> Bool {
        let ha = URL(string: a)?.host?.lowercased()
        let hb = URL(string: b)?.host?.lowercased()
        if let ha, let hb { return ha == hb }
        return NostrRelayManager.canonicalRelayURL(a) == NostrRelayManager.canonicalRelayURL(b)
    }

    private static func format(watermark secs: UInt64) -> String {
        guard secs > 0 else { return "never" }
        let date = Date(timeIntervalSince1970: TimeInterval(secs))
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}
