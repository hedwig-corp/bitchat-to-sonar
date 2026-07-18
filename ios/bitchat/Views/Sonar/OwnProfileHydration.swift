import Foundation

/// Plan for adopting our own kind-0 (NIP-01) profile into local account state
/// after nsec restore / lost prefs. Mirrors Compose `OwnProfileHydration.kt`.
///
/// `publish_profile` only attaches `nip05` from the core sidecar, so a remote
/// handle that cannot be re-seeded there must never trigger a republish.
struct OwnProfileHydrationPlan: Equatable {
    let nicknameToAdopt: String?
    let nip05ToAdopt: String?
    let handleLocalToClaim: String?
    let shouldPublishNickname: Bool
}

enum OwnProfileHydration {
    static func plan(
        localNickname: String,
        localBip353: String,
        localClaimedHandle: String?,
        remoteName: String?,
        remoteNip05: String?,
        handleDomain: String
    ) -> OwnProfileHydrationPlan {
        let domain = handleDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let nick = localNickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = remoteName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nip05 = remoteNip05?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteNip05Valid = (nip05?.contains("@") == true) ? nip05 : nil
        let adoptNick = nick.isEmpty ? name.flatMap { $0.isEmpty ? nil : $0 } : nil
        let claimed = localClaimedHandle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let claimedValid = (claimed?.isEmpty == false) ? claimed : nil
        let adoptNip05: String?
        if let remoteNip05Valid, localBip353.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            adoptNip05 = remoteNip05Valid
        } else {
            adoptNip05 = nil
        }
        let isSonarNip05: Bool = {
            guard let remoteNip05Valid else { return false }
            let remoteDomain = String(remoteNip05Valid.split(separator: "@").dropFirst().first ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return !domain.isEmpty && remoteDomain == domain
        }()
        let handleLocal: String?
        if claimedValid == nil, let remoteNip05Valid, isSonarNip05 {
            let local = String(remoteNip05Valid.split(separator: "@").first ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            handleLocal = local.isEmpty ? nil : local
        } else {
            handleLocal = nil
        }
        let effectiveNick = (adoptNick ?? nick).trimmingCharacters(in: .whitespacesAndNewlines)
        // Callers must still wait for claim success before emit when reclaiming.
        let nip05SafeToPublish: Bool = {
            guard let remoteNip05Valid else { return true }
            if let claimedValid, claimedValid.caseInsensitiveCompare(remoteNip05Valid) == .orderedSame {
                return true
            }
            if isSonarNip05, claimedValid == nil, handleLocal != nil { return true }
            return false
        }()
        return OwnProfileHydrationPlan(
            nicknameToAdopt: adoptNick,
            nip05ToAdopt: adoptNip05,
            handleLocalToClaim: handleLocal,
            shouldPublishNickname: !effectiveNick.isEmpty && nip05SafeToPublish
        )
    }

    /// Whether a rename / opportunistic kind-0 republish is safe.
    /// After nsec restore the host may mirror remote `nip05` into prefs before
    /// the core sidecar is re-claimed; publishing then omits `nip05` and
    /// replaces the durable kind-0 on relays.
    static func canPublishOwnProfile(
        localBip353: String,
        coreClaimedHandle: String?
    ) -> Bool {
        let hasHandle = !localBip353.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !hasHandle { return true }
        let claimed = coreClaimedHandle?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !claimed.isEmpty
    }

    /// Whether connect-path hydration must hit relays for our own kind-0.
    /// Fetch when nick is blank, when there is no sidecar and no handle pref
    /// (unknown remote nip05), or when a Sonar-domain pref lacks a sidecar.
    /// Skip when the sidecar is seeded, or the pref is an external domain we
    /// cannot reclaim (publish is already gated off).
    static func needsRelayFetch(
        localNickname: String,
        localBip353: String,
        localClaimedHandle: String?,
        handleDomain: String
    ) -> Bool {
        let nick = localNickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if nick.isEmpty { return true }
        let claimed = localClaimedHandle?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !claimed.isEmpty { return false }
        let bip = localBip353.trimmingCharacters(in: .whitespacesAndNewlines)
        // No local handle record and no sidecar: relays may still hold a nip05.
        if bip.isEmpty { return true }
        let domain = handleDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let bipDomain = String(bip.split(separator: "@").dropFirst().first ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return !domain.isEmpty && bipDomain == domain
    }

    /// Missing key = first launch (mint anon). Present key including "" =
    /// respect it so restore-cleared nick does not regenerate anonXXXX.
    static func shouldMintAnonymousNickname(savedValue: String?) -> Bool {
        savedValue == nil
    }
}
