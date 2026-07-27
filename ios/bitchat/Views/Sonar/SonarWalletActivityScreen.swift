//
// SonarWalletActivityScreen.swift
// bitchat
//
// Wallet — 1:1 with the design's `WalletScreen` + `WalletActivity`
// (design/handoff/project/sonar/settings.jsx and pay.jsx): the balance block,
// then the transaction log. It is a log only; there are no send/receive actions
// here — paying starts from the new-chat sheet or inside a chat. Mirrors the
// Compose Multiplatform SonarWalletActivityScreen.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct SonarWalletActivityScreen: View {
    @EnvironmentObject private var store: SonarAppStore

    private var balanceSats: Int64 { store.balanceSats ?? 0 }
    private var entries: [SonarPaymentActivity] { store.paymentActivities }

    var body: some View {
        VStack(spacing: 0) {
            SNNavHeader(hairline: false, onBack: { store.pop() }) {
                SNHeaderName("Wallet")
            }

            // Read the ledger ONCE per body. `entries` is a computed property
            // over the activity ledger; mentioning it three times meant three
            // passes over the whole ledger every time SwiftUI evaluated this
            // view.
            let rows = entries
            ScrollView {
                VStack(spacing: 0) {
                    // ── .wallet-balance: centered, 14px top / 6px bottom, 3px gap ──
                    VStack(spacing: 3) {
                        // .wallet-balnum: 34/800, -0.02em. `money()` is the
                        // design's walletStr — sats or fiat, per the user's
                        // display preference.
                        Text(verbatim: store.money(balanceSats))
                            .font(SonarTheme.uiFont(size: 34, weight: .heavy))
                            .kerning(34 * -0.02)
                            .foregroundColor(SonarTheme.text)
                        // .wallet-ballabel: 12.5px, text3
                        Text("Balance · pays directly, no claim step")
                            .font(SonarTheme.uiFont(size: 12.5))
                            .foregroundColor(SonarTheme.text3)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 14)
                    .padding(.bottom, 6)

                    SNSectionLabel("Activity")

                    if rows.isEmpty {
                        // .wallet-empty: centered text3, 14px, 30px/20px padding
                        Text("No transactions yet.")
                            .font(SonarTheme.uiFont(size: 14))
                            .foregroundColor(SonarTheme.text3)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(EdgeInsets(top: 30, leading: 20, bottom: 30, trailing: 20))
                    } else {
                        // LazyVStack, not VStack: a plain VStack inside a
                        // ScrollView builds every row up front and rebuilds
                        // them on each body evaluation, which is what made the
                        // screen slow to open and rough to scroll. Lazy builds
                        // rows as they come into view.
                        LazyVStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                                activityRow(entry, divider: index < rows.count - 1)
                            }
                        }
                    }

                    Color.clear.frame(height: 40)
                }
            }
        }
        .background(SonarTheme.bg.ignoresSafeArea())
    }

    /// .wallet-txrow — icon bubble, "To/From <who>", "<status> · <rail> · <time>",
    /// signed amount.
    private func activityRow(_ entry: SonarPaymentActivity, divider: Bool) -> some View {
        let sent = entry.direction == .outgoing
        let failed = entry.status == .failed

        // Design pay.jsx WalletActivity: send glyph out, download glyph in.
        let icon: SNIconName = sent ? .send : .download
        // .wallet-txicon.out = net-soft/net-deep, .in = green-soft/green-deep
        let tileBg = sent ? SonarTheme.netSoft : SonarTheme.greenSoft
        let tileFg = sent ? SonarTheme.netDeep : SonarTheme.greenDeep

        // Design status words. The app has no separate "confirmed" state — a
        // settled outgoing payment is "Sent", a settled incoming one "Received".
        let statusLabel: String = {
            switch entry.status {
            case .pending: return "Pending"
            case .failed: return "Failed"
            case .paid: return sent ? "Sent" : "Received"
            }
        }()
        let rail = entry.via == SNVia.mesh.rawValue ? "Bluetooth" : "Lightning"
        // Same label the chat list uses: today → HH:MM, this week → weekday,
        // older → date. Matches the design's `tx.time` ("18:06" / "Mon").
        let time = SonarAppStore.listTime(entry.settledAt ?? entry.createdAt)
        let meta = time.isEmpty
            ? "\(statusLabel) · \(rail)"
            : "\(statusLabel) · \(rail) · \(time)"

        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Circle()
                    .fill(tileBg)
                    .frame(width: 36, height: 36)
                    .overlay(
                        SNIcon(name: icon, size: 16, weight: 2.2)
                            .foregroundColor(tileFg)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    // .wallet-txwho: 15.5/650
                    Text(verbatim: (sent ? "To " : "From ") + entry.peerName)
                        .font(SonarTheme.uiFont(size: 15.5, weight: .semibold))
                        .foregroundColor(SonarTheme.text)
                        .lineLimit(1)
                    // .wallet-txmeta: 12.5px, text2 — not status-colored in the design.
                    Text(verbatim: meta)
                        .font(SonarTheme.uiFont(size: 12.5))
                        .foregroundColor(SonarTheme.text2)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // .wallet-txamt: 15/700; .in green-deep; .failed text3 + strikethrough
                Text(verbatim: (sent ? "−" : "+") + store.money(entry.sats))
                    .font(SonarTheme.uiFont(size: 15, weight: .bold))
                    .monospacedDigit()
                    .strikethrough(failed)
                    .foregroundColor(failed ? SonarTheme.text3 : (sent ? SonarTheme.text : SonarTheme.greenDeep))
            }
            .padding(EdgeInsets(top: 11, leading: 18, bottom: 11, trailing: 18))

            // .wallet-txrow::after — hairline inset to 64px, hidden on the last row
            if divider {
                SonarTheme.hairline
                    .frame(height: 1)
                    .padding(.leading, 64)
                    .padding(.trailing, 18)
            }
        }
    }
}
