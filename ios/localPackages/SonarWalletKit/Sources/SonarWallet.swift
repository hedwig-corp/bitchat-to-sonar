//
// SonarWallet.swift
// WalletKit
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(iOS)

import Foundation
import BreezSDKLiquid

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
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("sonar-wallet", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.apiKey = apiKey
        self.mainnet = mainnet
        self.workingDir = dir.path
        self.isConfigured = true
    }

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
            let resp = try node.receivePayment(req: ReceivePaymentRequest(prepareResponse: prepared, description: "Sonar", useDescriptionHash: nil, payerNote: nil))
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
        Payment(
            id: p.txId ?? p.destination ?? UUID().uuidString,
            amountSats: Int64(p.amountSat),
            isIncoming: p.paymentType == .receive,
            timestamp: Date(timeIntervalSince1970: TimeInterval(p.timestamp)),
            note: nil,
            feesSats: Int64(p.feesSat)
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
