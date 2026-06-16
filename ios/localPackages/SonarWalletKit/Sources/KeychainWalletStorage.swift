//
// KeychainWalletStorage.swift
// WalletKit
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(iOS)

import Foundation
import Security

/// Keychain-backed store for the Sonar wallet: the deterministic seed (so the
/// Breez node restarts from a background push without leaving the device) plus
/// small display prefs. Standalone — raw Security framework, own service name —
/// so the package stays self-contained. Every method is a single atomic SecItem*
/// call; the wallet façade invokes these from a background queue.
public final class KeychainWalletStorage {

    /// Keychain service namespace for all wallet entries.
    public static let service = "chat.bitchat.sonar.wallet"

    public init() {}

    // MARK: - Public API (plain Swift, no KMP types)

    public func getString(_ key: String) -> String? {
        guard let data = read(key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func putString(_ key: String, _ value: String) {
        write(key, Data(value.utf8))
    }

    public func getData(_ key: String) -> Data? { read(key) }

    public func putData(_ key: String, _ value: Data) { write(key, value) }

    public func remove(_ key: String) {
        SecItemDelete(query(key) as CFDictionary)
    }

    public func clear() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
        ]
        SecItemDelete(q as CFDictionary)
    }

    public func contains(_ key: String) -> Bool {
        var q = query(key)
        q[kSecReturnData as String] = false
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    // MARK: - Keychain plumbing

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
        ]
    }

    private func read(_ key: String) -> Data? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func write(_ key: String, _ data: Data) {
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var add = query(key)
        attrs.forEach { add[$0] = $1 }
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            SecItemUpdate(query(key) as CFDictionary, attrs as CFDictionary)
        }
    }
}

#endif
