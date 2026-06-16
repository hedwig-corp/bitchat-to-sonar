package chat.bitchat.sonar.wallet

import chat.bitchat.sonar.crypto.Hkdf

/**
 * Deterministic Lightning-wallet seed derived from the Nostr identity secret,
 * so wiping/reinstalling reconstructs the same wallet. This must stay byte-for-byte
 * identical to iOS `SonarWalletDerivation`: same nsec => same Breez seed => same
 * wallet on Android and iOS.
 */
object WalletSeed {
    private val SALT = "sonar-wallet".encodeToByteArray()
    private val INFO = "sonar-bolt12-v1".encodeToByteArray()

    /** 32-byte entropy, identical to iOS `SonarWalletDerivation.entropy`. */
    fun entropy(secret: ByteArray): ByteArray = Hkdf.derive(secret, SALT, INFO, 32)

    /** 64-char lowercase hex of the 32-byte entropy (iOS `entropyHex`). */
    fun entropyHex(secret: ByteArray): String = entropy(secret).toHex()

    /** Raw Breez seed, identical to iOS wallet `seed.v1`. */
    fun breezSeed(secret: ByteArray): ByteArray = entropy(secret)

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
