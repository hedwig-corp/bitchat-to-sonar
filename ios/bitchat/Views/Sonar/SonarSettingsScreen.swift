//
// SonarSettingsScreen.swift
// bitchat
//
// Settings screen ported from design/handoff/project/sonar/settings.jsx,
// backed by real preferences and data only. Rows from the prototype that
// have no real backend yet (App lock, Read receipts, Message requests,
// App icon, Notifications, Data & storage, Help) are hidden — see
// docs/MOCK-REMOVAL-PLAN.md for what is needed to unhide each.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct SonarSettingsScreen: View {
    @EnvironmentObject private var store: SonarAppStore

    @State private var connSheet = false
    @State private var wipeAsk = false
    @State private var eraseAsk = false
    @State private var walletSheet = false
    @State private var currencySheet = false

    var body: some View {
        VStack(spacing: 0) {
            SNNavHeader(hairline: false, onBack: { store.pop() }) {
                SNHeaderName("Settings")
            }
            ScrollView {
                VStack(spacing: 0) {
                    profileCard

                    SNSectionLabel("App")
                    SNSettingsCard {
                        SNSettingsRow(
                            icon: .moon, label: "Appearance",
                            value: store.isDarkMode ? "Dark" : "Light",
                            divider: false
                        ) {
                            store.toggleMode()
                        }
                    }

                    SNSectionLabel("Network")
                    SNSettingsCard {
                        SNSettingsRow(
                            icon: .mesh, tone: .cyan, label: "Connection",
                            sub: store.online ? "Bluetooth + internet" : "Nearby only, no internet",
                            value: store.online ? "Online" : "Bluetooth only",
                            divider: false
                        ) {
                            connSheet = true
                        }
                    }

                    SNSectionLabel("Wallet")
                    SNSettingsCard {
                        SNSettingsRow(
                            icon: .coin, tone: .gold, label: "Balance",
                            sub: "Pays like you message — tap to pay nearby or over the internet",
                            value: walletValue,
                            divider: true
                        ) {
                            // Real balance is just informational; anything
                            // less than ready explains the setup state.
                            if store.balanceSats == nil { walletSheet = true }
                        }
                        // Show balance in fiat (default) or bitcoin (sats).
                        SNSettingsRow(
                            icon: .coin, tone: .gold, label: "Show balance in",
                            value: store.displayMode == "fiat" ? "Money" : "Bitcoin",
                            divider: true
                        ) {
                            store.setDisplayMode(store.displayMode == "fiat" ? "bitcoin" : "fiat")
                        }
                        // Currency for the fiat display.
                        SNSettingsRow(
                            icon: .coin, tone: .gold, label: "Currency",
                            value: store.displayCurrency,
                            divider: false
                        ) {
                            currencySheet = true
                        }
                    }

                    SNSectionLabel("Privacy & safety")
                    SNSettingsCard {
                        SNSettingsRow(icon: .shieldCheck, tone: .cyan, label: "Verified people", value: String(store.verifiedCount)) {
                            store.push(.nearby)
                        }
                        SNSettingsRow(
                            icon: .trash, tone: .cyan, label: "Erase all chats",
                            sub: "Clears conversations — keeps your identity"
                        ) {
                            eraseAsk = true
                        }
                        SNSettingsRow(
                            icon: .trash, tone: .red, label: "Emergency wipe",
                            sub: "Deletes your key, chats and nickname",
                            danger: true, divider: false
                        ) {
                            wipeAsk = true
                        }
                    }
                    settingsNote("Tip: triple-tap the sonar title on the home screen to wipe instantly.")

                    SNSectionLabel("About")
                    SNSettingsCard {
                        SNSettingsRow(
                            icon: .info, label: "About Sonar",
                            sub: "Open protocols — Bluetooth mesh + Nostr",
                            trail: .none, divider: false
                        ) {}
                    }
                    Color.clear.frame(height: 16)
                }
                .padding(.bottom, 40)
            }
        }
        .background(SonarTheme.bg.ignoresSafeArea())
        .snSheet(isPresented: $connSheet, title: "Connection") {
            SNConnectivitySheetContent(onClose: { connSheet = false })
        }
        .snSheet(isPresented: $eraseAsk, title: "Erase all chats") {
            SNEraseChatsSheetContent(
                onErase: {
                    eraseAsk = false
                    store.eraseAllChats()
                },
                onClose: { eraseAsk = false }
            )
        }
        .snSheet(isPresented: $wipeAsk, title: "Emergency wipe") {
            SNWipeSheetContent(
                onWipe: {
                    wipeAsk = false
                    store.wipe()
                },
                onClose: { wipeAsk = false }
            )
        }
        .snSheet(isPresented: $walletSheet, title: "Your wallet") {
            SNWalletSetupSheetContent(
                settingUp: store.walletState == .settingUp,
                onClose: { walletSheet = false }
            )
        }
        .snSheet(isPresented: $currencySheet, title: "Currency") {
            SNCurrencyPickerContent(
                currencies: store.supportedCurrencies(),
                selected: store.displayCurrency,
                onPick: { code in
                    store.setDisplayCurrency(code)
                    currencySheet = false
                },
                onClose: { currencySheet = false }
            )
        }
    }

    /// Real balance when the wallet is ready, in the chosen display unit;
    /// honest affordance otherwise.
    private var walletValue: String {
        switch store.walletState {
        case .ready(let balance): return store.money(balance)
        case .settingUp: return "Setting up\u{2026}"
        case .notConfigured: return "Set up"
        }
    }

    // st-prof — profile card → Profile screen
    private var profileCard: some View {
        Button(action: { store.push(.profile) }) {
            HStack(spacing: 14) {
                SonarAvatar(name: store.nick.isEmpty ? "you" : store.nick, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: store.nick.isEmpty ? "you" : store.nick)
                        .font(SonarTheme.uiFont(size: 18, weight: .bold))
                        .foregroundColor(SonarTheme.text)
                    Text(verbatim: store.shortKey)
                        .font(SonarTheme.monoFont(size: 12))
                        .foregroundColor(SonarTheme.text3)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SNIcon(name: .chevron, size: 15, weight: 2.2)
                    .foregroundColor(SonarTheme.text3)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(SonarTheme.surface)
                    .shadow(color: Color(sonarHex: 0x081E28, opacity: 0.04), radius: 1, y: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(SNRowPressStyle(cornerRadius: 20))
        .padding(EdgeInsets(top: 8, leading: 14, bottom: 4, trailing: 14))
    }

    private func settingsNote(_ text: String) -> some View {
        Text(verbatim: text)
            .font(SonarTheme.uiFont(size: 12))
            .lineSpacing(12 * 0.3)
            .foregroundColor(SonarTheme.text3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 0, leading: 24, bottom: 4, trailing: 24))
    }
}

/// Simple bold header title (bc-hname alone), used by Settings/Profile/Sonar headers.
struct SNHeaderName: View {
    let name: String

    init(_ name: String) { self.name = name }

    var body: some View {
        Text(verbatim: name)
            .font(SonarTheme.uiFont(size: 17, weight: .bold))
            .kerning(-17 * 0.01)
            .foregroundColor(SonarTheme.text)
    }
}
