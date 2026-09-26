//
// LegacyBreezWallet.swift
// bitchat
//
// The old Breez (Liquid) Lightning wallet, now LEGACY. Cashu is Sonar's
// wallet for everyone (`CashuWallet`); Breez survives only while its store
// already exists on the device:
//
//  - never created for a new install (`WalletBridgeService.allowCreatingWallet`
//    is false everywhere except the one post-restore check);
//  - visible as the "Old Lightning wallet" card while present;
//  - spendable through the normal send flow with this wallet as the source;
//  - deletable by the user ONLY when `SonarLegacyDeleteGate` proves the funds
//    are safe — never auto-deleted;
//  - its Breez NDS webhook / invoice_request push path stays alive only while
//    it exists.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Combine
import CryptoKit
import Foundation
import Security

/// Deterministic wallet-entropy derivation from the Sonar chat identity.
///
/// The Breez wallet was derived from the same Nostr secret that backs the
/// chat identity (Keychain `marmot-nsec`), so it is always reconstructable
/// from the nsec. Derivation is a domain-separated HKDF so the wallet seed is
/// not the raw signing key:
///
///   entropy = HKDF-SHA256(ikm: nostrSecret, salt: "sonar-wallet",
///                         info: "sonar-bolt12-v1", L: 32)
///
/// Pure and platform-agnostic so it can be unit-tested without the wallet
/// framework.
enum SonarWalletDerivation {
    static let salt = "sonar-wallet"
    static let info = "sonar-bolt12-v1"

    /// Derive 32 bytes of wallet entropy from a 32-byte Nostr secret.
    static func entropy(fromSecret secret: Data) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: Data(salt.utf8),
            info: Data(info.utf8),
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    /// 64-char lowercase hex of the derived entropy (what the wallet-kit
    /// `createWalletFromEntropy` expects).
    static func entropyHex(fromSecret secret: Data) -> String {
        entropy(fromSecret: secret).map { String(format: "%02x", $0) }.joined()
    }

    /// Decode the 32-byte secret from an `nsec1…` bech32 string.
    static func secret(fromNsec nsec: String) -> Data? {
        guard let decoded = try? Bech32.decode(nsec),
              decoded.hrp == "nsec",
              decoded.data.count == 32
        else { return nil }
        return decoded.data
    }
}

// MARK: - Delete gate (pure)

/// What the legacy wallet reported after a sync on the CURRENT connection.
/// Every field that is nil is unknown — and unknown is never safe.
struct SonarLegacyWalletSnapshot: Equatable {
    var connected: Bool
    /// A sync completed on this connection (not an earlier one).
    var syncedSinceConnect: Bool
    var confirmedSats: UInt64?
    var pendingSendSats: UInt64?
    var pendingReceiveSats: UInt64?
    var refundableSwaps: Int?
    /// Payments not in a terminal state (Pending, Refundable, ...).
    var unsettledPayments: Int?
    var hasHistory: Bool?
}

/// The one-time post-restore check's decision. Pure; unit-tested.
///
/// One empty pass is not proof: on a fresh device a sync can finish before
/// the wallet's history has landed locally, and a discarded wallet is never
/// opened again, so whatever it held would be out of the app's reach. An
/// empty first pass is believed only when a second pass, `confirmDelay`
/// later and synced, is empty too. Unknown decides nothing: the store is
/// kept and the check runs again on a later launch.
enum SonarLegacyRestoreCheck {
    enum Verdict: Equatable {
        case keep
        case discard
        case undecided
    }

    /// How long the check waits before the pass that confirms an empty wallet.
    static let confirmDelayNanos: UInt64 = 15_000_000_000

    /// Whether a synced pass saw anything at all; nil = not synced, or a
    /// fact could not be read.
    static func holdsAnything(_ snapshot: SonarLegacyWalletSnapshot?) -> Bool? {
        guard let s = snapshot, s.connected, s.syncedSinceConnect,
              let confirmed = s.confirmedSats,
              let pendingSend = s.pendingSendSats,
              let pendingReceive = s.pendingReceiveSats,
              let refundables = s.refundableSwaps,
              let unsettled = s.unsettledPayments,
              let hasHistory = s.hasHistory
        else { return nil }
        return confirmed > 0 || pendingSend > 0 || pendingReceive > 0
            || refundables > 0 || unsettled > 0 || hasHistory
    }

    static func verdict(first: SonarLegacyWalletSnapshot?, confirm: SonarLegacyWalletSnapshot?) -> Verdict {
        switch holdsAnything(first) {
        case .none: return .undecided
        case .some(true): return .keep
        case .some(false): break
        }
        switch holdsAnything(confirm) {
        case .none: return .undecided
        case .some(true): return .keep
        case .some(false): return .discard
        }
    }
}

/// Whether the legacy wallet may be deleted. Pure; unit-tested as a matrix.
/// ALL of: connected + a completed sync since connecting; confirmed == 0;
/// pending send == 0; pending receive == 0; no refundable swaps; no
/// Pending/Refundable payments. Anything unknown ⇒ NOT safe.
enum SonarLegacyDeleteGate {
    enum Blocker: Equatable {
        case unknown
        case notConnected
        case notSynced
        case balance(UInt64)
        case pendingSend(UInt64)
        case pendingReceive(UInt64)
        case refundableSwaps(Int)
        case unsettledPayments(Int)
    }

    /// nil = safe to delete.
    static func blocker(for snapshot: SonarLegacyWalletSnapshot?) -> Blocker? {
        guard let s = snapshot else { return .unknown }
        guard s.connected else { return .notConnected }
        guard s.syncedSinceConnect else { return .notSynced }
        guard let confirmed = s.confirmedSats,
              let pendingSend = s.pendingSendSats,
              let pendingReceive = s.pendingReceiveSats,
              let refundables = s.refundableSwaps,
              let unsettled = s.unsettledPayments
        else { return .unknown }
        if confirmed > 0 { return .balance(confirmed) }
        if pendingSend > 0 { return .pendingSend(pendingSend) }
        if pendingReceive > 0 { return .pendingReceive(pendingReceive) }
        if refundables > 0 { return .refundableSwaps(refundables) }
        if unsettled > 0 { return .unsettledPayments(unsettled) }
        return nil
    }

    /// The reason shown when the delete action is refused.
    static func message(for blocker: Blocker, money: (Int64) -> String) -> String {
        switch blocker {
        case .unknown:
            return String(localized: "Sonar can't confirm the old wallet is empty yet.")
        case .notConnected:
            return String(localized: "Connect to the internet so Sonar can check the old wallet.")
        case .notSynced:
            return String(localized: "Still checking the old wallet — try again in a moment.")
        case .balance(let sats):
            let amount = money(Int64(clamping: sats))
            return String(localized: "It still holds \(amount). Send it out first.")
        case .pendingSend:
            return String(localized: "A payment is still leaving the old wallet.")
        case .pendingReceive:
            return String(localized: "A payment is still arriving in the old wallet.")
        case .refundableSwaps:
            return String(localized: "The old wallet has a refund waiting to be claimed.")
        case .unsettledPayments:
            return String(localized: "A payment in the old wallet hasn't settled yet.")
        }
    }
}

// MARK: - Storage

/// Presence of the legacy Breez wallet on this device.
enum SonarLegacyPresence: Equatable {
    case present
    case absent
    /// The Keychain could not answer (locked, access error). Decide later.
    case unknown
}

enum SonarLegacyWalletStorageError: Error {
    case keychain(OSStatus)
    case filesystem(Error)
    case storageStillPresent
    case marker
    case seedWrite
}

/// Every on-disk / Keychain location of the legacy Breez wallet, plus the
/// crash-safe markers around destructive steps. Paths are injectable so the
/// file half is unit-testable.
struct SonarLegacyWalletStorage {
    /// Breez keeps its seed and (formerly) display prefs here.
    static let keychainService = "chat.bitchat.sonar.wallet"
    static let seedAccount = "seed.v1"
    static let appGroupId = "group.sh.hedwig.sonar"

    enum Markers {
        /// Finish deleting the legacy store + seed (user delete, panic wipe,
        /// and the identity-replacement wipe of older builds).
        static let cleanupPending = "sonar.wallet.cleanupPending"
        /// Finish archiving the legacy store for this account id.
        static let archivePending = "sonar.legacy.archivePending"
        static let restoreCheckPendingPrefix = "sonar.legacy.restoreCheckPending."
        static let restoreCheckDonePrefix = "sonar.legacy.restoreCheckDone."
    }

    let fileManager: FileManager
    let appGroupContainer: URL?
    let applicationSupportDirectory: URL?
    let sharedDefaults: UserDefaults?
    let defaults: UserDefaults

    static func live() -> SonarLegacyWalletStorage {
        let fm = FileManager.default
        return SonarLegacyWalletStorage(
            fileManager: fm,
            appGroupContainer: fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupId),
            applicationSupportDirectory: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
            sharedDefaults: UserDefaults(suiteName: appGroupId),
            defaults: .standard
        )
    }

    /// The Breez working-directory roots: the App Group store the app and the
    /// NSE share, and the pre-App-Group per-app fallback.
    var storeRoots: [URL] {
        [
            appGroupContainer?.appendingPathComponent("breez-sdk", isDirectory: true),
            applicationSupportDirectory?.appendingPathComponent("sonar-wallet", isDirectory: true),
        ].compactMap { $0 }
    }

    /// `<root>-archive`, a sibling on the same volume so archiving is a rename.
    static func archiveRoot(for root: URL) -> URL {
        root.deletingLastPathComponent()
            .appendingPathComponent(root.lastPathComponent + "-archive", isDirectory: true)
    }

    // MARK: Keychain

    /// Seed present ⇒ the legacy wallet exists.
    func seedPresence() -> SonarLegacyPresence {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.seedAccount,
            kSecReturnData as String: false,
        ]
        switch SecItemCopyMatching(query as CFDictionary, nil) {
        case errSecSuccess: return .present
        case errSecItemNotFound: return .absent
        default: return .unknown
        }
    }

    /// Delete ONLY the Breez seed item (not the whole service).
    func deleteSeed() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.seedAccount,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SonarLegacyWalletStorageError.keychain(status)
        }
    }

    /// Panic wipe: every item in the Breez Keychain service.
    func deleteKeychainService() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SonarLegacyWalletStorageError.keychain(status)
        }
    }

    /// Re-create the deterministic seed for an account whose archived store
    /// is coming back (same bytes the old app derived: HKDF of the nsec).
    func writeDerivedSeed(nsec: String) throws {
        guard let secret = SonarWalletDerivation.secret(fromNsec: nsec) else {
            throw SonarLegacyWalletStorageError.seedWrite
        }
        let seed = SonarWalletDerivation.entropy(fromSecret: secret)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.seedAccount,
        ]
        var add = base
        add[kSecValueData as String] = seed
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: seed] as CFDictionary)
        }
        guard status == errSecSuccess else { throw SonarLegacyWalletStorageError.keychain(status) }
    }

    // MARK: Files

    /// NSE / App Group mirrored connect creds (seed hex) must not outlive the
    /// wallet they connect.
    func clearSharedCredentials() {
        guard let sharedDefaults else { return }
        sharedDefaults.removeObject(forKey: "breez_api_key")
        sharedDefaults.removeObject(forKey: "breez_seed_hex")
        sharedDefaults.removeObject(forKey: "breez_mainnet")
        _ = sharedDefaults.synchronize()
    }

    /// Remove the live Breez store roots (not archives). Proves absence.
    func deleteStoreFiles() throws {
        for root in storeRoots {
            try remove(root)
        }
    }

    /// Panic wipe: live roots AND archives.
    func deleteStoreFilesAndArchives() throws {
        for root in storeRoots {
            try remove(root)
            try remove(Self.archiveRoot(for: root))
        }
    }

    private func remove(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw SonarLegacyWalletStorageError.filesystem(error)
        }
        guard !fileManager.fileExists(atPath: url.path) else {
            throw SonarLegacyWalletStorageError.storageStillPresent
        }
    }

    /// Move each live root to `<root>-archive/<accountId>` (a same-volume
    /// rename — nothing is copied or deleted). An existing archive for the
    /// same account is never overwritten: the new one gets a suffix.
    func archiveStore(accountId: String) throws {
        for root in storeRoots where fileManager.fileExists(atPath: root.path) {
            let archive = Self.archiveRoot(for: root)
            do {
                try fileManager.createDirectory(at: archive, withIntermediateDirectories: true)
                var target = archive.appendingPathComponent(accountId, isDirectory: true)
                var suffix = 2
                while fileManager.fileExists(atPath: target.path) {
                    target = archive.appendingPathComponent("\(accountId)-\(suffix)", isDirectory: true)
                    suffix += 1
                }
                try fileManager.moveItem(at: root, to: target)
            } catch {
                throw SonarLegacyWalletStorageError.filesystem(error)
            }
        }
    }

    /// Whether any archive exists for `accountId`.
    func hasArchive(accountId: String) -> Bool {
        storeRoots.contains {
            fileManager.fileExists(atPath: Self.archiveRoot(for: $0).appendingPathComponent(accountId).path)
        }
    }

    /// Move `<root>-archive/<accountId>` back to `<root>` when the live root
    /// is absent. Returns true when anything came back.
    @discardableResult
    func restoreArchive(accountId: String) throws -> Bool {
        var restored = false
        for root in storeRoots {
            let archived = Self.archiveRoot(for: root).appendingPathComponent(accountId, isDirectory: true)
            guard fileManager.fileExists(atPath: archived.path),
                  !fileManager.fileExists(atPath: root.path)
            else { continue }
            do {
                try fileManager.moveItem(at: archived, to: root)
            } catch {
                throw SonarLegacyWalletStorageError.filesystem(error)
            }
            restored = true
        }
        return restored
    }

    // MARK: Markers

    func setMarker(_ key: String, _ value: Any) throws {
        defaults.set(value, forKey: key)
        guard defaults.synchronize() else { throw SonarLegacyWalletStorageError.marker }
    }

    func clearMarker(_ key: String) throws {
        defaults.removeObject(forKey: key)
        guard defaults.synchronize() else { throw SonarLegacyWalletStorageError.marker }
    }

    var cleanupPending: Bool { defaults.bool(forKey: Markers.cleanupPending) }
    var archivePendingAccount: String? { defaults.string(forKey: Markers.archivePending) }

    func restoreCheckPending(_ accountId: String) -> Bool {
        defaults.bool(forKey: Markers.restoreCheckPendingPrefix + accountId)
    }

    func restoreCheckDone(_ accountId: String) -> Bool {
        defaults.bool(forKey: Markers.restoreCheckDonePrefix + accountId)
    }

    /// Arm the one-time post-restore check for `accountId` (unless it ran).
    func armRestoreCheck(_ accountId: String) {
        guard !restoreCheckDone(accountId) else { return }
        defaults.set(true, forKey: Markers.restoreCheckPendingPrefix + accountId)
    }

    func completeRestoreCheck(_ accountId: String) {
        defaults.removeObject(forKey: Markers.restoreCheckPendingPrefix + accountId)
        defaults.set(true, forKey: Markers.restoreCheckDonePrefix + accountId)
    }

    func clearAllMarkers() {
        defaults.removeObject(forKey: Markers.cleanupPending)
        defaults.removeObject(forKey: Markers.archivePending)
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(Markers.restoreCheckPendingPrefix) || key.hasPrefix(Markers.restoreCheckDonePrefix) {
            defaults.removeObject(forKey: key)
        }
        _ = defaults.synchronize()
    }

    // MARK: Composite steps (crash-safe)

    /// Delete the legacy store and ONLY its seed/credentials, behind the
    /// cleanup marker. The caller must have stopped the node.
    func deleteLegacyWallet() throws {
        try setMarker(Markers.cleanupPending, true)
        try deleteStoreFiles()
        try deleteSeed()
        clearSharedCredentials()
        try clearMarker(Markers.cleanupPending)
    }

    /// Archive the legacy store under `accountId` and clear its seed and
    /// credentials, behind the archive marker. The caller must have stopped
    /// the node.
    func archiveLegacyWallet(accountId: String) throws {
        try setMarker(Markers.archivePending, accountId)
        try archiveStore(accountId: accountId)
        try deleteSeed()
        clearSharedCredentials()
        try clearMarker(Markers.archivePending)
    }

    /// Finish a destructive step a crash interrupted. Runs before any
    /// presence check, while no Breez node is open.
    func finishInterruptedSteps() {
        if let accountId = archivePendingAccount {
            do {
                try archiveLegacyWallet(accountId: accountId)
            } catch {
                SecureLogger.error("Legacy wallet: interrupted archive still incomplete: \(error)", category: .session)
            }
        }
        if cleanupPending {
            do {
                try deleteLegacyWallet()
            } catch {
                SecureLogger.error("Legacy wallet: interrupted cleanup still incomplete: \(error)", category: .session)
            }
        }
    }

    /// Panic wipe: everything, archives and markers included.
    func wipeEverything() throws {
        try setMarker(Markers.cleanupPending, true)
        try deleteKeychainService()
        try deleteStoreFilesAndArchives()
        clearSharedCredentials()
        clearAllMarkers()
    }
}

#if os(iOS) || os(macOS)

// MARK: - Legacy wallet

@MainActor
final class LegacyBreezWallet: ObservableObject, SonarWalletProviding {
    enum Mode: Equatable {
        /// Open the wallet whose seed exists. Never creates one.
        case openExisting
        /// The one-time post-restore check: may re-derive the seed.
        case restoreCheck
    }

    enum DeleteError: LocalizedError, Equatable {
        case blocked(SonarLegacyDeleteGate.Blocker)
        case cleanupFailed

        var errorDescription: String? {
            switch self {
            case .blocked(let blocker):
                return SonarLegacyDeleteGate.message(for: blocker, money: sonarFormatSats)
            case .cleanupFailed:
                return String(localized: "The old wallet couldn't be removed. Restart Sonar and try again.")
            }
        }
    }

    let mode: Mode
    private let bridge: WalletBridgeService
    var walletService: WalletBridgeService { bridge }
    private let storage: SonarLegacyWalletStorage

    /// Last snapshot taken after a sync on the current connection.
    @Published private(set) var snapshot: SonarLegacyWalletSnapshot?
    private var snapshotEpoch: UInt64?
    private var snapshotTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(
        mode: Mode,
        keychain: KeychainManagerProtocol,
        storage: SonarLegacyWalletStorage = .live()
    ) {
        self.mode = mode
        self.bridge = WalletBridgeService()
        self.storage = storage
        bridge.allowCreatingWallet = (mode == .restoreCheck)
        let keychainRef = keychain
        bridge.entropyProvider = {
            guard let data = keychainRef.getIdentityKey(forKey: SonarAccountKeyExport.marmotNsecKey),
                  let nsec = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let secret = SonarWalletDerivation.secret(fromNsec: nsec)
            else { return nil }
            return SonarWalletDerivation.entropyHex(fromSecret: secret)
        }
        // Take the delete-gate snapshot each time the node (re)connects.
        bridge.$state
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                if case .ready = state {
                    self.refreshSnapshotSoon()
                } else if self.snapshot != nil {
                    // A snapshot from a connection that is gone proves nothing.
                    self.snapshot = nil
                    self.snapshotEpoch = nil
                }
            }
            .store(in: &cancellables)
        retrySetup()
    }

    /// (Re)attempt opening the node. Safe to call repeatedly.
    func retrySetup() {
        Task { [weak self] in try? await self?.bridge.setupIfNeeded() }
    }

    // MARK: SonarWalletProviding (the legacy send source)

    private static func map(_ state: WalletBridgeService.State) -> SonarWalletState {
        switch state {
        case .notConfigured: return .notConfigured
        case .settingUp: return .settingUp
        case .ready(let balanceSats): return .ready(balanceSats: balanceSats)
        }
    }

    var state: SonarWalletState { Self.map(bridge.state) }

    var statePublisher: AnyPublisher<SonarWalletState, Never> {
        bridge.statePublisher
            .map { LegacyBreezWallet.map($0) }
            .eraseToAnyPublisher()
    }

    var connectivity: SonarWalletConnectivity {
        switch bridge.state {
        case .ready: return .online
        case .settingUp: return .connecting
        case .notConfigured: return .offline
        }
    }

    var balanceDetail: SonarWalletBalanceDetail? {
        guard let s = snapshot, let confirmed = s.confirmedSats else { return nil }
        return SonarWalletBalanceDetail(
            confirmedSats: Int64(clamping: confirmed),
            pendingReceiveSats: Int64(clamping: s.pendingReceiveSats ?? 0),
            pendingSendSats: Int64(clamping: s.pendingSendSats ?? 0),
            isLive: true
        )
    }

    var detailChanged: AnyPublisher<Void, Never> {
        $snapshot.map { _ in () }
            .merge(with: bridge.$state.map { _ in () })
            .eraseToAnyPublisher()
    }

    func send(
        destination: String,
        amountSats: Int64,
        note: String?,
        feeFromAmount: Bool
    ) async throws -> SonarWalletPayment {
        // Breez `Max` keeps the 0.5% reserve (SonarSpendableBalance); the
        // fee-from-amount mode is a Cashu mechanism and is ignored here.
        let payment = try await bridge.send(destination: destination, amountSats: amountSats, note: note ?? "")
        refreshSnapshotSoon()
        return SonarWalletPayment(
            id: payment.id,
            amountSats: payment.amountSats,
            isIncoming: payment.isIncoming,
            timestamp: payment.timestamp,
            note: payment.note,
            feesSats: payment.feesSats,
            preimage: payment.preimage
        )
    }

    /// The legacy wallet's OWN offer — only the Breez NDS webhook uses it.
    func createOffer() async throws -> String {
        try await bridge.createOffer()
    }

    // MARK: Snapshot / gate

    var deleteBlocker: SonarLegacyDeleteGate.Blocker? {
        SonarLegacyDeleteGate.blocker(for: currentSnapshot)
    }

    /// The snapshot, only while it belongs to the live connection.
    private var currentSnapshot: SonarLegacyWalletSnapshot? {
        guard let snapshot, case .ready = bridge.state, snapshotEpoch == bridge.connectionEpoch else {
            return nil
        }
        return snapshot
    }

    private func refreshSnapshotSoon() {
        guard snapshotTask == nil else { return }
        snapshotTask = Task { [weak self] in
            await self?.refreshSnapshot()
            self?.snapshotTask = nil
        }
    }

    /// Sync on the current connection and record what the gate needs. A
    /// failure records an all-unknown snapshot (never safe).
    func refreshSnapshot() async {
        guard case .ready = bridge.state else {
            snapshot = nil
            snapshotEpoch = nil
            return
        }
        let epoch = bridge.connectionEpoch
        do {
            let info = try await bridge.inspect()
            guard epoch == bridge.connectionEpoch else { return }
            snapshot = SonarLegacyWalletSnapshot(
                connected: true,
                syncedSinceConnect: true,
                confirmedSats: info.balanceSat,
                pendingSendSats: info.pendingSendSat,
                pendingReceiveSats: info.pendingReceiveSat,
                refundableSwaps: info.refundableSwaps,
                unsettledPayments: info.unsettledPayments,
                hasHistory: info.hasHistory
            )
            snapshotEpoch = epoch
        } catch {
            SecureLogger.warning("Legacy wallet inspection failed: \(error)", category: .session)
            guard epoch == bridge.connectionEpoch else { return }
            snapshot = SonarLegacyWalletSnapshot(connected: true, syncedSinceConnect: false)
            snapshotEpoch = epoch
        }
    }

    // MARK: Destructive paths

    /// Delete this wallet: re-check the gate on a fresh sync → unregister the
    /// webhook → disconnect → crash-safe marker → delete the store and ONLY
    /// the Breez seed/credentials → clear the marker.
    func deleteIfSafe(unregisterWebhook: (WalletBridgeService) async -> Void) async throws {
        await refreshSnapshot()
        if let blocker = deleteBlocker { throw DeleteError.blocked(blocker) }
        let gated = currentSnapshot
        await unregisterWebhook(bridge)
        // A payment could settle while the webhook was being removed (an
        // incoming swap completing, say): read again, and delete only if
        // nothing moved. If this stops here, the next push registration puts
        // the webhook back.
        await refreshSnapshot()
        if let blocker = deleteBlocker { throw DeleteError.blocked(blocker) }
        guard currentSnapshot == gated else { throw DeleteError.blocked(.unknown) }
        do {
            // Disconnect BEFORE the marker: a crash in between leaves an
            // intact wallet that simply reopens, never a half-armed delete.
            try await bridge.shutdownForStorageMutation()
            try storage.deleteLegacyWallet()
        } catch {
            SecureLogger.error("Legacy wallet delete failed: \(error)", category: .session)
            throw DeleteError.cleanupFailed
        }
        snapshot = nil
    }

    /// Account replacement: delete when the gate passes, otherwise archive
    /// the store under `oldAccountId` and clear its seed/credentials. Never
    /// destroys a wallet that may hold funds.
    func releaseForReplacement(oldAccountId: String) async throws {
        await refreshSnapshot()
        let safe = deleteBlocker == nil
        try await bridge.shutdownForStorageMutation()
        if safe {
            try storage.deleteLegacyWallet()
        } else {
            try storage.archiveLegacyWallet(accountId: oldAccountId)
        }
        snapshot = nil
    }

    /// Panic wipe: stop the node, then everything goes.
    func wipeForEmergency() async -> Bool {
        do {
            try storage.setMarker(SonarLegacyWalletStorage.Markers.cleanupPending, true)
            try await bridge.shutdownForStorageMutation()
        } catch {
            SecureLogger.error("Legacy wallet shutdown before emergency wipe failed: \(error)", category: .session)
            return false
        }
        do {
            try storage.wipeEverything()
        } catch {
            SecureLogger.error("Legacy wallet emergency wipe failed: \(error)", category: .session)
            return false
        }
        snapshot = nil
        return true
    }
}

// MARK: - Coordinator (presence, restore check, replacement)

/// Decides whether a legacy wallet exists for this device and account and
/// owns its lifecycle. The store holds one; tests inject the probes.
@MainActor
final class SonarLegacyWalletCoordinator: ObservableObject {
    typealias Factory = (LegacyBreezWallet.Mode) -> LegacyBreezWallet

    @Published private(set) var wallet: LegacyBreezWallet?
    /// True while the one-time post-restore check has not decided yet. The
    /// store keeps the Breez webhook off until the wallet is known to stay.
    @Published private(set) var restoreCheckInProgress = false

    private let storage: SonarLegacyWalletStorage
    private let presence: () -> SonarLegacyPresence
    private let hasAPIKey: () -> Bool
    private let nsecProvider: () -> String?
    private let factory: Factory
    private let unregisterWebhook: (WalletBridgeService) async -> Void
    private let restoreConfirmDelayNanos: UInt64
    private var restoreCheckCancellable: AnyCancellable?
    private var restoreCheckAccountId: String?

    init(
        storage: SonarLegacyWalletStorage = .live(),
        presence: (() -> SonarLegacyPresence)? = nil,
        hasAPIKey: @escaping () -> Bool = { SonarBreezBuildConfig.hasAPIKey },
        nsecProvider: @escaping () -> String?,
        unregisterWebhook: @escaping (WalletBridgeService) async -> Void = { _ in },
        restoreConfirmDelayNanos: UInt64 = SonarLegacyRestoreCheck.confirmDelayNanos,
        factory: @escaping Factory
    ) {
        self.storage = storage
        self.presence = presence ?? { storage.seedPresence() }
        self.hasAPIKey = hasAPIKey
        self.nsecProvider = nsecProvider
        self.unregisterWebhook = unregisterWebhook
        self.restoreConfirmDelayNanos = restoreConfirmDelayNanos
        self.factory = factory
    }

    private var currentAccountId: String? {
        nsecProvider().map { SonarCashuStorage.accountId(nsec: $0) }
    }

    /// Presence check. Runs after local paint and again after a restore;
    /// constructs NOTHING when no legacy store exists for this device/account.
    func refresh() {
        guard wallet == nil else { return }
        storage.finishInterruptedSteps()
        switch presence() {
        case .present:
            attach(factory(.openExisting))
        case .unknown:
            return
        case .absent:
            guard let nsec = nsecProvider() else { return }
            let accountId = SonarCashuStorage.accountId(nsec: nsec)
            if storage.hasArchive(accountId: accountId) {
                // This account's archived legacy store comes back with it.
                do {
                    try storage.restoreArchive(accountId: accountId)
                    try storage.writeDerivedSeed(nsec: nsec)
                    attach(factory(.openExisting))
                } catch {
                    SecureLogger.error("Legacy wallet archive restore failed: \(error)", category: .session)
                }
                return
            }
            if storage.restoreCheckPending(accountId), hasAPIKey() {
                attach(factory(.restoreCheck))
            }
        }
    }

    private func attach(_ legacy: LegacyBreezWallet) {
        wallet = legacy
        watchRestoreCheck(legacy)
    }

    /// Arm the one-time post-restore check for the account just restored.
    func armRestoreCheck() {
        guard let id = currentAccountId else { return }
        storage.armRestoreCheck(id)
    }

    /// While this account's restore check is pending, decide once a synced
    /// snapshot exists: keep the wallet if it has any balance, pending amount
    /// or payment history; delete what the check created only when a second
    /// pass confirms it empty (`SonarLegacyRestoreCheck`).
    private func watchRestoreCheck(_ legacy: LegacyBreezWallet) {
        guard let id = currentAccountId, storage.restoreCheckPending(id) else { return }
        restoreCheckAccountId = id
        restoreCheckInProgress = true
        restoreCheckCancellable = legacy.$snapshot
            .compactMap { $0 }
            .filter { $0.syncedSinceConnect }
            .first()
            .sink { [weak self, weak legacy] snapshot in
                guard let self, let legacy else { return }
                Task { await self.concludeRestoreCheck(legacy, snapshot: snapshot, accountId: id) }
            }
    }

    private func concludeRestoreCheck(
        _ legacy: LegacyBreezWallet,
        snapshot first: SonarLegacyWalletSnapshot,
        accountId: String
    ) async {
        guard wallet === legacy, currentAccountId == accountId else { return }
        var confirm: SonarLegacyWalletSnapshot?
        if SonarLegacyRestoreCheck.holdsAnything(first) == false {
            // Empty so far: look again later before deleting anything.
            try? await Task.sleep(nanoseconds: restoreConfirmDelayNanos)
            guard wallet === legacy, currentAccountId == accountId else { return }
            await legacy.refreshSnapshot()
            confirm = legacy.snapshot
        }
        switch SonarLegacyRestoreCheck.verdict(first: first, confirm: confirm) {
        case .keep:
            storage.completeRestoreCheck(accountId)
        case .discard:
            do {
                try await legacy.deleteIfSafe(unregisterWebhook: unregisterWebhook)
                wallet = nil
            } catch {
                // Not provably empty after all: keep it as legacy.
                SecureLogger.warning("Legacy restore check: kept wallet (\(error))", category: .session)
            }
            storage.completeRestoreCheck(accountId)
        case .undecided:
            // Could not tell: keep the store and leave the check pending, so
            // a later launch decides. Never delete on doubt.
            SecureLogger.warning("Legacy restore check: undecided, kept the wallet for now", category: .session)
        }
        restoreCheckCancellable = nil
        restoreCheckAccountId = nil
        restoreCheckInProgress = false
    }

    /// User-initiated delete (gated).
    func deleteLegacy(unregisterWebhook: (WalletBridgeService) async -> Void) async throws {
        guard let legacy = wallet else { return }
        try await legacy.deleteIfSafe(unregisterWebhook: unregisterWebhook)
        wallet = nil
    }

    /// Account replacement. Must run BEFORE the new key is committed.
    func prepareForIdentityReplacement() async throws {
        restoreCheckCancellable = nil
        restoreCheckInProgress = false
        guard let oldNsec = nsecProvider() else {
            // No current account: nothing on this device belongs to one.
            if let legacy = wallet { try await legacy.releaseForReplacement(oldAccountId: "unknown") }
            wallet = nil
            return
        }
        let oldAccountId = SonarCashuStorage.accountId(nsec: oldNsec)
        if let legacy = wallet {
            try await legacy.releaseForReplacement(oldAccountId: oldAccountId)
            wallet = nil
            return
        }
        // Not open (no key in this build, or never attached): archive by
        // presence, without inspecting — unknown is never "safe to delete".
        switch presence() {
        case .present:
            try storage.archiveLegacyWallet(accountId: oldAccountId)
        case .absent:
            return
        case .unknown:
            throw SonarLegacyWalletStorageError.marker
        }
    }

    /// Panic wipe: everything legacy, open or not.
    func wipeForEmergency() async -> Bool {
        restoreCheckCancellable = nil
        restoreCheckInProgress = false
        if let legacy = wallet {
            let ok = await legacy.wipeForEmergency()
            wallet = nil
            return ok
        }
        do {
            try storage.wipeEverything()
            return true
        } catch {
            SecureLogger.error("Legacy wallet emergency wipe failed: \(error)", category: .session)
            return false
        }
    }
}

#endif
