//
// SonarWallet.swift
// WalletKit
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(iOS) || os(macOS)

import Foundation
import Security
import BreezSDKLiquid
import os

#if DEBUG
/// DEBUG-only instrumentation: forwards the Breez SDK's internal Rust log lines
/// into os_log so `idevicesyslog` can capture the *underlying* network error
/// behind the SDK's opaque "Could not contact servers" wrapper. Filtered to
/// network-relevant + warn/error lines. Never compiled into release builds — it
/// would otherwise emit Breez internals (URLs, swap details) to the device log.
private final class BreezLogForwarder: BreezSDKLiquid.Logger {
    static let oslog = OSLog(subsystem: "sh.hedwig.sonar", category: "BreezSDK")
    func log(l: LogEntry) {
        let lvl = l.level.uppercased()
        let isErr = (lvl == "ERROR" || lvl == "WARN")
        let lower = l.line.lowercased()
        let netRelevant = ["swap", "connect", "dns", "tls", "reqwest", "certificate",
                           "timed out", "timeout", "refused", "breez.technology",
                           "sending request", "io error", "tcp", "unreachable", "resolve"]
            .contains { lower.contains($0) }
        guard isErr || netRelevant else { return }
        os_log("BREEZ[%{public}@] %{public}@", log: Self.oslog, type: isErr ? .error : .info, lvl, l.line)
    }
}
#endif

/// Swift façade over the OFFICIAL Breez SDK Liquid Swift bindings — the same SDK
/// the Android/desktop app uses via the Breez KMP package, consumed directly
/// instead of through the retired SonarWalletKit KMP framework. async/await over
/// Breez's blocking calls, plain Swift value types, a one-call
/// `configure(apiKey:mainnet:)`, and a deterministic per-identity seed.
public final class SonarWallet {

    // MARK: - Public model types (callers must not import BreezSDKLiquid)

    public struct Payment: Sendable, Equatable {
        public let id: String
        public let amountSats: Int64
        public let isIncoming: Bool
        public let timestamp: Date
        public let note: String?
        public let feesSats: Int64?
        public let preimage: String?
    }

    public struct Destination: Sendable, Equatable {
        public let raw: String
        /// "bolt11", "bolt12_offer", "lightning_address", "lnurl_pay", "unknown".
        public let kind: String
        public let amountSats: Int64?
        public let note: String
    }

    public enum WalletError: Error, Equatable {
        case notConfigured
        case core(String)
    }

    public struct SupportedCurrency: Sendable, Equatable {
        public let code: String
        public let symbol: String
        public let decimals: Int
    }

    public struct ExchangeRate: Sendable, Equatable {
        public let currencyCode: String
        public let rate: Double
    }

    // MARK: - State

    private let storage = KeychainWalletStorage()
    private let queue = DispatchQueue(label: "chat.bitchat.sonar.wallet.sdk")
    private var sdk: BindingLiquidSdk?
    private var apiKey: String = ""
    private var mainnet = true
    private var workingDir = ""
    private var ratesCache: [ExchangeRate] = []

    private static let seedKey = "seed.v1"
    private static let modeKey = "display.mode"
    private static let currencyKey = "display.currency"

    public private(set) var isConfigured = false

    public init() {}

    deinit { try? sdk?.disconnect() }

    // MARK: - Configuration

    /// Store the API key + working directory (`Application Support/sonar-wallet`).
    /// Must be called once before any other method.
    public func configure(apiKey: String, mainnet: Bool) throws {
        let dir = try Self.breezWorkingDir(mainnet: mainnet)
        Self.migrateLegacyWorkingDirIfNeeded(to: dir)
        #if os(iOS)
        // Heal data protection AFTER migration (so files moved in from the legacy
        // pre-App-Group dir are repinned too) and BEFORE the SDK opens the store in
        // `startNode()`, so the directory default lands on the files Breez creates.
        Self.applyDatabaseProtection(to: dir)
        #endif
        self.apiKey = apiKey
        self.mainnet = mainnet
        self.workingDir = dir.path
        self.isConfigured = true
        #if DEBUG
        Self.installBreezLoggerOnce()
        #endif
    }

    // MARK: - App Group sharing (offline receive via Notification Service Extension)

    /// App Group shared with the Notification Service Extension. The NSE connects
    /// the Breez SDK in its own process to answer offline BOLT12 invoice requests,
    /// so it must use the SAME working dir + creds as the app. Keep in sync with
    /// `ios/SonarNotificationService/NotificationService.swift` and `APP_GROUP_ID`.
    public static let appGroupId = "group.sh.hedwig.sonar"

    /// Breez working directory inside the shared App Group container (so the NSE
    /// sees the same wallet state). Falls back to the per-app location only if the
    /// App Group container is unavailable (e.g. entitlement missing in a dev build).
    static func breezWorkingDir(mainnet: Bool) throws -> URL {
        let fm = FileManager.default
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) {
            let dir = group.appendingPathComponent("breez-sdk", isDirectory: true)
                .appendingPathComponent(mainnet ? "mainnet" : "testnet", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sonar-wallet", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    #if os(iOS)
    /// Data-Protection class for the Breez SQLite store. Deliberately
    /// `.completeUntilFirstUserAuthentication`, NOT `.complete`.
    ///
    /// The Breez SDK runs a background task (`track_new_blocks`) that polls its
    /// SQLite cache continuously. Under `.complete` the DB files are inaccessible
    /// while the device is locked, so holding a SQLite lock while the process is
    /// suspended-and-locked gets the app killed by RunningBoard with `0xdead10cc`
    /// ("held a file lock during suspension") — observed on TestFlight 1.6.0 (15).
    /// The same class also avoids the mmap'd `-shm` SIGBUS that #133 fixed for the
    /// Marmot store. `...UntilFirstUserAuthentication` keeps the bytes encrypted at
    /// rest (protected until the first unlock after boot) while staying accessible
    /// for the rest of the session, including locked background wakes. Matches the
    /// Marmot store (MarmotService) and Signal-iOS's GRDB store.
    private static let dbFileProtection: FileProtectionType = .completeUntilFirstUserAuthentication

    /// (Re)apply `dbFileProtection` to the working dir and every file already in
    /// it — the Breez SQLite store plus its `-wal`/`-shm`/`-journal` sidecars. The
    /// directory attribute sets the default for files the SDK creates later; the
    /// per-file pass heals installs whose files an older build wrote with
    /// `.complete`, in place and without a reinstall. Best-effort: the rewrite
    /// only lands while data is accessible (foreground / unlocked), which is where
    /// `configure()` runs.
    static func applyDatabaseProtection(to dir: URL) {
        let fm = FileManager.default
        let attrs: [FileAttributeKey: Any] = [.protectionKey: dbFileProtection]
        try? fm.setAttributes(attrs, ofItemAtPath: dir.path)
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            try? fm.setAttributes(attrs, ofItemAtPath: file.path)
        }
    }
    #endif

    /// One-time move of the pre-App-Group working dir (`Application Support/sonar-wallet`)
    /// into the shared container, so an existing wallet keeps its synced Breez state
    /// instead of re-scanning from the seed.
    private static func migrateLegacyWorkingDirIfNeeded(to dest: URL) {
        let fm = FileManager.default
        let legacy = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sonar-wallet", isDirectory: true)
        guard fm.fileExists(atPath: legacy.path), legacy.path != dest.path else { return }
        let destEmpty = ((try? fm.contentsOfDirectory(atPath: dest.path)) ?? []).isEmpty
        guard destEmpty else { return }
        // Atomic move: drop the freshly-created empty dest and rename the whole legacy
        // dir into place, so the Breez SQLite trio (.db / .db-wal / .db-shm) always
        // travels together. A per-item move could half-complete (e.g. .db moves but
        // .db-wal fails) and silently split the wallet DB across both dirs. Fall back
        // to a best-effort copy only if the rename itself fails.
        do {
            try fm.removeItem(at: dest)
            try fm.moveItem(at: legacy, to: dest)
        } catch {
            try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
            for item in (try? fm.contentsOfDirectory(atPath: legacy.path)) ?? [] {
                try? fm.copyItem(at: legacy.appendingPathComponent(item),
                                 to: dest.appendingPathComponent(item))
            }
        }
    }

    /// Mirror the connect creds into the App Group so the NSE can connect the SDK
    /// while the app is backgrounded/terminated. Seed lives in the app Keychain;
    /// we copy the hex into the shared defaults (matches Unify — hardening to a
    /// shared Keychain access group is a tracked follow-up).
    private func syncCredsToAppGroup(seedHex: String) {
        guard let defaults = UserDefaults(suiteName: Self.appGroupId) else { return }
        defaults.set(apiKey, forKey: "breez_api_key")
        defaults.set(seedHex, forKey: "breez_seed_hex")
        defaults.set(mainnet, forKey: "breez_mainnet")
    }

    #if DEBUG
    // DEBUG-only: install the Breez SDK log forwarder exactly once per process
    // (setLogger is global and rejects a second call).
    private static let breezLogger = BreezLogForwarder()
    private static var breezLoggerInstalled = false
    private static func installBreezLoggerOnce() {
        guard !breezLoggerInstalled else { return }
        breezLoggerInstalled = true
        do { try setLogger(logger: breezLogger) }
        catch { /* already installed elsewhere — fine */ }
    }
    #endif

    // MARK: - Wallet lifecycle (seed-based; deterministic per identity)

    public func hasWallet() async throws -> Bool {
        try ensureConfigured()
        return storage.getData(Self.seedKey) != nil
    }

    /// Persist the deterministic seed from caller-supplied entropy (32-byte hex).
    /// Returns the hex (callers discard it; there is no BIP39 mnemonic here — we
    /// connect Breez with the raw seed, like the Android app).
    @discardableResult
    public func createWalletFromEntropy(entropyHex: String) async throws -> String {
        try ensureConfigured()
        guard let seed = Self.bytes(fromHex: entropyHex), seed.count >= 16 else {
            throw WalletError.core("bad entropy")
        }
        storage.putData(Self.seedKey, Data(seed))
        return entropyHex
    }

    /// Generate + persist a random 32-byte seed (standalone path).
    @discardableResult
    public func createWallet() async throws -> String {
        try ensureConfigured()
        var seed = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, seed.count, &seed)
        storage.putData(Self.seedKey, Data(seed))
        return Self.hex(seed)
    }

    public func loadWallet() async throws -> String? {
        try ensureConfigured()
        return storage.getData(Self.seedKey).map { Self.hex([UInt8]($0)) }
    }

    // MARK: - Node lifecycle

    public func startNode() async throws {
        try ensureConfigured()
        guard let seedData = storage.getData(Self.seedKey) else {
            throw WalletError.core("no wallet seed")
        }
        let seed = [UInt8](seedData)
        // Mirror creds so the Notification Service Extension can connect the SDK
        // and answer offline BOLT12 invoice requests while the app is closed.
        syncCredsToAppGroup(seedHex: Self.hex(seed))
        let key = apiKey, dir = workingDir
        let net: LiquidNetwork = mainnet ? .mainnet : .testnet
        let node: BindingLiquidSdk = try await run {
            var config = try defaultConfig(network: net, breezApiKey: key)
            config.workingDir = dir
            return try connect(req: ConnectRequest(config: config, mnemonic: nil, passphrase: nil, seed: seed))
        }
        self.sdk = node
    }

    public func stopNode() async throws {
        let node = sdk
        sdk = nil
        try await run { try node?.disconnect() }
    }

    // MARK: - Observation

    /// Live balance in sats. Polls `getInfo` every ~5s (Breez has no Combine
    /// publisher); ends when the consuming task is cancelled.
    public func balanceStream() -> AsyncStream<Int64> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                while !Task.isCancelled {
                    if let bal = try? await self?.balanceSats() { continuation.yield(bal) }
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Incoming payments. Breez surfaces these via an event listener; v1 keeps the
    /// balance fresh (above) and leaves this stream idle.
    public func incomingPaymentsStream() -> AsyncStream<Payment> {
        AsyncStream { _ in }
    }

    private func balanceSats() async throws -> Int64 {
        guard let node = sdk else { throw WalletError.notConfigured }
        return try await run { Int64(try node.getInfo().walletInfo.balanceSat) }
    }

    // MARK: - Payments

    @discardableResult
    public func send(destination: String, amountSats: Int64 = 0, note: String = "") async throws -> Payment {
        guard let node = sdk else { throw WalletError.notConfigured }
        return try await run {
            let amount: PayAmount? = amountSats > 0 ? .bitcoin(receiverAmountSat: UInt64(amountSats)) : nil
            let prepared = try node.prepareSendPayment(req: PrepareSendRequest(destination: destination, amount: amount))
            let resp = try node.sendPayment(req: SendPaymentRequest(prepareResponse: prepared, useAssetFees: nil, payerNote: note.isEmpty ? nil : note))
            return Self.map(resp.payment)
        }
    }

    /// Lightweight classification (no node round-trip) so the composer can label a
    /// pasted destination. Breez resolves the real type at send time.
    public func parseDestination(_ input: String) async throws -> Destination {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        let kind: String
        if lower.hasPrefix("lno") { kind = "bolt12_offer" }
        else if lower.hasPrefix("lnbc") || lower.hasPrefix("lntb") { kind = "bolt11" }
        else if lower.hasPrefix("lnurl") { kind = "lnurl_pay" }
        else if s.contains("@") { kind = "lightning_address" }
        else { kind = "unknown" }
        return Destination(raw: s, kind: kind, amountSats: nil, note: "")
    }

    /// Reusable amountless BOLT12 offer for receiving.
    public func createOffer() async throws -> String {
        guard let node = sdk else { throw WalletError.notConfigured }
        return try await run {
            let prepared = try node.prepareReceivePayment(req: PrepareReceiveRequest(paymentMethod: .bolt12Offer, amount: nil))
            let resp = try node.receivePayment(req: ReceivePaymentRequest(prepareResponse: prepared, description: "Sonar", descriptionHash: nil, payerNote: nil))
            return resp.destination
        }
    }

    // MARK: - Money display (plain Swift; sats or fiat via the cached rate)

    public func supportedCurrencies() -> [SupportedCurrency] {
        [
            SupportedCurrency(code: "USD", symbol: "$", decimals: 2),
            SupportedCurrency(code: "EUR", symbol: "€", decimals: 2),
            SupportedCurrency(code: "GBP", symbol: "£", decimals: 2),
            SupportedCurrency(code: "CHF", symbol: "₣", decimals: 2),
        ]
    }

    public func fetchExchangeRates() async -> [ExchangeRate] {
        guard let node = sdk else { return ratesCache }
        let rates: [ExchangeRate] = (try? await run {
            try node.fetchFiatRates().map { ExchangeRate(currencyCode: $0.coin.uppercased(), rate: $0.value) }
        }) ?? ratesCache
        ratesCache = rates.isEmpty ? ratesCache : rates
        return ratesCache
    }

    public func cachedExchangeRates() -> [ExchangeRate] { ratesCache }

    public func displayMode() -> String { storage.getString(Self.modeKey) ?? "bitcoin" }

    @discardableResult
    public func setDisplayMode(_ mode: String) async -> String {
        storage.putString(Self.modeKey, mode); return mode
    }

    public func displayCurrency() -> String { storage.getString(Self.currencyKey) ?? "USD" }

    @discardableResult
    public func setDisplayCurrency(_ code: String) async -> String {
        storage.putString(Self.currencyKey, code); return code
    }

    /// SDK-free formatting: fiat when the mode is "fiat" AND a live rate exists,
    /// else sats. Callers gate the fiat path on their own `hasLiveRate`.
    public func formatAmount(sats: Int64) -> String {
        if displayMode() == "fiat", let rate = rate(for: displayCurrency()) {
            let fiat = Double(sats) / 100_000_000.0 * rate
            let cur = supportedCurrencies().first { $0.code == displayCurrency() }
            return "\(cur?.symbol ?? "")\(String(format: "%.2f", fiat))"
        }
        return "\(sats) sats"
    }

    /// Convert typed fiat (or sats) text to sats using the cached rate. 0 if unparseable.
    public func parseFiatInput(_ text: String, currencyCode: String) -> Int64 {
        let cleaned = text.filter { $0.isNumber || $0 == "." }
        guard let value = Double(cleaned) else { return 0 }
        if displayMode() == "fiat", let rate = rate(for: currencyCode), rate > 0 {
            return Int64((value / rate) * 100_000_000.0)
        }
        return Int64(value)
    }

    // MARK: - Helpers

    private func rate(for currency: String) -> Double? {
        ratesCache.first { $0.currencyCode == currency.uppercased() }?.rate
    }

    public func registerWebhook(url: String) async throws {
        try ensureConfigured()
        guard let sdk else { throw WalletError.notConfigured }
        try await run { try sdk.registerWebhook(webhookUrl: url) }
    }

    public func unregisterWebhook() async throws {
        try ensureConfigured()
        guard let sdk else { throw WalletError.notConfigured }
        try await run { try sdk.unregisterWebhook() }
    }

    private func ensureConfigured() throws {
        guard isConfigured else { throw WalletError.notConfigured }
    }

    /// Run a blocking Breez call off the main thread, surfacing errors as WalletError.core.
    private func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try body()) }
                catch { cont.resume(throwing: WalletError.core("\(error)")) }
            }
        }
    }

    private static func map(_ p: BreezSDKLiquid.Payment) -> Payment {
        var preimage: String?
        if case let .lightning(
            swapId: _,
            description: _,
            liquidExpirationBlockheight: _,
            preimage: pi,
            invoice: _,
            bolt12Offer: _,
            paymentHash: _,
            destinationPubkey: _,
            lnurlInfo: _,
            bip353Address: _,
            payerNote: _,
            claimTxId: _,
            refundTxId: _,
            refundTxAmountSat: _,
            settledAt: _
        ) = p.details {
            preimage = pi
        }
        return Payment(
            id: p.txId ?? p.destination ?? UUID().uuidString,
            amountSats: Int64(p.amountSat),
            isIncoming: p.paymentType == .receive,
            timestamp: Date(timeIntervalSince1970: TimeInterval(p.timestamp)),
            note: nil,
            feesSats: Int64(p.feesSat),
            preimage: preimage
        )
    }

    private static func bytes(fromHex hex: String) -> [UInt8]? {
        let s = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard s.count % 2 == 0 else { return nil }
        var out = [UInt8](); out.reserveCapacity(s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let b = UInt8(s[idx..<next], radix: 16) else { return nil }
            out.append(b); idx = next
        }
        return out
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

#endif
