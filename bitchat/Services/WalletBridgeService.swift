//
// WalletBridgeService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(iOS)

import Combine
import Foundation
import WalletKit

/// App-side facade over the Lightning wallet engine (Breez SDK Liquid via
/// the `SonarWalletKit` KMP framework, wrapped by the `WalletKit` Swift
/// package). iOS-only: the KMP framework ships no macOS slice.
///
/// Design (mirrors `MarmotService`):
/// - No singleton: construct one and inject it. The underlying Kotlin
///   `SonarWalletComponent` is process-global, so keep a single instance
///   per process in practice.
/// - `@MainActor`: the KMP bridge fires every callback on the main thread
///   (its coroutine scope runs on `Dispatchers.Main`); the heavy lifting
///   happens on Kotlin background dispatchers, so nothing here blocks.
/// - This service owns no UI. Stores/ViewModels observe `statePublisher`
///   (or `$state`) and call the async methods.
///
/// Surface intentionally matches what a `SonarWalletProviding` adapter
/// needs: a state enum (`.notConfigured` / `.settingUp` /
/// `.ready(balanceSats:)`), async `send`/`createOffer`, and live balance
/// updates folded into the `.ready` state.
@MainActor
final class WalletBridgeService: ObservableObject {

    // MARK: - Public model types

    typealias Payment = SonarWallet.Payment
    typealias Destination = SonarWallet.Destination

    enum State: Equatable {
        /// No `BREEZ_API_KEY` configured (or setup failed); wallet UI
        /// should hide/disable itself.
        case notConfigured
        /// Setup in flight: configuring storage, creating the wallet on
        /// first run, starting the Breez node.
        case settingUp
        /// Node running. Balance updates live as payments settle.
        case ready(balanceSats: Int64)
    }

    enum WalletBridgeError: Error, Equatable {
        /// `BREEZ_API_KEY` is missing/empty — see docs/WALLET-INTEGRATION.md.
        case missingAPIKey
        /// Failure inside the wallet engine (Breez SDK, storage...).
        case core(String)
    }

    // MARK: - State

    @Published private(set) var state: State = .notConfigured

    /// State stream for adapters that prefer a publisher over `$state`.
    var statePublisher: AnyPublisher<State, Never> {
        $state.eraseToAnyPublisher()
    }

    private let wallet: SonarWallet
    private let mainnet: Bool
    private var balanceTask: Task<Void, Never>?
    private var setupTask: Task<Void, Error>?

    // MARK: - Money display

    /// True only after a live-rate fetch returned the selected currency. The UI
    /// shows fiat ONLY when this is true; otherwise sats (never a bundled rate).
    @Published private(set) var hasLiveRate = false
    /// Fires when display mode, currency, or rate availability changes.
    let moneyDisplay = PassthroughSubject<Void, Never>()
    private var ratesTask: Task<Void, Never>?
    private static let moneyDefaultedKey = "sonar.money.defaulted"

    /// Supplies 64-hex (32-byte) entropy to derive the wallet deterministically
    /// on first run, or nil when the source identity is not ready yet. When
    /// nil-returning (or unset) and no wallet exists, setup defers. Set by the
    /// host so the wallet is reconstructable from the chat identity (nsec).
    var entropyProvider: (() -> String?)?

    /// - Parameter mainnet: pass false to point the node at testnet.
    init(mainnet: Bool = true) {
        self.wallet = SonarWallet()
        self.mainnet = mainnet
    }

    deinit {
        balanceTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Bring the wallet up if it isn't already:
    /// 1. read `BREEZ_API_KEY` from Info.plist (injected from xcconfig);
    ///    leaves state at `.notConfigured` and throws when empty,
    /// 2. wire Keychain storage (service `chat.bitchat.sonar.wallet`),
    /// 3. generate + persist a BIP39 mnemonic on first run,
    /// 4. start the Breez node and begin observing the balance.
    ///
    /// Safe to call repeatedly (e.g. on every foreground): concurrent and
    /// repeat calls await/reuse the first successful setup.
    func setupIfNeeded() async throws {
        if case .ready = state { return }
        if let running = setupTask {
            return try await running.value
        }
        let task = Task<Void, Error> { try await self.setup() }
        setupTask = task
        do {
            try await task.value
        } catch {
            // Allow a later retry (e.g. key added, transient node failure).
            setupTask = nil
            state = .notConfigured
            throw error
        }
    }

    private func setup() async throws {
        guard let apiKey = Self.configuredAPIKey() else {
            throw WalletBridgeError.missingAPIKey
        }
        state = .settingUp
        do {
            try wallet.configure(apiKey: apiKey, mainnet: mainnet)
            if try await !wallet.hasWallet() {
                if let entropyHex = entropyProvider?() {
                    // Deterministic: wallet is reconstructable from the chat
                    // identity (one identity = one wallet).
                    try await wallet.createWalletFromEntropy(entropyHex: entropyHex)
                } else if entropyProvider != nil {
                    // Identity not ready yet — defer; setupIfNeeded retries
                    // once the identity exists (so we never create a random,
                    // non-derivable wallet for a derived-wallet host).
                    state = .notConfigured
                    throw WalletBridgeError.core("identity not ready for wallet derivation")
                } else {
                    // No derivation source configured: random wallet (the
                    // standalone/back-compat path).
                    try await wallet.createWallet()
                }
            }
            try await wallet.startNode()
        } catch let error as SonarWallet.WalletError {
            throw Self.map(error)
        }
        startObservingBalance()
        state = .ready(balanceSats: 0)
        // Money display: apply first-run defaults (fiat + locale currency) then
        // fetch live rates and keep them fresh while ready.
        applyFirstRunMoneyDefaults()
        startRefreshingRates()
    }

    /// Stop the Breez node (e.g. on scene teardown). Setup can run again.
    func shutdown() async {
        balanceTask?.cancel()
        balanceTask = nil
        ratesTask?.cancel()
        ratesTask = nil
        setupTask = nil
        try? await wallet.stopNode()
        state = .notConfigured
    }

    // MARK: - Payments

    /// Send to any Lightning destination: BOLT11 invoice, BOLT12 offer,
    /// LNURL-pay, or a BIP-353 address (`user@domain` — resolved by the
    /// Breez SDK). `amountSats` > 0 for amountless destinations; 0 when
    /// the destination embeds the amount.
    @discardableResult
    func send(destination: String, amountSats: Int64 = 0, note: String = "") async throws -> Payment {
        do {
            return try await wallet.send(destination: destination, amountSats: amountSats, note: note)
        } catch let error as SonarWallet.WalletError {
            throw Self.map(error)
        }
    }

    /// Create a reusable BOLT12 offer for receiving payments (the string
    /// behind the user's BIP-353 `user@domain` address).
    func createOffer() async throws -> String {
        do {
            return try await wallet.createOffer()
        } catch let error as SonarWallet.WalletError {
            throw Self.map(error)
        }
    }

    /// Classify a destination string (invoice/offer/LNURL/BIP-353) and
    /// surface its embedded amount, without paying it.
    func parseDestination(_ input: String) async throws -> Destination {
        do {
            return try await wallet.parseDestination(input)
        } catch let error as SonarWallet.WalletError {
            throw Self.map(error)
        }
    }

    /// Incoming payments as they settle (for notifications/refreshing
    /// history). The stream ends when the consuming task is cancelled.
    func incomingPayments() -> AsyncStream<Payment> {
        wallet.incomingPaymentsStream()
    }

    // MARK: - Money display (forwarded to the SDK)

    var displayMode: String { wallet.displayMode() }
    var displayCurrency: String { wallet.displayCurrency() }

    func supportedCurrencies() -> [SonarCurrency] {
        wallet.supportedCurrencies().map {
            SonarCurrency(code: $0.code, symbol: $0.symbol, decimals: $0.decimals)
        }
    }

    func setDisplayMode(_ mode: String) async {
        _ = await wallet.setDisplayMode(mode)
        moneyDisplay.send()
    }

    func setDisplayCurrency(_ code: String) async {
        _ = await wallet.setDisplayCurrency(code)
        // A new currency needs a rate for it; refresh + recompute hasLiveRate.
        await refreshRates()
        moneyDisplay.send()
    }

    /// Effective money string: fiat (SDK) only when mode==fiat AND a live rate
    /// exists; otherwise grouped sats (never the SDK's bundled fallback fiat).
    func formatMoney(sats: Int64) -> String {
        if displayMode == "fiat" && hasLiveRate {
            return wallet.formatAmount(sats: sats)
        }
        return sonarFormatSats(sats)
    }

    /// Fiat text → sats at the live rate (callers gate on `hasLiveRate`).
    func parseFiatInput(_ text: String) -> Int64 {
        wallet.parseFiatInput(text, currencyCode: displayCurrency)
    }

    /// First run only: default to fiat display in the device-locale currency
    /// (if supported, else EUR). Never overrides a later user choice.
    private func applyFirstRunMoneyDefaults() {
        guard !UserDefaults.standard.bool(forKey: Self.moneyDefaultedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.moneyDefaultedKey)
        let supported = Set(supportedCurrencies().map(\.code))
        let locale = Locale.current.currency?.identifier ?? "EUR"
        let currency = supported.contains(locale) ? locale : (supported.contains("EUR") ? "EUR" : (supported.first ?? "USD"))
        Task {
            await self.setDisplayCurrency(currency)
            await self.setDisplayMode("fiat")
        }
    }

    /// Fetch live rates now and recompute `hasLiveRate` for the selected
    /// currency. Empty result (offline/error) → hasLiveRate=false → sats.
    private func refreshRates() async {
        let rates = await wallet.fetchExchangeRates()
        let live = rates.contains { $0.currencyCode == displayCurrency }
        if live != hasLiveRate { hasLiveRate = live; moneyDisplay.send() }
    }

    /// Refresh rates on ready and every few minutes while the node runs.
    private func startRefreshingRates() {
        ratesTask?.cancel()
        ratesTask = Task { [weak self] in
            while !Task.isCancelled {
                // Stop the loop if the service is gone, so a missed shutdown()
                // can't leave a bare 5-minute timer spinning forever.
                guard let self else { return }
                await self.refreshRates()
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
            }
        }
    }

    // MARK: - Internals

    private func startObservingBalance() {
        balanceTask?.cancel()
        let stream = wallet.balanceStream()
        balanceTask = Task { [weak self] in
            for await sats in stream {
                guard let self, !Task.isCancelled else { return }
                self.state = .ready(balanceSats: sats)
            }
        }
    }

    /// `BREEZ_API_KEY` from Info.plist (build-setting expanded from
    /// `Configs/Local.xcconfig` / `Release.xcconfig`); nil when unset.
    private static func configuredAPIKey() -> String? {
        guard
            let raw = Bundle.main.object(forInfoDictionaryKey: "BREEZ_API_KEY") as? String
        else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    private static func map(_ error: SonarWallet.WalletError) -> WalletBridgeError {
        switch error {
        case .notConfigured: return .missingAPIKey
        case .core(let message): return .core(message)
        }
    }
}

#endif
