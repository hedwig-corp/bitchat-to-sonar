package chat.bitchat.sonar

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import uniffi.sonar_ffi.SonarIdentity
import uniffi.sonar_ffi.MediaDownloadListener as FfiMediaDownloadListener
import uniffi.sonar_ffi.SonarNode
import uniffi.sonar_ffi.wipeMarmotDatabase
import java.io.File
import java.security.SecureRandom
import java.util.concurrent.locks.ReentrantLock
import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlin.concurrent.read
import kotlin.concurrent.write

/**
 * Desktop (JVM) `actual`: drive the Rust core (Marmot / White Noise) through the
 * SAME UniFFI Kotlin/JNA bindings as Android, loading a host dynamic library
 * (libsonar_ffi.dylib/.so/.dll bundled in jvmMain/resources, extracted by
 * [SonarNativeLoader]). The FFI owns a tokio runtime and is blocking, so every
 * call hops to [Dispatchers.IO]. Identity + DB key + prefs persist via
 * [DesktopEnv] under the per-user app-data dir.
 *
 * This is the cross-platform-testable slice: secure DMs, geohash channels,
 * presence, media and profiles interop with the iOS/Android apps over the same
 * Nostr relays. BLE mesh is hardware-gated and unavailable on desktop (see
 * [MeshRadio]/[UnifyRadio]).
 */
actual object SonarCore {

    // Must match the iOS/Android relays so the three interop.
    private val relayUrls = listOf(
        "wss://relay.damus.io",
        "wss://nos.lol",
        "wss://relay.primal.net",
        "wss://relay.kaleidoswap.com",
        "wss://nostr.relay.hedwig.sh",
    )

    private val lock = Mutex()
    // Fairness prevents a wipe/import writer from starving behind a stream of
    // picker/transcript reads while still allowing unrelated images in parallel.
    private val stickerOperationLock = ReentrantReadWriteLock(true)
    private val installedStickerMutationLock = ReentrantLock(true)
    private var node: SonarNode? = null
    @Volatile private var relayConnected = false
    @Volatile private var npub: String = ""
    @Volatile private var pubkeyHex: String = ""

    private fun marmotDir(): File = DesktopEnv.file("sonar-marmot").apply { mkdirs() }

    actual suspend fun start(): String = withContext(Dispatchers.IO) {
        SonarNativeLoader.ensureLoaded()
        lock.withLock {
            if (node == null) {
                val identity = loadOrCreateIdentity()
                npub = identity.npub()
                pubkeyHex = identity.pubkeyHex()

                val dbPath = File(marmotDir(), "marmot.sqlite").absolutePath
                val dbKeyHex = loadOrCreateDbKey()

                // Diagnostics file sink must exist before the node spins up so
                // relay connect/EOSE/watermark events are captured. Non-fatal.
                installCoreLogging(diagnosticsVerbose())
                node = SonarNode.connect(identity, emptyList(), dbPath, dbKeyHex)
                relayConnected = false
            }
            npub
        }
    }

    actual suspend fun connectRelays(): String = withContext(Dispatchers.IO) {
        SonarNativeLoader.ensureLoaded()
        lock.withLock {
            if (relayConnected) return@withLock npub
            val identity = loadOrCreateIdentity()
            npub = identity.npub()
            pubkeyHex = identity.pubkeyHex()

            val dbPath = File(marmotDir(), "marmot.sqlite").absolutePath
            val dbKeyHex = loadOrCreateDbKey()
            installCoreLogging(diagnosticsVerbose())

            val connected = SonarNode.connect(identity, relayUrls, dbPath, dbKeyHex)
            val previousNode = node
            node = connected
            relayConnected = true
            installConversationListener()
            previousNode?.close()
            runCatching { connected.retryOutbox() }
            runCatching { connected.publishKeyPackageBackground() }
            npub
        }
    }

    actual fun isRelayConnected(): Boolean = relayConnected

    actual fun myNpub(): String = npub

    actual fun classifyNotificationContent(content: String): SonarNotificationKind {
        SonarNativeLoader.ensureLoaded()
        return uniffi.sonar_ffi.sonarNotificationClassifyContent(content).toCommon()
    }

    actual fun renderNotification(input: SonarNotificationRenderInput): SonarNotificationEnvelope? {
        SonarNativeLoader.ensureLoaded()
        return uniffi.sonar_ffi.sonarRenderNotification(input.toFfi())?.toCommon()
    }

    actual suspend fun chats(): List<SonarChat> = withContext(Dispatchers.IO) {
        val n = node ?: return@withContext emptyList()
        n.groups().map { SonarChat(id = it.idHex, name = it.name, members = it.memberNpubs) }
    }

    actual suspend fun startChat(peer: String): String = withContext(Dispatchers.IO) {
        requireNode().startDm(peer.trim(), "")
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

    actual suspend fun retryMessage(messageId: String): String = withContext(Dispatchers.IO) {
        requireNode().retryMessage(messageId)
    }

    actual suspend fun sendMedia(
        chatId: String,
        data: ByteArray,
        filename: String,
        mime: String,
        caption: String,
        serverUrl: String,
        requestId: String,
    ) = withContext(Dispatchers.IO) {
        val usedNode = requireNode()
        usedNode.sendMediaRetryable(chatId, data, filename, mime, caption, serverUrl, requestId)
        handOffMediaOutboxIfNodeChanged(usedNode)
    }

    actual suspend fun sendMediaMulti(
        chatId: String,
        items: List<AlbumUpload>,
        caption: String,
        serverUrl: String,
        requestId: String,
    ) = withContext(Dispatchers.IO) {
        val usedNode = requireNode()
        usedNode.sendMediaMultiRetryable(
            chatId,
            items.map { uniffi.sonar_ffi.MediaUploadItem(it.bytes, it.filename, it.mime) },
            caption,
            serverUrl,
            requestId,
        )
        handOffMediaOutboxIfNodeChanged(usedNode)
    }

    actual suspend fun sendSticker(
        chatId: String,
        packCoordinate: String,
        shortcode: String,
        plaintextSha256: String,
    ) = withContext(Dispatchers.IO) {
        stickerOperationLock.read {
            requireNode().sendSticker(chatId, packCoordinate, shortcode, plaintextSha256)
        }
    }

    actual suspend fun fetchStickerPack(
        authorPubkeyHex: String,
        identifier: String,
        relayUrls: List<String>,
    ): SonarStickerPack = withContext(Dispatchers.IO) {
        stickerOperationLock.read {
            requireNode().fetchStickerPack(authorPubkeyHex, identifier, relayUrls).toCommon()
        }
    }

    actual suspend fun fetchStickerImage(url: String, expectedSha256: String): ByteArray =
        withContext(Dispatchers.IO) {
            stickerOperationLock.read {
                requireNode().fetchStickerImage(url, expectedSha256)
            }
        }

    actual suspend fun cachedStickerImageForRef(ref: SonarStickerRef): ByteArray? =
        withContext(Dispatchers.IO) {
            stickerOperationLock.read {
                requireNode().cachedStickerImageForRef(
                    ref.packCoordinate,
                    ref.shortcode,
                    ref.plaintextSha256,
                )
            }
        }

    actual suspend fun fetchInstalledPacks(): List<String> =
        withContext(Dispatchers.IO) {
            stickerOperationLock.read {
                installedStickerMutationLock.lock()
                try {
                    requireNode().fetchInstalledPacks()
                } finally {
                    installedStickerMutationLock.unlock()
                }
            }
        }

    actual suspend fun installStickerPack(coordinate: String) =
        withContext(Dispatchers.IO) {
            stickerOperationLock.read {
                installedStickerMutationLock.lock()
                try {
                    requireNode().installStickerPack(coordinate)
                } finally {
                    installedStickerMutationLock.unlock()
                }
            }
        }

    actual suspend fun uninstallStickerPack(coordinate: String) =
        withContext(Dispatchers.IO) {
            stickerOperationLock.read {
                installedStickerMutationLock.lock()
                try {
                    requireNode().uninstallStickerPack(coordinate)
                } finally {
                    installedStickerMutationLock.unlock()
                }
            }
        }

    actual suspend fun fetchMedia(chatId: String, url: String): ByteArray =
        withContext(Dispatchers.IO) { requireNode().fetchMedia(chatId, url) }

    actual suspend fun fetchMediaToFile(
        chatId: String,
        url: String,
        destinationPath: String,
        listener: SonarMediaDownloadListener,
    ): Long = withContext(Dispatchers.IO) {
        requireNode().fetchMediaToFile(
            chatId,
            url,
            destinationPath,
            object : FfiMediaDownloadListener {
                override fun onProgress(bytesReceived: ULong, totalBytes: ULong?) =
                    listener.onProgress(bytesReceived, totalBytes)

                override fun isCancelled(): Boolean = listener.isCancelled()
            },
        ).toLong()
    }

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
        // Core rows are White Noise/Marmot relay messages; send-echo
        // reconciliation and retry eligibility match on this flag.
        viaInternet = true,
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

    actual suspend fun claimedHandle(): String? = withContext(Dispatchers.IO) {
        runCatching { node?.claimedHandle() }.getOrNull()
    }

    actual suspend fun claimHandle(handle: String, offer: String?): String = withContext(Dispatchers.IO) {
        requireNode().claimHandle(handle, offer)
    }

    actual suspend fun resolveHandle(input: String): SonarResolvedHandle? = withContext(Dispatchers.IO) {
        val n = node ?: return@withContext null
        runCatching {
            n.resolveHandle(input).let { SonarResolvedHandle(it.address, it.npub, it.pubkeyHex) }
        }.getOrNull()
    }

    actual suspend fun verifyNip05(address: String, npub: String): Boolean? = withContext(Dispatchers.IO) {
        val n = node ?: return@withContext null
        runCatching { n.verifyNip05(address, npub) }.getOrNull()
    }

    actual fun handleLooksValid(input: String): Boolean =
        runCatching { uniffi.sonar_ffi.handleLooksValid(input) }.getOrDefault(false)

    actual fun defaultHandleDomain(): String =
        runCatching { uniffi.sonar_ffi.defaultHandleDomain() }.getOrDefault("sonarprivacy.xyz")

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

    // Routine heartbeat sync: syncOnce() short-circuits while live subscriptions
    // are active, so a periodic tick does NOT force the batched all-groups fetch.
    // Real wake events call syncForce() below.
    actual suspend fun sync() = withContext(Dispatchers.IO) {
        runCatching { node?.syncOnce() }
        Unit
    }

    // Push-wake / foreground-resume catch-up: bypasses the live short-circuit and
    // runs the batched all-groups gap-recovery fetch. Keep OFF the heartbeat.
    actual suspend fun syncForce() = withContext(Dispatchers.IO) {
        runCatching { node?.syncForce() }
        Unit
    }

    actual suspend fun preferCatchupGroup(mlsGroupIdHex: String?) = withContext(Dispatchers.IO) {
        val value = mlsGroupIdHex?.trim().orEmpty()
        runCatching { node?.preferCatchupGroup(value) }
        Unit
    }

    actual suspend fun ensureSubscriptions() = withContext(Dispatchers.IO) {
        runCatching { node?.ensureSubscriptions() }
        Unit
    }

    actual suspend fun waitForMarmotEvent(timeoutSecs: Long): Boolean =
        withContext(Dispatchers.IO) {
            // Honor the "park up to timeoutSecs" contract even with no node
            // (pre-start / post-wipe): returning instantly would make the host
            // wake loop busy-spin a core until a node is recreated.
            val n = node ?: run {
                delay(timeoutSecs.coerceAtLeast(1) * 1000)
                return@withContext false
            }
            runCatching { n.waitForMarmotEvent(timeoutSecs.toULong()) }.getOrDefault(false)
        }

    actual suspend fun drainPendingMarmot(): Int = withContext(Dispatchers.IO) {
        val n = node ?: return@withContext 0
        runCatching { n.drainPendingMarmot().size }.getOrDefault(0)
    }

    // ── Diagnostics (Settings → Diagnostics) ──

    private fun coreLogDirectory(): File =
        DesktopEnv.file("sonar-marmot/logs/core").apply { mkdirs() }

    private fun diagnosticsVerbose(): Boolean = loadBlob("pref.diagVerbose") == "1"

    private fun installCoreLogging(verbose: Boolean) {
        runCatching {
            SonarNativeLoader.ensureLoaded()
            uniffi.sonar_ffi.setupLogging(coreLogDirectory().absolutePath, verbose)
        }.onFailure { sonarLog("SonarDiag", "core log sink unavailable: $it") }
    }

    actual suspend fun syncStateSnapshotJson(): String? = withContext(Dispatchers.IO) {
        runCatching { node?.syncStateSnapshotJson() }.getOrNull()
    }

    actual fun setDiagnosticsVerbose(verbose: Boolean) {
        // Persist happens via the caller's pref blob; here we swap the core's
        // level filter (setupLogging is idempotent — later calls only reload).
        installCoreLogging(verbose)
    }

    actual suspend fun exportDiagnostics(): Boolean = withContext(Dispatchers.IO) {
        val snapshot = runCatching { node?.syncStateSnapshotJson() }.getOrNull()
        val coreLogs = coreLogDirectory()
            .listFiles { file -> file.name.startsWith("sonar-core") }
            ?.toList().orEmpty()
        val logs = coreLogs + SonarFileLog.files()
        if (logs.isEmpty() && snapshot == null) return@withContext false

        val exportDir = DesktopEnv.file("diagnostics").apply { mkdirs() }
        val stamp = "${System.currentTimeMillis()}-${java.util.UUID.randomUUID().toString().take(8)}"
        val zip = File(exportDir, "sonar-diagnostics-$stamp.zip")
        runCatching {
            java.util.zip.ZipOutputStream(zip.outputStream().buffered()).use { out ->
                for (file in logs) {
                    out.putNextEntry(java.util.zip.ZipEntry(file.name))
                    file.inputStream().use { it.copyTo(out) }
                    out.closeEntry()
                }
                if (snapshot != null) {
                    out.putNextEntry(java.util.zip.ZipEntry("snapshot.json"))
                    out.write(snapshot.toByteArray())
                    out.closeEntry()
                }
            }
        }.onFailure {
            zip.delete()
            return@withContext false
        }

        // No share sheet on desktop: reveal the zip in the file manager.
        runCatching {
            if (java.awt.Desktop.isDesktopSupported()) {
                java.awt.Desktop.getDesktop().open(exportDir)
            }
        }
        true
    }

    actual fun joinedChannels(): List<String> =
        DesktopEnv.getString("channels", "")?.split(",")?.filter { it.isNotBlank() } ?: emptyList()

    actual fun joinChannel(geohash: String) {
        val g = geohash.trim().lowercase()
        if (g.isEmpty()) return
        val set = joinedChannels().toMutableList()
        if (!set.contains(g)) { set.add(g); DesktopEnv.putString("channels", set.joinToString(",")) }
    }

    actual fun leaveChannel(geohash: String) {
        val set = joinedChannels().toMutableList()
        set.remove(geohash.trim().lowercase())
        DesktopEnv.putString("channels", set.joinToString(","))
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

    actual suspend fun sendDirectDm(
        recipientHex: String,
        senderPeerIdHex: String,
        recipientPeerIdHex: String,
        messageId: String,
        text: String,
    ) = withContext(Dispatchers.IO) {
        requireNode().sendDirectDm(recipientHex, senderPeerIdHex, recipientPeerIdHex, messageId, text)
    }

    actual suspend fun drainDirectDms(): List<SonarDirectDm> = withContext(Dispatchers.IO) {
        val n = node ?: return@withContext emptyList()
        runCatching {
            n.drainDirectDms().map {
                SonarDirectDm(
                    eventId = it.eventIdHex,
                    id = it.idHex,
                    senderPubkeyHex = it.senderPubkeyHex,
                    content = it.content,
                    tsSecs = it.createdAtSecs.toLong(),
                )
            }
        }.getOrDefault(emptyList())
    }

    actual suspend fun acknowledgeDirectDms(eventIds: List<String>) = withContext(Dispatchers.IO) {
        val n = node ?: return@withContext
        n.acknowledgeDirectDms(eventIds)
    }

    actual fun nickname(): String = DesktopEnv.getString("nickname", "") ?: ""

    actual fun setNickname(value: String) {
        DesktopEnv.putString("nickname", value.trim())
    }

    actual fun fingerprint(): String {
        var hex = pubkeyHex
        if (hex.isEmpty()) {
            val saved = DesktopEnv.getString("nsec")
            if (saved != null) hex = runCatching { SonarIdentity.import(saved).pubkeyHex() }.getOrDefault("")
        }
        if (hex.isEmpty()) return ""
        return hex.take(32).uppercase().chunked(4).joinToString(" ")
    }

    actual fun identityNsec(): String = DesktopSecrets.get("nsec") ?: ""

    actual fun hasIdentity(): Boolean =
        runCatching {
            SonarNativeLoader.ensureLoaded()
            val saved = DesktopSecrets.get("nsec")?.trim() ?: return@runCatching false
            SonarIdentity.import(saved)
            true
        }
            .getOrDefault(false)

    actual suspend fun prepareIdentityForOnboarding(): String = withContext(Dispatchers.IO) {
        SonarNativeLoader.ensureLoaded()
        lock.withLock {
            if (npub.isNotBlank()) return@withLock npub
            val saved = DesktopSecrets.get("nsec")
            if (saved != null) return@withLock SonarIdentity.import(saved).npub()
            val identity = SonarIdentity.generate()
            DesktopSecrets.put("nsec", identity.nsec())
            identity.npub()
        }
    }

    actual suspend fun validateIdentity(nsec: String): String = withContext(Dispatchers.IO) {
        SonarNativeLoader.ensureLoaded()
        SonarIdentity.import(nsec.trim()).npub()
    }

    actual suspend fun importIdentity(nsec: String): String = withContext(Dispatchers.IO) {
        SonarNativeLoader.ensureLoaded()
        val identity = SonarIdentity.import(nsec.trim())
        lock.withLock {
            stickerOperationLock.write {
                val previousIdentity = DesktopSecrets
                    .get("nsec")
                    ?.let { saved -> runCatching { SonarIdentity.import(saved) }.getOrNull() }
                closeNode()
                val marmotDir = marmotDir()
                try {
                    wipeMarmotStorage(marmotDir)
                    DesktopSecrets.put("nsec", identity.nsec())
                    npub = identity.npub()
                    pubkeyHex = identity.pubkeyHex()
                    npub
                } catch (importError: Throwable) {
                    if (previousIdentity != null) {
                        try {
                            node = connectLocalIdentity(previousIdentity)
                            relayConnected = false
                            npub = previousIdentity.npub()
                            pubkeyHex = previousIdentity.pubkeyHex()
                            installConversationListener()
                        } catch (recoveryError: Throwable) {
                            importError.addSuppressed(recoveryError)
                        }
                    }
                    throw importError
                }
            }
        }
    }

    actual fun onboardingComplete(): Boolean = DesktopEnv.getBoolean("onboarding.complete", false)

    actual fun setOnboardingComplete(value: Boolean) {
        DesktopEnv.putBoolean("onboarding.complete", value)
    }

    actual fun isDark(): Boolean = DesktopEnv.getBoolean("appearance.dark", true)

    actual fun setDark(value: Boolean) {
        DesktopEnv.putBoolean("appearance.dark", value)
    }

    actual fun loadBlob(key: String): String = DesktopEnv.getString("blob.$key", "") ?: ""

    actual fun saveBlob(key: String, value: String) {
        DesktopEnv.putString("blob.$key", value)
    }

    actual suspend fun wipe() = withContext(Dispatchers.IO) {
        lock.withLock {
            stickerOperationLock.write {
                closeNode()
                npub = ""; pubkeyHex = ""
                // marmotDir() covers the DB + diagnostics logs (sonar-marmot/logs);
                // the exported diagnostics zips live in a sibling dir, so drop them
                // too — at verbose level they can contain peer npubs and must not
                // survive a wipe (Account Key Durability / privacy rule).
                val marmotDir = marmotDir()
                val wipeFailure = runCatching { wipeMarmotStorage(marmotDir) }.exceptionOrNull()
                DesktopEnv.file("diagnostics").deleteRecursively()
                DesktopSecrets.clear("nsec", "dbKeyHex")
                DesktopEnv.clear()
                wipeFailure?.let { throw it }
                Unit
            }
        }
    }

    actual suspend fun eraseChats() {
        withContext(Dispatchers.IO) {
            lock.withLock {
                stickerOperationLock.write {
                    closeNode()
                    // Delete ONLY the encrypted Marmot DB — keep nsec, DB key,
                    // nickname and prefs. start() reopens a fresh empty DB with the
                    // SAME identity + key.
                    val marmotDir = marmotDir()
                    wipeMarmotStorage(marmotDir)
                }
            }
        }
        start()
        connectRelays()
    }

    actual suspend fun deleteChat(chatId: String): Unit = withContext(Dispatchers.IO) {
        runCatching { node?.deleteGroup(chatId) }
        Unit
    }

    private fun requireNode(): SonarNode =
        node ?: error("SonarCore not started — call start() first")

    /** Mirror Android/iOS: if a local-only node finishes media after relay-node
     * installation, immediately retry the shared durable outbox on the current
     * relay-backed node. The lifecycle mutex makes the comparison and retry
     * atomic with connect, wipe, and identity replacement. */
    private suspend fun handOffMediaOutboxIfNodeChanged(usedNode: SonarNode) {
        lock.withLock {
            val currentNode = node ?: return@withLock
            if (!mediaOutboxHandoffRequired(usedNode, currentNode, relayConnected)) {
                return@withLock
            }
            runCatching { currentNode.retryOutbox() }
        }
    }

    /** Release the UniFFI/Rust owner before deleting or replacing its SQLite store. */
    private fun closeNode() {
        val previousNode = node
        node = null
        relayConnected = false
        previousNode?.close()
    }

    /** Reopen the previous account locally when a fallible identity wipe fails. */
    private fun connectLocalIdentity(identity: SonarIdentity): SonarNode {
        val dir = marmotDir()
        installCoreLogging(diagnosticsVerbose())
        return SonarNode.connect(
            identity,
            emptyList(),
            File(dir, "marmot.sqlite").absolutePath,
            loadOrCreateDbKey(),
        )
    }

    /** Preserve the FFI wipe tombstone if deleting the cache fails midway. */
    private fun wipeMarmotStorage(marmotDir: File) {
        wipeMarmotDatabase(File(marmotDir, "marmot.sqlite").absolutePath)
        check(marmotDir.deleteRecursively()) { "failed to remove Marmot storage" }
    }

    private fun loadOrCreateIdentity(): SonarIdentity {
        // Stored in the OS keystore (macOS Keychain), NOT plaintext prefs — the nsec
        // also derives the wallet seed. [DesktopSecrets.get] migrates a legacy
        // plaintext nsec in transparently.
        val saved = DesktopSecrets.get("nsec")
        if (saved != null) {
            return SonarIdentity.import(saved)
        }
        if (onboardingComplete()) {
            throw IllegalStateException("Account key missing. Restore from your backup key.")
        }
        val id = SonarIdentity.generate()
        DesktopSecrets.put("nsec", id.nsec())
        return id
    }

    private fun loadOrCreateDbKey(): String {
        DesktopSecrets.get("dbKeyHex")?.let { return it }
        val bytes = ByteArray(32).also { SecureRandom().nextBytes(it) }
        val hex = bytes.joinToString("") { b -> "%02x".format(b) }
        DesktopSecrets.put("dbKeyHex", hex)
        return hex
    }

    // ── Push token registration (MIP-05) ──

    actual suspend fun registerPushToken(platform: String, token: ByteArray, serverNpub: String): Unit =
        withContext(Dispatchers.IO) { requireNode().registerPushToken(platform, token, serverNpub) }

    // ── P2P voice calls — UNAVAILABLE on desktop ──────────────────────────────
    // The iroh call engine (calls-audio: iroh + opus + cpal) is not built into the
    // desktop sonar_ffi dylib, so calls no-op here: callStart throws → the app's
    // ensureCallStarted catches it → callStarted stays false → the call UI is never
    // offered (graceful, like a keyless wallet). Wiring desktop calls (build the
    // host dylib with calls-audio) is the documented follow-up.
    actual suspend fun callStart() { error("calls unavailable on desktop") }
    actual suspend fun callLocalAddress(): String = ""
    actual suspend fun callPlace(callId: String, video: Boolean) {}
    actual suspend fun callIncomingOffer(callId: String, addrB64: String, video: Boolean) {}
    actual suspend fun callAnswer(callId: String, answer: SonarAnswer, addrB64: String) {}
    actual suspend fun callAccept(callId: String) {}
    actual suspend fun callHangup(callId: String) {}
    actual suspend fun callSetMuted(callId: String, muted: Boolean) {}
    actual suspend fun callWaitEvent(timeoutSecs: Long): SonarCallEvent? {
        kotlinx.coroutines.delay(timeoutSecs.coerceIn(1, 30) * 1000) // park, don't busy-spin
        return null
    }
    actual fun callEncodeOffer(callId: String, video: Boolean, addrB64: String, unixSecs: Long): String = ""
    actual fun callEncodeAnswer(callId: String, answer: SonarAnswer, addrB64: String): String = ""
    actual fun callEncodeEnd(callId: String, reason: String): String = ""
    actual fun callParseControl(content: String): SonarCallControl? = null

    private val _conversationChanged = MutableSharedFlow<String>(extraBufferCapacity = 256)
    actual val conversationChanged: SharedFlow<String> = _conversationChanged.asSharedFlow()

    actual fun installConversationListener() {
        val n = node ?: return
        n.setConversationChangeListener(object : uniffi.sonar_ffi.ConversationChangeListener {
            override fun onConversationChanged(groupIdHex: String) {
                _conversationChanged.tryEmit(groupIdHex)
            }
        })
    }
}

private fun SonarNotificationKind.toFfi(): uniffi.sonar_ffi.SonarNotificationKindInfo =
    when (this) {
        SonarNotificationKind.Message -> uniffi.sonar_ffi.SonarNotificationKindInfo.MESSAGE
        SonarNotificationKind.Payment -> uniffi.sonar_ffi.SonarNotificationKindInfo.PAYMENT
        SonarNotificationKind.Call -> uniffi.sonar_ffi.SonarNotificationKindInfo.CALL
        SonarNotificationKind.Invite -> uniffi.sonar_ffi.SonarNotificationKindInfo.INVITE
        SonarNotificationKind.Mention -> uniffi.sonar_ffi.SonarNotificationKindInfo.MENTION
        SonarNotificationKind.Geohash -> uniffi.sonar_ffi.SonarNotificationKindInfo.GEOHASH
        SonarNotificationKind.Network -> uniffi.sonar_ffi.SonarNotificationKindInfo.NETWORK
    }

private fun uniffi.sonar_ffi.SonarNotificationKindInfo.toCommon(): SonarNotificationKind =
    when (this) {
        uniffi.sonar_ffi.SonarNotificationKindInfo.MESSAGE -> SonarNotificationKind.Message
        uniffi.sonar_ffi.SonarNotificationKindInfo.PAYMENT -> SonarNotificationKind.Payment
        uniffi.sonar_ffi.SonarNotificationKindInfo.CALL -> SonarNotificationKind.Call
        uniffi.sonar_ffi.SonarNotificationKindInfo.INVITE -> SonarNotificationKind.Invite
        uniffi.sonar_ffi.SonarNotificationKindInfo.MENTION -> SonarNotificationKind.Mention
        uniffi.sonar_ffi.SonarNotificationKindInfo.GEOHASH -> SonarNotificationKind.Geohash
        uniffi.sonar_ffi.SonarNotificationKindInfo.NETWORK -> SonarNotificationKind.Network
    }

private fun SonarNotificationRenderInput.toFfi(): uniffi.sonar_ffi.SonarNotificationRenderInputInfo =
    uniffi.sonar_ffi.SonarNotificationRenderInputInfo(
        enabled = enabled,
        kindHint = kindHint?.toFfi(),
        conversationTitle = conversationTitle,
        senderName = senderName,
        groupName = groupName,
        contentPreview = contentPreview,
        unreadCount = unreadCount.coerceAtLeast(1L).toULong(),
        showNames = showNames,
        showPreview = showPreview,
        showPaymentAmount = showPaymentAmount,
    )

private fun uniffi.sonar_ffi.SonarNotificationEnvelopeInfo.toCommon(): SonarNotificationEnvelope =
    SonarNotificationEnvelope(
        kind = kind.toCommon(),
        title = title,
        body = body,
        paymentSats = paymentSats?.toLong(),
    )
