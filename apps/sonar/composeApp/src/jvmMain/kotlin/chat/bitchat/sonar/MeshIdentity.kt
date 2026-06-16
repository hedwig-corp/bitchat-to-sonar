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

    /** Noise static keypair (X25519), persisted or generated + saved once. */
    private val keypair: NoiseKeypairHex by lazy {
        val priv = DesktopEnv.getString("mesh.noise.priv")
        val pub = DesktopEnv.getString("mesh.noise.pub")
        if (priv != null && pub != null) {
            NoiseKeypairHex(priv, pub)
        } else {
            noiseGenerateKeypair().also {
                DesktopEnv.putString("mesh.noise.priv", it.privateHex)
                DesktopEnv.putString("mesh.noise.pub", it.publicHex)
            }
        }
    }

    /** Ed25519 announce-signing seed (32 bytes hex), persisted or made once. */
    private val seedHex: String by lazy {
        DesktopEnv.getString("mesh.ed25519.seed")
            ?: hex(ByteArray(32).also { SecureRandom().nextBytes(it) })
                .also { DesktopEnv.putString("mesh.ed25519.seed", it) }
    }

    /** bitchat peerID = SHA256(noise static pubkey)[:8], hex. */
    val peerIdHex: String by lazy { hex(Sha256.hash(unhex(keypair.publicHex)).copyOf(8)) }

    /** Our Noise static private key (for the responder handshake). */
    fun noisePrivHex(): String = keypair.privateHex

    /** The signed bitchat ANNOUNCE (type 0x01) for [nickname], current timestamp. */
    fun announce(nickname: String): ByteArray = meshBuildAnnounce(
        seedHex,
        peerIdHex,
        nickname.ifBlank { "sonar" },
        keypair.publicHex,
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
        meshBuildSignedPacket(seedHex, TYPE_SONAR, peerIdHex, "", DEFAULT_TTL, System.currentTimeMillis().toULong(), payload)

    /** Stable peer fingerprint = SHA256(noise static pubkey), full hex. */
    fun fingerprintOf(noisePublicKeyHex: String): String =
        runCatching { hex(Sha256.hash(unhex(noisePublicKeyHex))) }.getOrDefault("")
}
