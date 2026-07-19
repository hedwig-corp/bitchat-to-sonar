//
// SonarAccountKeyExport.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Settings → Export private key: prefer the durable account key over the
/// live Marmot engine. Compose's `exportNsec()` reads secrets synchronously;
/// iOS must not FIFO-wait on `MarmotService.workQueue`, which sync/relay work
/// can park for seconds.
enum SonarAccountKeyExport {
    /// Keychain item that stores the account `nsec1…` (same as onboarding).
    static let marmotNsecKey = "marmot-nsec"

    /// Durable `nsec1…` from keychain, or nil when missing / unreadable.
    ///
    /// Transient failures (`deviceLocked` / `accessDenied` / …) also return nil
    /// so `exportNsec` can fall through to the same-session in-memory identity
    /// (`engineExport`). That is intentional: connect refuses to mint a
    /// replacement key on those errors (Account Key Durability), so the live
    /// identity matches the durable account when the device later unlocks.
    static func nsecFromKeychain(_ keychain: KeychainManagerProtocol) -> String? {
        switch keychain.getIdentityKeyWithResult(forKey: marmotNsecKey) {
        case .success(let data):
            let nsec = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return nsec.isEmpty ? nil : nsec
        case .itemNotFound, .accessDenied, .deviceLocked, .authenticationFailed, .otherError:
            return nil
        }
    }

    /// Call-site preference used by Settings export (`SonarAppStore` /
    /// `MarmotChatModel`): durable keychain first, then the in-memory Marmot
    /// identity via `engineExport`. A keychain hit must not invoke
    /// `engineExport` (that path used to park behind sync on `workQueue`).
    ///
    /// Keychain is the account source of truth when present — matching Compose
    /// `identityNsec()` and Account Key Durability. We do not cross-check
    /// against the engine here: that would reintroduce an engine wait on the
    /// fast path.
    static func exportNsec(
        keychain: KeychainManagerProtocol,
        engineExport: () async -> String?
    ) async -> String? {
        if let nsec = nsecFromKeychain(keychain) {
            return nsec
        }
        return await engineExport()
    }
}
