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
}
