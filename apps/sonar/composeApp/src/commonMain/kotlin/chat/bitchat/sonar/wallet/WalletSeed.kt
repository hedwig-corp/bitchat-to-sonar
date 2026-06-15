package chat.bitchat.sonar.wallet

import chat.bitchat.sonar.crypto.Hkdf

/**
 * Deterministic Lightning-wallet seed derived from the Nostr identity secret,
 * so wiping/reinstalling reconstructs the same wallet. Mirrors the iOS
 * `SonarWalletDerivation` HKDF parameters (salt "sonar-wallet", info
 * "sonar-bolt12-v1").
 *
 * DEVIATION from iOS (documented): iOS converts the 32-byte HKDF entropy to a
 * BIP-39 mnemonic and connects Breez with that mnemonic; Android connects Breez
 * with a raw 64-byte seed derived from the same identity. Both are deterministic
 * per-identity, but the two platforms do NOT currently produce the *same* wallet
 * for the same identity (would require bundling the BIP-39 wordlist on Android).
 * Tracked for the parity push; not required for "deterministic reconstruction".
 */
object WalletSeed {
    private val SALT = "sonar-wallet".encodeToByteArray()
    private val INFO = "sonar-bolt12-v1".encodeToByteArray()

    /** 32-byte entropy, identical to iOS `SonarWalletDerivation.entropy`. */
    fun entropy(secret: ByteArray): ByteArray = Hkdf.derive(secret, SALT, INFO, 32)

    /** 64-char lowercase hex of the 32-byte entropy (iOS `entropyHex`). */
    fun entropyHex(secret: ByteArray): String = entropy(secret).toHex()

    /** 64-byte raw wallet seed for Breez `ConnectRequest.seed`. */
    fun seed64(secret: ByteArray): ByteArray = Hkdf.derive(secret, SALT, INFO, 64)

    fun hexToBytes(hex: String): ByteArray {
        val clean = hex.trim().removePrefix("0x")
        require(clean.length % 2 == 0) { "odd-length hex" }
        return ByteArray(clean.length / 2) {
            ((clean[2 * it].digit() shl 4) or clean[2 * it + 1].digit()).toByte()
        }
    }

    private fun Char.digit(): Int {
        val d = digitToIntOrNull(16) ?: error("bad hex char '$this'")
        return d
    }

    private fun ByteArray.toHex(): String =
        joinToString("") { ((it.toInt() and 0xFF) + 0x100).toString(16).substring(1) }
}
