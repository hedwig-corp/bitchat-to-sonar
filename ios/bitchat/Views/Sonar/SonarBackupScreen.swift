//
// SonarBackupScreen.swift
// bitchat
//
// Chat backup — 1:1 with design/handoff/project/sonar/settings.jsx
// `BackupScreen`, mirroring the Compose SonarBackupScreen string for string.
//
// Two layouts behind one hero: on, where the card carries the toggle, cadence
// and last-backup rows above a stats strip; off, where three feature rows sit
// above a bottom call to action. Every figure is real — the design's 128 MB and
// 1,204 messages are prototype fiction, so an unmeasured value renders as a
// dash rather than a confident zero.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SonarCore
import SwiftUI

struct SonarBackupScreen: View {
    @EnvironmentObject private var store: SonarAppStore
    @State private var setupSheet = false
    @State private var freqSheet = false
    @State private var dryRunSheet = false

    private var lastBackup: String? {
        BackupFormat.lastBackup(
            atSecs: store.backupLastSuccessAt,
            nowSecs: UInt64(Date().timeIntervalSince1970)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            SNNavHeader(hairline: false, onBack: { store.pop() }) {
                SNHeaderName(String(localized: "Chat backup"))
            }
            ScrollView {
                VStack(spacing: 0) {
                    hero
                    if store.autoBackupEnabled {
                        onLayout
                    } else {
                        offLayout
                    }
                    Spacer().frame(height: 16)
                }
            }
            if !store.autoBackupEnabled {
                bottomCta
            }
        }
        .background(SonarTheme.bg.ignoresSafeArea())
        .onAppear {
            store.discloseAutoBackup()
            store.refreshBackupPolicy()
        }
        .snSheet(isPresented: $setupSheet, title: String(localized: "Turn on backup")) {
            setupSheetContent
        }
        .snSheet(isPresented: $freqSheet, title: String(localized: "Backup frequency")) {
            frequencySheetContent
        }
        .snSheet(isPresented: $dryRunSheet, title: String(localized: "Dry run · restore preview")) {
            SonarBackupDryRunSheet()
        }
    }

    // bk-hero: icon, title and copy that flip with the on state.
    private var hero: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(store.autoBackupEnabled ? SonarTheme.accentSoft : SonarTheme.surface2)
                .frame(width: 66, height: 66)
                .overlay(
                    SNIcon(name: .shieldCheck, size: 34)
                        .foregroundColor(store.autoBackupEnabled ? SonarTheme.accentDeep : SonarTheme.text3)
                )
            Text(verbatim: store.autoBackupEnabled
                ? String(localized: "Backups are on")
                : String(localized: "Back up your chats"))
                .font(SonarTheme.uiFont(size: 20, weight: .bold))
                .foregroundColor(SonarTheme.text)
                .padding(.top, 12)
            Text(verbatim: store.autoBackupEnabled
                ? String(localized: "Your history is encrypted with the key on this phone — nothing extra to remember.")
                : String(localized: "Keep an encrypted copy of your messages, groups and settings so you can restore on a new phone."))
                .font(SonarTheme.uiFont(size: 13.5, weight: .medium))
                .foregroundColor(SonarTheme.text3)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    private var onLayout: some View {
        VStack(spacing: 0) {
            SNSettingsCard {
                SNSettingsRow(
                    icon: .shieldCheck, tone: .cyan,
                    label: String(localized: "Backup"),
                    value: String(localized: "On"),
                    trail: .toggle(true)
                ) {
                    store.setAutoBackupEnabled(false)
                }
                SNSettingsRow(
                    icon: .data,
                    label: String(localized: "Frequency"),
                    value: BackupFormat.frequencyLabel(store.backupFrequency)
                ) {
                    freqSheet = true
                }
                SNSettingsRow(
                    icon: .drive,
                    label: String(localized: "Last backup"),
                    sub: String(localized: "Restores automatically · tap for a dry run"),
                    value: lastBackup ?? String(localized: "Never"),
                    divider: false
                ) {
                    dryRunSheet = true
                }
            }
            statsStrip
            Text(verbatim: String(localized: "Backups are encrypted on this device before upload. Sonar's servers only ever see ciphertext."))
                .font(SonarTheme.uiFont(size: 12, weight: .medium))
                .foregroundColor(SonarTheme.text3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            Spacer().frame(height: 8)
            dryRunCard
        }
    }

    private var offLayout: some View {
        VStack(spacing: 0) {
            SNSettingsCard {
                feature(icon: .lock,
                        title: String(localized: "Encrypted by default"),
                        sub: String(localized: "Sealed with the key already on this phone."))
                feature(icon: .data,
                        title: String(localized: "Automatic"),
                        sub: String(localized: "Runs quietly in the background, on your schedule."))
                feature(icon: .importKey,
                        title: String(localized: "Restores automatically"),
                        sub: String(localized: "Sign in on a new phone and your history comes back on its own."),
                        divider: false)
            }
            Spacer().frame(height: 8)
            dryRunCard
        }
    }

    private var dryRunCard: some View {
        SNSettingsCard {
            SNSettingsRow(
                icon: .importKey,
                label: String(localized: "Dry run a restore"),
                sub: String(localized: "Preview what would come back — changes nothing"),
                divider: false
            ) {
                dryRunSheet = true
            }
        }
    }

    // bk-stats: three figures side by side; a dash where nothing is measured.
    private var statsStrip: some View {
        HStack(spacing: 8) {
            stat(BackupFormat.bytes(store.backupSizeBytes) ?? "—",
                 String(localized: "backup size"))
            stat(String(localized: "End-to-end"), String(localized: "encrypted"))
            stat(BackupFormat.count(store.backupMessageCount) ?? "—",
                 String(localized: "messages"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(verbatim: value)
                .font(SonarTheme.uiFont(size: 15, weight: .bold))
                .foregroundColor(SonarTheme.text)
            Text(verbatim: label)
                .font(SonarTheme.uiFont(size: 11.5, weight: .medium))
                .foregroundColor(SonarTheme.text3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(SonarTheme.surface)
        )
    }

    // bk-feat: an explanatory row used in the off state and the setup sheet.
    private func feature(icon: SNIconName, title: String, sub: String, divider: Bool = true) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(SonarTheme.surface2)
                    .frame(width: 34, height: 34)
                    .overlay(SNIcon(name: icon, size: 17).foregroundColor(SonarTheme.text2))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(SonarTheme.uiFont(size: 15, weight: .semibold))
                        .foregroundColor(SonarTheme.text)
                    Text(verbatim: sub)
                        .font(SonarTheme.uiFont(size: 12.5, weight: .medium))
                        .foregroundColor(SonarTheme.text3)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            if divider {
                Rectangle()
                    .fill(SonarTheme.surface2)
                    .frame(height: 1)
                    .padding(.leading, 60)
            }
        }
    }

    private var bottomCta: some View {
        VStack(spacing: 8) {
            SNPrimaryButton(label: String(localized: "Turn on backup")) {
                setupSheet = true
            }
            Text(verbatim: String(localized: "Encrypted with the key already on this phone — nothing to write down."))
                .font(SonarTheme.uiFont(size: 12, weight: .medium))
                .foregroundColor(SonarTheme.text3)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 30)
    }

    private var setupSheetContent: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(SonarTheme.accentSoft)
                .frame(width: 60, height: 60)
                .overlay(SNIcon(name: .shieldCheck, size: 34).foregroundColor(SonarTheme.accentDeep))
            Text(verbatim: String(localized: "Encrypted automatically"))
                .font(SonarTheme.uiFont(size: 17, weight: .bold))
                .foregroundColor(SonarTheme.text)
                .padding(.top, 10)
            Text(verbatim: String(localized: "Your backup is locked with the key already on this phone — there's nothing extra to write down. Sonar's servers only ever see ciphertext."))
                .font(SonarTheme.uiFont(size: 13, weight: .medium))
                .foregroundColor(SonarTheme.text3)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
                .padding(.horizontal, 22)
            SNSettingsCard {
                feature(icon: .lock,
                        title: String(localized: "No passphrase to lose"),
                        sub: String(localized: "Sealed with your existing identity key."))
                feature(icon: .importKey,
                        title: String(localized: "Restores itself"),
                        sub: String(localized: "Sign in on a new phone and it recovers in the background."),
                        divider: false)
            }
            VStack(spacing: 8) {
                SNPrimaryButton(label: String(localized: "Turn on backup")) {
                    store.setAutoBackupEnabled(true)
                    setupSheet = false
                }
                SNGhostButton(label: String(localized: "Not now")) {
                    setupSheet = false
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private var frequencySheetContent: some View {
        VStack(spacing: 0) {
            frequencyRow("daily", String(localized: "Daily"),
                         String(localized: "Once a day, plus after changes"))
            frequencyRow("weekly", String(localized: "Weekly"),
                         String(localized: "Once a week"))
            frequencyRow("manual", String(localized: "Manual only"),
                         String(localized: "Nothing uploads unless you ask"), divider: false)
            SNGhostButton(label: String(localized: "Done")) {
                freqSheet = false
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private func frequencyRow(_ key: String, _ label: String, _ sub: String, divider: Bool = true) -> some View {
        SNSettingsRow(
            icon: .data, label: label, sub: sub,
            trail: store.backupFrequency == key ? .check : .none,
            divider: divider
        ) {
            store.updateBackupFrequency(key)
            freqSheet = false
        }
    }
}

/// Dry run: what a restore would bring back.
///
/// The core preview never stages, commits, or opens the live store, so this is
/// safe to open mid-conversation — and the sheet says so, because a screen that
/// reads a backup is exactly where a user expects something to be overwritten.
private struct SonarBackupDryRunSheet: View {
    @EnvironmentObject private var store: SonarAppStore
    @State private var preview: AccountBackupPreviewInfo?
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Text(verbatim: String(localized: "Nothing is changed on your device"))
                    .font(SonarTheme.uiFont(size: 11.5, weight: .semibold))
                    .foregroundColor(SonarTheme.accentDeep)
                Text(verbatim: title)
                    .font(SonarTheme.uiFont(size: 17, weight: .bold))
                    .foregroundColor(SonarTheme.text)
                    .padding(.top, 8)
                Text(verbatim: subtitle)
                    .font(SonarTheme.uiFont(size: 13, weight: .medium))
                    .foregroundColor(SonarTheme.text3)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)

            if let preview {
                ForEach(Array(preview.conversations.enumerated()), id: \.offset) { _, c in
                    HStack(spacing: 11) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(SonarTheme.surface2)
                            .frame(width: 30, height: 30)
                            .overlay(SNIcon(name: .lock, size: 15).foregroundColor(SonarTheme.text2))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: c.name)
                                .font(SonarTheme.uiFont(size: 14.5, weight: .semibold))
                                .foregroundColor(SonarTheme.text)
                            if !c.latestContent.isEmpty {
                                Text(verbatim: c.latestContent)
                                    .font(SonarTheme.uiFont(size: 12.5, weight: .medium))
                                    .foregroundColor(SonarTheme.text3)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        Text(verbatim: BackupFormat.count(c.messageCount) ?? "")
                            .font(SonarTheme.uiFont(size: 12.5, weight: .medium))
                            .foregroundColor(SonarTheme.text3)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                }
            }
        }
        .task {
            do {
                preview = try await store.marmot.previewBackup()
            } catch {
                let message = error.localizedDescription
                failure = message.contains("account_backup_missing") || message.contains("no account backup found")
                    ? String(localized: "No backup on the server for this account yet.")
                    : String(localized: "Could not read the backup — try again when online.")
            }
        }
    }

    private var title: String {
        if failure != nil { return String(localized: "Nothing to preview") }
        if preview == nil { return String(localized: "Reading your backup…") }
        return String(localized: "This is what would come back")
    }

    private var subtitle: String {
        if let failure { return failure }
        guard let preview else {
            return String(localized: "Decrypting the index to show you exactly what a restore would bring back.")
        }
        let at = BackupFormat.lastBackup(
            atSecs: preview.uploadedAtSecs,
            nowSecs: UInt64(Date().timeIntervalSince1970)
        )
        let counts = "\(preview.conversations.count) conversations · \(BackupFormat.count(preview.totalMessages) ?? "0") messages"
        return at.map { counts + " · from \($0)" } ?? counts
    }
}
