//
// SonarWalletStore.swift
// bitchat
//
// Wallet abstraction behind the Sonar bitcoin payments UI
// (docs/SONAR-PAYMENTS.md). The UI binds to `SonarWalletProviding`; the
// real Lightning wallet (bitchat/Services/WalletBridgeService.swift) is
// injected into SonarAppStore later — until then the app runs with
// `UnconfiguredWallet`, which honestly reports "no wallet" everywhere:
// the Settings row shows a "Set up" affordance, direct sends stay unavailable,
// and no fiat line is ever rendered
// from a fake rate.
//
// Money display (fiat-by-default + bitcoin toggle, currency picker, fiat
// entry) is layered on top: the wallet exposes the persisted display mode
// and currency, the supported-currency list, a `hasLiveRate` flag, a single
// `format(sats:)` that returns the EFFECTIVE money string (fiat only when
// the mode is fiat AND a live rate exists, otherwise sats), and a
// `moneyDisplayChanged` publisher the UI re-renders on. See the brainstorm
// docs/brainstorms/2026-06-12-money-display-fiat-toggle.md (Approach B):
// the SDK owns conversion/formatting, Swift only renders and (for the
// honest offline sats fallback) formats sats with grouping.
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

/// A fiat currency the wallet can display amounts in.
struct SonarCurrency: Equatable, Identifiable {
    let code: String
    let symbol: String
    let decimals: Int
    var id: String { code }
}

/// Wallet payment metadata surfaced to app state after a send settles.
/// This is intentionally independent from the Breez SDK type so UI code does
/// not import wallet internals.
struct SonarWalletPayment: Equatable, Codable, Sendable {
    let id: String
    let amountSats: Int64
    let isIncoming: Bool
    let timestamp: Date
    let note: String?
    let feesSats: Int64?

    init(
        id: String,
        amountSats: Int64,
        isIncoming: Bool,
        timestamp: Date,
        note: String?,
        feesSats: Int64? = nil
    ) {
        self.id = id
        self.amountSats = amountSats
        self.isIncoming = isIncoming
        self.timestamp = timestamp
        self.note = note
        self.feesSats = feesSats
    }
}

/// Minimal, locale-grouped sats formatting — the ONLY money formatting done
/// in Swift. Used for the honest offline case (no live rate) where we must
/// NOT show a fiat conversion. Everything else flows through the SDK.
func sonarFormatSats(_ sats: Int64) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    let grouped = f.string(from: NSNumber(value: sats)) ?? String(sats)
    return "\(grouped) sats"
}

/// What the payments UI needs from a wallet. Implementations must be safe
/// to call from the main actor; `send`/`createOffer` may suspend.
protocol SonarWalletProviding: AnyObject {
    var state: SonarWalletState { get }
    var statePublisher: AnyPublisher<SonarWalletState, Never> { get }

    /// Pay `amountSats` to `destination` and return wallet metadata for local
    /// payment activity.
    @discardableResult
    func send(destination: String, amountSats: Int64, note: String?) async throws -> SonarWalletPayment

    /// Create a reusable BOLT12 offer that the counterpart can pay into.
    func createOffer() async throws -> String

    /// Incoming wallet payments as the wallet backend observes them. Older
    /// backends may return an idle stream until they expose settlement events.
    func incomingPayments() -> AsyncStream<SonarWalletPayment>

    // MARK: Money display

    /// Persisted display mode: "bitcoin" or "fiat".
    var displayMode: String { get }
    /// Persist a new display mode ("bitcoin"|"fiat").
    func setDisplayMode(_ mode: String) async

    /// Persisted display currency (ISO code, e.g. "EUR").
    var displayCurrency: String { get }
    /// Persist a new display currency (ISO code).
    func setDisplayCurrency(_ code: String) async

    /// Fiat currencies the user can pick (4 currencies; [] when unconfigured).
    func supportedCurrencies() -> [SonarCurrency]

    /// True only after a successful rate fetch that returned the selected
    /// currency. When false, money is shown/entered in SATS — never a fake
    /// or bundled fiat rate. The fiat entry toggle is disabled while false.
    var hasLiveRate: Bool { get }

    /// The EFFECTIVE money string for `sats`:
    ///   - fiat (via the SDK formatter) when displayMode == "fiat" AND a live
    ///     rate exists for the selected currency,
    ///   - otherwise grouped sats ("12,345 sats").
    /// NEVER a bundled/fallback fiat conversion.
    func format(sats: Int64) -> String

    /// Convert typed fiat text to sats at the live rate. Callers must only use
    /// fiat entry when `hasLiveRate` is true.
    func parseFiatInput(_ text: String, currencyCode: String) -> Int64

    /// Fires when the display mode, currency, or live-rate availability
    /// changes, so the UI re-renders every amount.
    var moneyDisplayChanged: AnyPublisher<Void, Never> { get }
}

extension SonarWalletProviding {
    /// True when the user prefers fiat AND a live rate makes it honest.
    var effectiveShowsFiat: Bool {
        displayMode == "fiat" && hasLiveRate
    }

    func incomingPayments() -> AsyncStream<SonarWalletPayment> {
        AsyncStream { continuation in continuation.finish() }
    }
}

/// Default wallet: nothing is configured. Every operation fails loudly so
/// no flow can pretend money moved. Money is always shown in sats (no rate,
/// no currencies, fiat entry disabled).
final class UnconfiguredWallet: SonarWalletProviding {
    enum WalletError: LocalizedError {
        case notConfigured

        var errorDescription: String? {
            #if os(macOS)
            return "Wallet is not configured on this Mac yet."
            #else
            return "No wallet is set up on this phone yet."
            #endif
        }
    }

    let state: SonarWalletState = .notConfigured

    var statePublisher: AnyPublisher<SonarWalletState, Never> {
        Just(.notConfigured).eraseToAnyPublisher()
    }

    func send(destination: String, amountSats: Int64, note: String?) async throws -> SonarWalletPayment {
        throw WalletError.notConfigured
    }

    func createOffer() async throws -> String {
        throw WalletError.notConfigured
    }

    // MARK: Money display (sats-only, no rate)

    var displayMode: String { "bitcoin" }
    func setDisplayMode(_ mode: String) async {}

    var displayCurrency: String { "USD" }
    func setDisplayCurrency(_ code: String) async {}

    func supportedCurrencies() -> [SonarCurrency] { [] }

    var hasLiveRate: Bool { false }

    func format(sats: Int64) -> String { sonarFormatSats(sats) }

    func parseFiatInput(_ text: String, currencyCode: String) -> Int64 {
        Int64(text.filter(\.isNumber)) ?? 0
    }

    var moneyDisplayChanged: AnyPublisher<Void, Never> {
        Empty().eraseToAnyPublisher()
    }
}
