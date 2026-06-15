//
// KeychainWalletStorage.swift
// SonarWalletKit
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(iOS)

import Foundation
import Security
import SonarWalletKit

/// Keychain-backed implementation of the `WalletKitStorage` SPI exported by
/// the SonarWalletKit KMP framework. The wallet engine stores its BIP39
/// mnemonic (and small bits of wallet state, e.g. the cached BOLT12 offer)
/// through this class, so everything lands in the iOS Keychain instead of
/// NSUserDefaults.
///
/// Deliberately standalone (raw Security framework, own service name) — it
/// must NOT depend on the app's KeychainManager so the package stays
/// self-contained.
///
/// Thread-safe: every method is a single atomic SecItem* call; the wallet
/// engine invokes these from background dispatchers.
public final class KeychainWalletStorage: NSObject, WalletKitStorage {

    /// Keychain service namespace for all wallet entries.
    public static let service = "chat.bitchat.sonar.wallet"

    public override init() {
        super.init()
    }

    // MARK: - WalletKitStorage

    public func getString(key: String) -> String? {
        guard let data = read(key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func putString(key: String, value: String) {
        write(key, Data(value.utf8))
    }

    public func getBytes(key: String) -> KotlinByteArray? {
        guard let data = read(key) else { return nil }
        return Self.toKotlin(data)
    }

    public func putBytes(key: String, value: KotlinByteArray) {
        write(key, Self.toData(value))
    }

    public func remove(key: String) {
        SecItemDelete(query(key) as CFDictionary)
    }

    public func clear() {
        // Delete every generic-password item under our service.
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
        ]
        SecItemDelete(q as CFDictionary)
    }

    public func contains(key: String) -> Bool {
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
        // The seed must survive device restarts (Breez node starts from a
        // background push) but never leave this device.
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

    // MARK: - KotlinByteArray <-> Data

    static func toKotlin(_ data: Data) -> KotlinByteArray {
        let array = KotlinByteArray(size: Int32(data.count))
        for (i, byte) in data.enumerated() {
            array.set(index: Int32(i), value: Int8(bitPattern: byte))
        }
        return array
    }

    static func toData(_ array: KotlinByteArray) -> Data {
        var data = Data(capacity: Int(array.size))
        for i in 0..<array.size {
            data.append(UInt8(bitPattern: array.get(index: i)))
        }
        return data
    }
}

#endif
