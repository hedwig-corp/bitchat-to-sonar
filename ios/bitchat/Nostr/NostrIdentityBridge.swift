import BitLogger
import Foundation
import CryptoKit

/// Bridge between Noise and Nostr identities
final class NostrIdentityBridge {
    private let keychainService = "chat.bitchat.nostr"
    private let currentIdentityKey = "nostr-current-identity"
    private let deviceSeedKey = "nostr-device-seed"
    // In-memory cache to avoid transient keychain access issues
    private var deviceSeedCache: Data?
    // Cache derived identities to avoid repeated crypto during view rendering
    private var derivedIdentityCache: [String: NostrIdentity] = [:]
    private let cacheLock = NSLock()

    private let keychain: KeychainManagerProtocol

    init(keychain: KeychainManagerProtocol = KeychainManager()) {
        self.keychain = keychain
    }
    
    /// Get or create the current Nostr identity
    func getCurrentNostrIdentity() throws -> NostrIdentity? {
        // Check if we already have a Nostr identity
        if let existingData = keychain.load(key: currentIdentityKey, service: keychainService),
           let identity = try? JSONDecoder().decode(NostrIdentity.self, from: existingData) {
            return identity
        }
        
        // Generate new Nostr identity
        let nostrIdentity = try NostrIdentity.generate()
        
        // Store it
        let data = try JSONEncoder().encode(nostrIdentity)
        keychain.save(key: currentIdentityKey, data: data, service: keychainService, accessible: nil)
        
        return nostrIdentity
    }
    
    /// Associate a Nostr identity with a Noise public key (for favorites)
    func associateNostrIdentity(_ nostrPubkey: String, with noisePublicKey: Data) {
        let key = "nostr-noise-\(noisePublicKey.base64EncodedString())"
        if let data = nostrPubkey.data(using: .utf8) {
            keychain.save(key: key, data: data, service: keychainService, accessible: nil)
        }
    }
    
    /// Get Nostr public key associated with a Noise public key
    func getNostrPublicKey(for noisePublicKey: Data) -> String? {
        let key = "nostr-noise-\(noisePublicKey.base64EncodedString())"
        guard let data = keychain.load(key: key, service: keychainService),
              let pubkey = String(data: data, encoding: .utf8) else {
            return nil
        }
        return pubkey
    }
    
    /// Clear all Nostr identity associations and current identity
    func clearAllAssociations() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let items = result as? [[String: Any]] {
            for item in items {
                var deleteQuery: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: keychainService
                ]
                if let account = item[kSecAttrAccount as String] as? String {
                    deleteQuery[kSecAttrAccount as String] = account
                }
                SecItemDelete(deleteQuery as CFDictionary)
            }
        } else if status == errSecItemNotFound {
            // nothing persisted; no action needed
        }

        deviceSeedCache = nil
    }

    // MARK: - Per-Geohash Identities (Location Channels)

    /// Returns a stable device seed used to derive unlinkable per-geohash identities.
    /// Stored only on device keychain.
    /// This seed keys the HMAC that derives every per-geohash Nostr *private
    /// key*, and it is persisted on first use, so it throws rather than
    /// returning anything it is not sure about. Three ways that could go wrong,
    /// all of which permanently rotate every geohash identity:
    ///   1. an unchecked `SecRandomCopyBytes` failure minting an all-zeros seed
    ///      (same seed on every affected install), then persisting it;
    ///   2. an unreadable keychain read up as "absent", minting a replacement
    ///      that overwrites the real seed in place;
    ///   3. a failed persist leaving the seed memory-only, so the next launch
    ///      mints a different one.
    private func getOrCreateDeviceSeed() throws -> Data {
        if let cached = deviceSeedCache { return cached }

        // Classify the read. A bare `Data?` cannot tell "no seed yet" from
        // "seed exists but is not readable right now", and this function
        // responds to "absent" by minting a replacement and saving it — and
        // `save` is update-then-add, so it overwrites in place. `deriveIdentity`
        // runs off the foreground path via GeohashPresenceService, so a single
        // locked-device or access-denied read would permanently rotate every
        // per-geohash identity. Only `.itemNotFound` may create.
        switch keychain.loadWithResult(key: deviceSeedKey, service: keychainService) {
        case .success(let existing):
            // Migrate to AfterFirstUnlockThisDeviceOnly for stability during lock
            keychain.save(key: deviceSeedKey, data: existing, service: keychainService, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
            deviceSeedCache = existing
            return existing

        case .accessDenied, .deviceLocked, .authenticationFailed, .otherError:
            SecureLogger.warning(
                "⚠️ geohash device seed not readable yet (device locked?) — deferring rather than rotating identities",
                category: .keychain
            )
            throw DeviceSeedError.notReadable

        case .itemNotFound:
            break  // genuinely absent: safe to create
        }

        let seed = try SecureRandom.bytes(32)
        // Ensure availability after first unlock to prevent unintended rotation when locked
        keychain.save(key: deviceSeedKey, data: seed, service: keychainService, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        // Only cache after a readback confirms the seed actually persisted. A
        // discarded save result would leave it memory-only, and the next launch
        // would mint a different one — the same rotation by a slower route.
        guard keychain.load(key: deviceSeedKey, service: keychainService) == seed else {
            SecureLogger.error(
                NSError(domain: "NostrIdentity", code: -2),
                context: "geohash device seed failed to persist — refusing to use an ephemeral seed",
                category: .keychain
            )
            throw DeviceSeedError.notPersisted
        }
        deviceSeedCache = seed
        return seed
    }

    enum DeviceSeedError: Error, LocalizedError {
        case notReadable
        case notPersisted

        var errorDescription: String? {
            switch self {
            case .notReadable:
                return "device seed not readable yet (device locked?)"
            case .notPersisted:
                return "device seed could not be persisted"
            }
        }
    }

    /// Derive a deterministic, unlinkable Nostr identity for a given geohash.
    /// Uses HMAC-SHA256(deviceSeed, geohash) as private key material, with fallback rehashing
    /// if the candidate is not a valid secp256k1 private key.
    func deriveIdentity(forGeohash geohash: String) throws -> NostrIdentity {
        // Check cache first to avoid repeated crypto + keychain I/O during view rendering
        cacheLock.lock()
        if let cached = derivedIdentityCache[geohash] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let seed = try getOrCreateDeviceSeed()
        guard let msg = geohash.data(using: .utf8) else {
            throw NSError(domain: "NostrIdentity", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid geohash string"])
        }

        func candidateKey(iteration: UInt32) -> Data {
            var input = Data(msg)
            var iterBE = iteration.bigEndian
            withUnsafeBytes(of: &iterBE) { bytes in
                input.append(contentsOf: bytes)
            }
            let code = HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: seed))
            return Data(code)
        }

        // Try a few iterations to ensure a valid key can be formed
        for i in 0..<10 {
            let keyData = candidateKey(iteration: UInt32(i))
            if let identity = try? NostrIdentity(privateKeyData: keyData) {
                // Cache the result
                cacheLock.lock()
                derivedIdentityCache[geohash] = identity
                cacheLock.unlock()
                return identity
            }
        }
        // As a final fallback, hash the seed+msg and try again
        let fallback = (seed + msg).sha256Hash()
        let identity = try NostrIdentity(privateKeyData: fallback)

        // Cache the result
        cacheLock.lock()
        derivedIdentityCache[geohash] = identity
        cacheLock.unlock()

        return identity
    }
}
