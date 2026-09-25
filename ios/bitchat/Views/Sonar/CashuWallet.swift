//
// CashuWallet.swift
// bitchat
//
// The primary wallet for everyone: adapts `CashuWalletService` (the Rust
// `SonarCashuWallet`, ecash at mint.hedwig.sh) to the `SonarWalletProviding`
// seam the payments UI and `SonarAppStore` consume. The store gets it from
// `SonarAppStore.makeWallet(keychain:)`.
//
// The wallet is derived from the account's nsec (Keychain `marmot-nsec`,
// read-only here — this type never writes, replaces or deletes the account
// key; see the Account Key Durability Rule).
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Combine
import Foundation

@MainActor
final class CashuWallet: SonarWalletProviding {
    let service: CashuWalletService
    private let keychain: KeychainManagerProtocol
    private let nsecKey: String
    private var startTask: Task<Void, Never>?

    init(
        keychain: KeychainManagerProtocol,
        service: CashuWalletService? = nil,
        nsecKey: String = SonarAccountKeyExport.marmotNsecKey
    ) {
        self.keychain = keychain
        self.service = service ?? CashuWalletService()
        self.nsecKey = nsecKey
    }

    // MARK: State

    private static func state(accountId: String?, balance: SonarWalletBalanceDetail?) -> SonarWalletState {
        guard accountId != nil else { return .notConfigured }
        guard let balance else { return .settingUp }
        return .ready(balanceSats: balance.confirmedSats)
    }

    var state: SonarWalletState {
        Self.state(accountId: service.accountId, balance: service.balance)
    }

    var statePublisher: AnyPublisher<SonarWalletState, Never> {
        service.$accountId
            .combineLatest(service.$balance)
            .map { Self.state(accountId: $0, balance: $1) }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    var connectivity: SonarWalletConnectivity { service.connectivity }
    var balanceDetail: SonarWalletBalanceDetail? { service.balance }

    var detailChanged: AnyPublisher<Void, Never> {
        service.$connectivity.removeDuplicates().map { _ in () }
            .merge(with: service.$balance.removeDuplicates().map { _ in () })
            .eraseToAnyPublisher()
    }

    var cachedReceiveOffer: String? { service.receiveOffer }

    var receiveOfferPublisher: AnyPublisher<String?, Never> {
        service.$receiveOffer.removeDuplicates().eraseToAnyPublisher()
    }

    var custodyDescription: String? {
        String(localized: "Held as ecash at mint.hedwig.sh")
    }

    // MARK: Payments

    func send(
        destination: String,
        amountSats: Int64,
        note: String?,
        feeFromAmount: Bool
    ) async throws -> SonarWalletPayment {
        try await service.send(
            destination: destination,
            amountSats: amountSats,
            note: note,
            feeFromAmount: feeFromAmount
        )
    }

    func createOffer() async throws -> String {
        try await service.createOffer()
    }

    func receiveInvoice(amountSats: Int64, description: String?) async throws -> SonarReceiveInvoice {
        try await service.receiveInvoice(amountSats: amountSats, description: description)
    }

    func quoteFee(destination: String, amountSats: Int64) async throws -> Int64 {
        try await service.quoteFee(destination: destination, amountSats: amountSats)
    }

    func paymentUpdates() -> AsyncStream<SonarWalletPayment> {
        let publisher = service.paymentUpdates
        return AsyncStream { continuation in
            let cancellable = publisher.sink { continuation.yield($0) }
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }

    func latestPaymentUpdate(id: String) -> SonarWalletPayment? {
        service.latestUpdate(id: id)
    }

    func lookupPayment(id: String) async -> SonarWalletPayment? {
        await service.lookupPayment(id: id)
    }

    // MARK: Lifecycle

    /// Open for the signed-in account. Called after local paint (and again
    /// after a restore commits a new key); a no-op while no key exists.
    func start() {
        guard let nsec = readNsec() else { return }
        let previous = startTask
        startTask = Task { [weak self] in
            await previous?.value
            await self?.service.open(nsec: nsec)
        }
    }

    func setForeground(_ foreground: Bool) {
        service.setForeground(foreground)
    }

    /// Account replacement: KEEP `sonar-cashu/<oldAccountId>/` on disk.
    func prepareForIdentityReplacement() async throws {
        await startTask?.value
        try await service.release()
    }

    /// Panic wipe: every `sonar-cashu/` store and cache goes.
    func wipeForEmergency() async -> Bool {
        await startTask?.value
        startTask = nil
        return await service.wipeAll()
    }

    /// The account nsec, read-only. Any non-success read (locked device,
    /// access error) is "not yet" — retried on the next start — and never a
    /// reason to create anything.
    private func readNsec() -> String? {
        switch keychain.getIdentityKeyWithResult(forKey: nsecKey) {
        case .success(let data):
            let nsec = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard SonarWalletDerivation.secret(fromNsec: nsec) != nil else { return nil }
            return nsec
        case .itemNotFound:
            return nil
        case .accessDenied, .deviceLocked, .authenticationFailed, .otherError:
            SecureLogger.warning("Cashu wallet: account key not readable yet; wallet start deferred", category: .session)
            return nil
        }
    }
}

/// The account's relays for the wallet's offer backups, through the Marmot node.
@MainActor
final class MarmotOfferBackupRelay: SonarOfferBackupRelay {
    private weak var marmot: MarmotChatModel?

    init(marmot: MarmotChatModel) {
        self.marmot = marmot
    }

    func fetch() async -> [String]? {
        guard let marmot else { return nil }
        return try? await marmot.fetchWalletOfferBackups()
    }

    func publish(_ backup: String) async -> Bool {
        guard let marmot else { return false }
        return (try? await marmot.publishWalletOfferBackup(backup)) != nil
    }
}
