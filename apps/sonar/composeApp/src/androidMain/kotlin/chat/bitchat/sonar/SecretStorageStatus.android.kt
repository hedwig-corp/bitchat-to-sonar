package chat.bitchat.sonar

/** Android `actual`: secrets are Keystore-backed via AndroidSecrets. */
actual object SecretStorageStatus {
    actual fun degradedReason(): String? = null
}
