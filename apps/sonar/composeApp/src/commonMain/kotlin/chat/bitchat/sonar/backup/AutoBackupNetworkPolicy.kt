package chat.bitchat.sonar.backup

/**
 * Whether an AUTOMATIC account backup may spend the current link.
 *
 * Mirror of iOS `MarmotAccountBackupFlow.autoBackupAllowedOnCurrentPath` — the
 * Cross-Platform Feature Rule applies to the fix as much as to the feature: a
 * gate that lands on one platform only leaves the other one uploading.
 *
 * Background: an account backup is a FULL-ACCOUNT snapshot (the whole SQLCipher
 * DB plus its conversation index, sealed and PUT to Blossom), the executors fire
 * on every backgrounding, and nothing used to distinguish Wi-Fi from cellular. A
 * roaming user reported 66.3 GB of Sonar mobile data in a single billing period.
 */
/**
 * What one backup attempt actually did.
 *
 * [AlreadyUpToDate] exists because "we uploaded nothing" and "we failed" are
 * different things and a boolean conflated them: a manual tap on an account
 * that has not changed since its last upload was reporting
 * "Backup failed — try again when online" for a perfectly backed-up account.
 * That is the same false-alarm class this whole change set exists to remove.
 */
enum class AccountBackupOutcome {
    Uploaded,
    AlreadyUpToDate,
    Failed,
}

object AutoBackupNetworkPolicy {
    /** Blob key for the user's "back up over cellular" choice. Off by default. */
    const val CELLULAR_OPT_IN_PREF = "pref.auto_backup_cellular"

    /**
     * Manual "Back up now" deliberately does not consult this: the user asked
     * for it and can see the outcome.
     *
     * This must never become "no backups at all" — the Backup screen shows the
     * age of the last successful upload beside the toggle, so a user who lives
     * on cellular can see the staleness and opt in. Silently skipping forever
     * would be an Account Key Durability problem, not a data saving.
     */
    fun allowsUpload(metered: Boolean, cellularOptIn: Boolean): Boolean =
        !metered || cellularOptIn

    /**
     * Stable Display text of `sonar_core::Error::AccountBackupUnchanged`.
     *
     * Errors cross UniFFI as rendered strings (`SonarFfiError` is a
     * `flat_error`), so matching the message is the contract — the same one
     * `AccountBackupMissing` already relies on. Matched on the distinctive stem
     * so a reworded tail cannot silently turn a no-op back into a failure.
     */
    private const val UNCHANGED_ACCOUNT_MARKER = "account backup unchanged"

    /**
     * True when core refused to re-seal because the account's plaintext
     * fingerprint still matches the one recorded for the last **successful**
     * upload, inside the refresh window.
     *
     * Stated precisely on purpose: this is a local check against
     * `last_plain_hash`/`last_success_at`, not a confirmation that the blob is
     * still present on Blossom. If the host GC'd it, the refresh window (the
     * user's cadence, capped at a week) is what re-establishes it.
     *
     * A **no-op, not a failure**: callers must not write it to `last_error` and
     * must not surface it as a failed backup.
     */
    fun isUnchangedAccount(error: Throwable): Boolean =
        (error.message ?: error.toString()).contains(
            UNCHANGED_ACCOUNT_MARKER,
            ignoreCase = true,
        )
}
