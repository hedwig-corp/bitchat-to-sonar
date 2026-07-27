//
// SonarWalletActivityScreen.swift
// bitchat
//
// Wallet activity screen: gold-themed balance card plus the transaction log
// from SonarPaymentActivityLedger. It is a log only — sending starts from the
// new-chat sheet or inside a chat. Ported from the Compose Multiplatform
// SonarWalletActivityScreen.
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

            ScrollView {
                VStack(spacing: 0) {
                    // ── Balance card ──
                    VStack(spacing: 0) {
                        SNIcon(name: .coin, size: 32)
                            .foregroundColor(SonarTheme.goldDeep)
                        HStack(alignment: .bottom, spacing: 6) {
                            Text(verbatim: sonarFormatSats(balanceSats))
                                .font(SonarTheme.uiFont(size: 36, weight: .heavy))
                                .foregroundColor(SonarTheme.text)
                            Text("sats")
                                .font(SonarTheme.uiFont(size: 15, weight: .bold))
                                .foregroundColor(SonarTheme.text3)
                                .padding(.bottom, 5)
                        }
                        .padding(.top, 10)
                        if let fiat = store.fiatText(balanceSats) {
                            Text(verbatim: fiat)
                                .font(SonarTheme.uiFont(size: 14))
                                .foregroundColor(SonarTheme.text2)
                                .padding(.top, 4)
                        }
                        Text("Lightning wallet")
                            .font(SonarTheme.uiFont(size: 12))
                            .foregroundColor(SonarTheme.text3)
                            .padding(.top, 6)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(SonarTheme.goldSoft)
                    )
                    .padding(EdgeInsets(top: 10, leading: 14, bottom: 4, trailing: 14))

                    // ── Activity ──
                    // Design (`design/handoff/project/sonar/settings.jsx`
                    // WalletScreen): balance, then the transaction log. No
                    // send/receive actions live here — paying starts from the
                    // new-chat sheet or inside a chat.
                    SNSectionLabel("Activity")

                    if entries.isEmpty {
                        SNEmptyState(
                            icon: .bolt, iconSize: 24,
                            title: "No transactions yet",
                            desc: "Payments you send and receive show up here."
                        )
                        .frame(height: 200)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(entries) { entry in
                                activityRow(entry)
                            }
                        }
                    }

                    Color.clear.frame(height: 40)
                }
            }
        }
        .background(SonarTheme.bg.ignoresSafeArea())
    }

    private func activityRow(_ entry: SonarPaymentActivity) -> some View {
        let sent = entry.direction == .outgoing
        let icon: SNIconName = sent ? .bolt : .coin

        let statusLabel: String = {
            switch entry.status {
            case .paid: return "Completed"
            case .pending: return "Pending"
            case .failed: return "Failed"
            }
        }()

        let statusColor: Color = {
            switch entry.status {
            case .paid: return SonarTheme.green
            case .pending: return SonarTheme.goldDeep
            case .failed: return SonarTheme.danger
            }
        }()

        let amountPrefix = sent ? "" : "+"
        let amountColor = sent ? SonarTheme.text : SonarTheme.green
        let fiat = store.fiatText(entry.sats)

        return HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(SonarTheme.goldSoft)
                .frame(width: 38, height: 38)
                .overlay(
                    SNIcon(name: icon, size: 18)
                        .foregroundColor(SonarTheme.goldDeep)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: sent ? "Sent" : "Received")
                    .font(SonarTheme.uiFont(size: 15.5, weight: .semibold))
                    .foregroundColor(SonarTheme.text)
                HStack(spacing: 0) {
                    Text(verbatim: statusLabel)
                        .font(SonarTheme.uiFont(size: 12.5))
                        .foregroundColor(statusColor)
                    Text(verbatim: " · Lightning")
                        .font(SonarTheme.uiFont(size: 12.5))
                        .foregroundColor(SonarTheme.text3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: "\(amountPrefix)\(sonarFormatSats(entry.sats)) sats")
                    .font(SonarTheme.uiFont(size: 16, weight: .semibold))
                    .foregroundColor(amountColor)
                if let fiat {
                    Text(verbatim: fiat)
                        .font(SonarTheme.uiFont(size: 12))
                        .foregroundColor(SonarTheme.text3)
                }
            }
        }
        .padding(EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14))
    }
}
