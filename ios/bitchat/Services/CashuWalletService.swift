//
// CashuWalletService.swift
// bitchat
//
// Host side of Sonar's Cashu wallet: lifecycle, per-account caches, the
// send pipeline and event fan-out around ONE Rust `SonarCashuWallet` per
// account (core/sonar-ffi/src/wallet.rs — its doc comments are the contract).
//
// Threading: every FFI call BLOCKS (mint round-trips, store I/O). All of them
// run on one private serial `DispatchQueue(qos: .utility)` behind a checked
// continuation — never the main thread, never the Swift cooperative pool
// (a blocked cooperative thread starves unrelated async work). Serial also
// gives the FFI's ordering rules for free: `disconnect()` can never overlap a
// `send()` because both are queued on the same thread.
//
// Money rules enforced here (mirror of Compose `CashuWalletEngine`):
//  - A `Pending` send is surfaced as pending, never as failed, and is never
//    re-sent; its outcome arrives as an update with the same id.
//  - Affordability is checked against the mint's REAL fee reserve from
//    `prepareSend` before `send`; a shortfall is the typed
//    `CashuWalletError.insufficientFunds`.
//  - Never disconnect under a send in flight; the disconnect waits.
//  - Account replacement keeps the old account's store on disk; only a panic
//    wipe deletes stores.
//
// Signal-Comparable Performance Rule: `open` is called after local paint,
// publishes the cached balance/offer first, and runs the mint connect with
// backoff in the background. Nothing here gates first paint or chat UI.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Combine
import CryptoKit
import Foundation
import SonarCore
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Storage layout

/// Account id + on-disk layout of the Cashu wallet. MUST match every other
/// host (Android `filesDir`, desktop root): devices that ran earlier builds
/// already hold stores at these paths.
enum SonarCashuStorage {
    static let productionMintURL = "https://mint.hedwig.sh"
    static let mintHost = "mint.hedwig.sh"

    /// DEBUG builds only: a `sonar.debug.cashuMintURL` default points the
    /// wallet at another mint (e.g. a local cdk-mintd fake wallet) so
    /// send/receive can be QA'd without real sats. Release always uses the
    /// production mint. On a simulator, write it into the APP CONTAINER's
    /// plist while the SIMULATOR is shut down — with it booted, cfprefsd
    /// keeps its cached copy and rewrites the file (a plain `defaults write`
    /// edits the Mac's own preferences, and `simctl spawn … defaults` the
    /// device's, neither of which the app reads):
    /// `/usr/libexec/PlistBuddy -c "Add :sonar.debug.cashuMintURL string
    /// http://127.0.0.1:8085" "$(xcrun simctl get_app_container <udid>
    /// sh.hedwig.sonar data)/Library/Preferences/sh.hedwig.sonar.plist"`.
    static let debugMintOverrideKey = "sonar.debug.cashuMintURL"

    static var mintURL: String {
        #if DEBUG
        if let override = UserDefaults.standard.string(forKey: debugMintOverrideKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return override
        }
        #endif
        return productionMintURL
    }
    static let rootDirectoryName = "sonar-cashu"
    static let networkDirectoryName = "mainnet"

    /// Lowercase hex of the first 16 bytes of SHA-256(nsec as UTF-8) — 32
    /// hex chars. The ONE place this is derived.
    static func accountId(nsec: String) -> String {
        let digest = SHA256.hash(data: Data(nsec.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// `<base>/sonar-cashu`
    static func root(in base: URL) -> URL {
        base.appendingPathComponent(rootDirectoryName, isDirectory: true)
    }

    /// `<base>/sonar-cashu/<accountId>`
    static func accountDirectory(in base: URL, accountId: String) -> URL {
        root(in: base).appendingPathComponent(accountId, isDirectory: true)
    }

    /// `<base>/sonar-cashu/<accountId>/mainnet` — the FFI `workingDir`.
    static func workingDirectory(in base: URL, accountId: String) -> URL {
        accountDirectory(in: base, accountId: accountId)
            .appendingPathComponent(networkDirectoryName, isDirectory: true)
    }

    /// The app's OWN Application Support container — never the App Group:
    /// a lock held on a shared-container file at suspension is the
    /// `0xdead10cc` kill this app has chased nine times.
    static func defaultBase() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    /// Create the working directory (and its parents under `base`) and pin
    /// the data-protection class. `.completeUntilFirstUserAuthentication`, not
    /// `.complete`: the store must stay readable for locked background wakes
    /// (same class as the Marmot and Breez stores).
    static func prepareWorkingDirectory(_ dir: URL, base: URL, fileManager: FileManager = .default) throws {
        #if os(iOS)
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        let attributes: [FileAttributeKey: Any] = [:]
        #endif
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: attributes)
        #if os(iOS)
        // Heal directories an older build created without the attribute.
        for url in [root(in: base), dir.deletingLastPathComponent(), dir] {
            try? fileManager.setAttributes(attributes, ofItemAtPath: url.path)
        }
        #endif
    }
}

// MARK: - Errors

/// Typed wallet failures the UI branches on. Mapped from `WalletFfiError`.
enum CashuWalletError: LocalizedError, Equatable {
    /// No wallet is open for an account yet.
    case notOpen
    /// NotConnected / Network / Timeout: nothing was sent; retrying.
    case mintOffline
    case busy
    /// Amount plus the mint's fee reserve exceeds the balance. The numbers
    /// are present when the shortfall was computed here from a real quote.
    case insufficientFunds(amountSats: Int64?, feeSats: Int64?, balanceSats: Int64?)
    case invalidDestination(String)
    case unsupported(String)
    case invalidInput(String)
    case backend(String)
    /// Refused because a payment is still in flight (e.g. account switch).
    case paymentInFlight

    init(_ error: Error) {
        if let typed = error as? CashuWalletError {
            self = typed
            return
        }
        guard let ffi = error as? WalletFfiError else {
            self = .backend(String(describing: error))
            return
        }
        switch ffi {
        case .NotConnected, .Network, .Timeout: self = .mintOffline
        case .Busy: self = .busy
        case .InsufficientFunds: self = .insufficientFunds(amountSats: nil, feeSats: nil, balanceSats: nil)
        case .InvalidDestination(let reason): self = .invalidDestination(reason)
        case .Unsupported(let reason): self = .unsupported(reason)
        case .InvalidInput(let reason): self = .invalidInput(reason)
        case .Backend(let reason): self = .backend(reason)
        }
    }

    var isOffline: Bool { self == .mintOffline }

    var errorDescription: String? {
        switch self {
        case .notOpen:
            return String(localized: "Your wallet is still starting. Try again in a moment.")
        case .mintOffline:
            return String(localized: "Mint offline — retrying. Nothing was sent.")
        case .busy:
            return String(localized: "Your wallet is busy. Try again in a moment.")
        case let .insufficientFunds(amount?, fee?, balance?):
            return SonarSpendableBalance.insufficientMessage(amountSats: amount, feeSats: fee, balanceSats: balance)
        case .insufficientFunds:
            return String(localized: "Amount plus fee exceeds your balance.")
        case .invalidDestination, .invalidInput:
            return String(localized: "That payment address can't be paid.")
        case .unsupported:
            return String(localized: "This kind of payment isn't supported yet.")
        case .backend:
            return String(localized: "Payment failed — you were not charged.")
        case .paymentInFlight:
            return String(localized: "A payment is still in flight. Wait for it to finish and try again.")
        }
    }
}

// MARK: - Listener bridge

/// Receives events on the wallet's own thread and forwards them; the
/// closure hops to the main actor itself.
private final class CashuListenerBridge: CashuWalletListener, @unchecked Sendable {
    private let forward: (CashuWalletEvent) -> Void

    init(_ forward: @escaping (CashuWalletEvent) -> Void) {
        self.forward = forward
    }

    func onEvent(event: CashuWalletEvent) {
        forward(event)
    }
}

#if canImport(UIKit)
/// Keeps the process alive long enough to finish a send or a disconnect
/// that began in the foreground.
@MainActor
private final class CashuBackgroundTaskLease {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
#endif

// MARK: - Service

@MainActor
final class CashuWalletService: ObservableObject {
    typealias NativeFactory = (_ nsec: String, _ mintURL: String, _ workingDir: String) throws -> SonarCashuWalletProtocol

    /// The account whose wallet is open (nil = none).
    @Published private(set) var accountId: String?
    @Published private(set) var connectivity: SonarWalletConnectivity = .unavailable
    /// Cached value until `balance()` answers; `isLive` tells which.
    @Published private(set) var balance: SonarWalletBalanceDetail?
    /// THE published receive offer for this account, or nil while unknown.
    @Published private(set) var receiveOffer: String?

    private let updatesSubject = PassthroughSubject<SonarWalletPayment, Never>()
    /// Every payment update, both directions, on the main actor.
    var paymentUpdates: AnyPublisher<SonarWalletPayment, Never> { updatesSubject.eraseToAnyPublisher() }

    private let queue = DispatchQueue(label: "sh.hedwig.sonar.cashu.ffi", qos: .utility)
    private let makeNative: NativeFactory
    private let defaults: UserDefaults
    private let storageBase: () throws -> URL
    private let mintURL: String
    private let retryDelaysNanos: [UInt64]
    private let fileManager: FileManager

    private var native: SonarCashuWalletProtocol?
    /// Bumped on every native swap; late results from an older native drop.
    private var epoch: UInt64 = 0
    /// Foreground intent. The app starts foregrounded.
    private var wantOnline: Bool
    private var connectTask: Task<Void, Never>?
    private var connectLoopToken: UInt64 = 0
    private var sendsInFlight = 0
    private var disconnectWhenIdle = false
    private var balanceRefreshInFlight = false
    private var balanceRefreshPending = false
    /// Latest update per payment id, so a caller that learns an id after its
    /// outcome was already delivered can catch up. Bounded.
    private var recentUpdates: [String: SonarWalletPayment] = [:]
    private var recentOrder: [String] = []
    private static let recentLimit = 128

    nonisolated static let defaultRetryDelaysNanos: [UInt64] = [2, 5, 15, 30, 60].map { $0 * 1_000_000_000 }

    init(
        makeNative: @escaping NativeFactory = { nsec, mint, dir in
            try SonarCashuWallet(nsec: nsec, mintUrl: mint, workingDir: dir)
        },
        defaults: UserDefaults = .standard,
        storageBase: @escaping () throws -> URL = SonarCashuStorage.defaultBase,
        mintURL: String = SonarCashuStorage.mintURL,
        startsForeground: Bool = true,
        retryDelaysNanos: [UInt64] = CashuWalletService.defaultRetryDelaysNanos,
        fileManager: FileManager = .default
    ) {
        self.makeNative = makeNative
        self.defaults = defaults
        self.storageBase = storageBase
        self.mintURL = mintURL
        self.wantOnline = startsForeground
        self.retryDelaysNanos = retryDelaysNanos.isEmpty ? CashuWalletService.defaultRetryDelaysNanos : retryDelaysNanos
        self.fileManager = fileManager
    }

    var isOpen: Bool { native != nil }

    // MARK: Cache keys (per account)

    static func balanceKey(_ accountId: String) -> String { "wallet.cashu.balance.\(accountId)" }
    static func offerKey(_ accountId: String) -> String { "wallet.cashu.offer.\(accountId)" }
    private static let cacheKeyPrefix = "wallet.cashu."

    // MARK: FFI hop

    /// Run a blocking FFI call on the wallet queue.
    private func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: Lifecycle

    /// Open the wallet for `nsec`: publish the cached balance and offer,
    /// construct the native wallet (local only), read the offer from disk,
    /// then connect with backoff in the background. Idempotent per account;
    /// a different account releases the previous one (its files stay).
    func open(nsec: String) async {
        let key = nsec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let id = SonarCashuStorage.accountId(nsec: key)
        if accountId == id, native != nil { return }
        if native != nil || accountId != nil {
            guard sendsInFlight == 0 else { return }
            await releaseCurrent()
        }
        epoch &+= 1
        let myEpoch = epoch
        accountId = id
        balance = loadCachedBalance(id)
        receiveOffer = defaults.string(forKey: Self.offerKey(id))
        connectivity = .connecting

        let factory = makeNative
        let mint = mintURL
        let baseProvider = storageBase
        let fm = fileManager
        let listener = CashuListenerBridge { [weak self] event in
            Task { @MainActor in self?.handle(event, epoch: myEpoch) }
        }
        let created: SonarCashuWalletProtocol
        do {
            created = try await run {
                let base = try baseProvider()
                let dir = SonarCashuStorage.workingDirectory(in: base, accountId: id)
                try SonarCashuStorage.prepareWorkingDirectory(dir, base: base, fileManager: fm)
                let wallet = try factory(key, mint, dir.path)
                wallet.setListener(listener: listener)
                return wallet
            }
        } catch {
            SecureLogger.error("Cashu wallet open failed: \(CashuWalletError(error))", category: .session)
            if epoch == myEpoch { connectivity = .offline }
            return
        }
        guard epoch == myEpoch, accountId == id else {
            // Replaced while opening: detach the orphan without touching files.
            _ = try? await run {
                created.clearListener()
                try? created.disconnect()
            }
            return
        }
        native = created
        await refreshOffer()
        if wantOnline {
            startConnectLoop()
        } else {
            connectivity = .offline
        }
    }

    /// Foreground: connect (with retry) then sync. Background: disconnect,
    /// deferred while a send is in flight.
    func setForeground(_ foreground: Bool) {
        wantOnline = foreground
        guard native != nil else { return }
        if foreground {
            disconnectWhenIdle = false
            if connectivity == .online {
                Task { await self.syncAndRefresh() }
            } else {
                startConnectLoop()
            }
        } else {
            cancelConnectLoop()
            Task { await self.disconnectIfIdle() }
        }
    }

    private func startConnectLoop() {
        guard connectTask == nil, native != nil else { return }
        connectLoopToken &+= 1
        let token = connectLoopToken
        connectTask = Task { [weak self] in
            await self?.connectLoop()
            guard let self, self.connectLoopToken == token else { return }
            self.connectTask = nil
        }
    }

    private func cancelConnectLoop() {
        connectTask?.cancel()
        connectTask = nil
        connectLoopToken &+= 1
    }

    private func connectLoop() async {
        var attempt = 0
        while !Task.isCancelled {
            guard wantOnline, let n = native else { return }
            let myEpoch = epoch
            if connectivity != .online { connectivity = .connecting }
            var failure: CashuWalletError?
            do {
                try await run { try n.connect() }
            } catch {
                failure = CashuWalletError(error)
            }
            guard epoch == myEpoch, native === n else { return }
            guard let failure else {
                connectivity = .online
                await syncAndRefresh()
                if !wantOnline { await disconnectIfIdle() }
                return
            }
            connectivity = .offline
            SecureLogger.warning(
                "Cashu connect failed (attempt \(attempt + 1)): \(failure)",
                category: .session
            )
            guard wantOnline else { return }
            let delay = retryDelaysNanos[min(attempt, retryDelaysNanos.count - 1)]
            attempt += 1
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
        }
    }

    private func disconnectIfIdle() async {
        guard !wantOnline, let n = native else { return }
        if sendsInFlight > 0 {
            disconnectWhenIdle = true
            return
        }
        #if canImport(UIKit)
        let lease = CashuBackgroundTaskLease(name: "cashu-disconnect")
        defer { lease.end() }
        #endif
        _ = try? await run { try n.disconnect() }
        if native === n, !wantOnline {
            connectivity = .offline
        }
    }

    private func syncAndRefresh() async {
        if let n = native {
            let myEpoch = epoch
            do {
                try await run { try n.sync() }
            } catch {
                if epoch == myEpoch {
                    SecureLogger.warning("Cashu sync failed: \(CashuWalletError(error))", category: .session)
                }
            }
        }
        await refreshBalance()
        await refreshOffer()
    }

    // MARK: Events

    private func handle(_ event: CashuWalletEvent, epoch eventEpoch: UInt64) {
        guard eventEpoch == epoch, native != nil else { return }
        switch event {
        case .connected:
            connectivity = .online
            requestBalanceRefresh()
            Task { await self.refreshOffer() }
        case .disconnected:
            connectivity = .offline
            if wantOnline { startConnectLoop() }
        case .synced:
            requestBalanceRefresh()
            Task { await self.refreshOffer() }
        case .paymentReceived(let payment), .paymentSent(let payment):
            deliver(Self.map(payment))
        case .paymentFailed(let payment):
            deliver(Self.map(payment, forceFailed: true))
        }
    }

    private func deliver(_ update: SonarWalletPayment) {
        remember(update)
        updatesSubject.send(update)
        requestBalanceRefresh()
    }

    /// Record `update` unless it would downgrade a terminal outcome already
    /// seen for the same id (a late Pending must never undo Complete).
    private func remember(_ update: SonarWalletPayment) {
        if let known = recentUpdates[update.id], known.status != .pending, update.status == .pending {
            return
        }
        if recentUpdates[update.id] == nil {
            recentOrder.append(update.id)
            if recentOrder.count > Self.recentLimit {
                let evicted = recentOrder.removeFirst()
                recentUpdates[evicted] = nil
            }
        }
        recentUpdates[update.id] = update
    }

    func latestUpdate(id: String) -> SonarWalletPayment? { recentUpdates[id] }

    static func map(_ p: WalletPayment, forceFailed: Bool = false) -> SonarWalletPayment {
        let status: SonarWalletPayment.Status
        if forceFailed {
            status = .failed
        } else {
            switch p.status {
            case .complete: status = .complete
            case .failed: status = .failed
            // Refundable is a Breez-era state; for Cashu it is not terminal,
            // so it stays in flight rather than being claimed as failed.
            case .pending, .refundable: status = .pending
            }
        }
        return SonarWalletPayment(
            id: p.id,
            amountSats: Int64(clamping: p.amountSats),
            isIncoming: p.incoming,
            timestamp: Date(timeIntervalSince1970: TimeInterval(p.timestampSecs)),
            note: p.note,
            feesSats: p.feesSats.map { Int64(clamping: $0) },
            preimage: p.preimage,
            status: status
        )
    }

    // MARK: Balance / offer

    private func requestBalanceRefresh() {
        if balanceRefreshInFlight {
            balanceRefreshPending = true
            return
        }
        Task { await self.refreshBalance() }
    }

    func refreshBalance() async {
        guard !balanceRefreshInFlight else {
            balanceRefreshPending = true
            return
        }
        balanceRefreshInFlight = true
        defer { balanceRefreshInFlight = false }
        repeat {
            balanceRefreshPending = false
            guard let n = native, let id = accountId else { return }
            let myEpoch = epoch
            guard let live = try? await run({ try n.balance() }) else { return }
            guard epoch == myEpoch, native === n else { return }
            let detail = SonarWalletBalanceDetail(
                confirmedSats: Int64(clamping: live.confirmedSats),
                pendingReceiveSats: Int64(clamping: live.pendingReceiveSats),
                pendingSendSats: Int64(clamping: live.pendingSendSats),
                isLive: true
            )
            if balance != detail { balance = detail }
            storeCachedBalance(detail, accountId: id)
        } while balanceRefreshPending
    }

    /// Re-read the offer; publish only on change. The FFI answers from disk
    /// once the offer exists, so this works offline; a failure keeps the
    /// last offer this account published.
    func refreshOffer() async {
        guard let n = native, let id = accountId else { return }
        let myEpoch = epoch
        let live: String?
        do {
            live = try await run { try n.receiveOffer() }
        } catch {
            live = nil
        }
        guard epoch == myEpoch, native === n else { return }
        guard let live, !live.isEmpty else { return }
        if defaults.string(forKey: Self.offerKey(id)) != live {
            defaults.set(live, forKey: Self.offerKey(id))
        }
        if receiveOffer != live { receiveOffer = live }
    }

    /// THE receive offer; creates it on first use (needs a connect).
    func createOffer() async throws -> String {
        if let receiveOffer { return receiveOffer }
        guard native != nil else { throw CashuWalletError.notOpen }
        await refreshOffer()
        if let receiveOffer { return receiveOffer }
        throw CashuWalletError.mintOffline
    }

    func receiveInvoice(amountSats: Int64, description: String?) async throws -> String {
        guard let n = native else { throw CashuWalletError.notOpen }
        guard amountSats > 0 else { throw CashuWalletError.invalidInput("amount must be greater than zero") }
        do {
            return try await run { try n.receiveInvoice(amountSats: UInt64(amountSats), description: description) }
        } catch {
            throw CashuWalletError(error)
        }
    }

    func lookupPayment(id: String) async -> SonarWalletPayment? {
        guard let n = native else { return nil }
        let found: WalletPayment?
        do {
            found = try await run { try n.lookupPayment(id: id) }
        } catch {
            return nil
        }
        guard let found else { return nil }
        let mapped = Self.map(found)
        remember(mapped)
        return mapped
    }

    private func loadCachedBalance(_ id: String) -> SonarWalletBalanceDetail? {
        guard let raw = defaults.dictionary(forKey: Self.balanceKey(id)),
              let confirmed = (raw["confirmed"] as? NSNumber)?.int64Value
        else { return nil }
        return SonarWalletBalanceDetail(
            confirmedSats: confirmed,
            pendingReceiveSats: (raw["pendingReceive"] as? NSNumber)?.int64Value ?? 0,
            pendingSendSats: (raw["pendingSend"] as? NSNumber)?.int64Value ?? 0,
            isLive: false
        )
    }

    private func storeCachedBalance(_ detail: SonarWalletBalanceDetail, accountId id: String) {
        defaults.set([
            "confirmed": NSNumber(value: detail.confirmedSats),
            "pendingReceive": NSNumber(value: detail.pendingReceiveSats),
            "pendingSend": NSNumber(value: detail.pendingSendSats),
        ], forKey: Self.balanceKey(id))
    }

    // MARK: Send

    /// Pay `destination`. `amountSats` 0 lets an invoice speak for its own
    /// amount. `feeFromAmount` is `Max`: when amount + fee reserve exceeds
    /// the balance, re-quote at `amountSats - fee` instead of refusing.
    /// Throws a typed `CashuWalletError`; a `.pending` result is NOT an
    /// error and must never be retried.
    func send(
        destination: String,
        amountSats: Int64,
        note: String?,
        feeFromAmount: Bool
    ) async throws -> SonarWalletPayment {
        guard let n = native else { throw CashuWalletError.notOpen }
        let dest = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dest.isEmpty, amountSats >= 0 else {
            throw CashuWalletError.invalidInput("missing destination or amount")
        }
        sendsInFlight += 1
        #if canImport(UIKit)
        let lease = CashuBackgroundTaskLease(name: "cashu-send")
        #endif
        defer {
            sendsInFlight -= 1
            #if canImport(UIKit)
            lease.end()
            #endif
            if sendsInFlight == 0, disconnectWhenIdle {
                disconnectWhenIdle = false
                Task { await self.disconnectIfIdle() }
            }
        }
        let noteText = note ?? ""
        let requested: UInt64? = amountSats > 0 ? UInt64(amountSats) : nil
        do {
            let paid: WalletPayment = try await run {
                if !n.isConnected() { try n.connect() }
                var prepared = try n.prepareSend(destination: dest, amountSats: requested)
                let confirmed = try n.balance().confirmedSats
                var fee = prepared.feesSats ?? 0
                if Self.exceeds(prepared.amountSats, fee, confirmed) {
                    guard feeFromAmount, let full = requested, full > fee else {
                        throw Self.shortfall(prepared.amountSats, fee, confirmed)
                    }
                    prepared = try n.prepareSend(destination: dest, amountSats: full - fee)
                    fee = prepared.feesSats ?? 0
                    if Self.exceeds(prepared.amountSats, fee, confirmed) {
                        throw Self.shortfall(prepared.amountSats, fee, confirmed)
                    }
                }
                return try n.send(prepared: prepared, note: noteText)
            }
            let mapped = Self.map(paid)
            // Never let the send's own (possibly Pending) result undo an
            // outcome event that already landed for this id.
            remember(mapped)
            requestBalanceRefresh()
            return recentUpdates[mapped.id] ?? mapped
        } catch {
            let typed = CashuWalletError(error)
            if typed.isOffline, wantOnline, connectivity != .online {
                startConnectLoop()
            }
            throw typed
        }
    }

    private nonisolated static func exceeds(_ amount: UInt64, _ fee: UInt64, _ balance: UInt64) -> Bool {
        let (total, overflow) = amount.addingReportingOverflow(fee)
        return overflow || total > balance
    }

    private nonisolated static func shortfall(_ amount: UInt64, _ fee: UInt64, _ balance: UInt64) -> CashuWalletError {
        .insufficientFunds(
            amountSats: Int64(clamping: amount),
            feeSats: Int64(clamping: fee),
            balanceSats: Int64(clamping: balance)
        )
    }

    // MARK: Account replacement / wipe

    private func releaseCurrent() async {
        epoch &+= 1
        cancelConnectLoop()
        disconnectWhenIdle = false
        let n = native
        native = nil
        accountId = nil
        balance = nil
        receiveOffer = nil
        connectivity = .unavailable
        recentUpdates = [:]
        recentOrder = []
        if let n {
            _ = try? await run {
                n.clearListener()
                try? n.disconnect()
            }
        }
    }

    /// Account replacement: disconnect and forget this account's wallet but
    /// KEEP `sonar-cashu/<accountId>/` on disk — it may hold funds (proofs
    /// are bearer; sats paid to an unminted quote are not NUT-13
    /// restorable). Refuses while a send is in flight.
    func release() async throws {
        guard sendsInFlight == 0 else { throw CashuWalletError.paymentInFlight }
        await releaseCurrent()
    }

    /// Panic wipe: disconnect (queued behind any in-flight send), wipe the
    /// open store, then delete EVERY account's store under `sonar-cashu/`
    /// and every cached balance/offer. False when anything remains.
    func wipeAll() async -> Bool {
        let n = native
        await releaseCurrent()
        if let n {
            _ = try? await run { try n.wipeLocalStorage() }
        }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.cacheKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
        let baseProvider = storageBase
        let fm = fileManager
        do {
            return try await run {
                let root = SonarCashuStorage.root(in: try baseProvider())
                if fm.fileExists(atPath: root.path) {
                    try fm.removeItem(at: root)
                }
                return !fm.fileExists(atPath: root.path)
            }
        } catch {
            SecureLogger.error("Cashu wallet wipe failed: \(error)", category: .session)
            return false
        }
    }
}
