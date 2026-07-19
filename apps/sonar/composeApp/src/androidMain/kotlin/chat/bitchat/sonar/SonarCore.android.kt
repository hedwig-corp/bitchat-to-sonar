package chat.bitchat.sonar

import android.content.Context
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
    @Volatile private var lastImportBackupOutcomeValue: AccountBackupRestoreOutcome =
        AccountBackupRestoreOutcome.Missing

    private val ctx: Context get() = AppContextHolder.ctx
    private fun prefs() = ctx.getSharedPreferences("sonar", Context.MODE_PRIVATE)

    actual fun lastImportBackupOutcome(): AccountBackupRestoreOutcome = lastImportBackupOutcomeValue

    actual suspend fun start(): String = withContext(Dispatchers.IO) {
        lock.withLock {
            if (node == null) {
                val identity = loadOrCreateIdentity()
                npub = identity.npub()
                pubkeyHex = identity.pubkeyHex()

                val dir = File(ctx.filesDir, "sonar-marmot").apply { mkdirs() }
                val dbPath = File(dir, "marmot.sqlite").absolutePath
                val dbKeyHex = loadOrCreateDbKey()
                // Finish or discard an interrupted Blossom restore before open.
                runCatching { uniffi.sonar_ffi.reconcileAccountRestore(dbPath, dbKeyHex) }
                    .onFailure {
                        if (uniffi.sonar_ffi.accountRestoreStagingPresent(dbPath)) {
                            throw it
                        }
                    }

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
        lock.withLock {
            if (relayConnected) return@withLock npub
            val identity = loadOrCreateIdentity()
            npub = identity.npub()
            pubkeyHex = identity.pubkeyHex()

            val dir = File(ctx.filesDir, "sonar-marmot").apply { mkdirs() }
            val dbPath = File(dir, "marmot.sqlite").absolutePath
            val dbKeyHex = loadOrCreateDbKey()
            runCatching { uniffi.sonar_ffi.reconcileAccountRestore(dbPath, dbKeyHex) }
                .onFailure {
                    if (uniffi.sonar_ffi.accountRestoreStagingPresent(dbPath)) {
                        throw it
                    }
                }
            installCoreLogging(diagnosticsVerbose())

            // Match iOS MarmotService.connect(): keep the local-only node usable
            // until the relay-backed replacement is fully connected.
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

    actual fun classifyNotificationContent(content: String): SonarNotificationKind =
        uniffi.sonar_ffi.sonarNotificationClassifyContent(content).toCommon()

    actual fun renderNotification(input: SonarNotificationRenderInput): SonarNotificationEnvelope? =
        uniffi.sonar_ffi.sonarRenderNotification(input.toFfi())?.toCommon()

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
    ) = withContext(Dispatchers.IO) {
        requireNode().sendMedia(chatId, data, filename, mime, caption, serverUrl)
    }

    actual suspend fun sendMediaMulti(
        chatId: String,
        items: List<AlbumUpload>,
        caption: String,
        serverUrl: String,
    ) = withContext(Dispatchers.IO) {
        requireNode().sendMediaMulti(
            chatId,
            items.map { uniffi.sonar_ffi.MediaUploadItem(it.bytes, it.filename, it.mime) },
            caption,
            serverUrl,
        )
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
            // The core updates the replaceable installed-pack event with a
            // fetch-modify-publish cycle, so mutations must be FIFO.
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
    // are active, so a periodic tick does NOT force the batched all-groups fetch
    // (that would be wasted battery/relay traffic every interval). Real wake
    // events call syncForce() instead — see below.
    actual suspend fun sync() = withContext(Dispatchers.IO) {
        runCatching { node?.syncOnce() }
        Unit
    }

    // Push-wake / foreground-resume catch-up: syncForce() bypasses the
    // live-subscription short-circuit and runs the batched all-groups fetch so a
    // message that arrived while the relay socket was torn down (longer than the
    // live tail) is fetched deterministically. Mirrors the iOS fix in
    // MarmotChatView.refresh(). Keep this OFF the routine heartbeat.
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
        File(ctx.filesDir, "sonar-marmot/logs/core").apply { mkdirs() }

    private fun diagnosticsVerbose(): Boolean = loadBlob("pref.diagVerbose") == "1"

    private fun installCoreLogging(verbose: Boolean) {
        runCatching {
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

        // The media-share cache dir is already whitelisted for the app's
        // FileProvider (sonar_file_paths.xml), so the zip is shareable as-is.
        val shareDir = File(ctx.cacheDir, "media-share").apply { mkdirs() }
        val stamp = "${System.currentTimeMillis()}-${java.util.UUID.randomUUID().toString().take(8)}"
        val zip = File(shareDir, "sonar-diagnostics-$stamp.zip")
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

        val uri = androidx.core.content.FileProvider.getUriForFile(
            ctx, "${ctx.packageName}.fileprovider", zip
        )
        val send = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
            type = "application/zip"
            putExtra(android.content.Intent.EXTRA_STREAM, uri)
            addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val chooser = android.content.Intent.createChooser(send, "Share diagnostics")
            .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { ctx.startActivity(chooser) }.isSuccess
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

    actual fun nickname(): String = prefs().getString("nickname", "") ?: ""

    actual fun setNickname(value: String) {
        prefs().edit().putString("nickname", value.trim()).apply()
    }

    actual fun fingerprint(): String {
        var hex = pubkeyHex
        if (hex.isEmpty()) {
            val saved = AndroidSecrets.getMigrating("nsec", durable = true)
            if (saved != null) hex = runCatching { SonarIdentity.import(saved).pubkeyHex() }.getOrDefault("")
        }
        if (hex.isEmpty()) return ""
        // First 32 hex chars grouped in 4s, uppercase — a stable key fingerprint.
        return hex.take(32).uppercase().chunked(4).joinToString(" ")
    }

    actual fun identityNsec(): String = AndroidSecrets.getMigrating("nsec", durable = true) ?: ""

    actual fun hasIdentity(): Boolean =
        runCatching {
            val saved = AndroidSecrets.getMigrating("nsec", durable = true)?.trim()
                ?: return@runCatching false
            SonarIdentity.import(saved)
            true
        }
            .getOrDefault(false)

    actual suspend fun prepareIdentityForOnboarding(): String = withContext(Dispatchers.IO) {
        lock.withLock {
            if (npub.isNotBlank()) return@withLock npub
            val saved = AndroidSecrets.getMigrating("nsec", durable = true)
            if (saved != null) return@withLock SonarIdentity.import(saved).npub()
            val identity = SonarIdentity.generate()
            AndroidSecrets.put("nsec", identity.nsec(), durable = true)
            identity.npub()
        }
    }

    actual suspend fun validateIdentity(nsec: String): String = withContext(Dispatchers.IO) {
        SonarIdentity.import(nsec.trim()).npub()
    }

    actual suspend fun importIdentity(nsec: String): String = withContext(Dispatchers.IO) {
        val identity = SonarIdentity.import(nsec.trim())
        lock.withLock {
            stickerOperationLock.write {
                val previousIdentity = AndroidSecrets
                    .getMigrating("nsec", durable = true)
                    ?.let { saved -> runCatching { SonarIdentity.import(saved) }.getOrNull() }
                closeNode()
                val marmotDir = File(ctx.filesDir, "sonar-marmot")
                try {
                    wipeMarmotStorage(marmotDir)
                    AndroidSecrets.put("nsec", identity.nsec(), durable = true)
                    npub = identity.npub()
                    pubkeyHex = identity.pubkeyHex()
                    tryRestoreAccountBackupLocked(identity, marmotDir).also {
                        lastImportBackupOutcomeValue = it
                    }
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


    actual suspend fun backupAccountToBlossom(): String = withContext(Dispatchers.IO) {
        lock.withLock {
            stickerOperationLock.write {
                val nsec = AndroidSecrets.getMigrating("nsec", durable = true)
                    ?: error("no identity to back up")
                val marmotDir = File(ctx.filesDir, "sonar-marmot").apply { mkdirs() }
                val dbPath = File(marmotDir, "marmot.sqlite").absolutePath
                val dbKeyHex = loadOrCreateDbKey()
                // UniFFI close — nulling `node` alone leaves SQLCipher open.
                closeNode()
                val info = uniffi.sonar_ffi.backupAccountToBlossom(nsec, dbPath, dbKeyHex, null)
                "uploaded ${info.size} bytes"
            }
        }
    }

    actual suspend fun tryRestoreAccountBackup(): AccountBackupRestoreOutcome = withContext(Dispatchers.IO) {
        lock.withLock {
            stickerOperationLock.write {
                val nsec = AndroidSecrets.getMigrating("nsec", durable = true)
                    ?: return@write AccountBackupRestoreOutcome.Missing
                val marmotDir = File(ctx.filesDir, "sonar-marmot").apply { mkdirs() }
                tryRestoreAccountBackupLocked(SonarIdentity.import(nsec), marmotDir)
            }
        }
    }

    /** Caller must hold [lock] + sticker write lock; node must be closed. */
    private fun tryRestoreAccountBackupLocked(
        identity: SonarIdentity,
        marmotDir: File,
    ): AccountBackupRestoreOutcome {
        marmotDir.mkdirs()
        val dbPath = File(marmotDir, "marmot.sqlite").absolutePath
        closeNode()
        return try {
            val dbKeyHex = uniffi.sonar_ffi.restoreAccountFromBlossom(identity.nsec(), dbPath, null)
            require(dbKeyHex.matches(Regex("^[0-9a-fA-F]{64}$"))) { "restored db key malformed" }
            try {
                AndroidSecrets.put("dbKeyHex", dbKeyHex, durable = true)
                uniffi.sonar_ffi.commitAccountRestore(dbPath)
                AccountBackupRestoreOutcome.Restored
            } catch (persistError: Throwable) {
                // Clear the key only while staging remains (DB not promoted).
                if (uniffi.sonar_ffi.accountRestoreStagingPresent(dbPath)) {
                    runCatching { uniffi.sonar_ffi.abortAccountRestore(dbPath) }
                    AndroidSecrets.remove("dbKeyHex", durable = true)
                }
                throw persistError
            }
        } catch (e: Throwable) {
            runCatching { uniffi.sonar_ffi.abortAccountRestore(dbPath) }
            // Identity restore still proceeds with a fresh empty DB.
            val msg = e.message.orEmpty()
            if (uniffi.sonar_ffi.isMissingAccountBackupError(msg)) {
                AccountBackupRestoreOutcome.Missing
            } else {
                AccountBackupRestoreOutcome.Failed
            }
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
            stickerOperationLock.write {
                closeNode()
                npub = ""; pubkeyHex = ""
                // Drop the encrypted Marmot DB + all prefs. The diagnostics logs
                // live under sonar-marmot/ (logs/), so this also removes them — at
                // verbose level they can contain peer npubs and must not survive a
                // wipe (Account Key Durability / privacy rule).
                val marmotDir = File(ctx.filesDir, "sonar-marmot")
                val wipeFailure = runCatching { wipeMarmotStorage(marmotDir) }.exceptionOrNull()
                // Exported diagnostics bundles are staged in the FileProvider cache
                // dir (not under sonar-marmot); drop them too — at verbose level
                // they can contain peer npubs.
                File(ctx.cacheDir, "media-share")
                    .listFiles { f -> f.name.startsWith("sonar-diagnostics") }
                    ?.forEach { it.delete() }
                AndroidSecrets.clear()
                prefs().edit().clear().apply()
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
                    // Delete ONLY the encrypted Marmot DB — keep nsec, the DB key,
                    // nickname and every pref. start() (below) reopens a fresh empty
                    // DB with the SAME identity + key.
                    val marmotDir = File(ctx.filesDir, "sonar-marmot")
                    wipeMarmotStorage(marmotDir)
                }
            }
        }
        // Reconnect with the same identity and republish our KeyPackage so peers
        // can still start new secure chats with us.
        start()
        connectRelays()
    }

    actual suspend fun deleteChat(chatId: String): Unit = withContext(Dispatchers.IO) {
        runCatching { node?.deleteGroup(chatId) }
        Unit
    }

    // ── Push token registration (MIP-05) ──

    actual suspend fun registerPushToken(platform: String, token: ByteArray, serverNpub: String): Unit =
        withContext(Dispatchers.IO) { requireNode().registerPushToken(platform, token, serverNpub) }

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

    private fun requireNode(): SonarNode =
        node ?: error("SonarCore not started — call start() first")

    /** Release the UniFFI/Rust owner before deleting or replacing its SQLite store. */
    private fun closeNode() {
        val previousNode = node
        node = null
        relayConnected = false
        previousNode?.close()
    }

    /** Reopen the previous account locally when a fallible identity wipe fails.
     * The existing relay retry loop can replace this node with a connected one. */
    private fun connectLocalIdentity(identity: SonarIdentity): SonarNode {
        val dir = File(ctx.filesDir, "sonar-marmot").apply { mkdirs() }
        installCoreLogging(diagnosticsVerbose())
        return SonarNode.connect(
            identity,
            emptyList(),
            File(dir, "marmot.sqlite").absolutePath,
            loadOrCreateDbKey(),
        )
    }

    /**
     * If the FFI wipe fails, it may have left a durable tombstone beside the
     * cache. Do not recurse through the parent and erase that safety guard.
     */
    private fun wipeMarmotStorage(marmotDir: File) {
        wipeMarmotDatabase(File(marmotDir, "marmot.sqlite").absolutePath)
        check(marmotDir.deleteRecursively()) { "failed to remove Marmot storage" }
        // Match iOS wipeDatabase: drop the host SQLCipher key so a soft-failed
        // Blossom restore cannot reopen a fresh empty DB with a prior key.
        AndroidSecrets.remove("dbKeyHex", durable = true)
    }

    private fun loadOrCreateIdentity(): SonarIdentity {
        val saved = AndroidSecrets.getMigrating("nsec", durable = true)
        if (saved != null) {
            return SonarIdentity.import(saved)
        }
        if (onboardingComplete()) {
            throw IllegalStateException("Account key missing. Restore from your backup key.")
        }
        val id = SonarIdentity.generate()
        AndroidSecrets.put("nsec", id.nsec(), durable = true)
        return id
    }

    private fun loadOrCreateDbKey(): String {
        val existing = AndroidSecrets.getMigrating("dbKeyHex", durable = true)
        if (existing != null) {
            require(existing.matches(Regex("^[0-9a-fA-F]{64}$"))) {
                "database key malformed — refusing to overwrite (would lose history)"
            }
            return existing
        }
        val bytes = ByteArray(32).also { SecureRandom().nextBytes(it) }
        val hex = bytes.joinToString("") { b -> "%02x".format(b) }
        AndroidSecrets.put("dbKeyHex", hex, durable = true)
        return hex
    }
}

// ── Mapping between the generated UniFFI call types and the commonMain types ──

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
