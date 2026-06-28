package chat.bitchat.sonar

import chat.bitchat.sonar.crypto.Bech32
import kotlinx.coroutines.flow.SharedFlow

/** A White Noise (Marmot) chat, as the UI sees it. */
data class SonarChat(
    val id: String,        // MLS group id hex
    val name: String,
    val members: List<String>,
)

/** Pending multi-member group invite awaiting explicit accept/decline. */
data class SonarGroupInvite(
    val id: String,
    val groupId: String,
    val groupName: String,
    val groupDescription: String,
    val welcomerNpub: String,
    val memberCount: Int,
    val relays: List<String>,
)

/** A pending join request for a group. */
data class SonarJoinRequest(
    val requesterNpub: String,
    val groupId: String,
    val receivedAt: Long,
)

/** A decrypted message in a chat. [viaInternet] marks the transport for the
 *  per-message bubble colour: false = BLE mesh (cyan), true = White Noise /
 *  Nostr internet (indigo). A Sonar-peer DM merges both legs into one thread. */
data class SonarMsg(
    val id: String,
    val senderNpub: String,
    val content: String,
    val mine: Boolean,
    val tsSecs: Long,
    val viaInternet: Boolean = false,
    /// Encrypted media attachments (Marmot MIP-04), empty for plain text.
    val media: List<SonarMedia> = emptyList(),
    /// Local send state projected from core delivery metadata.
    val state: String? = null,
    /// Sticker reference if this message is a sticker send.
    val stickerRef: SonarStickerRef? = null,
)

/** A sticker reference carried on a chat message. */
data class SonarStickerRef(
    val packCoordinate: String,
    val shortcode: String,
    val plaintextSha256: String,
) {
    fun packAddressParts(): Pair<String, String>? {
        val parts = packCoordinate.split(":", limit = 3)
        if (parts.size != 3 || parts[0] != "30030") return null
        return parts[1] to parts[2]
    }
}

internal data class MeshStickerContentRef(
    val packCoordinate: String,
    val shortcode: String,
    val plaintextSha256: String,
)

private const val MESH_STICKER_TAG = "sticker"
private const val MESH_STICKER_SEPARATOR = '\u001F'

internal fun meshStickerContent(
    packCoordinate: String,
    shortcode: String,
    plaintextSha256: String,
): String =
    "$MESH_STICKER_SEPARATOR$MESH_STICKER_TAG$MESH_STICKER_SEPARATOR" +
        "$packCoordinate$MESH_STICKER_SEPARATOR$shortcode$MESH_STICKER_SEPARATOR$plaintextSha256"

internal fun meshParseStickerContent(content: String): MeshStickerContentRef? {
    val parts = content.split(MESH_STICKER_SEPARATOR, limit = 5)
    if (parts.size != 5 || parts[0].isNotEmpty() || parts[1] != MESH_STICKER_TAG) return null
    return MeshStickerContentRef(
        packCoordinate = parts[2],
        shortcode = parts[3],
        plaintextSha256 = parts[4],
    )
}

/** A single sticker in a pack. */
data class SonarStickerItem(
    val shortcode: String,
    val url: String,
    val sha256: String,
    val mime: String,
    val width: Int?,
    val height: Int?,
    val alt: String?,
    val emoji: String?,
)

/** A sticker pack fetched from relays. */
data class SonarStickerPack(
    val packCoordinate: String,
    val title: String,
    val description: String?,
    val coverUrl: String?,
    val stickers: List<SonarStickerItem>,
) {
    fun stickerMatching(ref: SonarStickerRef): SonarStickerItem? =
        stickers.firstOrNull {
            it.shortcode == ref.shortcode &&
                it.sha256.equals(ref.plaintextSha256, ignoreCase = true)
        }
}

/** Local transcript window for one recent chat, newest conversation first at
 *  the API boundary and oldest-first inside [messages]. */
data class SonarRecentTranscriptPage(
    val chatId: String,
    val latestTsSecs: Long,
    val messages: List<SonarMsg>,
)

/** A reference to an encrypted media attachment. [url] is the Blossom URL of the
 *  CIPHERTEXT; call [SonarCore.fetchMedia] to download + decrypt. */
data class SonarMedia(
    val url: String,
    val mimeType: String,
    val filename: String,
    val width: Int?,
    val height: Int?,
    val durationMs: Long?,
) {
    val isImage: Boolean get() = mimeType.startsWith("image/")
    val isGif: Boolean get() =
        mimeType.equals("image/gif", ignoreCase = true) ||
            filename.endsWith(".gif", ignoreCase = true)
}

/** A peer's Nostr profile (kind-0 metadata, NIP-01). A Marmot member's identity
 *  is a Nostr pubkey, so this resolves their human name + avatar (vs a raw npub). */
data class SonarProfile(
    val name: String?,
    val displayName: String?,
    val about: String?,
    val picture: String?,
    val nip05: String?,
) {
    /** Best human label: display name, else name, else null. */
    val bestName: String? get() =
        displayName?.takeIf { it.isNotBlank() } ?: name?.takeIf { it.isNotBlank() }
}

/** Public Sonar app descriptor advertised on Nostr so account-level peers can
 *  discover which Sonar capabilities are safe to offer when BLE is unavailable. */
data class SonarDescriptor(
    val schema: Int,
    val calls: Boolean,
    val media: List<String>,
    val signaling: List<String>,
    val transports: List<String>,
    val callIdentity: String,
    val bolt12Offer: String?,
    val paymentReceipts: List<String>,
    val publishedAtSecs: Long,
) {
    val supportsCurrentCalls: Boolean get() =
        calls &&
            "marmot" in signaling &&
            "iroh" in transports &&
            callIdentity == "iroh-hkdf-sonar-call-iroh-v1"
}

internal const val PROFILE_CACHE_BLOB_KEY = "profiles.byNpub.v1"
internal const val CHAT_SNAPSHOT_BLOB_KEY = "chats.snapshot.v1"

internal fun canonicalProfileKey(value: String): String {
    val clean = value.trim()
    val decoded = Bech32.decode(clean)
    if (decoded?.hrp == "npub" && decoded.data.size == 32) {
        return Bech32.encode("npub", decoded.data) ?: clean
    }
    val hex = clean.hexBytesOrNull()
    if (hex?.size == 32) {
        return Bech32.encode("npub", hex) ?: clean
    }
    return clean
}

internal fun encodeProfileCache(profiles: Map<String, SonarProfile>): String =
    normalizedProfileCache(profiles).entries
        .sortedBy { it.key }
        .joinToString("\n") { (npub, profile) ->
            listOf(
                hexEnc(npub),
                profileField(profile.name),
                profileField(profile.displayName),
                profileField(profile.about),
                profileField(profile.picture),
                profileField(profile.nip05),
            ).joinToString("\t")
        }

internal fun decodeProfileCache(blob: String): Map<String, SonarProfile> =
    blob.lineSequence()
        .mapNotNull { line ->
            if (line.isBlank()) return@mapNotNull null
            val parts = line.split("\t")
            if (parts.size != 6) return@mapNotNull null
            val npub = hexDec(parts[0])?.takeIf { it.isNotBlank() } ?: return@mapNotNull null
            val name = profileFieldValue(parts[1]) ?: return@mapNotNull null
            val displayName = profileFieldValue(parts[2]) ?: return@mapNotNull null
            val about = profileFieldValue(parts[3]) ?: return@mapNotNull null
            val picture = profileFieldValue(parts[4]) ?: return@mapNotNull null
            val nip05 = profileFieldValue(parts[5]) ?: return@mapNotNull null
            val profile = SonarProfile(
                name = name.value,
                displayName = displayName.value,
                about = about.value,
                picture = picture.value,
                nip05 = nip05.value,
            )
            npub to profile
        }
        .let { normalizedProfileCache(it.toMap()) }

internal fun normalizedProfileCache(profiles: Map<String, SonarProfile>): Map<String, SonarProfile> =
    profiles.entries.fold(linkedMapOf()) { result, (key, profile) ->
        val canonical = canonicalProfileKey(key)
        if (result[canonical]?.bestName == null || profile.bestName != null) {
            result[canonical] = profile
        }
        result
    }

@Suppress("UNUSED_PARAMETER")
internal fun encodeChatSnapshot(chats: List<SonarChat>, messagesByChat: Map<String, List<SonarMsg>>): String =
    buildString {
        chats.sortedBy { it.id }.forEach { chat ->
            append("c\t")
            append(hexEnc(chat.id)).append('\t')
            append(hexEnc(chat.name)).append('\t')
            append(chat.members.joinToString(",") { hexEnc(it) })
            append('\n')
        }
    }

internal fun decodeChatSnapshot(blob: String): Pair<List<SonarChat>, Map<String, List<SonarMsg>>> {
    val chats = mutableListOf<SonarChat>()
    blob.lineSequence().forEach { line ->
        if (line.isBlank()) return@forEach
        val parts = line.split('\t')
        when (parts.firstOrNull()) {
            "c" -> {
                if (parts.size != 4) return@forEach
                val id = hexDec(parts[1]) ?: return@forEach
                val name = hexDec(parts[2]) ?: return@forEach
                val members = parts[3]
                    .takeIf { it.isNotEmpty() }
                    ?.split(",")
                    ?.mapNotNull { hexDec(it) }
                    .orEmpty()
                chats += SonarChat(id, name, members)
            }
        }
    }
    return chats to emptyMap()
}

private fun profileField(value: String?): String =
    value?.let { "1" + hexEnc(it) } ?: "0"

private data class ProfileFieldValue(val value: String?)

private fun profileFieldValue(token: String): ProfileFieldValue? =
    when {
        token == "0" -> ProfileFieldValue(null)
        token.startsWith("1") -> hexDec(token.drop(1))?.let { ProfileFieldValue(it) }
        else -> null
    }

private fun hexEnc(s: String): String =
    s.encodeToByteArray().joinToString("") {
        ((it.toInt() and 0xFF) + 0x100).toString(16).substring(1)
    }

private fun hexDec(s: String): String? {
    if (s.isEmpty()) return ""
    if (s.length % 2 != 0) return null
    val bytes = ByteArray(s.length / 2)
    for (i in bytes.indices) {
        val hi = s[2 * i].digitToIntOrNull(16) ?: return null
        val lo = s[2 * i + 1].digitToIntOrNull(16) ?: return null
        bytes[i] = ((hi shl 4) or lo).toByte()
    }
    return bytes.decodeToString()
}

private fun String.hexBytesOrNull(): ByteArray? {
    val clean = trim().removePrefix("0x").removePrefix("0X")
    if (clean.isEmpty() || clean.length % 2 != 0) return null
    val bytes = ByteArray(clean.length / 2)
    for (i in bytes.indices) {
        val hi = clean[2 * i].digitToIntOrNull(16) ?: return null
        val lo = clean[2 * i + 1].digitToIntOrNull(16) ?: return null
        bytes[i] = ((hi shl 4) or lo).toByte()
    }
    return bytes
}

/** Precomputed conversation summary from the core-owned index. */
data class SonarConversationSummary(
    val groupIdHex: String,
    val name: String,
    val latestContent: String,
    val latestSenderNpub: String,
    val latestAtSecs: Long,
    val latestMine: Boolean,
    val messageCount: Long,
    val unreadCount: Long,
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

// ── P2P voice calls (iroh transport, ☎CALL signaling) ──

/** State of a 1:1 P2P call, as the core engine reports it. */
enum class SonarCallState { Ringing, Connecting, Connected, Ended, Failed, Declined, Busy, Missed }

/** A call state change emitted by the engine (drained via [SonarCore.callWaitEvent]). */
data class SonarCallEvent(
    val callId: String,
    val state: SonarCallState,
    /** Connected seconds — only meaningful for [SonarCallState.Ended]. */
    val durationSecs: Long,
    val reason: String,
)

/** The answerer's verdict on an incoming offer. */
enum class SonarAnswer { Accept, Decline, Busy }

/** A parsed inbound `☎CALL` control line. Rides encrypted chat content like
 *  ⚡PAY; the host scan loop feeds message text to [SonarCore.callParseControl]
 *  and routes the result to the call engine WITHOUT rendering it as a bubble. */
sealed class SonarCallControl {
    abstract val callId: String
    data class Offer(override val callId: String, val video: Boolean, val addrB64: String, val unixSecs: Long) : SonarCallControl()
    data class Answer(override val callId: String, val answer: SonarAnswer, val addrB64: String) : SonarCallControl()
    data class Cancel(override val callId: String) : SonarCallControl()
    data class End(override val callId: String, val reason: String) : SonarCallControl()
}

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

    /** Classify notification content through the Rust core renderer model. */
    fun classifyNotificationContent(content: String): SonarNotificationKind

    /** Render the user-visible notification envelope through the Rust core. */
    fun renderNotification(input: SonarNotificationRenderInput): SonarNotificationEnvelope?

    /** All active Marmot chats we belong to. */
    suspend fun chats(): List<SonarChat>

    /** Start (or fetch) a 1:1 chat with a peer (npub or hex). Returns chat id. */
    suspend fun startChat(peer: String): String

    /** Start a multi-member group with peers (npub or hex). Returns chat id. */
    suspend fun startGroup(members: List<String>, name: String): String

    /** Pending multi-member group invites. */
    suspend fun pendingGroupInvites(): List<SonarGroupInvite>

    /** Accept a pending group invite. Returns chat id. */
    suspend fun acceptGroupInvite(inviteId: String): String

    /** Decline a pending group invite. */
    suspend fun declineGroupInvite(inviteId: String)

    /** Add members to an existing group. */
    suspend fun addGroupMembers(chatId: String, members: List<String>)

    /** Remove members from an existing group. */
    suspend fun removeGroupMembers(chatId: String, members: List<String>)

    /** Leave a group. */
    suspend fun leaveGroup(chatId: String)

    /** Create a shareable invite link for a group. Returns sinvite1… token. */
    suspend fun createInviteLink(chatId: String, groupName: String): String

    /** Pending join requests for a group. */
    suspend fun pendingJoinRequests(chatId: String): List<SonarJoinRequest>

    /** Approve a pending join request. */
    suspend fun approveJoinRequest(chatId: String, requesterNpub: String)

    /** Decline a pending join request. */
    suspend fun declineJoinRequest(chatId: String, requesterNpub: String)

    /** Request to join a group via an invite link token. */
    suspend fun requestJoinViaLink(token: String)

    /** Send an encrypted text message to a chat. */
    suspend fun send(chatId: String, text: String)

    /** Encrypt + upload [data] to a Blossom server, then publish a media message
     *  to the chat. [serverUrl] empty → the core default. */
    suspend fun sendMedia(
        chatId: String,
        data: ByteArray,
        filename: String,
        mime: String,
        caption: String,
        serverUrl: String = "",
    )

    /** Send a sticker message to a chat. */
    suspend fun sendSticker(
        chatId: String,
        packCoordinate: String,
        shortcode: String,
        plaintextSha256: String,
    )

    /** Fetch a sticker pack from relays by author + identifier. */
    suspend fun fetchStickerPack(
        authorPubkeyHex: String,
        identifier: String,
        relayUrls: List<String> = emptyList(),
    ): SonarStickerPack

    /** Download a public sticker image and verify the bytes match [expectedSha256]. */
    suspend fun fetchStickerImage(url: String, expectedSha256: String): ByteArray

    /** Fetch the user's installed sticker pack list (kind 10030) from relays. */
    suspend fun fetchInstalledPacks(): List<String>

    /** Add a sticker pack to the user's installed list and publish kind 10030. */
    suspend fun installStickerPack(coordinate: String)

    /** Remove a sticker pack from the user's installed list and publish kind 10030. */
    suspend fun uninstallStickerPack(coordinate: String)

    /** Download + decrypt the media blob at [url] for the chat. Returns plaintext. */
    suspend fun fetchMedia(chatId: String, url: String): ByteArray

    /** Decrypted message history for a chat, oldest first. */
    suspend fun messages(chatId: String): List<SonarMsg>

    /** Bounded local message window for a chat, oldest first within the page. */
    suspend fun messagesPage(chatId: String, limit: Int, offset: Int = 0): List<SonarMsg>

    /** Bounded local transcript windows for the most recent chats. */
    suspend fun recentMessagePages(groupLimit: Int, pageLimit: Int): List<SonarRecentTranscriptPage>

    /** Precomputed conversation summaries from the core-owned index, ordered
     *  by latest message timestamp (newest first). */
    suspend fun conversationSummaries(): List<SonarConversationSummary>

    /** Reset unread count for a chat to 0. */
    suspend fun markConversationRead(chatId: String)

    /** Cursor-based message page — newest first, before the given cursor. */
    suspend fun messagesCursorPage(
        chatId: String,
        beforeSecs: Long? = null,
        beforeIdHex: String? = null,
        limit: Int,
    ): List<SonarMsg>

    /** Poll the relays once (welcomes + group messages). */
    suspend fun sync()

    /** Re-subscribe with current watermark + group set to self-heal after
     *  relay disconnects. Lighter than sync() — no blocking fetch. */
    suspend fun ensureSubscriptions()

    /** Publish our kind-0 profile (NIP-01) so peers see our nickname, not npub. */
    suspend fun publishProfile(name: String, about: String? = null, picture: String? = null)

    /** Fetch a peer's kind-0 profile (npub or hex). null if they have none. */
    suspend fun fetchProfile(npub: String): SonarProfile?

    /** Publish this build's public Sonar descriptor. */
    suspend fun publishSonarDescriptor(callsEnabled: Boolean = true, bolt12Offer: String? = null)

    /** Fetch a peer's public Sonar descriptor (npub or hex). null on miss. */
    suspend fun fetchSonarDescriptor(npub: String): SonarDescriptor?

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

    /** Validate and persist an existing identity. Returns the restored npub. */
    suspend fun importIdentity(nsec: String): String

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

    /** Erase the White Noise (Marmot) chats but KEEP the identity: delete the
     *  encrypted SQLCipher DB only (nsec, DB key, nickname and prefs survive),
     *  then reconnect with the same identity so new secure chats still work and
     *  our KeyPackage is republished. Used by "erase all chats" (not full wipe). */
    suspend fun eraseChats()

    /** Delete ONE White Noise (Marmot) chat's local state (messages + MLS keys)
     *  by its group id. Local-only — the peer is NOT notified. Idempotent. Backs
     *  per-chat "delete this conversation". */
    suspend fun deleteChat(chatId: String)

    // ── Push token registration (MIP-05) ──

    /** Encrypt a device push token to the transponder and share it with peers. */
    suspend fun registerPushToken(platform: String, token: ByteArray, serverNpub: String)

    // ── P2P voice calls (iroh transport; ☎CALL rides chat signaling) ──

    /** Bind the iroh call endpoint once for this session. The Ed25519 call key is
     *  derived in-core from our Nostr identity, so nothing is passed. Idempotent-ish. */
    suspend fun callStart()

    /** Our dialable address (`nodeAddrB64`) to embed in a ☎CALL OFFER/ANSWER. */
    suspend fun callLocalAddress(): String

    /** Begin an OUTGOING call (offerer); returns at Ringing. The host then sends
     *  the encoded OFFER over the peer's chat transport. */
    suspend fun callPlace(callId: String, video: Boolean)

    /** Register an inbound OFFER the host parsed from a ☎CALL line. */
    suspend fun callIncomingOffer(callId: String, addrB64: String, video: Boolean)

    /** The offerer received the peer's ANSWER: accept pins the answerer + connects
     *  (awaiting their dial); decline/busy ends the call. */
    suspend fun callAnswer(callId: String, answer: SonarAnswer, addrB64: String)

    /** The user accepted an incoming call: we dial the offerer + start media. */
    suspend fun callAccept(callId: String)

    /** Hang up / cancel a call (tears down media + connection). */
    suspend fun callHangup(callId: String)

    /** Toggle the local microphone for this call without tearing media down. */
    suspend fun callSetMuted(callId: String, muted: Boolean)

    /** Park up to [timeoutSecs] for the next call state change (poll on a
     *  background coroutine; mirrors the Marmot wait loop). null on timeout. */
    suspend fun callWaitEvent(timeoutSecs: Long): SonarCallEvent?

    /** Encode a ☎CALL OFFER/ANSWER/END line to send as encrypted chat content. */
    fun callEncodeOffer(callId: String, video: Boolean, addrB64: String, unixSecs: Long): String
    fun callEncodeAnswer(callId: String, answer: SonarAnswer, addrB64: String): String
    fun callEncodeEnd(callId: String, reason: String): String

    /** Parse chat content as a ☎CALL line. null = not a control line (render it). */
    fun callParseControl(content: String): SonarCallControl?

    /** Flow of group IDs whose conversation summary changed (message sent/received,
     *  unread count reset). Collect to trigger UI refresh on change. */
    val conversationChanged: SharedFlow<String>

    /** Install the core callback that feeds [conversationChanged]. Call once
     *  after [start]. */
    fun installConversationListener()
}
