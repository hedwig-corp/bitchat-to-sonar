//
// SonarLegacyWalletCard.swift
// bitchat
//
// The "Old Lightning wallet" section: shown only while the legacy Breez
// wallet exists on this device (see `LegacyBreezWallet`). Balance + pending,
// "Send from old wallet" (the normal send flow with the legacy wallet as the
// source), and "Delete old wallet" — offered only when the delete gate proves
// the funds are safe; otherwise the row says why. Used by Settings, the
// Wallet screen and the Mac settings/wallet panes, and mirrors the Compose
// card.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct SNLegacyWalletSection: View {
    @EnvironmentObject private var store: SonarAppStore
    /// The host screen presents `SNLegacyWalletDeleteSheetContent` at its
    /// root (`snSheet` is an overlay, so it must not live inside a scroll
    /// view section).
    let onDelete: () -> Void

    var body: some View {
        if let legacy = store.legacyWallet {
            VStack(spacing: 0) {
                SNSectionLabel(String(localized: "Old Lightning wallet"))
                SNSettingsCard {
                    SNSettingsRow(
                        icon: .bolt, tone: .gold,
                        label: String(localized: "Balance"),
                        sub: pendingLine(legacy) ?? String(localized: "Your wallet from before Sonar moved to ecash"),
                        value: balanceValue(legacy),
                        trail: .none
                    ) {
                        store.refreshLegacyWallet()
                    }
                    SNSettingsRow(
                        icon: .send, tone: .gold,
                        label: String(localized: "Send from old wallet"),
                        sub: String(localized: "Pay anyone, or move the sats to your wallet"),
                        divider: true
                    ) {
                        store.sendFromLegacyWallet()
                    }
                    .disabled(!isReady(legacy))
                    .opacity(isReady(legacy) ? 1 : 0.5)
                    SNSettingsRow(
                        icon: .trash, tone: .red,
                        label: String(localized: "Delete old wallet"),
                        sub: store.legacyDeleteBlockerMessage ?? String(localized: "It's empty — safe to remove"),
                        danger: store.legacyDeleteBlockerMessage == nil,
                        trail: store.legacyDeleteBlockerMessage == nil ? .chevron : .none,
                        divider: false
                    ) {
                        guard store.legacyDeleteBlockerMessage == nil else {
                            store.refreshLegacyWallet()
                            return
                        }
                        onDelete()
                    }
                }
            }
            .onAppear { store.refreshLegacyWallet() }
        }
    }

    private func isReady(_ legacy: LegacyBreezWallet) -> Bool {
        if case .ready = legacy.state { return true }
        return false
    }

    private func balanceValue(_ legacy: LegacyBreezWallet) -> String {
        switch legacy.state {
        case .ready(let balance): return store.money(balance)
        case .settingUp: return String(localized: "Checking…")
        case .notConfigured:
            return SonarBreezBuildConfig.hasAPIKey
                ? String(localized: "Offline")
                : String(localized: "Unavailable in this build")
        }
    }

    private func pendingLine(_ legacy: LegacyBreezWallet) -> String? {
        guard let detail = legacy.balanceDetail else { return nil }
        var parts: [String] = []
        if detail.pendingReceiveSats > 0 {
            let amount = store.money(detail.pendingReceiveSats)
            parts.append(String(localized: "\(amount) arriving"))
        }
        if detail.pendingSendSats > 0 {
            let amount = store.money(detail.pendingSendSats)
            parts.append(String(localized: "\(amount) leaving"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Confirmation for deleting the old wallet. The store re-checks the delete
/// gate on a fresh sync before anything is removed; a refusal or failure is
/// shown here instead of closing.
struct SNLegacyWalletDeleteSheetContent: View {
    @EnvironmentObject private var store: SonarAppStore
    let onClose: () -> Void
    @State private var deleting = false
    @State private var deleteError: String?

    var body: some View {
        VStack(spacing: 0) {
            Text(verbatim: deleteError ?? String(localized: "Sonar checked the old wallet: it holds nothing and has nothing in flight. Deleting removes it from this device. Your ecash wallet is not affected."))
                .font(SonarTheme.uiFont(size: 13.5))
                .lineSpacing(13.5 * 0.3)
                .foregroundColor(deleteError == nil ? SonarTheme.text2 : SonarTheme.danger)
                .multilineTextAlignment(.center)
                .padding(EdgeInsets(top: 8, leading: 14, bottom: 2, trailing: 14))
            VStack(spacing: 6) {
                SNPrimaryButton(
                    label: deleting ? String(localized: "Checking…") : String(localized: "Delete old wallet"),
                    danger: true,
                    disabled: deleting
                ) {
                    guard !deleting else { return }
                    deleting = true
                    Task {
                        let failure = await store.deleteLegacyWallet()
                        deleting = false
                        if let failure {
                            deleteError = failure
                        } else {
                            onClose()
                        }
                    }
                }
                SNGhostButton(label: String(localized: "Cancel"), action: onClose)
            }
            .padding(EdgeInsets(top: 6, leading: 8, bottom: 0, trailing: 8))
        }
    }
}
