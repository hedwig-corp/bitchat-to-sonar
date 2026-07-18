package chat.bitchat.sonar

/**
 * Plan for adopting our own kind-0 (NIP-01) profile into local account state
 * after nsec restore / lost prefs.
 *
 * Local nickname and handle sidecars are device-bound and wiped on restore;
 * the durable copy lives on relays as kind-0. Hosts must fetch that event
 * before republishing, or an empty/stale local nick will clobber the remote
 * profile (including `nip05`).
 */
data class OwnProfileHydrationPlan(
    /** Non-null when the local nickname should be replaced by the remote name. */
    val nicknameToAdopt: String?,
    /** Non-null when prefs should mirror the remote `nip05` address. */
    val nip05ToAdopt: String?,
    /**
     * Local part to re-claim at the registrar so the core sidecar is seeded
     * and later kind-0 publishes keep `nip05`. Null when already claimed.
     */
    val handleLocalToClaim: String?,
    /** False when publishing would send a blank name and wipe relay metadata. */
    val shouldPublishNickname: Boolean,
)

fun planOwnProfileHydration(
    localNickname: String,
    localBip353: String,
    localClaimedHandle: String?,
    remote: SonarProfile?,
): OwnProfileHydrationPlan {
    val remoteName = remote?.bestName?.takeIf { it.isNotBlank() }
    val remoteNip05 = remote?.nip05
        ?.trim()
        ?.takeIf { it.isNotBlank() && '@' in it }
    val nick = localNickname.trim()
    val adoptNick = if (nick.isEmpty()) remoteName else null
    val claimed = localClaimedHandle?.trim()?.takeIf { it.isNotBlank() }
    val adoptNip05 = when {
        remoteNip05 == null -> null
        localBip353.isNotBlank() -> null
        else -> remoteNip05
    }
    val handleLocal = when {
        claimed != null -> null
        remoteNip05 == null -> null
        else -> remoteNip05.substringBefore('@').trim().takeIf { it.isNotBlank() }
    }
    val effectiveNick = (adoptNick ?: nick).trim()
    return OwnProfileHydrationPlan(
        nicknameToAdopt = adoptNick,
        nip05ToAdopt = adoptNip05,
        handleLocalToClaim = handleLocal,
        shouldPublishNickname = effectiveNick.isNotBlank(),
    )
}

/**
 * Whether a rename / opportunistic kind-0 republish is safe.
 *
 * After nsec restore the host may mirror remote `nip05` into prefs before the
 * core sidecar is re-claimed. Publishing in that window omits `nip05` and
 * replaces the durable kind-0 on relays.
 */
fun canPublishOwnProfile(
    localBip353: String,
    coreClaimedHandle: String?,
): Boolean {
    if (localBip353.isBlank()) return true
    return !coreClaimedHandle.isNullOrBlank()
}
