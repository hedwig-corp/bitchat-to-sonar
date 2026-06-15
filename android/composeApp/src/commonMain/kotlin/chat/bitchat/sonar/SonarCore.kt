package chat.bitchat.sonar

/** A White Noise (Marmot) 1:1 chat, as the UI sees it. */
data class SonarChat(
    val id: String,        // MLS group id hex
    val name: String,
    val members: List<String>,
)

/** A decrypted message in a chat. */
data class SonarMsg(
    val id: String,
    val senderNpub: String,
    val content: String,
    val mine: Boolean,
    val tsSecs: Long,
)

/** A public message in a geohash channel. */
data class SonarChannelMsg(
    val id: String,
    val author: String,
    val senderPubkey: String,
    val content: String,
    val mine: Boolean,
    val tsSecs: Long,
)

/**
 * Shared boundary to the headless Rust core (`sonar-core`). UI in `commonMain`
 * calls these; each platform provides the `actual`:
 *  - androidMain → UniFFI Kotlin/JNA over libsonar_ffi.so (blocking calls
 *    dispatched to a background thread),
 *  - iosMain (later) → Kotlin/Native call path.
 *
 * v1 surface = White Noise (Marmot) encrypted DMs over Nostr relays — the
 * cross-platform-testable slice that interops with the iOS app via the same
 * protocol + relays. BLE mesh / geohash come later (issue #6).
 */
expect object SonarCore {
    /** Ensure an identity exists, connect to relays, publish our KeyPackage.
     *  Returns our npub. Safe to call repeatedly. */
    suspend fun start(): String

    /** Our npub (empty until [start]). */
    fun myNpub(): String

    /** All 1:1 chats we belong to. */
    suspend fun chats(): List<SonarChat>

    /** Start (or fetch) a 1:1 chat with a peer (npub or hex). Returns chat id. */
    suspend fun startChat(peer: String): String

    /** Send an encrypted text message to a chat. */
    suspend fun send(chatId: String, text: String)

    /** Decrypted message history for a chat, oldest first. */
    suspend fun messages(chatId: String): List<SonarMsg>

    /** Poll the relays once (welcomes + group messages). */
    suspend fun sync()

    // ── Geohash public channels ──

    /** Geohash channels the user has joined (persisted). */
    fun joinedChannels(): List<String>
    fun joinChannel(geohash: String)
    fun leaveChannel(geohash: String)

    /** Recent public messages in a geohash channel, oldest first. */
    suspend fun channelMessages(geohash: String): List<SonarChannelMsg>

    /** Publish a public message to a geohash channel. */
    suspend fun sendChannel(geohash: String, text: String)

    /** Broadcast a presence heartbeat (kind-20001) for a geohash channel.
     *  Call on channel open and on a ~60s heartbeat while it stays open. */
    suspend fun sendChannelPresence(geohash: String)

    /** Count of participants currently "here now" in a geohash channel
     *  (distinct kind-20001 heartbeats within the presence TTL). */
    suspend fun channelPresenceCount(geohash: String): Int

    /** 1:1 encrypted DM conversation with a channel participant (NIP-17). */
    suspend fun geoDmMessages(geohash: String, peerHex: String): List<SonarMsg>
    suspend fun sendGeoDm(geohash: String, peerHex: String, text: String)

    // ── Identity / profile (persisted on-device) ──

    /** Display nickname (what people see). Empty until set. */
    fun nickname(): String
    fun setNickname(value: String)

    /** Grouped key-fingerprint string for the verify/profile surfaces. */
    fun fingerprint(): String

    /** Our Nostr secret key (`nsec1…`), empty until an identity exists. The
     *  Lightning wallet derives its deterministic seed from this. */
    fun identityNsec(): String

    /** Onboarding gate. */
    fun onboardingComplete(): Boolean
    fun setOnboardingComplete(value: Boolean)

    /** Appearance: dark (default) or light. */
    fun isDark(): Boolean
    fun setDark(value: Boolean)

    /** Generic persisted key/value blobs (⚡PAY ledger, BIP-353 address, …). */
    fun loadBlob(key: String): String
    fun saveBlob(key: String, value: String)

    /** Wipe all on-device data (identity, chats, prefs). */
    suspend fun wipe()
}
