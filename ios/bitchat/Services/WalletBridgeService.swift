//
// WalletBridgeService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(iOS) || os(macOS)

import BitLogger
import Combine
import Foundation
import WalletKit
#if canImport(UIKit)
import UIKit
#endif

/// App-side facade over the Lightning wallet engine (Breez SDK Liquid via
/// the local `WalletKit` Swift package).
///
/// Design (mirrors `MarmotService`):
/// - No singleton: construct one and inject it. The wrapped wallet owns
///   its Breez SDK instance, so keep a single bridge per process in practice.
/// - `@MainActor`: UI-facing state changes stay on the main thread. The
///   WalletKit facade moves Breez's blocking calls off the main actor.
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

    enum WalletBridgeError: Error, Equatable, LocalizedError {
        /// `BREEZ_API_KEY` is missing/empty — see docs/WALLET-INTEGRATION.md.
        case missingAPIKey
        /// Failure inside the wallet engine (Breez SDK, storage...).
        case core(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Breez API key is missing from this app build."
            case .core(let message):
                let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? "Wallet operation failed." : trimmed
            }
        }
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
    /// True between `suspendForBackground()` and `resumeFromBackground()` so the
    /// foreground rebuild only fires when we actually tore a ready node down.
    private var suspendedForBackground = false
    /// The in-flight `shutdown()` from `suspendForBackground()`. `resumeFromBackground()`
    /// awaits it before rebuilding, so a fast background→foreground bounce can't
    /// reconnect before the disconnect (and its `state = .notConfigured`) completes.
    private var suspendTask: Task<Void, Never>?
    /// Guards against stacking concurrent rebuilds if `resumeFromBackground()` is
    /// called again (next foreground) while a previous retry loop is still running.
    private var resumeInFlight = false
    /// The in-flight `resumeFromBackground()` retry loop. `suspendForBackground()`
    /// cancels it so a pending backoff retry can't wake and reconnect Breez while
    /// the app is already backgrounded (which would hold a SQLite lock at
    /// suspension with no matching teardown).
    private var resumeTask: Task<Void, Never>?
    #if canImport(UIKit)
    /// Active foreground-initiated payments. If iOS backgrounds us while one is
    /// running, keep the Breez node alive until the send completes, then run the
    /// normal clean suspend path.
    private var activeSendCount = 0
    private var suspendWhenActiveSendsFinish = false
    #endif

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
            #if DEBUG
            SecureLogger.error("Wallet setup failed: \(error)", category: .session)
            #endif
            // Allow a later retry (e.g. key added, transient node failure).
            setupTask = nil
            state = .notConfigured
            throw error
        }
    }

    private func setup() async throws {
        guard let apiKey = Self.configuredAPIKey() else {
            #if DEBUG
            SecureLogger.error("Wallet setup blocked: BREEZ_API_KEY missing", category: .session)
            #endif
            throw WalletBridgeError.missingAPIKey
        }
        #if DEBUG
        SecureLogger.info("Wallet setup: BREEZ_API_KEY present", category: .session)
        #endif
        state = .settingUp
        do {
            try wallet.configure(apiKey: apiKey, mainnet: mainnet)
            let hasExistingWallet = try await wallet.hasWallet()
            #if DEBUG
            SecureLogger.info("Wallet setup: existing wallet=\(hasExistingWallet)", category: .session)
            #endif
            if !hasExistingWallet {
                let entropyHex = entropyProvider?()
                if let entropyHex {
                    // Deterministic: wallet is reconstructable from the chat
                    // identity (one identity = one wallet).
                    #if DEBUG
                    SecureLogger.info("Wallet setup: identity entropy ready; creating deterministic wallet", category: .session)
                    #endif
                    try await wallet.createWalletFromEntropy(entropyHex: entropyHex)
                } else if entropyProvider != nil {
                    // Identity not ready yet — defer; setupIfNeeded retries
                    // once the identity exists (so we never create a random,
                    // non-derivable wallet for a derived-wallet host).
                    #if DEBUG
                    SecureLogger.warning("Wallet setup deferred: identity entropy not ready", category: .session)
                    #endif
                    state = .notConfigured
                    throw WalletBridgeError.core("identity not ready for wallet derivation")
                } else {
                    // No derivation source configured: random wallet (the
                    // standalone/back-compat path).
                    #if DEBUG
                    SecureLogger.warning("Wallet setup: no entropy provider; creating random wallet", category: .session)
                    #endif
                    try await wallet.createWallet()
                }
            }
            #if DEBUG
            SecureLogger.info("Wallet setup: starting Breez node", category: .session)
            #endif
            try await wallet.startNode()
        } catch let error as SonarWallet.WalletError {
            throw Self.map(error)
        }
        startObservingBalance()
        state = .ready(balanceSats: 0)
        #if DEBUG
        SecureLogger.info("Wallet setup: ready", category: .session)
        #endif
        // Money display: apply first-run defaults (fiat + locale currency) then
        // fetch live rates and keep them fresh while ready.
        applyFirstRunMoneyDefaults()
        startRefreshingRates()
    }

    /// Stop the Breez node (e.g. on scene teardown). Setup can run again.
    ///
    /// Awaits an in-flight `setup()` first so `stopNode()` never races a concurrent
    /// `connect()` on the SDK, and so the balance/rates tasks are cancelled AFTER
    /// `setup()` has created them (cancelling earlier would leave the fresh ones
    /// running). This is what lets `suspendForBackground()` cleanly tear down a
    /// reconnect that's still `.settingUp`.
    func shutdown() async {
        if let running = setupTask {
            _ = try? await running.value
        }
        setupTask = nil
        balanceTask?.cancel()
        balanceTask = nil
        ratesTask?.cancel()
        ratesTask = nil
        try? await wallet.stopNode()
        state = .notConfigured
    }

    // MARK: - Background lifecycle

    #if canImport(UIKit)
    /// Tear the Breez node down before the app suspends, to avoid a `0xdead10cc`
    /// kill.
    ///
    /// The Breez SDK runs a background task (`track_new_blocks`) that polls its
    /// SQLite cache continuously. If iOS suspends the process while that task
    /// holds a SQLite lock, RunningBoard terminates the app with `0xdead10cc`
    /// ("held a file lock during suspension"). `disconnect()` (via `shutdown()`)
    /// releases every lock so the suspend is clean. Offline receive is unaffected
    /// — it runs in the Notification Service Extension's own process — and
    /// dropping our connection also removes app↔NSE contention on the shared App
    /// Group DB. `resumeFromBackground()` rebuilds the node on the next foreground.
    ///
    /// Wrapped in a background-task assertion so the disconnect runs to completion
    /// before the OS suspends us. Tears down a ready node OR an in-flight reconnect
    /// — a fast foreground→background bounce can land here while still `.settingUp`,
    /// and leaving that connect running would let it hold a lock at suspension
    /// (`shutdown()` waits for the connect to settle, then disconnects). No-op only
    /// when the node was never brought up.
    func suspendForBackground() {
        // Cancel any in-flight foreground reconnect retry first. If it's mid-backoff
        // after a failed attempt (state is `.notConfigured`), it would otherwise wake
        // and reconnect Breez while we're backgrounded, with no matching teardown —
        // re-opening the lock-at-suspension path. It stays armed
        // (`suspendedForBackground`) so the next foreground retries.
        resumeTask?.cancel()
        resumeTask = nil
        if activeSendCount > 0 {
            suspendedForBackground = true
            suspendWhenActiveSendsFinish = true
            return
        }
        if case .notConfigured = state { return }
        suspendedForBackground = true
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "breez-suspend") {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
        suspendTask = Task { @MainActor in
            await shutdown()
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }
    }

    /// Rebuild the node torn down by `suspendForBackground()`. Awaits the in-flight
    /// disconnect first (so a fast bounce can't reconnect mid-teardown), then
    /// retries with backoff so a transient failure on foreground (e.g. no network
    /// yet) doesn't leave the wallet down. `suspendedForBackground` is cleared only
    /// on success, so if all attempts fail the resume stays armed and the next
    /// foreground retries — the wallet never gets stuck `.notConfigured` until a
    /// fresh `BridgedWallet`. No-op unless we previously suspended.
    func resumeFromBackground() {
        suspendWhenActiveSendsFinish = false
        guard suspendedForBackground, !resumeInFlight else { return }
        resumeInFlight = true
        let pendingSuspend = suspendTask
        resumeTask = Task { @MainActor in
            defer { resumeInFlight = false }
            await pendingSuspend?.value
            suspendTask = nil
            for attempt in 0..<3 {
                // Backgrounded mid-loop (suspendForBackground cancelled us): stop
                // before reconnecting, and stay armed so the next foreground retries.
                if Task.isCancelled { return }
                do {
                    try await setupIfNeeded()
                    if Task.isCancelled { return }
                    suspendedForBackground = false
                    return
                } catch {
                    guard attempt < 2 else {
                        SecureLogger.warning(
                            "Breez wallet reconnect failed after 3 attempts on foreground; staying armed for the next foreground: \(error)",
                            category: .session)
                        return
                    }
                    // `try await` (not `try?`) so cancellation during the backoff
                    // aborts the loop instead of falling through to another connect.
                    do {
                        try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 2_000_000_000)
                    } catch {
                        return
                    }
                }
            }
        }
    }
    #endif

    // MARK: - Push webhook

    func registerWebhook(url: String) async throws {
        do {
            try await wallet.registerWebhook(url: url)
        } catch let error as SonarWallet.WalletError {
            throw Self.map(error)
        }
    }

    func unregisterWebhook() async throws {
        do {
            try await wallet.unregisterWebhook()
        } catch let error as SonarWallet.WalletError {
            throw Self.map(error)
        }
    }

    // MARK: - Payments

    /// Send to any Lightning destination: BOLT11 invoice, BOLT12 offer,
    /// LNURL-pay, or a BIP-353 address (`user@domain` — resolved by the
    /// Breez SDK). `amountSats` > 0 for amountless destinations; 0 when
    /// the destination embeds the amount.
    @discardableResult
    func send(destination: String, amountSats: Int64 = 0, note: String = "") async throws -> Payment {
        #if canImport(UIKit)
        beginActiveSend()
        defer { finishActiveSend() }
        #endif
        do {
            #if canImport(UIKit)
            return try await withBackgroundTask(named: "breez-send") {
                try await wallet.send(destination: destination, amountSats: amountSats, note: note)
            }
            #else
            return try await wallet.send(destination: destination, amountSats: amountSats, note: note)
            #endif
        } catch let error as SonarWallet.WalletError {
            throw Self.map(error)
        }
    }

    #if canImport(UIKit)
    private func beginActiveSend() {
        activeSendCount += 1
    }

    private func finishActiveSend() {
        activeSendCount = max(0, activeSendCount - 1)
        guard activeSendCount == 0, suspendWhenActiveSendsFinish else { return }
        suspendWhenActiveSendsFinish = false
        suspendForBackground()
    }

    private func withBackgroundTask<T>(
        named name: String,
        operation: () async throws -> T
    ) async throws -> T {
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: name) {
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }
        defer {
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }
        return try await operation()
    }
    #endif

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
        let supported = Set(supportedCurrencies().map(\.code))
        let locale = Locale.current.currency?.identifier ?? "EUR"
        let currency = supported.contains(locale) ? locale : (supported.contains("EUR") ? "EUR" : (supported.first ?? "USD"))
        Task {
            await self.setDisplayCurrency(currency)
            await self.setDisplayMode("fiat")
            // Mark first-run done only after both persist — if the app dies
            // mid-Task the flag stays unset and we retry on next launch,
            // instead of stranding the user in the SDK's bitcoin default.
            UserDefaults.standard.set(true, forKey: Self.moneyDefaultedKey)
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
