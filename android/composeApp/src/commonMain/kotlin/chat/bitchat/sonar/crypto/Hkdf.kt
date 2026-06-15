package chat.bitchat.sonar.crypto

/**
 * HMAC-SHA256 + HKDF (RFC 5869) in pure Kotlin, on top of [Sha256]. Used to
 * derive the deterministic Lightning wallet seed from the Nostr identity secret,
 * byte-for-byte matching the iOS `SonarWalletDerivation` (CryptoKit HKDF):
 *   salt = "sonar-wallet", info = "sonar-bolt12-v1", over the 32-byte Nostr secret.
 */
object Hkdf {
    private const val BLOCK = 64 // SHA-256 block size

    fun hmacSha256(key: ByteArray, message: ByteArray): ByteArray {
        val k = if (key.size > BLOCK) Sha256.hash(key) else key
        val keyBlock = ByteArray(BLOCK)
        k.copyInto(keyBlock)
        val ipad = ByteArray(BLOCK) { (keyBlock[it].toInt() xor 0x36).toByte() }
        val opad = ByteArray(BLOCK) { (keyBlock[it].toInt() xor 0x5c).toByte() }
        val inner = Sha256.hash(ipad + message)
        return Sha256.hash(opad + inner)
    }

    /** HKDF-Extract then Expand to [outputBytes]. */
    fun derive(ikm: ByteArray, salt: ByteArray, info: ByteArray, outputBytes: Int): ByteArray {
        val prk = hmacSha256(salt, ikm) // Extract
        val out = ByteArray(outputBytes) // Expand
        var t = ByteArray(0)
        var generated = 0
        var counter = 1
        while (generated < outputBytes) {
            t = hmacSha256(prk, t + info + byteArrayOf(counter.toByte()))
            val take = minOf(t.size, outputBytes - generated)
            t.copyInto(out, generated, 0, take)
            generated += take
            counter++
        }
        return out
    }
}
