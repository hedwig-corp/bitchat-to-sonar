package chat.bitchat.sonar

/**
 * Desktop `actual`: reports when [DesktopSecrets] has had to keep secrets in
 * local prefs because no OS keystore was reachable.
 */
actual object SecretStorageStatus {
    actual fun degradedReason(): String? {
        if (!DesktopSecrets.plaintextFallbackInUse()) return null
        val why = DesktopSecrets.keystoreUnavailableReason()
        if (why != null) {
            return "Your account key is stored on this computer without OS protection, because $why."
        }
        // Reachable: a keystore is present, yet secrets are still on disk (a
        // failed prefs removal after a successful keystore write, or keys whose
        // lazy migration has not run this session). Returning null here would
        // hide a plaintext account key behind a healthy-looking probe, which is
        // the exact failure this whole surface exists to prevent.
        if (DesktopEnv.permissionsUnenforceable) {
            return "This computer's filesystem cannot restrict file permissions, so " +
                "secrets stored here may be readable by other users of this machine."
        }
        val n = DesktopSecrets.storedInPlaintext().size
        return "$n account secret${if (n == 1) " is" else "s are"} still stored on this " +
            "computer without OS protection. Restart Sonar to move ${if (n == 1) "it" else "them"} " +
            "into your system keyring."
    }
}
