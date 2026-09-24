//
// SonarWalletStore.swift
// bitchat
//
// Wallet abstraction behind the Sonar bitcoin payments UI
// (docs/SONAR-PAYMENTS.md). The UI binds to `SonarWalletProviding`; the
// primary wallet is Cashu (`CashuWallet`, backed by the Rust
// `SonarCashuWallet` through `CashuWalletService`). The old Breez wallet
// survives only as `LegacyBreezWallet`, held separately by the store while
// its store exists on the device. `UnconfiguredWallet` honestly reports "no
// wallet" everywhere and is what tests get by default.
//
// Money display (fiat-by-default + bitcoin toggle, currency picker, fiat
// entry) is NOT a wallet concern: see `SonarMoneyDisplay`, which owns the
// persisted mode/currency and the Yadio rates, so deleting or replacing a
// wallet never resets the user's currency.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Combine
import Foundation

/// Lifecycle of an on-device wallet.
enum SonarWalletState: Equatable {
    /// No wallet is open: no account yet, or (legacy Breez only) the node is
    /// down after a transient failure / background teardown.
    case notConfigured
    /// Opening, with no balance known yet (not even a cached one).
    case settingUp
    /// Open, with a spendable balance (sats). For Cashu this may be the
    /// per-account cached balance until the mint answers — `connectivity`
    /// says whether it is live.
    case ready(balanceSats: Int64)
}

/// Build-time Breez key presence (`Info.plist` ← xcconfig). Gates the LEGACY
/// Breez wallet only; the primary (Cashu) wallet needs no key.
enum SonarBreezBuildConfig {
    static var hasAPIKey: Bool {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "BREEZ_API_KEY") as? String else {
            return false
        }
        return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Which wallet a payment is sent from: the primary (Cashu) wallet, or the
/// legacy Breez wallet while it exists on the device.
enum SNPaymentSource: Equatable {
    case primary
    case legacy
}

/// A fiat currency the wallet can display amounts in.
struct SonarCurrency: Equatable, Identifiable {
    let code: String
    let symbol: String
    let decimals: Int
    var id: String { code }
}

/// A one-time invoice from `receiveInvoice`. Its payment arrives as an
/// incoming `SonarWalletPayment` whose `id` equals `paymentId` (nil when the
/// wallet cannot say), so the Receive sheet can tell THIS invoice was paid.
struct SonarReceiveInvoice: Equatable, Sendable {
    let invoice: String
    let paymentId: String?
}

/// Wallet payment metadata surfaced to app state after a send settles.
/// This is intentionally independent from the Breez SDK type so UI code does
/// not import wallet internals.
struct SonarWalletPayment: Equatable, Codable, Sendable {
    /// Where a payment is. `pending` is NOT a failure: a Cashu melt may still
    /// be routing, and its outcome arrives later as an update with the SAME
    /// `id`. Never re-send a pending payment — that can pay twice.
    enum Status: String, Codable, Sendable {
        case complete
        case pending
        case failed
    }

    let id: String
    let amountSats: Int64
    let isIncoming: Bool
    let timestamp: Date
    let note: String?
    let feesSats: Int64?
    let preimage: String?
    let status: Status

    init(
        id: String,
        amountSats: Int64,
        isIncoming: Bool,
        timestamp: Date,
        note: String?,
        feesSats: Int64? = nil,
        preimage: String? = nil,
        status: Status = .complete
    ) {
        self.id = id
        self.amountSats = amountSats
        self.isIncoming = isIncoming
        self.timestamp = timestamp
        self.note = note
        self.feesSats = feesSats
        self.preimage = preimage
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case id, amountSats, isIncoming, timestamp, note, feesSats, preimage, status
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        amountSats = try c.decode(Int64.self, forKey: .amountSats)
        isIncoming = try c.decode(Bool.self, forKey: .isIncoming)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        feesSats = try c.decodeIfPresent(Int64.self, forKey: .feesSats)
        preimage = try c.decodeIfPresent(String.self, forKey: .preimage)
        // Rows written before `status` existed were only ever settled sends.
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .complete
    }
}

/// Whether the primary wallet can reach its backend right now. Drives the
/// "mint offline — retrying" copy; never gates first paint.
enum SonarWalletConnectivity: Equatable {
    /// No wallet is open (no account yet, or a build without one).
    case unavailable
    /// Opening / first connect in flight.
    case connecting
    case online
    /// Last connect failed; a retry is scheduled while foreground.
    case offline
}

/// Balance breakdown for the wallet screens. `isLive` is false while the
/// value is the per-account cache shown until the wallet answers.
struct SonarWalletBalanceDetail: Equatable {
    let confirmedSats: Int64
    let pendingReceiveSats: Int64
    let pendingSendSats: Int64
    let isLive: Bool
}

/// Built once. `NumberFormatter` is expensive to allocate and this is on the
/// payment-status screen's 1 Hz render path — a live payment re-derives the
/// headline, money line and wallet row every tick.
private let sonarSatsFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    return f
}()

/// Locale-grouped sats with no unit — "2,100". Use this when the amount is
/// composed into a longer phrase ("2,100 sats in flight"); `sonarFormatSats`
/// already carries the unit and appending another one reads "2,100 sats sats".
func sonarGroupedSats(_ sats: Int64) -> String {
    sonarSatsFormatter.string(from: NSNumber(value: sats)) ?? String(sats)
}

/// Minimal, locale-grouped sats formatting. Used for the honest offline case
/// (no live rate) where we must NOT show a fiat conversion; fiat goes through
/// `SonarMoneyDisplay`.
func sonarFormatSats(_ sats: Int64) -> String {
    "\(sonarGroupedSats(sats)) sats"
}

/// What the payments UI needs from a wallet. Implementations must be safe
/// to call from the main actor; `send`/`createOffer` may suspend.
///
/// Money DISPLAY (fiat/bitcoin mode, currency, rates) is not a wallet concern
/// any more — it lives in `SonarMoneyDisplay`, so replacing or deleting a
/// wallet never resets the user's currency.
protocol SonarWalletProviding: AnyObject {
    var state: SonarWalletState { get }
    var statePublisher: AnyPublisher<SonarWalletState, Never> { get }

    /// Backend reachability ("mint offline — retrying").
    var connectivity: SonarWalletConnectivity { get }
    /// Confirmed / pending breakdown; nil until anything is known.
    var balanceDetail: SonarWalletBalanceDetail? { get }
    /// Fires when `connectivity` or `balanceDetail` changes.
    var detailChanged: AnyPublisher<Void, Never> { get }

    /// THE published receive offer, when one is known locally. This is what
    /// the descriptor, the BIP-353 handle, the Unify receiver and the BLE
    /// payments capability advertise.
    var cachedReceiveOffer: String? { get }
    /// Emits the current offer and every change to it.
    var receiveOfferPublisher: AnyPublisher<String?, Never> { get }

    /// One custody-disclosure line for Settings, or nil for none.
    var custodyDescription: String? { get }

    /// Pay `amountSats` to `destination`. `amountSats` 0 lets an invoice speak
    /// for its own amount. `feeFromAmount` is the `Max` send: the fee comes
    /// out of `amountSats` instead of on top of it. A returned payment with
    /// `status == .pending` is in flight, NOT failed; its outcome arrives
    /// through `paymentUpdates()` with the same id.
    @discardableResult
    func send(
        destination: String,
        amountSats: Int64,
        note: String?,
        feeFromAmount: Bool
    ) async throws -> SonarWalletPayment

    /// The reusable receive offer (creating it the first time if needed).
    func createOffer() async throws -> String

    /// A one-off BOLT11 invoice, with the id its payment will carry.
    func receiveInvoice(amountSats: Int64, description: String?) async throws -> SonarReceiveInvoice

    /// Price a send WITHOUT paying: the most the payment can cost on top of
    /// `amountSats` (Cashu: the mint's fee reserve from `prepareSend`). Shown
    /// on the send confirmation sheet only; the quote is discarded and `send`
    /// prepares again, so a stale quote can never be paid. `amountSats` 0 lets
    /// an invoice speak for its own amount. Wallets without a quote throw.
    func quoteFee(destination: String, amountSats: Int64) async throws -> Int64

    /// Every payment update the backend observes, both directions, in order:
    /// receives, in-flight sends, settlements and failures.
    func paymentUpdates() -> AsyncStream<SonarWalletPayment>

    /// Latest update this process saw for `id` (in-memory; no I/O). Lets a
    /// caller that learns an id AFTER its outcome arrived catch up.
    func latestPaymentUpdate(id: String) -> SonarWalletPayment?

    /// History lookup for one payment (local store read). nil when unknown.
    func lookupPayment(id: String) async -> SonarWalletPayment?

    /// Open the wallet for the signed-in account. Called after local paint;
    /// local only, network continues in the background. Idempotent.
    func start()

    /// Foreground: connect then sync. Background: disconnect, but never
    /// under a send in flight.
    func setForeground(_ foreground: Bool)

    /// Account replacement: release this account's wallet WITHOUT deleting
    /// anything that may hold funds. Throws when that cannot be done safely
    /// (e.g. a payment is still in flight).
    func prepareForIdentityReplacement() async throws

    /// Panic wipe: delete every local trace of this wallet. False when
    /// something could not be removed.
    func wipeForEmergency() async -> Bool
}

extension SonarWalletProviding {
    @discardableResult
    func send(destination: String, amountSats: Int64, note: String?) async throws -> SonarWalletPayment {
        try await send(destination: destination, amountSats: amountSats, note: note, feeFromAmount: false)
    }

    var connectivity: SonarWalletConnectivity { .unavailable }
    var balanceDetail: SonarWalletBalanceDetail? { nil }
    var detailChanged: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }
    var cachedReceiveOffer: String? { nil }
    var receiveOfferPublisher: AnyPublisher<String?, Never> { Just(nil).eraseToAnyPublisher() }
    var custodyDescription: String? { nil }

    func receiveInvoice(amountSats: Int64, description: String?) async throws -> SonarReceiveInvoice {
        throw UnconfiguredWallet.WalletError.notConfigured
    }

    /// No quote (unconfigured, legacy Breez): the sheet simply shows no fee line.
    func quoteFee(destination: String, amountSats: Int64) async throws -> Int64 {
        throw UnconfiguredWallet.WalletError.notConfigured
    }

    func paymentUpdates() -> AsyncStream<SonarWalletPayment> {
        AsyncStream { continuation in continuation.finish() }
    }

    func latestPaymentUpdate(id: String) -> SonarWalletPayment? { nil }
    func lookupPayment(id: String) async -> SonarWalletPayment? { nil }
    func start() {}
    func setForeground(_ foreground: Bool) {}
    func prepareForIdentityReplacement() async throws {}
    func wipeForEmergency() async -> Bool { true }
}

/// Coalesces receive-offer creation so repeated descriptor refreshes keep
/// advertising one reachable BOLT12 offer instead of rotating offers on every
/// wallet state tick.
@MainActor
final class SonarReceiveOfferCache {
    private struct InFlight {
        let id: UUID
        let generation: UInt64
        let task: Task<String, Error>
    }

    private var cachedOffer: String?
    private var inFlight: InFlight?
    private var resetGeneration: UInt64 = 0

    func offer(create: @escaping @MainActor () async throws -> String) async throws -> String {
        if let cachedOffer { return cachedOffer }
        if let inFlight { return try await resolve(inFlight) }

        let task = Task { @MainActor in
            try await create()
        }
        let next = InFlight(id: UUID(), generation: resetGeneration, task: task)
        inFlight = next
        return try await resolve(next)
    }

    private func resolve(_ observed: InFlight) async throws -> String {
        do {
            let offer = try await observed.task.value
            guard resetGeneration == observed.generation else { throw CancellationError() }
            if inFlight?.id == observed.id {
                cachedOffer = offer
                inFlight = nil
            } else if cachedOffer != offer {
                throw CancellationError()
            }
            return offer
        } catch {
            if inFlight?.id == observed.id {
                inFlight = nil
            }
            throw error
        }
    }

    func reset() {
        resetGeneration &+= 1
        inFlight?.task.cancel()
        inFlight = nil
        cachedOffer = nil
    }
}

/// Default wallet: nothing is configured. Every operation fails loudly so
/// no flow can pretend money moved.
final class UnconfiguredWallet: SonarWalletProviding {
    enum WalletError: LocalizedError {
        case notConfigured

        var errorDescription: String? {
            #if os(macOS)
            return String(localized: "Wallet is not configured on this Mac yet.")
            #else
            return String(localized: "No wallet is set up on this phone yet.")
            #endif
        }
    }

    let state: SonarWalletState = .notConfigured

    var statePublisher: AnyPublisher<SonarWalletState, Never> {
        Just(.notConfigured).eraseToAnyPublisher()
    }

    func send(
        destination: String,
        amountSats: Int64,
        note: String?,
        feeFromAmount: Bool
    ) async throws -> SonarWalletPayment {
        throw WalletError.notConfigured
    }

    func createOffer() async throws -> String {
        throw WalletError.notConfigured
    }
}
