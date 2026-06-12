//
// BridgedWallet.swift
// bitchat
//
// Glue: adapts the app-level WalletBridgeService (SonarWalletKit / Breez)
// to the SonarWalletProviding protocol the payments UI consumes. iOS only —
// the wallet framework has no macOS slice.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Combine
import Foundation

#if os(iOS)

@MainActor
final class BridgedWallet: SonarWalletProviding {
    private let bridge: WalletBridgeService

    init() {
        self.bridge = WalletBridgeService()
        // Kick setup at construction: with no BREEZ_API_KEY this settles to
        // .notConfigured immediately and the UI shows the setup affordance.
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

    /// Live rates land with the exchange-rate wiring (Breez fetchFiatRates);
    /// until then the fiat line is honestly omitted.
    func fiatText(forSats sats: Int64) -> String? { nil }

    /// Emergency wipe: forget the wallet seed along with everything else.
    /// (The keychain service is owned by SonarWalletKit's storage.)
    static func wipeWalletStorage() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "chat.bitchat.sonar.wallet",
        ]
        SecItemDelete(query as CFDictionary)
    }
}

#endif
