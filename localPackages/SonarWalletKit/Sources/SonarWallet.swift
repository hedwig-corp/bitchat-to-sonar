//
// SonarWallet.swift
// SonarWalletKit
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(iOS)

import Foundation
import SonarWalletKit

/// Swift façade over the KMP `IosWalletBridge`: async/await instead of
/// callbacks, plain Swift value types instead of KMP classes, and a
/// one-call `configure(apiKey:mainnet:)` that wires Keychain storage and
/// the Breez working directory.
///
/// No singleton — construct one and inject it (the underlying
/// `SonarWalletComponent` Kotlin object is process-global, so use one
/// instance per process in practice).
public final class SonarWallet {

    // MARK: - Public model types (callers must not import SonarWalletKit)

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
        /// "bolt11", "bolt12_offer", "lightning_address", "lnurl_pay", ...
        public let kind: String
        /// Embedded amount, when the destination carries one.
        public let amountSats: Int64?
        public let note: String
    }

    public enum WalletError: Error, Equatable {
        /// `configure(apiKey:mainnet:)` has not been called.
        case notConfigured
        /// Failure inside the wallet engine (Breez SDK, key manager...).
        case core(String)
    }

    // MARK: - State

    private let bridge = IosWalletBridge()
    public private(set) var isConfigured = false

    public init() {}

    deinit {
        bridge.destroy()
    }

    // MARK: - Configuration

    /// Wire the wallet engine: Keychain-backed storage + working directory
    /// at `Application Support/sonar-wallet`. Must be called once before
    /// any other method.
    public func configure(apiKey: String, mainnet: Bool) throws {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let workingDir = appSupport.appendingPathComponent("sonar-wallet", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)

        SonarWalletComponent.shared.configure(
            breezApiKey: apiKey,
            workingDir: workingDir.path,
            mainnet: mainnet,
            storage: KeychainWalletStorage()
        )
        isConfigured = true
    }

    // MARK: - Wallet lifecycle

    public func hasWallet() async throws -> Bool {
        try ensureConfigured()
        return await withCheckedContinuation { continuation in
            bridge.hasWallet { result in
                continuation.resume(returning: result.boolValue)
            }
        }
    }

    /// Generate and persist a fresh BIP39 mnemonic. Returns the mnemonic so
    /// the app can offer a manual backup flow. Throws if a wallet exists.
    @discardableResult
    public func createWallet() async throws -> String {
        try ensureConfigured()
        return try await withCheckedThrowingContinuation { continuation in
            bridge.createWallet(
                onSuccess: { continuation.resume(returning: $0) },
                onError: { continuation.resume(throwing: WalletError.core($0)) }
            )
        }
    }

    /// Create the wallet DETERMINISTICALLY from caller-supplied 32-byte
    /// entropy (`entropyHex` = 64 hex chars) → a 24-word BIP39 mnemonic.
    /// Lets the host derive one-wallet-per-identity (e.g. from a Nostr key).
    /// Does NOT start the node — call `startNode()` afterward. Throws if a
    /// wallet already exists or the entropy is malformed.
    @discardableResult
    public func createWalletFromEntropy(entropyHex: String) async throws -> String {
        try ensureConfigured()
        return try await withCheckedThrowingContinuation { continuation in
            bridge.createWalletFromEntropy(
                entropyHex: entropyHex,
                onSuccess: { continuation.resume(returning: $0) },
                onError: { continuation.resume(throwing: WalletError.core($0)) }
            )
        }
    }

    /// The stored mnemonic, or nil when no wallet exists.
    public func loadWallet() async throws -> String? {
        try ensureConfigured()
        return try await withCheckedThrowingContinuation { continuation in
            bridge.loadWallet(
                onResult: { continuation.resume(returning: $0) },
                onError: { continuation.resume(throwing: WalletError.core($0)) }
            )
        }
    }

    // MARK: - Node lifecycle

    public func startNode() async throws {
        try ensureConfigured()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            bridge.startNode(
                onSuccess: { continuation.resume() },
                onError: { continuation.resume(throwing: WalletError.core($0)) }
            )
        }
    }

    public func stopNode() async throws {
        try ensureConfigured()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            bridge.stopNode(
                onSuccess: { continuation.resume() },
                onError: { continuation.resume(throwing: WalletError.core($0)) }
            )
        }
    }

    // MARK: - Observation

    /// Live wallet balance in sats. The stream ends when the task consuming
    /// it is cancelled.
    public func balanceStream() -> AsyncStream<Int64> {
        let bridge = self.bridge
        return AsyncStream { continuation in
            let handle = bridge.observeBalance { amount in
                continuation.yield(amount.sats)
            }
            continuation.onTermination = { _ in
                handle.cancel()
            }
        }
    }

    /// Incoming payments as they settle.
    public func incomingPaymentsStream() -> AsyncStream<Payment> {
        let bridge = self.bridge
        return AsyncStream { continuation in
            let handle = bridge.observeIncomingPayments { payment in
                continuation.yield(Self.map(payment))
            }
            continuation.onTermination = { _ in
                handle.cancel()
            }
        }
    }

    // MARK: - Payments

    /// Send to any Lightning destination: BOLT11 invoice, BOLT12 offer,
    /// LNURL-pay, or a BIP-353 address (`user@domain`) — the Breez SDK
    /// resolves BIP-353 internally. Pass `amountSats` > 0 for amountless
    /// destinations; 0 when the destination embeds the amount.
    @discardableResult
    public func send(
        destination: String,
        amountSats: Int64 = 0,
        note: String = ""
    ) async throws -> Payment {
        try ensureConfigured()
        return try await withCheckedThrowingContinuation { continuation in
            bridge.send(
                destination: destination,
                amountSats: amountSats,
                payerNote: note,
                onSuccess: { continuation.resume(returning: Self.map($0)) },
                onError: { continuation.resume(throwing: WalletError.core($0)) }
            )
        }
    }

    /// Parse/classify a destination string (also resolves BIP-353).
    public func parseDestination(_ input: String) async throws -> Destination {
        try ensureConfigured()
        return try await withCheckedThrowingContinuation { continuation in
            bridge.parseDestination(
                input: input,
                onSuccess: { destination in
                    continuation.resume(returning: Destination(
                        raw: destination.raw,
                        kind: destination.type.name.lowercased(),
                        amountSats: destination.amount.map(\.sats),
                        note: destination.description_
                    ))
                },
                onError: { continuation.resume(throwing: WalletError.core($0)) }
            )
        }
    }

    /// Create a reusable BOLT12 offer for receiving payments.
    public func createOffer() async throws -> String {
        try ensureConfigured()
        return try await withCheckedThrowingContinuation { continuation in
            bridge.createOffer(
                onSuccess: { continuation.resume(returning: $0) },
                onError: { continuation.resume(throwing: WalletError.core($0)) }
            )
        }
    }

    // MARK: - Helpers

    private func ensureConfigured() throws {
        guard isConfigured else { throw WalletError.notConfigured }
    }

    private static func map(_ payment: LightningPayment) -> Payment {
        Payment(
            id: payment.id,
            amountSats: payment.amount.sats,
            isIncoming: payment.direction == .incoming,
            timestamp: Date(timeIntervalSince1970: TimeInterval(payment.timestampEpochSeconds)),
            note: payment.description_,
            feesSats: payment.feesSat?.int64Value
        )
    }
}

#endif
