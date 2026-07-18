package chat.bitchat.sonar

/**
 * Plan for adopting our own kind-0 (NIP-01) profile into local account state
 * after nsec restore / lost prefs.
 *
 * Local nickname and handle sidecars are device-bound and wiped on restore;
 * the durable copy lives on relays as kind-0. Hosts must fetch that event
 * before republishing, or an empty/stale local nick will clobber the remote
 * profile (including `nip05`).
 *
 * `publish_profile` only attaches `nip05` from the core sidecar, so a remote
 * handle that cannot be re-seeded there must never trigger a republish.
 */
data class OwnProfileHydrationPlan(
    /**
     * Non-null when local nickname must be replaced by the remote kind-0 name.
     * Remote is authoritative whenever present — never keep a divergent local.
     */
    val nicknameToAdopt: String?,
    /**
     * Non-null when prefs must mirror the remote `nip05`. Remote is
     * authoritative whenever present — never keep a divergent local pref.
     */
    val nip05ToAdopt: String?,
    /**
     * Local part to re-claim at the Sonar registrar so the core sidecar is seeded
     * and later kind-0 publishes keep `nip05`. Null when already claimed, or when
     * remote `nip05` is not on [handleDomain].
     */
    val handleLocalToClaim: String?,
    /**
     * False when publishing would send a blank name, or would omit/replace a
     * remote `nip05` the sidecar cannot preserve.
     */
    val shouldPublishNickname: Boolean,
)

fun planOwnProfileHydration(
    localNickname: String,
    localBip353: String,
    localClaimedHandle: String?,
    remote: SonarProfile?,
    handleDomain: String,
): OwnProfileHydrationPlan {
    val domain = handleDomain.trim().lowercase()
    val remoteName = remote?.bestName?.takeIf { it.isNotBlank() }
    val remoteNip05 = remote?.nip05
        ?.trim()
        ?.takeIf { it.isNotBlank() && '@' in it }
    val nick = localNickname.trim()
    val localBip = localBip353.trim()
    // Durable kind-0 on relays wins. If a name is already set remotely, use it
    // and never keep/publish a divergent local nick over it.
    val adoptNick = remoteName?.takeIf { !it.equals(nick, ignoreCase = true) }
    val claimed = localClaimedHandle?.trim()?.takeIf { it.isNotBlank() }
    // Same for nip05: remote address is already taken on the replaceable event.
    val adoptNip05 = remoteNip05?.takeIf { !it.equals(localBip, ignoreCase = true) }
    val isSonarNip05 = remoteNip05 != null &&
        remoteNip05.substringAfter('@').equals(domain, ignoreCase = true)
    val handleLocal = when {
        claimed != null -> null
        remoteNip05 == null -> null
        !isSonarNip05 -> null
        else -> remoteNip05.substringBefore('@').trim().takeIf { it.isNotBlank() }
    }
    // After adoption, the effective publish name is always the remote one when
    // present — never the stale local nick that would clobber kind-0.
    val effectiveNick = (remoteName ?: adoptNick ?: nick).trim()
    // Sidecar-backed publish can preserve nip05 only when absent, already
    // claimed to the same address, or reclaimable at the Sonar registrar.
    // Callers must still wait for claim success (`handleSeeded`) before emit.
    val nip05SafeToPublish = when {
        remoteNip05 == null -> true
        claimed != null && claimed.equals(remoteNip05, ignoreCase = true) -> true
        isSonarNip05 && claimed == null && handleLocal != null -> true
        else -> false
    }
    return OwnProfileHydrationPlan(
        nicknameToAdopt = adoptNick,
        nip05ToAdopt = adoptNip05,
        handleLocalToClaim = handleLocal,
        shouldPublishNickname = effectiveNick.isNotBlank() && nip05SafeToPublish,
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

/**
 * Whether connect-path hydration must hit relays for our own kind-0.
 *
 * Fetch when:
 * - local nick is blank (restore / cleared prefs), or
 * - no core sidecar and no handle pref (unknown whether relays hold `nip05`), or
 * - a Sonar-domain handle pref exists without a sidecar (needs reclaim).
 *
 * Skip when the sidecar is already seeded, or the pref is an external domain
 * we cannot reclaim into the sidecar (publish is already gated off).
 */
fun needsOwnProfileRelayFetch(
    localNickname: String,
    localBip353: String,
    localClaimedHandle: String?,
    handleDomain: String,
): Boolean {
    if (localNickname.trim().isEmpty()) return true
    if (!localClaimedHandle.isNullOrBlank()) return false
    val bip = localBip353.trim()
    // No local handle record and no sidecar: relays may still hold a nip05.
    // Publishing without fetching would omit it and wipe the replaceable event.
    if (bip.isEmpty()) return true
    val domain = handleDomain.trim().lowercase()
    return bip.substringAfter('@', "").equals(domain, ignoreCase = true)
}
