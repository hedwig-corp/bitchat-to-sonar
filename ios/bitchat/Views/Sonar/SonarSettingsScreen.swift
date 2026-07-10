//
// SonarSettingsScreen.swift
// bitchat
//
// Settings screen ported from design/handoff/project/sonar/settings.jsx,
// backed by real preferences and data only. Rows from the prototype that
// have no real backend yet (App lock, Read receipts, Message requests,
// App icon, Data & storage, Help) are hidden — see
// docs/MOCK-REMOVAL-PLAN.md for what is needed to unhide each.
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

struct SonarSettingsScreen: View {
    @EnvironmentObject private var store: SonarAppStore

    @State private var connSheet = false
    @State private var wipeAsk = false
    @State private var eraseAsk = false
    @State private var walletSheet = false
    @State private var currencySheet = false
    @State private var exportKeySheet = false
    @State private var restoreKeySheet = false
    @State private var diagnosticsSheet = false
    @State private var transcriptSpikeB = false
    @State private var collectionHostEnabled = SNTranscriptCollectionHostFlag.isEnabled
    @State private var linkedDevicesSheet = false

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

                    SNSectionLabel("Notifications")
                    SNSettingsCard {
                        SNSettingsRow(
                            icon: .bell,
                            label: "Notifications",
                            sub: "Show Sonar alerts on this device",
                            trail: .toggle(store.notificationsEnabled)
                        ) {
                            store.toggleNotificationsEnabled()
                        }
                        SNSettingsRow(
                            icon: .people,
                            label: "Show names",
                            sub: "Include sender and group names on the lock screen",
                            trail: .toggle(store.notificationShowNames)
                        ) {
                            store.toggleNotificationShowNames()
                        }
                        SNSettingsRow(
                            icon: .eye,
                            label: "Message preview",
                            sub: "Show message text in notifications",
                            trail: .toggle(store.notificationShowPreview),
                            divider: false
                        ) {
                            store.toggleNotificationShowPreview()
                        }
                    }

                    SNSectionLabel("Network")
                    SNSettingsCard {
                        SNSettingsRow(
                            icon: .mesh, tone: .cyan, label: "Connection",
                            sub: store.online ? "Bluetooth + internet" : "Nearby only, no internet",
                            value: store.online ? "Online" : "Bluetooth only",
                            divider: true
                        ) {
                            connSheet = true
                        }
                        SNSettingsRow(
                            icon: .mesh, tone: .cyan, label: "Discover new people",
                            sub: store.bleDiscoverySettingsDescription,
                            trail: .toggle(store.discoverNewPeople),
                            divider: false
                        ) {
                            store.setDiscoverNewPeople(!store.discoverNewPeople)
                        }
                    }

                    SNSectionLabel("Wallet")
                    SNSettingsCard {
                        SNSettingsRow(
                            icon: .coin, tone: .gold, label: "Balance",
                            sub: walletBalanceSub,
                            value: walletValue,
                            divider: walletKeyConfigured
                        ) {
                            if case .ready = store.walletState {
                                store.push(.walletActivity)
                            } else if walletKeyConfigured {
                                walletSheet = true
                            }
                        }
                        if walletKeyConfigured {
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
                    }
                    if !walletKeyConfigured {
                        Text("This build has no Breez API key, so Lightning stays off. Chat and restore still work.")
                            .font(SonarTheme.uiFont(size: 12))
                            .foregroundColor(SonarTheme.text3)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 4)
                    }

                    SNSectionLabel("Privacy & safety")
                    SNSettingsCard {
                        SNSettingsRow(icon: .shieldCheck, tone: .cyan, label: "Verified people", value: String(store.verifiedCount)) {
                            store.push(.nearby)
                        }
                        SNSettingsRow(
                            icon: .link, tone: .cyan, label: "Linked devices",
                            sub: "Use this account on another phone or computer"
                        ) {
                            linkedDevicesSheet = true
                        }
                        SNSettingsRow(
                            icon: .importKey, tone: .cyan, label: "Export private key",
                            sub: "Back up your nsec — needed to restore on another phone"
                        ) {
                            exportKeySheet = true
                        }
                        SNSettingsRow(
                            icon: .importKey, tone: .cyan, label: "Restore account",
                            sub: "Replace this account with an nsec from a backup"
                        ) {
                            restoreKeySheet = true
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

                    if SNTranscriptCollectionHostFlag.entryVisible || SonarTranscriptSpikeB.entryVisible {
                        SNSectionLabel("Developer")
                        SNSettingsCard {
                            if SNTranscriptCollectionHostFlag.entryVisible {
                                SNSettingsRow(
                                    icon: .info,
                                    label: "UIKit transcript host",
                                    sub: "Signal engine (pre-measured cells / sticky days) — default ON",
                                    trail: .toggle(collectionHostEnabled),
                                    divider: SonarTranscriptSpikeB.entryVisible
                                ) {
                                    collectionHostEnabled.toggle()
                                    SNTranscriptCollectionHostFlag.setEnabled(collectionHostEnabled)
                                }
                            }
                            if SonarTranscriptSpikeB.entryVisible {
                                SNSettingsRow(
                                    icon: .info,
                                    label: "Transcript Spike B",
                                    sub: "Signal-Android reverse / stack-from-end host",
                                    trail: .none,
                                    divider: false
                                ) {
                                    transcriptSpikeB = true
                                }
                            }
                        }
                    }

                    SNSectionLabel("About")
                    SNSettingsCard {
                        SNSettingsRow(
                            icon: .info, label: "Diagnostics",
                            sub: "Relay sync status and shareable debug logs"
                        ) {
                            diagnosticsSheet = true
                        }
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
            SNWalletSheetContent(onClose: { walletSheet = false })
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
        .snSheet(isPresented: $exportKeySheet, title: "Export private key") {
            SNExportKeySheetContent()
        }
        .snSheet(isPresented: $restoreKeySheet, title: "Restore account") {
            SNRestoreAccountSheetContent(onClose: { restoreKeySheet = false })
        }
        .snSheet(isPresented: $diagnosticsSheet, title: "Diagnostics") {
            SNDiagnosticsSheetContent()
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $transcriptSpikeB) {
            SonarTranscriptSpikeBDemo(onClose: { transcriptSpikeB = false })
        }
        #else
        .sheet(isPresented: $transcriptSpikeB) {
            SonarTranscriptSpikeBDemo(onClose: { transcriptSpikeB = false })
        }
        #endif
        .snSheet(isPresented: $linkedDevicesSheet, title: "Linked devices") {
            SNLinkedDevicesSheetContent()
        }
    }

    /// Build has a non-empty Breez key — not the same as wallet lifecycle ready.
    /// `.notConfigured` also covers transient setup failure when the key exists.
    private var walletKeyConfigured: Bool { SonarBreezBuildConfig.hasAPIKey }

    private var walletBalanceSub: String {
        walletKeyConfigured
            ? "Pays like you message — tap to pay nearby or over the internet"
            : "Lightning wallet unavailable in this build"
    }

    /// Real balance when the wallet is ready, in the chosen display unit;
    /// honest affordance otherwise. Keyless builds say Unavailable (Compose parity).
    /// Key-present + `.notConfigured` is a transient/setup gap, not a missing key.
    private var walletValue: String {
        switch store.walletState {
        case .ready(let balance): return store.money(balance)
        case .settingUp: return "Setting up\u{2026}"
        case .notConfigured:
            return walletKeyConfigured ? "Not ready" : "Unavailable"
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

// MARK: - Export private key sheet (ExportKeySheet) — self-custody escape hatch

/// Reveal + copy the `nsec1…` private key so the user can move their account to
/// another Nostr wallet. Ported from ExportKeySheet in settings.jsx.
struct SNExportKeySheetContent: View {
    @EnvironmentObject private var store: SonarAppStore

    @State private var nsec: String?
    @State private var revealed = false
    @State private var copied = false

    /// First 5 chars + 28 bullets, matching the prototype's masked form.
    private var masked: String {
        guard let nsec else { return "" }
        return String(nsec.prefix(5)) + " " + String(repeating: "\u{2022}", count: 28)
    }

    private func copyKey() {
        guard let nsec else { return }
        #if canImport(UIKit)
        UIPasteboard.general.string = nsec
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(nsec, forType: .string)
        #endif
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) {
            withAnimation(.easeOut(duration: 0.15)) { copied = false }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // nsec-warn
            HStack(alignment: .top, spacing: 11) {
                SNIcon(name: .shield, size: 18, weight: 2)
                    .foregroundColor(SonarTheme.danger)
                (Text("This ") + Text("nsec").fontWeight(.bold) + Text(" key ")
                    + Text("is").fontWeight(.bold)
                    + Text(" your account. Anyone who has it can read your messages and spend your balance. Paste it into another Nostr app to move in — never share it with a person."))
                    .font(SonarTheme.uiFont(size: 13))
                    .lineSpacing(13 * 0.5)
                    .foregroundColor(SonarTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 13, leading: 15, bottom: 13, trailing: 15))
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SonarTheme.danger.opacity(0.10)))
            .padding(EdgeInsets(top: 2, leading: 8, bottom: 12, trailing: 8))

            // nsec-field — tap to reveal / hide
            Button { if nsec != nil { revealed.toggle() } } label: {
                HStack(spacing: 10) {
                    Text(verbatim: nsec == nil ? "Loading\u{2026}" : (revealed ? (nsec ?? "") : masked))
                        .font(SonarTheme.monoFont(size: 13))
                        .lineSpacing(13 * 0.5)
                        .foregroundColor(revealed ? SonarTheme.text : SonarTheme.text2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                    SNIcon(name: revealed ? .eyeOff : .eye, size: 17, weight: 2)
                        .foregroundColor(SonarTheme.text3)
                }
                .padding(EdgeInsets(top: 14, leading: 15, bottom: 14, trailing: 15))
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SonarTheme.surface2))
                .contentShape(Rectangle())
            }
            .buttonStyle(SNScaleStyle(scale: 0.99))
            .disabled(nsec == nil)
            .padding(EdgeInsets(top: 0, leading: 8, bottom: 12, trailing: 8))

            // copy
            Button(action: copyKey) {
                HStack(spacing: 7) {
                    SNIcon(name: copied ? .check : .copy, size: 17, weight: 2.2)
                    Text(verbatim: copied ? "Copied" : "Copy private key")
                        .font(SonarTheme.uiFont(size: 14.5, weight: .bold))
                }
                .foregroundColor(SonarTheme.onAccent)
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(copied ? SonarTheme.green : SonarTheme.accentFill))
            }
            .buttonStyle(SNScaleStyle(scale: 0.97))
            .disabled(nsec == nil)
            .padding(.horizontal, 8)

            Text("Tip: store it in a password manager. Sonar can\u{2019}t recover it for you.")
                .font(SonarTheme.uiFont(size: 13))
                .lineSpacing(13 * 0.5)
                .foregroundColor(SonarTheme.text3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(EdgeInsets(top: 12, leading: 18, bottom: 4, trailing: 18))
        }
        .task { nsec = await store.exportNsec() }
    }
}

/// Settings → Restore account: paste an `nsec1…` to replace the local identity
/// and rebuild the Lightning wallet from that key. Destructive for chats on
/// this device (Marmot DB wipe); wallet is always rebuilt from the pasted nsec.
struct SNRestoreAccountSheetContent: View {
    @EnvironmentObject private var store: SonarAppStore
    var onClose: () -> Void

    @State private var nsec = ""
    @State private var errorText: String?
    @State private var inFlight = false
    @State private var confirmed = false
    @FocusState private var focused: Bool

    private var nsecOk: Bool {
        let t = nsec.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.range(of: "^nsec1[0-9a-z]{20,}$", options: .regularExpression) != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 11) {
                SNIcon(name: .shield, size: 18, weight: 2)
                    .foregroundColor(SonarTheme.danger)
                Text("This replaces the account on this phone. Chats stored here are erased. Your Lightning wallet is rebuilt from the nsec you paste (same key = same balance after sync).")
                    .font(SonarTheme.uiFont(size: 13))
                    .lineSpacing(13 * 0.5)
                    .foregroundColor(SonarTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 13, leading: 15, bottom: 13, trailing: 15))
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SonarTheme.danger.opacity(0.10)))
            .padding(EdgeInsets(top: 2, leading: 8, bottom: 12, trailing: 8))

            ZStack(alignment: .topLeading) {
                if nsec.isEmpty {
                    Text(verbatim: "nsec1\u{2026}")
                        .font(SonarTheme.monoFont(size: 15))
                        .foregroundColor(SonarTheme.text3)
                        .padding(EdgeInsets(top: 14, leading: 16, bottom: 0, trailing: 16))
                        .allowsHitTesting(false)
                }
                TextEditor(text: $nsec)
                    .font(SonarTheme.monoFont(size: 15))
                    .foregroundColor(SonarTheme.text)
                    .focused($focused)
                    .frame(minHeight: 72)
                    .scrollContentBackground(.hidden)
                    .padding(EdgeInsets(top: 6, leading: 11, bottom: 6, trailing: 11))
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
            }
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(SonarTheme.surface2))
            .padding(.horizontal, 8)

            Toggle(isOn: $confirmed) {
                Text("I understand chats on this phone will be erased")
                    .font(SonarTheme.uiFont(size: 13, weight: .semibold))
                    .foregroundColor(SonarTheme.text)
            }
            .toggleStyle(.switch)
            .padding(EdgeInsets(top: 14, leading: 12, bottom: 8, trailing: 12))

            if let errorText {
                Text(verbatim: errorText)
                    .font(SonarTheme.uiFont(size: 13))
                    .foregroundColor(SonarTheme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            SNPrimaryButton(
                label: inFlight ? "Restoring\u{2026}" : "Restore account",
                danger: true,
                disabled: !nsecOk || !confirmed || inFlight
            ) {
                restore()
            }
            .padding(.horizontal, 8)
            SNGhostButton(label: "Cancel", action: onClose)
                .padding(.top, 4)
        }
    }

    private func restore() {
        let key = nsec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard nsecOk, confirmed, !inFlight else { return }
        inFlight = true
        errorText = nil
        Task { @MainActor in
            do {
                try await store.restoreAccount(nsec: key)
                onClose()
            } catch {
                errorText = (error as? SonarAccountRestoreError)?.localizedDescription
                    ?? "That key couldn\u{2019}t be imported. Check you pasted the full nsec1\u{2026} key."
                inFlight = false
            }
        }
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
