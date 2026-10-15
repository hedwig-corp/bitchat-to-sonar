package chat.bitchat.sonar

/**
 * Multi-account switcher model shared by the Android and desktop `SonarCore`
 * actuals, `SonarAppState` and the Settings UI. The core owns the registry
 * (`<data dir>/accounts.json`, `sonar_core::accounts`); these are the host's
 * view of it plus the two rules the host adds: per-account secret naming and
 * row ordering. Mirror of iOS `SonarAccountRegistry` / `SonarAccount`.
 */
data class SonarAccount(
    /** 64-char lowercase hex x-only public key. Row identity. */
    val pubkeyHex: String,
    val npub: String,
    val label: String?,
    /** Absolute `marmot.sqlite` path; every core sidecar hangs off it. */
    val dbPath: String,
    /** `""` for the legacy account (unsuffixed secret names), else the hex. */
    val secretTag: String,
    val isLegacy: Boolean,
    val isActive: Boolean,
    val lastActiveAt: Long,
) {
    /** `npub1abcd…wxyz` for rows without a label. */
    val shortNpub: String
        get() = if (npub.length <= 16) npub else npub.take(9) + "…" + npub.takeLast(4)

    val nsecSecretKey: String get() = accountSecretKeyName(NSEC_SECRET_BASE, secretTag)
    val dbKeySecretKey: String get() = accountSecretKeyName(DB_KEY_SECRET_BASE, secretTag)
}

/** Registry snapshot. [fault] is set when `accounts.json` exists but could not
 *  be read: the host then runs the legacy single-account path for this launch
 *  and never mints a key or store because of it. */
data class SonarAccountRegistrySnapshot(
    val accounts: List<SonarAccount>,
    val active: SonarAccount?,
    val maxAccounts: Int,
    val fault: String? = null,
) {
    val isEmpty: Boolean get() = accounts.isEmpty()
    val canAdd: Boolean get() = fault == null && accounts.size < maxAccounts

    /** Active first, then most recently active — the switcher's row order. */
    val ordered: List<SonarAccount>
        get() = accounts.sortedWith(compareByDescending<SonarAccount> { it.isActive }.thenByDescending { it.lastActiveAt })

    companion object {
        val EMPTY = SonarAccountRegistrySnapshot(emptyList(), null, DEFAULT_MAX_ACCOUNTS)
    }
}

/** Compose secret names; iOS uses `marmot-nsec` / `marmot-db-key`. */
const val NSEC_SECRET_BASE = "nsec"
const val DB_KEY_SECRET_BASE = "dbKeyHex"

/** Mirrors `sonar_core::accounts::MAX_ACCOUNTS`; the FFI value wins at runtime. */
const val DEFAULT_MAX_ACCOUNTS = 5

/**
 * Host secret name for [base] under [secretTag]: `base` for the legacy tag,
 * `base.<tag>` otherwise. Same rule as `sonar_core::accounts::secret_key_name`
 * and iOS `SonarAccountRegistry`, spelled here so the pure-JVM tests can pin it
 * without the native library.
 */
fun accountSecretKeyName(base: String, secretTag: String): String =
    if (secretTag.isEmpty()) base else "$base.$secretTag"

/** Row title: label, else the active profile name for the active row, else
 *  the shortened npub. */
fun accountDisplayName(account: SonarAccount, activeNick: String): String {
    account.label?.takeIf { it.isNotBlank() }?.let { return it }
    if (account.isActive && activeNick.isNotBlank()) return activeNick
    return account.shortNpub
}

/** The account to switch to when [removedPubkeyHex] is the active one: the
 *  most recently active other account, or null when it is the only one. */
fun nextActiveAfterRemoving(accounts: List<SonarAccount>, removedPubkeyHex: String): SonarAccount? =
    accounts.filter { it.pubkeyHex != removedPubkeyHex }.maxByOrNull { it.lastActiveAt }
