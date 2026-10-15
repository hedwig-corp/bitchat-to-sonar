//
// SonarAccountRegistry.swift
// bitchat
//
// Host facade over the core-owned account registry (`sonar_core::accounts`):
// several Marmot accounts per install, exactly one active. The core owns
// `<data dir>/accounts.json` and the `accounts/<pubkey>/` layout; this file
// owns the keychain naming and the "no registry yet" fast path.
//
// Secrets never move: the legacy account keeps the unsuffixed `marmot-nsec`
// / `marmot-db-key` items it always had (`secretTag == ""`), later accounts
// get `marmot-nsec.<hex>` / `marmot-db-key.<hex>`. See
// docs/plans/2026-10-15-multi-account-switcher.md.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Foundation
import SonarCore

/// One registered account, as the switcher and the store resolvers see it.
struct SonarAccount: Equatable, Identifiable, Sendable {
    let pubkeyHex: String
    let npub: String
    let label: String?
    /// Absolute `marmot.sqlite` path; every core sidecar hangs off it.
    let dbPath: String
    /// `""` for the legacy account (unsuffixed keychain names), else the hex.
    let secretTag: String
    let isLegacy: Bool
    let isActive: Bool
    let lastActiveAt: UInt64

    var id: String { pubkeyHex }

    var nsecKeychainKey: String { SonarAccountRegistry.nsecKeychainKey(tag: secretTag) }
    var dbKeychainKey: String { SonarAccountRegistry.dbKeychainKey(tag: secretTag) }

    /// Short display form for rows: `npub1abcd…wxyz`.
    var shortNpub: String {
        guard npub.count > 16 else { return npub }
        return "\(npub.prefix(9))…\(npub.suffix(4))"
    }

    init(_ info: AccountInfo) {
        pubkeyHex = info.pubkeyHex
        npub = info.npub
        label = info.label
        dbPath = info.dbPath
        secretTag = info.secretTag
        isLegacy = info.isLegacy
        isActive = info.isActive
        lastActiveAt = info.lastActiveAt
    }

    /// The pre-registry single account: the legacy store at `<data dir>/
    /// marmot.sqlite` with the unsuffixed keychain names. Used until the host
    /// has a confirmed identity to register it under.
    init(legacyAt dbPath: String) {
        pubkeyHex = ""
        npub = ""
        label = nil
        self.dbPath = dbPath
        secretTag = ""
        isLegacy = true
        isActive = true
        lastActiveAt = 0
    }
}

enum SonarAccountRegistry {
    static let nsecKeyBase = "marmot-nsec"
    static let dbKeyBase = "marmot-db-key"

    struct Snapshot: Equatable, Sendable {
        let accounts: [SonarAccount]
        let active: SonarAccount?
        let maxAccounts: Int
        /// Set when `accounts.json` exists but could not be read. The host
        /// then runs the legacy single-account path for this launch and
        /// surfaces the fault; it never mints a key or a store because of it.
        let fault: String?

        var isEmpty: Bool { accounts.isEmpty }
        var canAdd: Bool { fault == nil && accounts.count < maxAccounts }
    }

    enum RegistryError: LocalizedError {
        case limitReached(Int)
        case notRegistered
        case lastAccount
        case faulted(String)

        var errorDescription: String? {
            switch self {
            case .limitReached(let max):
                return String(localized: "You can keep up to \(String(max)) accounts on this phone.")
            case .notRegistered:
                return String(localized: "That account is not on this phone.")
            case .lastAccount:
                return String(localized: "This is your only account. Use Emergency wipe to remove it.")
            case .faulted(let why):
                return String(localized: "Account list unreadable: \(why)")
            }
        }
    }

    private static let lock = NSLock()
    private static var cached: Snapshot?

    // MARK: Naming

    static func nsecKeychainKey(tag: String) -> String {
        accountSecretKeyName(base: nsecKeyBase, secretTag: tag)
    }

    static func dbKeychainKey(tag: String) -> String {
        accountSecretKeyName(base: dbKeyBase, secretTag: tag)
    }

    /// Keychain name of the ACTIVE account's nsec. Falls back to the legacy
    /// name when there is no registry (single-account installs and
    /// onboarding) or the registry is faulted.
    static func activeNsecKeychainKey() -> String {
        nsecKeychainKey(tag: activeSecretTag())
    }

    static func activeDbKeychainKey() -> String {
        dbKeychainKey(tag: activeSecretTag())
    }

    private static func activeSecretTag() -> String {
        (try? resolveActive())?.secretTag ?? ""
    }

    // MARK: Data dir

    /// The store root: iOS App Group `sonar-marmot`, macOS Application
    /// Support. The legacy store is `<data dir>/marmot.sqlite`.
    static func dataDirectory() throws -> URL {
        try MarmotAppGroupStore.databaseDirectory()
    }

    static func legacyDatabasePath() throws -> String {
        try dataDirectory().appendingPathComponent(MarmotAppGroupStore.dbFileName).path
    }

    // MARK: Reads

    /// Current registry. Cached in-process; every writer below invalidates.
    static func snapshot() -> Snapshot {
        lock.lock()
        if let cached {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let fresh = loadFromDisk()
        lock.lock()
        cached = fresh
        lock.unlock()
        return fresh
    }

    static func invalidate() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    private static func loadFromDisk() -> Snapshot {
        let dir: String
        do {
            dir = try dataDirectory().path
        } catch {
            return Snapshot(accounts: [], active: nil, maxAccounts: Int(accountRegistryMaxAccounts()), fault: error.localizedDescription)
        }
        do {
            let info = try accountRegistryLoad(dataDir: dir)
            let accounts = info.accounts.map(SonarAccount.init)
            let active = accounts.first { $0.pubkeyHex == info.activePubkeyHex }
            return Snapshot(accounts: accounts, active: active, maxAccounts: Int(info.maxAccounts), fault: nil)
        } catch {
            SecureLogger.error(
                "Account registry unreadable — running the legacy single-account path: \(error.localizedDescription)",
                category: .session
            )
            return Snapshot(accounts: [], active: nil, maxAccounts: Int(accountRegistryMaxAccounts()), fault: error.localizedDescription)
        }
    }

    /// The account to open. With a registry this is its active entry; with
    /// none (or a faulted one) it is the legacy single account, exactly what
    /// every build before the registry opened.
    static func resolveActive() throws -> SonarAccount {
        let snap = snapshot()
        if let active = snap.active { return active }
        return SonarAccount(legacyAt: try legacyDatabasePath())
    }

    /// Accounts other than the active one, most recently active first.
    static func inactiveAccounts() -> [SonarAccount] {
        snapshot().accounts
            .filter { !$0.isActive }
            .sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    // MARK: Writes (main app only; the NSE never writes)

    /// Register the legacy store in place once the host knows whose it is.
    /// Idempotent and cheap after the first call; a no-op when the registry
    /// already has entries or is faulted.
    static func registerLegacyIfNeeded(pubkey: String) {
        let snap = snapshot()
        guard snap.fault == nil, snap.isEmpty else { return }
        do {
            _ = try accountRegistryRegisterLegacy(dataDir: try dataDirectory().path, pubkey: pubkey)
            invalidate()
            SecureLogger.info("Account registry: registered the legacy store in place", category: .session)
        } catch {
            SecureLogger.warning(
                "Account registry: legacy registration failed — staying single-account: \(error.localizedDescription)",
                category: .session
            )
        }
    }

    /// Add `pubkey` under its own directory. An already registered key is
    /// returned unchanged (callers treat that as a switch, never a replace).
    @discardableResult
    static func add(pubkey: String, label: String?) throws -> SonarAccount {
        let snap = snapshot()
        if let fault = snap.fault { throw RegistryError.faulted(fault) }
        let alreadyRegistered = snap.accounts.contains { $0.pubkeyHex == pubkey || $0.npub == pubkey }
        if !alreadyRegistered && !snap.canAdd {
            throw RegistryError.limitReached(snap.maxAccounts)
        }
        defer { invalidate() }
        return SonarAccount(try accountRegistryAdd(dataDir: try dataDirectory().path, pubkey: pubkey, label: label))
    }

    @discardableResult
    static func setActive(pubkey: String) throws -> SonarAccount {
        defer { invalidate() }
        return SonarAccount(try accountRegistrySetActive(dataDir: try dataDirectory().path, pubkey: pubkey))
    }

    @discardableResult
    static func setLabel(pubkey: String, label: String?) throws -> SonarAccount {
        defer { invalidate() }
        return SonarAccount(try accountRegistrySetLabel(dataDir: try dataDirectory().path, pubkey: pubkey, label: label))
    }

    /// An nsec restore replaced the key behind `old` in place: point the
    /// registry row at `new`. No-op before the registry exists.
    static func replacePubkey(old: String, new: String) {
        guard !old.isEmpty, old != new else { return }
        defer { invalidate() }
        do {
            _ = try accountRegistryReplacePubkey(dataDir: try dataDirectory().path, oldPubkey: old, newPubkey: new)
        } catch {
            SecureLogger.warning(
                "Account registry: could not repoint the restored row: \(error.localizedDescription)",
                category: .session
            )
        }
    }

    /// The key that just opened the active store is `openedNpub`. When the
    /// registry's active row names another key, a restore replaced the slot
    /// and died before repointing it; repoint now so switch, add and the
    /// NSE address the right account. No-op before the registry exists.
    static func healActiveRowIfNeeded(openedNpub: String) {
        let snap = snapshot()
        guard snap.fault == nil, let active = snap.active, !active.npub.isEmpty,
              active.npub != openedNpub else { return }
        SecureLogger.warning(
            "Account registry: active row \(active.npub.prefix(12))… does not match the opened key — repointing",
            category: .session
        )
        replacePubkey(old: active.pubkeyHex, new: openedNpub)
    }

    /// A row added moments ago whose key could not be stored and whose store
    /// was never opened. Dropping it is the opposite of a wipe: nothing it
    /// named ever existed.
    static func discardUnopenedRow(pubkey: String, keychain: KeychainManagerProtocol) {
        defer { invalidate() }
        do {
            _ = try accountRegistryRemove(dataDir: try dataDirectory().path, pubkey: pubkey)
        } catch {
            SecureLogger.warning(
                "Account registry: could not drop the unopened row: \(error.localizedDescription)",
                category: .session
            )
        }
    }

    /// Remove `pubkey`: the core wipes its store and `accounts/<hex>/`, this
    /// clears its keychain items. Call with no live node on that store and
    /// never on the active account. The account's Cashu wallet directory is
    /// kept on disk — it may hold funds.
    static func remove(pubkey: String, keychain: KeychainManagerProtocol) throws -> (removed: SonarAccount, newActive: SonarAccount) {
        let snap = snapshot()
        if snap.accounts.count <= 1 { throw RegistryError.lastAccount }
        guard snap.accounts.contains(where: { $0.pubkeyHex == pubkey }) else { throw RegistryError.notRegistered }
        defer { invalidate() }
        let out = try accountRegistryRemove(dataDir: try dataDirectory().path, pubkey: pubkey)
        let removed = SonarAccount(out.removed)
        // Explicit user action on a store the core has just wiped: the keys
        // guard nothing any more. (Durability invariant 5 applies to wipe;
        // this is the same boundary scoped to one account.)
        _ = keychain.deleteIdentityKey(forKey: removed.nsecKeychainKey)
        _ = keychain.deleteIdentityKey(forKey: removed.dbKeychainKey)
        return (removed, SonarAccount(out.newActive))
    }

    /// Every keychain name a panic wipe must clear: the legacy pair plus one
    /// pair per registered tag.
    static func allKeychainKeysForWipe() -> [String] {
        var tags = Set([""])
        for a in snapshot().accounts { tags.insert(a.secretTag) }
        return tags.flatMap { [nsecKeychainKey(tag: $0), dbKeychainKey(tag: $0)] }
    }
}
