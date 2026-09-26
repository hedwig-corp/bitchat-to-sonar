package chat.bitchat.sonar.wallet

import chat.bitchat.sonar.SonarCore

/**
 * Small persisted key/value seam for wallet caches (last-known balance and
 * offer per account, the restore-check flag). The production store is the
 * account's `SonarCore` blob store, which a panic wipe clears with every other
 * pref; tests hand the engine an in-memory map.
 */
interface WalletPrefs {
    fun get(key: String): String?
    fun put(key: String, value: String)
    fun remove(key: String)
}

/** [WalletPrefs] over `SonarCore.loadBlob/saveBlob` (a blank value is absent). */
object CoreWalletPrefs : WalletPrefs {
    override fun get(key: String): String? = SonarCore.loadBlob(key).ifEmpty { null }
    override fun put(key: String, value: String) = SonarCore.saveBlob(key, value)
    override fun remove(key: String) = SonarCore.saveBlob(key, "")
}

/**
 * The file operations the wallet layer needs, so common code (the Cashu wipe
 * and the legacy Breez presence/archive rules) can be written once and tested
 * against a real temp dir on the JVM. Paths use `/`; both targets are JVM.
 */
interface WalletFileOps {
    fun exists(path: String): Boolean
    /** True when [path] is a directory with at least one entry. */
    fun hasEntries(path: String): Boolean
    /** Recursive delete. True when nothing remains at [path]. */
    fun deleteTree(path: String): Boolean
    /** Same-volume rename; creates the destination's parent. True on success. */
    fun rename(from: String, to: String): Boolean
    fun readText(path: String): String?
    /** Writes [text], creating parents. True on success. */
    fun writeText(path: String, text: String): Boolean
}

/** The platform [WalletFileOps] (java.io.File on both targets). */
expect fun platformWalletFiles(): WalletFileOps

/**
 * Wallet display preferences (fiat toggle + currency). These keys predate the
 * Cashu switch and live in the app's own prefs (Android `sonar` shared prefs,
 * desktop `DesktopEnv`), NOT in any Breez-owned store, so deleting the legacy
 * wallet never resets the user's currency. Nothing is migrated.
 */
expect object WalletDisplayPrefs {
    fun showFiat(): Boolean
    fun setShowFiat(value: Boolean)
    fun currencyCode(): String?
    fun setCurrencyCode(value: String)
}
