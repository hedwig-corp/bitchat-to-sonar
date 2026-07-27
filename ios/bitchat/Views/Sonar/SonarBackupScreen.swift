//
// SonarBackupScreen.swift
// bitchat
//
// Settings → Chat backup: status, auto-backup toggle, sanity checklist, and
// manual Blossom upload. Mirrors Compose SonarBackupScreen.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct SonarBackupScreen: View {
    @EnvironmentObject private var store: SonarAppStore

    var body: some View {
        VStack(spacing: 0) {
            SNNavHeader(hairline: false, onBack: { store.pop() }) {
                SNHeaderName(String(localized: "Chat backup"))
            }
            ScrollView {
                VStack(spacing: 0) {
                    statusCard

                    SNSectionLabel(String(localized: "Auto-backup"))
                    SNSettingsCard {
                        SNSettingsRow(
                            icon: .shieldCheck,
                            tone: .cyan,
                            label: String(localized: "Auto-backup"),
                            sub: String(localized: "Encrypted cloud backup when chats change"),
                            trail: .toggle(store.autoBackupEnabled),
                            divider: false
                        ) {
                            store.setAutoBackupEnabled(!store.autoBackupEnabled)
                        }
                    }

                    SNSectionLabel(String(localized: "Sanity check"))
                    SNSettingsCard {
                        let checks = store.backupSanityChecks
                        ForEach(Array(checks.enumerated()), id: \.element.id) { index, item in
                            SNSettingsRow(
                                icon: item.ok ? .check : .info,
                                tone: .cyan,
                                label: item.title,
                                sub: item.detail,
                                value: item.ok ? "OK" : "Check",
                                divider: index < checks.count - 1
                            ) {}
                        }
                        if checks.isEmpty {
                            SNSettingsRow(
                                icon: .info,
                                tone: .cyan,
                                label: String(localized: "Sanity check"),
                                sub: "Loading…",
                                divider: false
                            ) {}
                        }
                    }

                    SNSectionLabel(String(localized: "Backup chats"))
                    SNSettingsCard {
                        SNSettingsRow(
                            icon: .shieldCheck,
                            tone: .cyan,
                            label: store.backupInProgress
                                ? String(localized: "Backing up chats…")
                                : String(localized: "Backup chats"),
                            sub: String(localized: "Encrypted cloud backup — recover chats after reinstall"),
                            divider: false
                        ) {
                            guard !store.backupInProgress else { return }
                            Task { await store.backupAccountNow() }
                        }
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .background(SonarTheme.bg.ignoresSafeArea())
        .onAppear {
            store.discloseAutoBackup()
            store.refreshBackupPolicy()
        }
    }

    private var statusCard: some View {
        VStack(spacing: 0) {
            SNIcon(name: .shieldCheck, size: 32)
                .foregroundColor(SonarTheme.accentDeep)
            Text(
                store.autoBackupStatusLine.isEmpty
                    ? String(localized: "No backup yet")
                    : store.autoBackupStatusLine
            )
            .font(SonarTheme.uiFont(size: 18, weight: .bold))
            .foregroundColor(SonarTheme.text)
            .padding(.top, 10)
            Text(String(localized: "Encrypted cloud backup when chats change"))
                .font(SonarTheme.uiFont(size: 13))
                .foregroundColor(SonarTheme.text2)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
                .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(SonarTheme.accentSoft)
        )
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 4, trailing: 14))
    }
}
