//
// BridgedWallet.swift
// bitchat
//
// Glue: adapts the app-level WalletBridgeService (SonarWalletKit / Breez)
// to the SonarWalletProviding protocol the payments UI consumes.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Combine
import CryptoKit
import Foundation
import Security

/// Deterministic wallet-entropy derivation from the Sonar chat identity.
///
/// One identity = one wallet: the BOLT12 Lightning wallet is derived from the
/// same Nostr secret that backs the chat identity (Keychain `marmot-nsec`), so
/// the wallet is always reconstructable from the nsec — the nsec IS the wallet
/// backup. Derivation is a domain-separated HKDF so the wallet seed is not the
/// raw signing key:
///
///   entropy = HKDF-SHA256(ikm: nostrSecret, salt: "sonar-wallet",
///                         info: "sonar-bolt12-v1", L: 32)
///
/// Pure and platform-agnostic so it can be unit-tested without the wallet
/// framework.
enum SonarWalletDerivation {
    static let salt = "sonar-wallet"
    static let info = "sonar-bolt12-v1"

    /// Derive 32 bytes of wallet entropy from a 32-byte Nostr secret.
    static func entropy(fromSecret secret: Data) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: Data(salt.utf8),
            info: Data(info.utf8),
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    /// 64-char lowercase hex of the derived entropy (what the wallet-kit
    /// `createWalletFromEntropy` expects).
    static func entropyHex(fromSecret secret: Data) -> String {
        entropy(fromSecret: secret).map { String(format: "%02x", $0) }.joined()
    }

    /// Decode the 32-byte secret from an `nsec1…` bech32 string.
    static func secret(fromNsec nsec: String) -> Data? {
        guard let decoded = try? Bech32.decode(nsec),
              decoded.hrp == "nsec",
              decoded.data.count == 32
        else { return nil }
        return decoded.data
    }
}

#if os(iOS) || os(macOS)

@MainActor
final class BridgedWallet: SonarWalletProviding {
    /// Keychain key holding the chat identity nsec (written by MarmotChatModel).
    private static let nsecKeychainKey = "marmot-nsec"

    private let bridge: WalletBridgeService
    private let keychain: KeychainManagerProtocol

    init(keychain: KeychainManagerProtocol = KeychainManager()) {
        self.bridge = WalletBridgeService()
        self.keychain = keychain

        // Derive the wallet from the chat identity's nsec (one id = one wallet).
        // Returns nil until the identity exists; setup defers and retries.
        let keychainRef = keychain
        bridge.entropyProvider = {
            guard let data = keychainRef.getIdentityKey(forKey: Self.nsecKeychainKey),
                  let nsec = String(data: data, encoding: .utf8),
                  let secret = SonarWalletDerivation.secret(fromNsec: nsec)
            else { return nil }
            return SonarWalletDerivation.entropyHex(fromSecret: secret)
        }

        // With no BREEZ_API_KEY this settles to .notConfigured immediately.
        let bridge = self.bridge
        Task { try? await bridge.setupIfNeeded() }
        // NOTE: incoming-payment observation must NOT be started here. The
        // receive flow should subscribe only after the wallet is ready.
    }

    /// Re-attempt setup once the chat identity exists (the entropy provider
    /// started returning non-nil). Called by the store when the npub lands.
    func retrySetup() {
        let bridge = self.bridge
        Task { try? await bridge.setupIfNeeded() }
    }

    private static func map(_ state: WalletBridgeService.State) -> SonarWalletState {
        switch state {
        case .notConfigured: return .notConfigured
        case .settingUp: return .settingUp
        case .ready(let balanceSats): return .ready(balanceSats: balanceSats)
        }
    }

    var state: SonarWalletState { Self.map(bridge.state) }

    var statePublisher: AnyPublisher<SonarWalletState, Never> {
        bridge.statePublisher
            .map { BridgedWallet.map($0) }
            .eraseToAnyPublisher()
    }

    func send(destination: String, amountSats: Int64, note: String?) async throws {
        _ = try await bridge.send(destination: destination, amountSats: amountSats, note: note ?? "")
    }

    func createOffer() async throws -> String {
        try await bridge.createOffer()
    }

    // MARK: Money display — forwarded to the SDK via WalletBridgeService

    var displayMode: String { bridge.displayMode }
    func setDisplayMode(_ mode: String) async { await bridge.setDisplayMode(mode) }

    var displayCurrency: String { bridge.displayCurrency }
    func setDisplayCurrency(_ code: String) async { await bridge.setDisplayCurrency(code) }

    func supportedCurrencies() -> [SonarCurrency] { bridge.supportedCurrencies() }

    var hasLiveRate: Bool { bridge.hasLiveRate }

    func format(sats: Int64) -> String { bridge.formatMoney(sats: sats) }

    func parseFiatInput(_ text: String, currencyCode: String) -> Int64 {
        bridge.parseFiatInput(text)
    }

    var moneyDisplayChanged: AnyPublisher<Void, Never> {
        // Re-render amounts when the persisted mode/currency or rate changes.
        bridge.moneyDisplay
            .merge(with: bridge.$hasLiveRate.map { _ in () })
            .eraseToAnyPublisher()
    }

    /// Emergency wipe: forget the wallet seed along with everything else.
    /// (The keychain service is owned by SonarWalletKit's storage.) The seed
    /// stays reconstructable from the nsec — until that is wiped too.
    static func wipeWalletStorage() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "chat.bitchat.sonar.wallet",
        ]
        SecItemDelete(query as CFDictionary)
    }
}

#endif
