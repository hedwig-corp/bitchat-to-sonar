package chat.bitchat.sonar

/**
 * Whether identity-controlling secrets are protected by an OS keystore.
 *
 * Exists so a platform that cannot reach one is forced to SAY so. The desktop
 * shipped storing the account nsec, the SQLCipher DB key and the mesh signing
 * keys in a plaintext prefs file whenever no Secret Service was reachable, which
 * is the default on Linux (`secret-tool` is not installed out of the box), with
 * nothing in the UI or logs to indicate it.
 *
 * The fallback itself has to stay: the Account Key Durability Rule forbids
 * failing to persist the account key, and refusing to write would destroy the
 * identity rather than protect it. Being silent about it is the part that is not
 * acceptable.
 */
expect object SecretStorageStatus {
    /**
     * Null when secrets are keystore-backed. Otherwise a short, user-facing
     * explanation of why they are not, suitable for a settings warning.
     */
    fun degradedReason(): String?
}
