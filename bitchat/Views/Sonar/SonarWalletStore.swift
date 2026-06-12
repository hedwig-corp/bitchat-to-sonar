//
// SonarWalletStore.swift
// bitchat
//
// Wallet abstraction behind the Sonar bitcoin payments UI
// (docs/SONAR-PAYMENTS.md). The UI binds to `SonarWalletProviding`; the
// real Lightning wallet (bitchat/Services/WalletBridgeService.swift) is
// injected into SonarAppStore later — until then the app runs with
// `UnconfiguredWallet`, which honestly reports "no wallet" everywhere:
// the Settings row shows a "Set up" affordance, claiming a sealed payment
// explains that a wallet is needed, and no fiat line is ever rendered
// from a fake rate.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Combine
import Foundation

/// Lifecycle of the on-device Lightning wallet.
enum SonarWalletState: Equatable {
    /// No wallet exists on this phone yet.
    case notConfigured
    /// A wallet is being created / restored / synced.
    case settingUp
    /// Wallet ready with a spendable balance (sats).
    case ready(balanceSats: Int64)
}

/// What the payments UI needs from a wallet. Implementations must be safe
/// to call from the main actor; `send`/`createOffer` may suspend.
protocol SonarWalletProviding: AnyObject {
    var state: SonarWalletState { get }
    var statePublisher: AnyPublisher<SonarWalletState, Never> { get }

    /// Pay `amountSats` to `destination` (a BOLT12 offer in the ⚡PAY flow).
    func send(destination: String, amountSats: Int64, note: String?) async throws

    /// Create a reusable BOLT12 offer that the counterpart can pay into.
    func createOffer() async throws -> String

    /// Fiat representation of `sats` using a LIVE exchange rate, e.g.
    /// "€1.27". Returns nil when no live rate is available — the UI then
    /// simply omits the fiat line. NEVER a fake/hardcoded rate.
    func fiatText(forSats sats: Int64) -> String?
}

/// Default wallet: nothing is configured. Every operation fails loudly so
/// no flow can pretend money moved.
final class UnconfiguredWallet: SonarWalletProviding {
    enum WalletError: LocalizedError {
        case notConfigured

        var errorDescription: String? { "No wallet is set up on this phone yet." }
    }

    let state: SonarWalletState = .notConfigured

    var statePublisher: AnyPublisher<SonarWalletState, Never> {
        Just(.notConfigured).eraseToAnyPublisher()
    }

    func send(destination: String, amountSats: Int64, note: String?) async throws {
        throw WalletError.notConfigured
    }

    func createOffer() async throws -> String {
        throw WalletError.notConfigured
    }

    func fiatText(forSats sats: Int64) -> String? { nil }
}
