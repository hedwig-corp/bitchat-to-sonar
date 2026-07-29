package chat.bitchat.sonar.signer

/**
 * Desktop has no NIP-55 surface (it is an Android intent/ContentResolver
 * protocol). NIP-46 remote signing would be the desktop equivalent — tracked
 * as a follow-up; until then desktop always uses a local key.
 */
actual object ExternalSigner {
    actual fun isAvailable(): Boolean = false

    actual suspend fun login(): ExternalSignerLogin =
        throw ExternalSignerException("External signers are not supported on desktop")
}
