import Foundation

/// Plan for adopting our own kind-0 (NIP-01) profile into local account state
/// after nsec restore / lost prefs. Mirrors Compose `OwnProfileHydration.kt`.
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
        remoteNip05: String?
    ) -> OwnProfileHydrationPlan {
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
        let handleLocal: String?
        if claimedValid == nil, let remoteNip05Valid {
            let local = String(remoteNip05Valid.split(separator: "@").first ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            handleLocal = local.isEmpty ? nil : local
        } else {
            handleLocal = nil
        }
        let effectiveNick = (adoptNick ?? nick).trimmingCharacters(in: .whitespacesAndNewlines)
        return OwnProfileHydrationPlan(
            nicknameToAdopt: adoptNick,
            nip05ToAdopt: adoptNip05,
            handleLocalToClaim: handleLocal,
            shouldPublishNickname: !effectiveNick.isEmpty
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

    /// Missing key = first launch (mint anon). Present key including "" =
    /// respect it so restore-cleared nick does not regenerate anonXXXX.
    static func shouldMintAnonymousNickname(savedValue: String?) -> Bool {
        savedValue == nil
    }
}
