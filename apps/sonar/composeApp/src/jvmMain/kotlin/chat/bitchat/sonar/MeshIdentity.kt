package chat.bitchat.sonar

import chat.bitchat.sonar.crypto.Sha256
import uniffi.sonar_ffi.NoiseKeypairHex
import uniffi.sonar_ffi.meshBuildAnnounce
import uniffi.sonar_ffi.meshBuildPacket
import uniffi.sonar_ffi.meshBuildSignedPacket
import uniffi.sonar_ffi.noiseGenerateKeypair
import java.security.SecureRandom

/**
 * Desktop mesh identity — the Noise static keypair + Ed25519 announce-signing
 * seed that back this device's bitchat presence, persisted in [DesktopEnv] so the
 * mesh peerID is STABLE across launches (the desktop twin of the Android
 * `MeshGatt` identity). Builds the signed ANNOUNCE packet via the SAME byte-exact
 * Rust core (`meshBuildAnnounce`) the Android/iOS apps use, so a phone that
 * receives it shows this desktop as a real named peer.
 */
object MeshIdentity {
    private const val DEFAULT_TTL: UByte = 7u
    private const val TYPE_SONAR: UByte = 0x53u

    private fun hex(b: ByteArray): String =
        b.joinToString("") { ((it.toInt() and 0xFF) + 0x100).toString(16).substring(1) }

    private fun unhex(s: String): ByteArray =
        ByteArray(s.length / 2) { ((s[it * 2].digitToInt(16) shl 4) or s[it * 2 + 1].digitToInt(16)).toByte() }

    private data class AccountIdentity(
        val generation: Long,
        val keypair: NoiseKeypairHex,
        val seedHex: String,
        val peerIdHex: String,
    )

    private const val BUNDLE_KEY = "mesh.identity.bundle.v1"
    private var generation = 0L
    private var current: AccountIdentity? = null

    /** Atomically load/provision one account generation. A panic reset clears
     * [current], so old secret objects cannot survive in a Kotlin `lazy`. */
    @Synchronized
    private fun identity(): AccountIdentity {
        current?.let { return it }
        check(!PanicWipeIntent.isPending()) { "mesh identity fenced by pending panic wipe" }
        val stored = DesktopSecrets.get(BUNDLE_KEY)?.split(':')?.takeIf { it.size == 3 }
        val keypair: NoiseKeypairHex
        val seed: String
        if (stored != null) {
            keypair = NoiseKeypairHex(stored[0], stored[1])
            seed = stored[2]
        } else {
            val legacyPriv = DesktopEnv.getString("mesh.noise.priv")
            val legacyPub = DesktopEnv.getString("mesh.noise.pub")
            keypair = if (legacyPriv != null && legacyPub != null) {
                NoiseKeypairHex(legacyPriv, legacyPub)
            } else {
                noiseGenerateKeypair()
            }
            seed = DesktopEnv.getString("mesh.ed25519.seed")
                ?: hex(ByteArray(32).also { SecureRandom().nextBytes(it) })
            check(DesktopSecrets.putDurable(BUNDLE_KEY, "${keypair.privateHex}:${keypair.publicHex}:$seed")) {
                "failed to durably provision desktop mesh identity"
            }
            check(DesktopEnv.removeDurable("mesh.noise.priv", "mesh.noise.pub", "mesh.ed25519.seed")) {
                "failed to remove legacy desktop mesh identity fragments"
            }
        }
        return AccountIdentity(
            generation = generation,
            keypair = keypair,
            seedHex = seed,
            peerIdHex = hex(Sha256.hash(unhex(keypair.publicHex)).copyOf(8)),
        ).also { current = it }
    }

    @Synchronized
    fun resetAccountState() {
        generation += 1
        current = null
    }

    /** bitchat peerID = SHA256(noise static pubkey)[:8], hex. */
    val peerIdHex: String get() = identity().peerIdHex

    /** Our Noise static private key (for the responder handshake). */
    fun noisePrivHex(): String = identity().keypair.privateHex

    /** The signed bitchat ANNOUNCE (type 0x01) for [nickname], current timestamp. */
    fun announce(nickname: String): ByteArray = meshBuildAnnounce(
        identity().seedHex,
        peerIdHex,
        nickname.ifBlank { "sonar" },
        identity().keypair.publicHex,
        DEFAULT_TTL,
        System.currentTimeMillis().toULong(),
    )

    /** Build an UNSIGNED mesh packet (Noise handshake / encrypted DM) from us to
     *  [recipientIdHex], wrapping [payload]. */
    fun buildPacket(packetType: UByte, recipientIdHex: String, payload: ByteArray): ByteArray =
        meshBuildPacket(packetType, peerIdHex, recipientIdHex, DEFAULT_TTL, System.currentTimeMillis().toULong(), payload)

    /** Build our SIGNED Sonar Discovery (0x53) packet wrapping [payload] (the
     *  encoded SonarAnnounce: npub + capabilities). MUST be Ed25519-signed with
     *  the same key as the 0x01 announce, or peers reject it as unverified — which
     *  is what lets a Sonar peer continue our BLE chat over White Noise (internet)
     *  when we go out of Bluetooth range. */
    fun buildSonarPacket(payload: ByteArray): ByteArray =
        meshBuildSignedPacket(identity().seedHex, TYPE_SONAR, peerIdHex, "", DEFAULT_TTL, System.currentTimeMillis().toULong(), payload)

    /** Stable peer fingerprint = SHA256(noise static pubkey), full hex. */
    fun fingerprintOf(noisePublicKeyHex: String): String =
        runCatching { hex(Sha256.hash(unhex(noisePublicKeyHex))) }.getOrDefault("")
}
