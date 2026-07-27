//
// BackupSanityItem.swift
// bitchat
//
// Settings → Chat backup sanity checklist. Mirrors Compose
// `buildBackupSanityChecks` so both hosts show the same checks.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

struct BackupSanityItem: Identifiable, Equatable {
    let id: String
    let title: String
    let ok: Bool
    let detail: String

    static func build(
        hasIdentity: Bool,
        localDbReady: Bool,
        disclosed: Bool,
        policyReadable: Bool,
        autoBackupEnabled: Bool,
        lastSuccessAt: Int64?,
        lastError: String?,
        dirty: Bool,
        relayConnected: Bool
    ) -> [BackupSanityItem] {
        [
            BackupSanityItem(
                id: "identity",
                title: "Account key",
                ok: hasIdentity,
                detail: hasIdentity ? "nsec present on this device" : "Missing account key"
            ),
            BackupSanityItem(
                id: "local_db",
                title: "Local chat database",
                ok: localDbReady,
                detail: localDbReady ? "Marmot DB open" : "Chat database not ready"
            ),
            BackupSanityItem(
                id: "disclosed",
                title: "Backup settings opened",
                ok: disclosed,
                detail: disclosed ? "Auto-backup may run when due" : "Open this page to allow auto-backup"
            ),
            BackupSanityItem(
                id: "policy",
                title: "Backup policy",
                ok: policyReadable,
                detail: {
                    if !policyReadable { return "Could not read backup policy" }
                    return autoBackupEnabled ? "Auto-backup on" : "Auto-backup off"
                }()
            ),
            BackupSanityItem(
                id: "cloud",
                title: "Cloud backup",
                ok: {
                    if let ts = lastSuccessAt, ts > 0 {
                        return (lastError ?? "").isEmpty
                    }
                    return false
                }(),
                detail: {
                    if let ts = lastSuccessAt, ts > 0, (lastError ?? "").isEmpty {
                        return "Last upload succeeded"
                    }
                    if let err = lastError, !err.isEmpty { return err }
                    return "No successful upload yet"
                }()
            ),
            BackupSanityItem(
                id: "dirty",
                title: "Pending changes",
                ok: !dirty,
                detail: dirty ? "Chats changed since last backup" : "In sync with last backup"
            ),
            BackupSanityItem(
                id: "relay",
                title: "Internet for upload",
                ok: relayConnected,
                detail: relayConnected
                    ? "Online — upload can reach Blossom"
                    : "Offline — seal works; upload needs network"
            ),
        ]
    }
}
