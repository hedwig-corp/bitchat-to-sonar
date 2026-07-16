package chat.bitchat.sonar

/**
 * Crash-durable, process-wide account-removal journal.
 *
 * The marker is committed before any destructive barrier or UI transition. Every
 * cold-start identity/radio/core entry point must remain closed while it exists;
 * it is removed only after all account stores have proved their wipe barriers.
 */
internal expect object PanicWipeIntent {
    fun begin(): Boolean
    fun isPending(): Boolean
    fun clear(): Boolean
}

/**
 * Commit the crash-durable wipe intent before exposing any redacted UI or
 * tearing down live account state. A cold-start recovery already has a durable
 * marker, so it may redact immediately without trying to create a second one.
 */
internal fun beginPanicWipeBeforeRedaction(
    alreadyPending: Boolean,
    commitIntent: () -> Boolean,
    redact: () -> Unit,
): Boolean {
    if (!alreadyPending && !commitIntent()) return false
    redact()
    return true
}

/** Never evaluate an old-account loader while panic-wipe recovery is pending. */
internal inline fun <T> loadInitialAccountState(
    panicWipePending: Boolean,
    redacted: T,
    load: () -> T,
): T = if (panicWipePending) redacted else load()

/**
 * Order cold-start work around the durable panic marker. Recovery owns the
 * process until the marker has been cleared; neither onboarding/account boot
 * nor platform radio startup may run in parallel with it.
 */
internal inline fun runAccountColdStart(
    panicWipePending: Boolean,
    onboarded: Boolean,
    recoverPendingWipe: () -> Unit,
    activateAccount: () -> Unit,
) {
    when {
        panicWipePending -> recoverPendingWipe()
        onboarded -> activateAccount()
    }
}

/** Defense in depth for platform entry points that can outlive a composition. */
internal fun canStartAccountServices(
    panicWipePending: Boolean,
    onboarded: Boolean,
    accountStarted: Boolean,
): Boolean = !panicWipePending && onboarded && accountStarted

/**
 * Resolve the first-frame onboarding gate without reading or migrating an
 * identity when a crash-durable wipe is pending.
 */
internal fun recoverInitialOnboardingState(
    panicWipePending: Boolean,
    readStored: () -> Boolean,
    hasIdentity: () -> Boolean,
    persistRecovered: () -> Unit,
): Boolean {
    if (panicWipePending) return false
    if (readStored()) return true
    if (!hasIdentity()) return false
    persistRecovered()
    return true
}
