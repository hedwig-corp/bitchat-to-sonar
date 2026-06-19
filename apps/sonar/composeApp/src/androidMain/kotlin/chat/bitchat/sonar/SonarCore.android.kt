package chat.bitchat.sonar

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import uniffi.sonar_ffi.SonarIdentity
import uniffi.sonar_ffi.SonarNode
import java.io.File
import java.security.SecureRandom

/**
 * Android `actual`: drive the Rust core (Marmot/White Noise) through the
 * UniFFI Kotlin/JNA bindings. The FFI is blocking (owns a tokio runtime), so
 * every call hops to [Dispatchers.IO]. Identity + DB key persist via
 * [AndroidSecrets] so private material is encrypted with Android Keystore.
 */
actual object SonarCore {

    // Must match the iOS MarmotService relays so the two interop.
    private val relayUrls = listOf(
        "wss://relay.damus.io",
        "wss://nos.lol",
        "wss://relay.primal.net",
        "wss://relay.kaleidoswap.com",
    )

    private val lock = Mutex()
    private var node: SonarNode? = null
    @Volatile private var npub: String = ""
    @Volatile private var pubkeyHex: String = ""

    private val ctx: Context get() = AppContextHolder.ctx
    private fun prefs() = ctx.getSharedPreferences("sonar", Context.MODE_PRIVATE)

    actual suspend fun start(): String = withContext(Dispatchers.IO) {
        lock.withLock {
            if (node == null) {
                val identity = loadOrCreateIdentity()
                npub = identity.npub()
                pubkeyHex = identity.pubkeyHex()

                val dir = File(ctx.filesDir, "sonar-marmot").apply { mkdirs() }
                val dbPath = File(dir, "marmot.sqlite").absolutePath
                val dbKeyHex = loadOrCreateDbKey()

                val n = SonarNode.connect(identity, relayUrls, dbPath, dbKeyHex)
                runCatching { n.publishKeyPackage() }
                node = n
            }
            npub
        }
    }

    actual fun myNpub(): String = npub

    actual suspend fun chats(): List<SonarChat> = withContext(Dispatchers.IO) {
        val n = node ?: return@withContext emptyList()
        n.groups().map { SonarChat(id = it.idHex, name = it.name, members = it.memberNpubs) }
    }

    actual suspend fun startChat(peer: String): String = withContext(Dispatchers.IO) {
        val n = requireNode()
        n.startDm(peer.trim(), "")
    }

    actual suspend fun startGroup(members: List<String>, name: String): String = withContext(Dispatchers.IO) {
        requireNode().startGroup(members.map { it.trim() }.filter { it.isNotEmpty() }, name.trim())
    }

    actual suspend fun pendingGroupInvites(): List<SonarGroupInvite> = withContext(Dispatchers.IO) {
        val n = node ?: return@withContext emptyList()
        n.pendingGroupInvites().map {
            SonarGroupInvite(
                id = it.idHex,
                groupId = it.groupIdHex,
                groupName = it.groupName,
                groupDescription = it.groupDescription,
                welcomerNpub = it.welcomerNpub,
                memberCount = it.memberCount.toInt(),
                relays = it.relayUrls,
            )
        }
    }

    actual suspend fun acceptGroupInvite(inviteId: String): String = withContext(Dispatchers.IO) {
        requireNode().acceptGroupInvite(inviteId)
    }

    actual suspend fun declineGroupInvite(inviteId: String) = withContext(Dispatchers.IO) {
        requireNode().declineGroupInvite(inviteId)
    }

    actual suspend fun addGroupMembers(chatId: String, members: List<String>) = withContext(Dispatchers.IO) {
        requireNode().addGroupMembers(chatId, members.map { it.trim() }.filter { it.isNotEmpty() })
    }

    actual suspend fun removeGroupMembers(chatId: String, members: List<String>) = withContext(Dispatchers.IO) {
        requireNode().removeGroupMembers(chatId, members.map { it.trim() }.filter { it.isNotEmpty() })
    }

    actual suspend fun leaveGroup(chatId: String) = withContext(Dispatchers.IO) {
        requireNode().leaveGroup(chatId)
    }

    actual suspend fun createInviteLink(chatId: String, groupName: String): String =
        withContext(Dispatchers.IO) { requireNode().createInviteLink(chatId, groupName) }

    actual suspend fun pendingJoinRequests(chatId: String): List<SonarJoinRequest> =
        withContext(Dispatchers.IO) {
            requireNode().pendingJoinRequests(chatId).map {
                SonarJoinRequest(it.requesterNpub, it.groupIdHex, it.receivedAt.toLong())
            }
        }

    actual suspend fun approveJoinRequest(chatId: String, requesterNpub: String) =
        withContext(Dispatchers.IO) { requireNode().approveJoinRequest(chatId, requesterNpub) }

    actual suspend fun declineJoinRequest(chatId: String, requesterNpub: String) =
        withContext(Dispatchers.IO) { requireNode().declineJoinRequest(chatId, requesterNpub) }

    actual suspend fun requestJoinViaLink(token: String) =
        withContext(Dispatchers.IO) { requireNode().requestJoinViaLink(token) }

    actual suspend fun send(chatId: String, text: String) = withContext(Dispatchers.IO) {
        requireNode().sendText(chatId, text)
    }

    actual suspend fun sendMedia(
        chatId: String,
        data: ByteArray,
        filename: String,
        mime: String,
        caption: String,
        serverUrl: String,
    ) = withContext(Dispatchers.IO) {
        requireNode().sendMedia(chatId, data, filename, mime, caption, serverUrl)
    }

    actual suspend fun sendSticker(
        chatId: String,
        packCoordinate: String,
        shortcode: String,
        plaintextSha256: String,
    ) = withContext(Dispatchers.IO) {
        requireNode().sendSticker(chatId, packCoordinate, shortcode, plaintextSha256)
    }

    actual suspend fun fetchStickerPack(
        authorPubkeyHex: String,
        identifier: String,
        relayUrls: List<String>,
    ): SonarStickerPack = withContext(Dispatchers.IO) {
        requireNode().fetchStickerPack(authorPubkeyHex, identifier, relayUrls).toCommon()
    }

    actual suspend fun fetchStickerImage(url: String, expectedSha256: String): ByteArray =
        withContext(Dispatchers.IO) { requireNode().fetchStickerImage(url, expectedSha256) }

    actual suspend fun fetchInstalledPacks(): List<String> =
        withContext(Dispatchers.IO) { requireNode().fetchInstalledPacks() }

    actual suspend fun fetchMedia(chatId: String, url: String): ByteArray =
        withContext(Dispatchers.IO) { requireNode().fetchMedia(chatId, url) }

    actual suspend fun messages(chatId: String): List<SonarMsg> = withContext(Dispatchers.IO) {
        val n = node ?: return@withContext emptyList()
        n.messages(chatId).map { it.toCommon() }
    }

    actual suspend fun messagesPage(chatId: String, limit: Int, offset: Int): List<SonarMsg> =
        withContext(Dispatchers.IO) {
            require(limit > 0) { "messagesPage limit must be greater than zero" }
            require(offset >= 0) { "messagesPage offset must be non-negative" }
            val n = node ?: return@withContext emptyList()
            n.messagesPage(chatId, limit.toUInt(), offset.toUInt()).map { it.toCommon() }
        }

    actual suspend fun recentMessagePages(groupLimit: Int, pageLimit: Int): List<SonarRecentTranscriptPage> =
        withContext(Dispatchers.IO) {
            require(groupLimit >= 0) { "recentMessagePages groupLimit must be non-negative" }
            require(pageLimit >= 0) { "recentMessagePages pageLimit must be non-negative" }
            val n = node ?: return@withContext emptyList()
            n.recentMessagePages(groupLimit.toUInt(), pageLimit.toUInt()).map {
                SonarRecentTranscriptPage(
                    chatId = it.groupIdHex,
                    latestTsSecs = it.latestCreatedAtSecs.toLong(),
                    messages = it.messages.map { message -> message.toCommon() },
                )
            }
        }

    actual suspend fun conversationSummaries(): List<SonarConversationSummary> = withContext(Dispatchers.IO) {
        val n = node ?: return@withContext emptyList()
        n.conversationSummaries().map {
            SonarConversationSummary(
                groupIdHex = it.groupIdHex,
                name = it.name,
                latestContent = it.latestContent,
                latestSenderNpub = it.latestSenderNpub,
                latestAtSecs = it.latestAtSecs.toLong(),
                latestMine = it.latestMine,
                messageCount = it.messageCount.toLong(),
                unreadCount = it.unreadCount.toLong(),
            )
        }
    }

    actual suspend fun markConversationRead(chatId: String) = withContext(Dispatchers.IO) {
        node?.markConversationRead(chatId)
        Unit
    }

    actual suspend fun messagesCursorPage(
        chatId: String,
        beforeSecs: Long?,
        beforeIdHex: String?,
        limit: Int,
    ): List<SonarMsg> = withContext(Dispatchers.IO) {
        val n = node ?: return@withContext emptyList()
        n.messagesCursorPage(
            chatId,
            beforeSecs?.toULong(),
            beforeIdHex,
            limit.toUInt(),
        ).map { it.toCommon() }
    }

    private fun uniffi.sonar_ffi.MessageInfo.toCommon(): SonarMsg = SonarMsg(
        id = idHex,
        senderNpub = senderNpub,
        content = content,
        mine = mine,
        tsSecs = createdAtSecs.toLong(),
        media = media.map { m ->
            SonarMedia(
                url = m.url,
                mimeType = m.mimeType,
                filename = m.filename,
                width = m.width?.toInt(),
                height = m.height?.toInt(),
                durationMs = m.durationMs?.toLong(),
            )
        },
        state = deliveryState.toUiState(mine),
        stickerRef = stickerRef?.let {
            SonarStickerRef(it.packCoordinate, it.shortcode, it.plaintextSha256)
        },
    )

    private fun uniffi.sonar_ffi.StickerPackInfo.toCommon(): SonarStickerPack = SonarStickerPack(
        packCoordinate = packCoordinate,
        title = title,
        description = description,
        coverUrl = coverUrl,
        stickers = stickers.map { s ->
            SonarStickerItem(
                shortcode = s.shortcode,
                url = s.url,
                sha256 = s.sha256,
                mime = s.mime,
                width = s.width?.toInt(),
                height = s.height?.toInt(),
                alt = s.alt,
                emoji = s.emoji,
            )
        },
    )

    private fun String.toUiState(mine: Boolean): String? {
        if (!mine) return null
        return when (this) {
            "pending" -> "Sending"
            "failed" -> "Couldn't send"
            "sent" -> "Sent"
            else -> "Sent"
        }
    }

    actual suspend fun publishProfile(name: String, about: String?, picture: String?) = withContext(Dispatchers.IO) {
        runCatching { node?.publishProfile(name, about, picture) }
        Unit
    }

    actual suspend fun fetchProfile(npub: String): SonarProfile? = withContext(Dispatchers.IO) {
        val n = node ?: return@withContext null
        runCatching {
            n.fetchProfile(npub)?.let {
                SonarProfile(it.name, it.displayName, it.about, it.picture, it.nip05)
            }
        }.getOrNull()
    }

    actual suspend fun publishSonarDescriptor(callsEnabled: Boolean, bolt12Offer: String?) = withContext(Dispatchers.IO) {
        runCatching { node?.publishSonarDescriptor(callsEnabled, listOf("marmot"), bolt12Offer) }
        Unit
    }

    actual suspend fun fetchSonarDescriptor(npub: String): SonarDescriptor? = withContext(Dispatchers.IO) {
        val n = node ?: return@withContext null
        runCatching {
            n.fetchSonarDescriptor(npub)?.let {
                SonarDescriptor(
                    schema = it.schema.toInt(),
                    calls = it.calls,
                    media = it.media,
                    signaling = it.signaling,
                    transports = it.transports,
                    callIdentity = it.callIdentity,
                    bolt12Offer = it.bolt12Offer,
                    paymentReceipts = it.paymentReceipts,
                    publishedAtSecs = it.publishedAtSecs.toLong(),
                )
            }
        }.getOrNull()
    }

    actual suspend fun sync() = withContext(Dispatchers.IO) {
        runCatching { node?.syncOnce() }
        Unit
    }

    actual fun joinedChannels(): List<String> =
        prefs().getString("channels", "")?.split(",")?.filter { it.isNotBlank() } ?: emptyList()

    actual fun joinChannel(geohash: String) {
        val g = geohash.trim().lowercase()
        if (g.isEmpty()) return
        val set = joinedChannels().toMutableList()
        if (!set.contains(g)) { set.add(g); prefs().edit().putString("channels", set.joinToString(",")).apply() }
    }

    actual fun leaveChannel(geohash: String) {
        val set = joinedChannels().toMutableList()
        set.remove(geohash.trim().lowercase())
        prefs().edit().putString("channels", set.joinToString(",")).apply()
    }

    actual suspend fun channelMessages(geohash: String): List<SonarChannelMsg> = withContext(Dispatchers.IO) {
        val n = node ?: return@withContext emptyList()
        runCatching {
            n.geohashMessages(geohash, 200u).map {
                SonarChannelMsg(
                    id = it.idHex,
                    author = it.nickname.ifBlank { it.senderPubkeyHex.take(8) },
                    senderPubkey = it.senderPubkeyHex,
                    content = it.content,
                    mine = it.mine,
                    tsSecs = it.createdAtSecs.toLong(),
                )
            }
        }.getOrDefault(emptyList())
    }

    actual suspend fun sendChannel(geohash: String, text: String) = withContext(Dispatchers.IO) {
        val nick = nickname().ifBlank { "anon" }
        requireNode().sendGeohash(geohash, text, nick)
    }

    actual suspend fun sendChannelPresence(geohash: String) = withContext(Dispatchers.IO) {
        runCatching { node?.sendGeohashPresence(geohash) }
        Unit
    }

    actual suspend fun channelPresenceCount(geohash: String): Int = withContext(Dispatchers.IO) {
        val n = node ?: return@withContext 0
        runCatching { n.geohashPresenceCount(geohash).toInt() }.getOrDefault(0)
    }

    actual suspend fun geoDmMessages(geohash: String, peerHex: String): List<SonarMsg> = withContext(Dispatchers.IO) {
        val n = node ?: return@withContext emptyList()
        runCatching {
            n.geoDmMessages(geohash, peerHex).map {
                SonarMsg(
                    id = it.idHex,
                    senderNpub = it.senderPubkeyHex,
                    content = it.content,
                    mine = it.mine,
                    tsSecs = it.createdAtSecs.toLong(),
                )
            }
        }.getOrDefault(emptyList())
    }

    actual suspend fun sendGeoDm(geohash: String, peerHex: String, text: String) = withContext(Dispatchers.IO) {
        requireNode().sendGeoDm(geohash, peerHex, text)
    }

    actual fun nickname(): String = prefs().getString("nickname", "") ?: ""

    actual fun setNickname(value: String) {
        prefs().edit().putString("nickname", value.trim()).apply()
    }

    actual fun fingerprint(): String {
        var hex = pubkeyHex
        if (hex.isEmpty()) {
            val saved = AndroidSecrets.getMigrating("nsec")
            if (saved != null) hex = runCatching { SonarIdentity.import(saved).pubkeyHex() }.getOrDefault("")
        }
        if (hex.isEmpty()) return ""
        // First 32 hex chars grouped in 4s, uppercase — a stable key fingerprint.
        return hex.take(32).uppercase().chunked(4).joinToString(" ")
    }

    actual fun identityNsec(): String = AndroidSecrets.getMigrating("nsec") ?: ""

    actual suspend fun importIdentity(nsec: String): String = withContext(Dispatchers.IO) {
        val identity = SonarIdentity.import(nsec.trim())
        lock.withLock {
            node = null
            npub = identity.npub()
            pubkeyHex = identity.pubkeyHex()
            File(ctx.filesDir, "sonar-marmot").deleteRecursively()
            AndroidSecrets.put("nsec", identity.nsec())
            npub
        }
    }

    actual fun onboardingComplete(): Boolean = prefs().getBoolean("onboarding.complete", false)

    actual fun setOnboardingComplete(value: Boolean) {
        prefs().edit().putBoolean("onboarding.complete", value).apply()
    }

    actual fun isDark(): Boolean = prefs().getBoolean("appearance.dark", true)

    actual fun setDark(value: Boolean) {
        prefs().edit().putBoolean("appearance.dark", value).apply()
    }

    actual fun loadBlob(key: String): String = prefs().getString("blob.$key", "") ?: ""

    actual fun saveBlob(key: String, value: String) {
        prefs().edit().putString("blob.$key", value).apply()
    }

    actual suspend fun wipe() = withContext(Dispatchers.IO) {
        lock.withLock {
            node = null
            npub = ""; pubkeyHex = ""
            // Drop the encrypted Marmot DB + all prefs.
            File(ctx.filesDir, "sonar-marmot").deleteRecursively()
            AndroidSecrets.clear()
            prefs().edit().clear().apply()
        }
    }

    actual suspend fun eraseChats() {
        withContext(Dispatchers.IO) {
            lock.withLock {
                node = null
                // Delete ONLY the encrypted Marmot DB — keep nsec, the DB key,
                // nickname and every pref. start() (below) reopens a fresh empty
                // DB with the SAME identity + key.
                File(ctx.filesDir, "sonar-marmot").deleteRecursively()
            }
        }
        // Reconnect with the same identity and republish our KeyPackage so peers
        // can still start new secure chats with us.
        start()
    }

    actual suspend fun deleteChat(chatId: String): Unit = withContext(Dispatchers.IO) {
        runCatching { node?.deleteGroup(chatId) }
        Unit
    }

    // ── P2P voice calls (delegate to the generated SonarNode call_* binding) ──

    actual suspend fun callStart(): Unit = withContext(Dispatchers.IO) { requireNode().callStart() }

    actual suspend fun callLocalAddress(): String =
        withContext(Dispatchers.IO) { requireNode().callLocalAddress() }

    actual suspend fun callPlace(callId: String, video: Boolean): Unit =
        withContext(Dispatchers.IO) { requireNode().callPlace(callId, video) }

    actual suspend fun callIncomingOffer(callId: String, addrB64: String, video: Boolean): Unit =
        withContext(Dispatchers.IO) { requireNode().callOnIncomingOffer(callId, addrB64, video) }

    actual suspend fun callAnswer(callId: String, answer: SonarAnswer, addrB64: String): Unit =
        withContext(Dispatchers.IO) { requireNode().callOnAnswer(callId, answer.toFfi(), addrB64) }

    actual suspend fun callAccept(callId: String): Unit =
        withContext(Dispatchers.IO) { requireNode().callAccept(callId) }

    actual suspend fun callHangup(callId: String): Unit =
        withContext(Dispatchers.IO) { requireNode().callHangup(callId) }

    actual suspend fun callSetMuted(callId: String, muted: Boolean): Unit =
        withContext(Dispatchers.IO) { requireNode().callSetMuted(callId, muted) }

    actual suspend fun callWaitEvent(timeoutSecs: Long): SonarCallEvent? =
        withContext(Dispatchers.IO) {
            val n = node ?: return@withContext null
            n.callWaitEvent(timeoutSecs.toULong())?.let {
                SonarCallEvent(it.callId, it.state.toCommon(), it.durationSecs.toLong(), it.reason)
            }
        }

    actual fun callEncodeOffer(callId: String, video: Boolean, addrB64: String, unixSecs: Long): String =
        uniffi.sonar_ffi.callEncodeOffer(callId, video, addrB64, unixSecs.toULong())

    actual fun callEncodeAnswer(callId: String, answer: SonarAnswer, addrB64: String): String =
        uniffi.sonar_ffi.callEncodeAnswer(callId, answer.toFfi(), addrB64)

    actual fun callEncodeEnd(callId: String, reason: String): String =
        uniffi.sonar_ffi.callEncodeEnd(callId, reason)

    actual fun callParseControl(content: String): SonarCallControl? =
        uniffi.sonar_ffi.callParseControl(content)?.toCommon()

    private val _conversationChanged = MutableSharedFlow<String>(extraBufferCapacity = 64)
    actual val conversationChanged: SharedFlow<String> = _conversationChanged.asSharedFlow()

    actual fun installConversationListener() {
        val n = node ?: return
        n.setConversationChangeListener(object : uniffi.sonar_ffi.ConversationChangeListener {
            override fun onConversationChanged(groupIdHex: String) {
                _conversationChanged.tryEmit(groupIdHex)
            }
        })
    }

    private fun requireNode(): SonarNode =
        node ?: error("SonarCore not started — call start() first")

    private fun loadOrCreateIdentity(): SonarIdentity {
        val saved = AndroidSecrets.getMigrating("nsec")
        if (saved != null) {
            runCatching { return SonarIdentity.import(saved) }
        }
        val id = SonarIdentity.generate()
        AndroidSecrets.put("nsec", id.nsec())
        return id
    }

    private fun loadOrCreateDbKey(): String {
        AndroidSecrets.getMigrating("dbKeyHex")?.let { return it }
        val bytes = ByteArray(32).also { SecureRandom().nextBytes(it) }
        val hex = bytes.joinToString("") { b -> "%02x".format(b) }
        AndroidSecrets.put("dbKeyHex", hex)
        return hex
    }
}

// ── Mapping between the generated UniFFI call types and the commonMain types ──

private fun SonarAnswer.toFfi(): uniffi.sonar_ffi.CallAnswerKind = when (this) {
    SonarAnswer.Accept -> uniffi.sonar_ffi.CallAnswerKind.ACCEPT
    SonarAnswer.Decline -> uniffi.sonar_ffi.CallAnswerKind.DECLINE
    SonarAnswer.Busy -> uniffi.sonar_ffi.CallAnswerKind.BUSY
}

private fun uniffi.sonar_ffi.CallAnswerKind.toCommon(): SonarAnswer = when (this) {
    uniffi.sonar_ffi.CallAnswerKind.ACCEPT -> SonarAnswer.Accept
    uniffi.sonar_ffi.CallAnswerKind.DECLINE -> SonarAnswer.Decline
    uniffi.sonar_ffi.CallAnswerKind.BUSY -> SonarAnswer.Busy
}

private fun uniffi.sonar_ffi.CallStateInfo.toCommon(): SonarCallState = when (this) {
    uniffi.sonar_ffi.CallStateInfo.RINGING -> SonarCallState.Ringing
    uniffi.sonar_ffi.CallStateInfo.CONNECTING -> SonarCallState.Connecting
    uniffi.sonar_ffi.CallStateInfo.CONNECTED -> SonarCallState.Connected
    uniffi.sonar_ffi.CallStateInfo.ENDED -> SonarCallState.Ended
    uniffi.sonar_ffi.CallStateInfo.FAILED -> SonarCallState.Failed
    uniffi.sonar_ffi.CallStateInfo.DECLINED -> SonarCallState.Declined
    uniffi.sonar_ffi.CallStateInfo.BUSY -> SonarCallState.Busy
    uniffi.sonar_ffi.CallStateInfo.MISSED -> SonarCallState.Missed
}

private fun uniffi.sonar_ffi.CallControlInfo.toCommon(): SonarCallControl = when (this) {
    is uniffi.sonar_ffi.CallControlInfo.Offer ->
        SonarCallControl.Offer(callId, video, nodeAddrB64, unixSecs.toLong())
    is uniffi.sonar_ffi.CallControlInfo.Answer ->
        SonarCallControl.Answer(callId, answer.toCommon(), nodeAddrB64)
    is uniffi.sonar_ffi.CallControlInfo.Cancel ->
        SonarCallControl.Cancel(callId)
    is uniffi.sonar_ffi.CallControlInfo.End ->
        SonarCallControl.End(callId, reason)
}
