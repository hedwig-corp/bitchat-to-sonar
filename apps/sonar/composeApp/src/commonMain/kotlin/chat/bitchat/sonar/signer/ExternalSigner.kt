package chat.bitchat.sonar.signer

/** Successful external-signer login: the account and which signer app owns it. */
data class ExternalSignerLogin(
    /** 64-char lowercase hex account public key. */
    val pubkeyHex: String,
    /** Signer application package (e.g. `com.greenart7c3.nostrsigner`). */
    val packageName: String?,
)

/** Thrown when the signer login is rejected, times out, or fails. */
class ExternalSignerException(message: String) : Exception(message)

/**
 * Platform gate for NIP-55 external signer apps (Amber). Android implements
 * the intent/ContentResolver bridge; desktop has no NIP-55 surface and
 * reports unavailable (NIP-46 remote signing is a separate follow-up).
 */
expect object ExternalSigner {
    /** True when a NIP-55 signer app is installed on this device. */
    fun isAvailable(): Boolean

    /**
     * Run the signer's `get_public_key` login (one approval screen, batched
     * permission grants). Throws [ExternalSignerException] on rejection,
     * timeout, or malformed responses.
     */
    suspend fun login(): ExternalSignerLogin
}
