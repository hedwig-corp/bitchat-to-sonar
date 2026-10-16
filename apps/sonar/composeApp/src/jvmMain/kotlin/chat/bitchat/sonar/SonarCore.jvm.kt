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
import uniffi.sonar_ffi.MediaUploadListener as FfiMediaUploadListener
import uniffi.sonar_ffi.SonarNode
import uniffi.sonar_ffi.wipeMarmotDatabase
import java.io.File
import java.security.SecureRandom
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.locks.ReentrantLock
import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlin.concurrent.read
import kotlin.concurrent.write

actual fun sonarReplyUiEnabled(): Boolean = System.getenv("SONAR_REPLY_UI") != "0"

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
    private val relayEpoch = AtomicLong(0)

    /** Serializes {read epoch, write latch} in [connectRelays] against {bump
     *  epoch, clear latch} in [invalidateRelayConnection] — see the Android
     *  actual. Desktop never invalidates on focus loss
     *  ([RelayConnectionPolicy.shouldInvalidateOnBackground] is false here), so
     *  this is parity insurance rather than a live race today. */
    private val relayLatchLock = Any()
    @Volatile private var npub: String = ""
    @Volatile private var pubkeyHex: String = ""
    @Volatile private var lastImportBackupOutcomeValue: AccountBackupRestoreOutcome =
        AccountBackupRestoreOutcome.Missing

    /** The store root: legacy store, registry and logs live here. */
    private fun marmotDir(): File = DesktopEnv.file("sonar-marmot").apply { mkdirs() }

    // ── Accounts (switcher) — mirror of the Android actual ──────────────
    private val registryCacheLock = Any()
    private var registryCache: SonarAccountRegistrySnapshot? = null
    private fun invalidateRegistry() { synchronized(registryCacheLock) { registryCache = null } }

    // Load and publish under one monitor so a load that started before a
    // switch's invalidation cannot publish its stale snapshot after it.
    actual fun accounts(): SonarAccountRegistrySnapshot = synchronized(registryCacheLock) {
        registryCache ?: loadRegistry().also { registryCache = it }
    }

    private fun loadRegistry(): SonarAccountRegistrySnapshot = runCatching {
        SonarNativeLoader.ensureLoaded()
        val info = uniffi.sonar_ffi.accountRegistryLoad(marmotDir().absolutePath)
        val accounts = info.accounts.map { it.toCommon() }
        SonarAccountRegistrySnapshot(
            accounts = accounts,
            active = accounts.firstOrNull { it.pubkeyHex == info.activePubkeyHex },
            maxAccounts = info.maxAccounts.toInt(),
        )
    }.getOrElse { e ->
        sonarLog("Accounts", "registry unreadable — legacy single-account path: ${e.message}")
        SonarAccountRegistrySnapshot(emptyList(), null, DEFAULT_MAX_ACCOUNTS, fault = e.message ?: "unreadable")
    }

    private fun legacyAccount(): SonarAccount = SonarAccount(
        pubkeyHex = "", npub = "", label = null,
        dbPath = File(marmotDir(), "marmot.sqlite").absolutePath,
        secretTag = "", isLegacy = true, isActive = true, lastActiveAt = 0,
    )

    /** The account whose store this process opens. A registry that exists
     *  but cannot be read falls back to the legacy store ONLY on an install
     *  that never had a second account (no `accounts/` directory); with one,
     *  the legacy slot may be another identity than the one the user had
     *  selected, so the open is refused instead (Durability rule 2). */
    private fun activeAccount(): SonarAccount {
        val snap = accounts()
        snap.active?.let { return it }
        if (snap.fault != null && File(marmotDir(), "accounts").isDirectory) {
            throw IllegalStateException("Account list unreadable: ${snap.fault}. Restore it before opening a chat account.")
        }
        return legacyAccount()
    }
    private fun nsecKey(): String = activeAccount().nsecSecretKey
    private fun dbKeyKey(): String = activeAccount().dbKeySecretKey

    private fun marmotDbPath(): String =
        File(activeAccount().dbPath).also { it.parentFile?.mkdirs() }.absolutePath

    private fun registerLegacyIfNeeded(hex: String) {
        val snap = accounts()
        if (snap.fault != null || !snap.isEmpty) return
        runCatching { uniffi.sonar_ffi.accountRegistryRegisterLegacy(marmotDir().absolutePath, hex) }
            .onSuccess { invalidateRegistry(); sonarLog("Accounts", "registered the legacy store in place") }
            .onFailure { sonarLog("Accounts", "legacy registration failed — staying single-account: ${it.message}") }
    }

    /** The key that just opened the active store is the truth: a restore that
     *  replaced this slot's key and died before repointing its row leaves the
     *  row naming the old key. Repoint so switch and add address the right one. */
    private fun healActiveRowIfNeeded(openedHex: String) {
        val snap = accounts()
        val active = snap.active ?: return
        if (snap.fault != null || active.pubkeyHex == openedHex) return
        sonarLog("Accounts", "active row ${active.pubkeyHex.take(8)}… does not match the opened key — repointing")
        runCatching { uniffi.sonar_ffi.accountRegistryReplacePubkey(marmotDir().absolutePath, active.pubkeyHex, openedHex) }
            .onFailure { sonarLog("Accounts", "could not repoint the active row: ${it.message}") }
        invalidateRegistry()
    }

    private fun uniffi.sonar_ffi.AccountInfo.toCommon() = SonarAccount(
        pubkeyHex = pubkeyHex, npub = npub, label = label, dbPath = dbPath,
        secretTag = secretTag, isLegacy = isLegacy, isActive = isActive,
        lastActiveAt = lastActiveAt.toLong(),
    )

    actual suspend fun switchAccount(pubkeyHex: String): String = withContext(Dispatchers.IO) {
        SonarNativeLoader.ensureLoaded()
        lock.withLock { stickerOperationLock.write { switchAccountLocked(pubkeyHex) } }
    }

    private fun switchAccountLocked(target: String): String {
        val previous = activeAccount()
        if (previous.pubkeyHex == target) return npub
        val dataDir = marmotDir().absolutePath
        try {
            closeNode()
            uniffi.sonar_ffi.accountRegistrySetActive(dataDir, target)
            invalidateRegistry()
            openActiveAccountLocally()
            sonarLog("Accounts", "switched to ${target.take(8)}…")
            return npub
        } catch (switchError: Throwable) {
            throw rollBackAccountChange(previous, switchError)
        }
    }

    /** Point the registry back at [previous] and reopen it. The thrown error
     *  carries both failures when the rollback itself fails, so a caller never
     *  reports "reopened the previous account" for a device with no store open. */
    private fun rollBackAccountChange(previous: SonarAccount, cause: Throwable): Throwable {
        sonarLog("Accounts", "account change failed — rolling back: ${cause.message}")
        val problems = mutableListOf(cause.message ?: cause.toString())
        if (previous.pubkeyHex.isNotEmpty()) {
            runCatching { uniffi.sonar_ffi.accountRegistrySetActive(marmotDir().absolutePath, previous.pubkeyHex) }
                .onFailure { problems += "could not restore the previous account pointer: ${it.message}" }
        }
        invalidateRegistry()
        runCatching { openActiveAccountLocally() }
            .onFailure { problems += "the previous account could not be reopened: ${it.message}" }
        return IllegalStateException(problems.joinToString("; "), cause)
    }

    private fun openActiveAccountLocally() {
        val identity = loadOrCreateIdentity()
        node = connectLocalIdentity(identity)
        relayConnected = false
        npub = identity.npub()
        pubkeyHex = identity.pubkeyHex()
        installConversationListener()
    }

    actual suspend fun addAccount(nsec: String?, label: String?): String = withContext(Dispatchers.IO) {
        SonarNativeLoader.ensureLoaded()
        val identity = if (nsec != null) SonarIdentity.import(nsec.trim()) else SonarIdentity.generate()
        lock.withLock {
            stickerOperationLock.write {
                val hex = identity.pubkeyHex()
                if (accounts().accounts.any { it.pubkeyHex == hex }) {
                    lastImportBackupOutcomeValue = AccountBackupRestoreOutcome.Unchanged
                    return@write switchAccountLocked(hex)
                }
                val dataDir = marmotDir().absolutePath
                val entry = uniffi.sonar_ffi.accountRegistryAdd(dataDir, hex, label).toCommon()
                invalidateRegistry()
                // The key lands under the new account's own name BEFORE it
                // becomes active; when it cannot be stored the row goes too.
                try {
                    DesktopSecrets.put(entry.nsecSecretKey, identity.nsec())
                } catch (putError: Throwable) {
                    runCatching { uniffi.sonar_ffi.accountRegistryRemove(dataDir, hex) }
                    invalidateRegistry()
                    throw putError
                }
                val previous = activeAccount()
                try {
                    closeNode()
                    uniffi.sonar_ffi.accountRegistrySetActive(dataDir, hex)
                    invalidateRegistry()
                    npub = identity.npub()
                    pubkeyHex = hex
                    lastImportBackupOutcomeValue =
                        if (nsec != null) tryRestoreAccountBackupLocked(identity, File(entry.dbPath).parentFile!!)
                        else AccountBackupRestoreOutcome.Missing
                    openActiveAccountLocally()
                    npub
                } catch (addError: Throwable) {
                    throw rollBackAccountChange(previous, addError)
                }
            }
        }
    }

    actual suspend fun removeAccount(pubkeyHex: String): Unit = withContext(Dispatchers.IO) {
        SonarNativeLoader.ensureLoaded()
        lock.withLock {
            stickerOperationLock.write {
                check(activeAccount().pubkeyHex != pubkeyHex) { "switch away before removing the active account" }
                val out = synchronized(bookkeepingMonitor) {
                    uniffi.sonar_ffi.accountRegistryRemove(marmotDir().absolutePath, pubkeyHex).also { invalidateRegistry() }
                }
                val removed = out.removed.toCommon()
                seal.get()?.takeIf { it.pubkeyHex == removed.pubkeyHex }?.let { forgetSeal(it) }
                DesktopSecrets.clear(removed.nsecSecretKey, removed.dbKeySecretKey)
            }
        }
    }

    actual fun lastImportBackupOutcome(): AccountBackupRestoreOutcome = lastImportBackupOutcomeValue

    actual suspend fun start(): String = withContext(Dispatchers.IO) {
        SonarNativeLoader.ensureLoaded()
        lock.withLock {
            if (node == null) {
                val identity = loadOrCreateIdentity()
                npub = identity.npub()
                pubkeyHex = identity.pubkeyHex()
                registerLegacyIfNeeded(identity.pubkeyHex())
                healActiveRowIfNeeded(identity.pubkeyHex())

                val dbPath = marmotDbPath()
                val dbKeyHex = loadOrCreateDbKey()
                runCatching { uniffi.sonar_ffi.reconcileAccountRestore(dbPath, dbKeyHex) }
                    .onFailure {
                        if (uniffi.sonar_ffi.accountRestoreStagingPresent(dbPath)) {
                            throw it
                        }
                    }

                // Diagnostics file sink must exist before the node spins up so
                // relay connect/EOSE/watermark events are captured. Non-fatal.
                installCoreLogging(diagnosticsVerbose())
                node = SonarNode.connect(identity, emptyList(), dbPath, dbKeyHex, null)
                relayConnected = false
            }
            npub
        }
    }

    actual suspend fun connectRelays(): String = withContext(Dispatchers.IO) {
        SonarNativeLoader.ensureLoaded()
        lock.withLock {
            if (RelayConnectionPolicy.wouldSkipConnect(relayConnected)) return@withLock npub
            // Snapshot the epoch before the long attach: a mid-attach invalidate
            // bumps it, so the completing connect must not restore the latch.
            val attachEpoch = relayEpoch.get()
            val identity = loadOrCreateIdentity()
            npub = identity.npub()
            pubkeyHex = identity.pubkeyHex()

            val dbPath = marmotDbPath()
            val dbKeyHex = loadOrCreateDbKey()
            runCatching { uniffi.sonar_ffi.reconcileAccountRestore(dbPath, dbKeyHex) }
                .onFailure {
                    if (uniffi.sonar_ffi.accountRestoreStagingPresent(dbPath)) {
                        throw it
                    }
                }
            installCoreLogging(diagnosticsVerbose())

            // suspendLatch = null: the iOS-only R-030 window (a connect holding SQLCipher
            // open when RunningBoard suspends the process) has no analogue here — the
            // Compose hosts have no file-lock kill and no fixed suspend deadline.
            val connected = SonarNode.connect(identity, relayUrls, dbPath, dbKeyHex, null)
            val previousNode = node
            node = connected
            // A mid-attach invalidate wins: keep the latch down so the next
            // connect rebuilds against fresh sockets. Read-and-write under
            // relayLatchLock so an invalidate cannot slip between the epoch read
            // and this assignment.
            synchronized(relayLatchLock) {
                relayConnected =
                    RelayConnectionPolicy.latchAfterAttach(attachEpoch, relayEpoch.get())
            }
            installConversationListener()
            previousNode?.close()
            runCatching { connected.retryOutbox() }
            runCatching { connected.publishKeyPackageBackground() }
            npub
        }
    }

    actual fun invalidateRelayConnection() {
        // Non-suspend: bump the epoch so an attach already inside [lock] cannot
        // restore the latch when it completes, then drop the latch itself. Both
        // steps under relayLatchLock so a completing attach cannot interleave
        // between them and write a stale `true` afterwards.
        synchronized(relayLatchLock) {
            relayEpoch.incrementAndGet()
            relayConnected = RelayConnectionPolicy.afterInvalidate()
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

    actual fun parseMentions(content: String): List<SonarMentionSpan> {
        SonarNativeLoader.ensureLoaded()
        return uniffi.sonar_ffi.sonarParseMentions(content).map { it.toCommon() }
    }

    actual fun mentionsPubkey(content: String, pubkeyHex: String, displayName: String?): Boolean {
        SonarNativeLoader.ensureLoaded()
        return uniffi.sonar_ffi.sonarMentionsPubkey(content, pubkeyHex, displayName)
    }

    actual fun mentionShortSuffix(pubkeyHex: String): String? {
        SonarNativeLoader.ensureLoaded()
        return uniffi.sonar_ffi.sonarMentionShortSuffix(pubkeyHex)
    }

    private fun uniffi.sonar_ffi.SonarMentionSpanInfo.toCommon(): SonarMentionSpan =
        SonarMentionSpan(
            start = startUtf16.toInt(),
            end = endUtf16.toInt(),
            name = name,
            suffixHex4 = suffixHex4,
        )

    actual suspend fun chats(): List<SonarChat> = withContext(Dispatchers.IO) {
        val n = node ?: return@withContext emptyList()
        n.groups().map { SonarChat(id = it.idHex, name = it.name, members = it.memberNpubs) }
    }

    actual suspend fun startChat(peer: String): String = withContext(Dispatchers.IO) {
        requireNode().startDm(peer.trim(), "")
    }

    actual suspend fun ensureNoteToSelf(): String = withContext(Dispatchers.IO) {
        requireNode().ensureNoteToSelf()
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

    actual suspend fun sendReply(
        chatId: String,
        text: String,
        replyToHex: String,
        replyToNpub: String,
        preview: String?,
    ) = withContext(Dispatchers.IO) {
        requireNode().sendTextReply(chatId, text, replyToHex, replyToNpub, preview)
    }

    actual suspend fun sendReaction(
        chatId: String,
        targetIdHex: String,
        targetNpub: String,
        emoji: String,
    ) = withContext(Dispatchers.IO) {
        requireNode().sendReaction(chatId, targetIdHex, targetNpub, emoji)
    }

    actual suspend fun reactionTallies(
        chatId: String,
        targetIdHexes: List<String>,
    ): Map<String, List<SonarReactionTally>> = withContext(Dispatchers.IO) {
        requireNode().reactionTallies(chatId, targetIdHexes).associate { row ->
            row.targetIdHex to row.tallies.map { t ->
                SonarReactionTally(emoji = t.emoji, count = t.count.toInt(), mine = t.mine)
            }
        }
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

    actual suspend fun sendMediaWithProgress(
        chatId: String,
        data: ByteArray,
        filename: String,
        mime: String,
        caption: String,
        clientPendingId: String,
        listener: SonarMediaUploadListener,
        serverUrl: String,
    ) = withContext(Dispatchers.IO) {
        requireNode().sendMediaWithProgress(
            chatId,
            data,
            filename,
            mime,
            caption,
            serverUrl,
            clientPendingId,
            object : FfiMediaUploadListener {
                override fun onProgress(clientPendingId: String, bytesSent: ULong, totalBytes: ULong) =
                    listener.onProgress(clientPendingId, bytesSent, totalBytes)

                override fun isCancelled(): Boolean = listener.isCancelled()
            },
        )
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

    actual suspend fun sendMediaMultiWithProgress(
        chatId: String,
        items: List<AlbumUpload>,
        caption: String,
        clientPendingId: String,
        listener: SonarMediaUploadListener,
        serverUrl: String,
    ) = withContext(Dispatchers.IO) {
        requireNode().sendMediaMultiWithProgress(
            chatId,
            items.map { uniffi.sonar_ffi.MediaUploadItem(it.bytes, it.filename, it.mime) },
            caption,
            serverUrl,
            clientPendingId,
            object : FfiMediaUploadListener {
                override fun onProgress(clientPendingId: String, bytesSent: ULong, totalBytes: ULong) =
                    listener.onProgress(clientPendingId, bytesSent, totalBytes)

                override fun isCancelled(): Boolean = listener.isCancelled()
            },
        )
    }

    actual suspend fun resumePendingMediaUploads(): UInt = withContext(Dispatchers.IO) {
        requireNode().resumePendingMediaUploadsQuiet()
    }

    actual suspend fun cancelAllMediaUploads() = withContext(Dispatchers.IO) {
        runCatching { requireNode().cancelAllMediaUploads() }
        Unit
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
            // NOT `?: emptyList()`: "the store is not readable" and "this
            // conversation has no messages" must not answer the same. Callers
            // read this as local truth and paint it — an empty list from a
            // missing node blanks a transcript that has history on disk.
            requireNode().messagesPage(chatId, limit.toUInt(), offset.toUInt()).map { it.toCommon() }
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

    actual suspend fun updateLocalTimezone(ianaIdentifier: String): Unit = withContext(Dispatchers.IO) {
        node?.updateLocalTimezone(ianaIdentifier)
    }

    actual suspend fun setTimezoneShareGroups(groupIdHexes: List<String>): Unit =
        withContext(Dispatchers.IO) {
            node?.setTimezoneShareGroups(groupIdHexes)
        }

    actual suspend fun peerTimezones(groupIdHexes: List<String>): List<SonarPeerTimezone> =
        withContext(Dispatchers.IO) {
            val n = node ?: return@withContext emptyList()
            n.peerTimezones(groupIdHexes).map {
                SonarPeerTimezone(
                    senderNpub = it.senderNpub,
                    groupIdHex = it.groupIdHex,
                    ianaIdentifier = it.ianaTimezone,
                    updatedAtSecs = it.updatedAtSecs.toLong(),
                )
            }
        }

    actual suspend fun revokeTimezoneShare(groupIdHexes: List<String>): Unit =
        withContext(Dispatchers.IO) {
            node?.revokeTimezoneShare(groupIdHexes)
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
        // Throws rather than answering `emptyList()` with no node: this is the
        // transcript's local read, and both call sites already treat a failure
        // as "unreadable, keep the current rows". An empty list would instead
        // be committed as the conversation's contents (blank chat).
        requireNode().messagesCursorPage(
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
        classification = classification.toCommon(),
        reply = reply?.let { r ->
            SonarReplyRef(
                parentId = r.parentIdHex,
                parentNpub = r.parentNpub,
                // Keep blank blank — QuoteChip resolves from the local parent.
                preview = r.preview.orEmpty(),
            )
        },
        reactions = reactions.map { t ->
            SonarReactionTally(emoji = t.emoji, count = t.count.toInt(), mine = t.mine)
        },
    )

    /** Core-computed classification; the host must not re-derive it from text. */
    private fun uniffi.sonar_ffi.MessageClassInfo.toCommon(): SonarMsgClass = when (this) {
        is uniffi.sonar_ffi.MessageClassInfo.Text -> SonarMsgClass.Text
        is uniffi.sonar_ffi.MessageClassInfo.PayReceipt ->
            // `amountSats` is a core u64 and the UI uses Long: above Long.MAX
            // `toULong().toLong()` wraps to a negative amount instead of
            // failing. Degrade to plain text on overflow, matching iOS
            // (`Int64(exactly:)` guard) and the string decoder it replaces.
            amountSats.toLong().takeIf { it >= 0L }
                ?.let { SonarMsgClass.PayReceipt(paymentId, it) }
                ?: SonarMsgClass.Text
        is uniffi.sonar_ffi.MessageClassInfo.PayDone ->
            SonarMsgClass.PayDone(paymentId, preimageHex)
        is uniffi.sonar_ffi.MessageClassInfo.CallControl -> SonarMsgClass.CallControl
    }

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

    actual suspend fun publishWalletOfferBackup(backup: String): Boolean = withContext(Dispatchers.IO) {
        val n = node ?: return@withContext false
        runCatching { n.publishWalletOfferBackup(backup) }.isSuccess
    }

    actual suspend fun fetchWalletOfferBackups(): List<String>? = withContext(Dispatchers.IO) {
        val n = node ?: return@withContext null
        runCatching { n.fetchWalletOfferBackups() }.getOrNull()
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

    actual suspend fun retryOutbox() = withContext(Dispatchers.IO) {
        runCatching { node?.retryOutbox() }
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
        replyTo: String?,
    ) = withContext(Dispatchers.IO) {
        requireNode().sendDirectDm(recipientHex, senderPeerIdHex, recipientPeerIdHex, messageId, text, replyTo)
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
                    replyTo = it.replyTo,
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
            val saved = DesktopSecrets.get(nsecKey())
            if (saved != null) hex = runCatching { SonarIdentity.import(saved).pubkeyHex() }.getOrDefault("")
        }
        if (hex.isEmpty()) return ""
        return hex.take(32).uppercase().chunked(4).joinToString(" ")
    }

    actual fun identityNsec(): String = DesktopSecrets.get(nsecKey()) ?: ""

    actual fun hasIdentity(): Boolean =
        runCatching {
            SonarNativeLoader.ensureLoaded()
            val saved = DesktopSecrets.get(nsecKey())?.trim() ?: return@runCatching false
            SonarIdentity.import(saved)
            true
        }
            .getOrDefault(false)

    actual suspend fun prepareIdentityForOnboarding(): String = withContext(Dispatchers.IO) {
        SonarNativeLoader.ensureLoaded()
        lock.withLock {
            if (npub.isNotBlank()) return@withLock npub
            val saved = DesktopSecrets.get(nsecKey())
            if (saved != null) return@withLock SonarIdentity.import(saved).npub()
            val identity = SonarIdentity.generate()
            DesktopSecrets.put(nsecKey(), identity.nsec())
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
                    .get(nsecKey())
                    ?.let { saved -> runCatching { SonarIdentity.import(saved) }.getOrNull() }
                // Same guard as Android: re-pasting the signed-in key must not
                // wipe the store and fall back to whatever Blossom last held.
                if (!shouldReplaceAccount(previousIdentity?.npub(), identity.npub())) {
                    sonarLog("Identity", "import matches the current account — keeping local data")
                    npub = identity.npub()
                    pubkeyHex = identity.pubkeyHex()
                    lastImportBackupOutcomeValue = AccountBackupRestoreOutcome.Unchanged
                    return@write npub
                }
                // Already another account on this phone: a switch, never a
                // replacement of the active slot (the host checks this too).
                if (accounts().accounts.any { it.pubkeyHex == identity.pubkeyHex() }) {
                    sonarLog("Identity", "import is a registered account — switching instead of replacing")
                    lastImportBackupOutcomeValue = AccountBackupRestoreOutcome.Unchanged
                    return@write switchAccountLocked(identity.pubkeyHex())
                }
                closeNode()
                val activeStoreDir = File(marmotDbPath()).parentFile!!
                try {
                    // Only the ACTIVE account's store: other accounts and the
                    // registry survive a restore of this one.
                    val replacedHex = activeAccount().pubkeyHex
                    wipeActiveStore()
                    DesktopSecrets.put(nsecKey(), identity.nsec())
                    npub = identity.npub()
                    pubkeyHex = identity.pubkeyHex()
                    tryRestoreAccountBackupLocked(identity, activeStoreDir).also {
                        lastImportBackupOutcomeValue = it
                    }
                    // The row this restore replaced in place now holds the new
                    // key under the same directory and secret names.
                    if (replacedHex.isNotEmpty()) {
                        runCatching {
                            uniffi.sonar_ffi.accountRegistryReplacePubkey(
                                marmotDir().absolutePath, replacedHex, identity.pubkeyHex(),
                            )
                        }.onFailure { sonarLog("Accounts", "could not repoint the restored row: ${it.message}") }
                        invalidateRegistry()
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


    actual suspend fun backupAccountToBlossom(requireNoLiveUiSession: Boolean): String =
        withContext(Dispatchers.IO) {
            try {
                val sealed = sealAccountBackup(requireNoLiveUiSession)
                val status = uploadSealedAccountBackup(sealed)
                runCatching { recordBackupSuccess(sealed.size.toLong()) }
                status
            } catch (t: Throwable) {
                // Mirrors the Android wrapper: an unchanged account is a no-op,
                // and recording it would put a red `last_error` under an
                // account that is perfectly backed up.
                if (!chat.bitchat.sonar.backup.AutoBackupNetworkPolicy.isUnchangedAccount(t)) {
                    runCatching { recordBackupFailure(t.message ?: "backup failed") }
                }
                throw t
            }
        }

    actual suspend fun sealAccountBackup(requireNoLiveUiSession: Boolean): ByteArray =
        withContext(Dispatchers.IO) {
            // Desktop has no WorkManager UI-session gate; param is ignored.
            SonarNativeLoader.ensureLoaded()
            lock.withLock {
                stickerOperationLock.write {
                    val nsec = DesktopSecrets.get(nsecKey()) ?: error("no identity to back up")
                    val dbPath = marmotDbPath()
                    val dbKeyHex = loadOrCreateDbKey()
                    val forPubkeyHex = activeAccount().pubkeyHex
                    closeNode()
                    uniffi.sonar_ffi.sealAccountBackup(nsec, dbPath, dbKeyHex).also {
                        seal.set(SealRecord(forPubkeyHex, nsec, sha256Hex(it)))
                    }
                }
            }
        }

    /** What the last [sealAccountBackup] produced: the account it ran for,
     *  the nsec captured then, and the SHA-256 of the ciphertext. One
     *  immutable record replaced as a whole, so an upload or a bookkeeping
     *  write that captured it keeps a consistent view even when a newer seal
     *  lands meanwhile. Clearing is compare-and-set against the record the
     *  caller holds: a finished upload never erases a newer seal. */
    private class SealRecord(val pubkeyHex: String, val nsec: String, val digest: String)
    private val seal = java.util.concurrent.atomic.AtomicReference<SealRecord?>(null)
    /** The record the most recent [uploadSealedAccountBackup] signed with,
     *  handed to the bookkeeping call that follows it. Bookkeeping must bind
     *  to the upload that completed, not to whatever [seal] holds by then: if
     *  a newer seal landed in between, reading [seal] would credit A's upload
     *  to B and forget B's credential. Callers also serialize seal → upload →
     *  record under their backup mutex; this keeps the core correct without
     *  relying on that. */
    private val uploaded = java.util.concurrent.atomic.AtomicReference<SealRecord?>(null)

    /** The record bookkeeping is for: the completed upload's, else (no upload
     *  happened, e.g. a metered abort right after sealing) the current seal. */
    private fun takeBookkeepingRecord(): SealRecord? = uploaded.getAndSet(null) ?: seal.get()

    private fun sha256Hex(bytes: ByteArray): String =
        java.security.MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    /** Forget a seal-time credential: [record] only, and only while it is
     *  still the current one; `null` forgets whatever is current (wipe). */
    private fun forgetSeal(record: SealRecord?) {
        if (record == null) seal.set(null) else seal.compareAndSet(record, null)
    }

    /** Store whose backup is being recorded: the one the seal ran for, which
     *  is the active one unless a switch happened while the upload was out.
     *  Bookkeeping must land on the account that was uploaded. */
    /** Held across "is the sealed account still registered?" + the FFI write,
     *  and across the registry removal + store deletion, so a removal cannot
     *  land between the lookup and the write (which would recreate the
     *  deleted directory with a stray policy sidecar). A plain monitor: the
     *  record paths are not suspend functions. */
    private val bookkeepingMonitor = Any()

    private fun sealedAccountDbPath(record: SealRecord?): String? {
        val sealed = record?.pubkeyHex ?: return marmotDbPath()
        // The sealed account was removed while the upload was out: there is
        // no store to record against. Never substitute the active account.
        return accounts().accounts.firstOrNull { it.pubkeyHex == sealed }?.dbPath
    }

    actual suspend fun uploadSealedAccountBackup(sealed: ByteArray): String = withContext(Dispatchers.IO) {
        SonarNativeLoader.ensureLoaded()
        // Sign with the key captured at seal time, and ONLY for the ciphertext
        // it was captured for: a switch between seal and upload must never
        // pair A's ciphertext with B's nsec, and there is deliberately no
        // fallback to the active account's key — without a matching seal the
        // caller must seal again.
        val record = seal.get() ?: error("no sealed backup to upload; seal again")
        check(record.digest == sha256Hex(sealed)) {
            "the sealed backup is not the most recent seal; seal again"
        }
        // Set before the call so a failure's bookkeeping binds to it too.
        uploaded.set(record)
        val info = uniffi.sonar_ffi.uploadSealedAccountBackup(record.nsec, sealed, null)
        "uploaded ${info.size} bytes"
    }


    actual fun getBackupPolicy(): BackupPolicySnapshot {
        SonarNativeLoader.ensureLoaded()
        val p = uniffi.sonar_ffi.getBackupPolicy(marmotDbPath())
        return BackupPolicySnapshot(
            enabled = p.enabled,
            dirty = p.dirty,
            lastSuccessAt = p.lastSuccessAt?.toLong(),
            lastAttemptAt = p.lastAttemptAt?.toLong(),
            lastError = p.lastError,
            lastSizeBytes = p.lastSizeBytes?.toLong(),
            lastMessageCount = p.lastMessageCount?.toLong(),
            frequency = p.frequency,
        )
    }

    actual fun setBackupFrequency(frequency: String) {
        SonarNativeLoader.ensureLoaded()
        uniffi.sonar_ffi.setBackupFrequency(marmotDbPath(), frequency)
    }

    actual fun accountStorageBytes(): Long {
        SonarNativeLoader.ensureLoaded()
        return uniffi.sonar_ffi.accountStorageBytes(marmotDbPath()).toLong()
    }

    actual suspend fun previewAccountBackup(): AccountBackupPreview = withContext(Dispatchers.IO) {
        SonarNativeLoader.ensureLoaded()
        val nsec = DesktopSecrets.get(nsecKey()) ?: error("no identity to preview")
        // No lock, no closeNode: the preview never touches the live store. The
        // DB path only places the scratch copy beside the account data.
        val info = uniffi.sonar_ffi.previewAccountBackup(nsec, marmotDbPath(), null)
        AccountBackupPreview(
            conversations = info.conversations.map {
                BackupPreviewConversation(it.name, it.latestContent, it.messageCount.toLong())
            },
            totalMessages = info.totalMessages.toLong(),
            sizeBytes = info.sizeBytes.toLong(),
            uploadedAtSecs = info.uploadedAtSecs.toLong(),
        )
    }

    actual fun setBackupEnabled(enabled: Boolean) {
        SonarNativeLoader.ensureLoaded()
        uniffi.sonar_ffi.setBackupEnabled(marmotDbPath(), enabled)
    }

    actual fun backupIsDue(): Boolean {
        SonarNativeLoader.ensureLoaded()
        return uniffi.sonar_ffi.backupIsDue(marmotDbPath())
    }

    actual fun recordBackupSuccess(sizeBytes: Long?) {
        SonarNativeLoader.ensureLoaded()
        synchronized(bookkeepingMonitor) {
            val record = takeBookkeepingRecord()
            val target = sealedAccountDbPath(record) ?: run {
                sonarLog("Backup", "upload finished for a removed account — not recorded")
                forgetSeal(record)
                return
            }
            // The key is only for the message count and must belong to the same
            // store: a foreign (non-active) target records without a count.
            val dbKeyHex = if (target == marmotDbPath()) runCatching { loadOrCreateDbKey() }.getOrNull() else null
            uniffi.sonar_ffi.recordBackupSuccess(target, sizeBytes?.toULong(), dbKeyHex)
            // The upload this seal was for is done: the credential has no
            // further use. A failed upload keeps it, so the retry of the same
            // ciphertext signs with the right key (see uploadSealedAccountBackup).
            forgetSeal(record)
        }
    }

    actual fun recordBackupFailure(error: String) {
        SonarNativeLoader.ensureLoaded()
        synchronized(bookkeepingMonitor) {
            val record = takeBookkeepingRecord()
            val target = sealedAccountDbPath(record) ?: run {
                sonarLog("Backup", "upload failed for a removed account — not recorded")
                forgetSeal(record)
                return
            }
            uniffi.sonar_ffi.recordBackupFailure(target, error)
        }
    }

    actual suspend fun tryRestoreAccountBackup(): AccountBackupRestoreOutcome = withContext(Dispatchers.IO) {
        SonarNativeLoader.ensureLoaded()
        lock.withLock {
            stickerOperationLock.write {
                val nsec = DesktopSecrets.get(nsecKey())
                    ?: return@write AccountBackupRestoreOutcome.Missing
                tryRestoreAccountBackupLocked(SonarIdentity.import(nsec), File(marmotDbPath()).parentFile!!)
            }
        }
    }

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
                DesktopSecrets.put(dbKeyKey(), dbKeyHex)
                uniffi.sonar_ffi.commitAccountRestore(dbPath)
                AccountBackupRestoreOutcome.Restored
            } catch (persistError: Throwable) {
                if (uniffi.sonar_ffi.accountRestoreStagingPresent(dbPath)) {
                    runCatching { uniffi.sonar_ffi.abortAccountRestore(dbPath) }
                    DesktopSecrets.clear(dbKeyKey())
                }
                throw persistError
            }
        } catch (e: Throwable) {
            runCatching { uniffi.sonar_ffi.abortAccountRestore(dbPath) }
            val msg = e.message.orEmpty()
            if (uniffi.sonar_ffi.isMissingAccountBackupError(msg)) {
                AccountBackupRestoreOutcome.Missing
            } else {
                AccountBackupRestoreOutcome.Failed
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
                // Every account's secret names, read BEFORE anything is torn
                // down or deleted. When the registry cannot be read, the
                // `accounts/<tag>` directory names ARE the tags: never leave
                // a key behind because the list that named it was corrupt.
                val snap = accounts()
                val accountsDir = File(marmotDir(), "accounts")
                val dirTags = if (accountsDir.exists()) {
                    // null here is an I/O failure, not "empty": deleting the
                    // stores would then orphan keys we could not enumerate.
                    // Nothing has been closed or removed yet, so the abort
                    // leaves the account exactly as it was.
                    accountsDir.listFiles()?.filter { it.isDirectory }?.map { it.name }
                        ?: error("cannot list ${accountsDir.path}; wipe aborted before deleting anything")
                } else {
                    emptyList()
                }
                val tags = (snap.accounts.map { it.secretTag } + dirTags).toSet()
                val accountKeys = tags.flatMap { listOf(accountSecretKeyName(NSEC_SECRET_BASE, it), accountSecretKeyName(DB_KEY_SECRET_BASE, it)) }
                closeNode()
                forgetSeal(null)
                uploaded.set(null)
                npub = ""; pubkeyHex = ""
                // marmotDir() covers the DB + diagnostics logs (sonar-marmot/logs);
                // the exported diagnostics zips live in a sibling dir, so drop them
                // too — at verbose level they can contain peer npubs and must not
                // survive a wipe (Account Key Durability / privacy rule).
                // The whole root: every account's store, the registry, logs.
                val wipeFailure = runCatching { wipeMarmotStorage(marmotDir()) }.exceptionOrNull()
                invalidateRegistry()
                DesktopEnv.file("diagnostics").deleteRecursively()
                // EVERY key DesktopSecrets owns, not just the account pair.
                // The mesh Noise key and Ed25519 announce seed used to live in
                // plain prefs, so DesktopEnv.clear() below removed them; once
                // they moved into the keystore that stopped being true, and a
                // surviving seed would sign the NEXT account's 0x53 discovery
                // packet with the OLD key, linking the two accounts for any
                // passive BLE listener. Driven off MANAGED_KEYS so adding a key
                // cannot silently miss the wipe. (Account Key Durability Rule 5.)
                DesktopSecrets.clear(*DesktopSecrets.MANAGED_KEYS.toTypedArray())
                // Per-account names (`nsec.<hex>` / `dbKeyHex.<hex>`) are not in
                // MANAGED_KEYS; the registry listed them (Durability rule 5).
                if (accountKeys.isNotEmpty()) DesktopSecrets.clear(*accountKeys.toTypedArray())
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
                    wipeActiveStore()
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

    /** Release the UniFFI/Rust owner before deleting or replacing its SQLite store. */
    private fun closeNode() {
        val previousNode = node
        node = null
        relayConnected = false
        previousNode?.close()
    }

    /** Reopen the previous account locally when a fallible identity wipe fails. */
    private fun connectLocalIdentity(identity: SonarIdentity): SonarNode {
        val dbPath = marmotDbPath()
        val dbKeyHex = loadOrCreateDbKey()
        runCatching { uniffi.sonar_ffi.reconcileAccountRestore(dbPath, dbKeyHex) }
            .onFailure { if (uniffi.sonar_ffi.accountRestoreStagingPresent(dbPath)) throw it }
        installCoreLogging(diagnosticsVerbose())
        return SonarNode.connect(identity, emptyList(), dbPath, dbKeyHex, null)
    }

    /** Erase-chats / nsec restore: the ACTIVE account's store, sidecars and
     *  DB key only. Other accounts, the registry and the logs survive. */
    private fun wipeActiveStore() {
        wipeMarmotDatabase(marmotDbPath())
        DesktopSecrets.clear(dbKeyKey())
    }

    /** Preserve the FFI wipe tombstone if deleting the cache fails midway. */
    private fun wipeMarmotStorage(marmotDir: File) {
        wipeMarmotDatabase(File(marmotDir, "marmot.sqlite").absolutePath)
        check(marmotDir.deleteRecursively()) { "failed to remove Marmot storage" }
        // Match iOS wipeDatabase: drop the host SQLCipher key so a soft-failed
        // Blossom restore cannot reopen a fresh empty DB with a prior key.
        DesktopSecrets.clear(dbKeyKey())
    }

    private fun loadOrCreateIdentity(): SonarIdentity {
        // Stored in the OS keystore (macOS Keychain), NOT plaintext prefs — the nsec
        // also derives the wallet seed. [DesktopSecrets.get] migrates a legacy
        // plaintext nsec in transparently.
        val saved = DesktopSecrets.get(nsecKey())
        if (saved != null) {
            return SonarIdentity.import(saved)
        }
        if (onboardingComplete()) {
            // Distinguish the two cases now that we can: telling a user to
            // restore from backup because their keyring happened to be locked
            // would push them into an unnecessary (and lossy) recovery.
            throw IllegalStateException(
                if (DesktopSecrets.absenceIsTrustworthy()) {
                    "Account key missing. Restore from your backup key."
                } else {
                    "Account key could not be read: " +
                        (DesktopSecrets.keystoreUnavailableReason() ?: "keystore fault") +
                        ". Unlock your keyring and reopen Sonar; do not restore from backup yet."
                },
            )
        }
        val id = SonarIdentity.generate()
        DesktopSecrets.put(nsecKey(), id.nsec())
        return id
    }

    private fun loadOrCreateDbKey(): String {
        val existing = DesktopSecrets.get(dbKeyKey())
        if (existing != null) {
            require(existing.matches(Regex("^[0-9a-fA-F]{64}$"))) {
                "database key malformed — refusing to overwrite (would lose history)"
            }
            return existing
        }
        // A null here means "no key stored" ONLY if the keystore was actually
        // readable. On a keystore fault it means "could not read", and minting a
        // replacement would overwrite the real SQLCipher key and leave the chat
        // database permanently undecryptable. Same "null means absent"
        // assumption that loadOrCreateIdentity already guards with
        // onboardingComplete().
        check(DesktopSecrets.absenceIsTrustworthy()) {
            "database key unreadable (keystore fault) — refusing to generate a new one, " +
                "which would make existing chats undecryptable"
        }
        // A store with no key is unrecoverable; a fresh key beside it would
        // make the core's open-failure self-heal wipe the history. Surface it.
        val db = File(activeAccount().dbPath)
        check(!(db.isFile && db.length() > 0)) {
            "database key missing for an existing store — refusing to generate a new one"
        }
        val bytes = ByteArray(32).also { SecureRandom().nextBytes(it) }
        val hex = bytes.joinToString("") { b -> "%02x".format(b) }
        DesktopSecrets.put(dbKeyKey(), hex)
        return hex
    }

    // ── Push token registration (MIP-05) ──

    actual suspend fun registerPushToken(platform: String, token: ByteArray, serverNpub: String): Unit =
        withContext(Dispatchers.IO) { requireNode().registerPushToken(platform, token, serverNpub) }

    // ── P2P voice calls — UNAVAILABLE on desktop ──────────────────────────────
    // The iroh call engine (calls-audio: iroh + opus + cpal) is not built into the
    // desktop sonar_ffi dylib, so calls no-op here: callStart throws → the app's
    // ensureCallStarted catches it → callStarted stays false. The UI is kept honest
    // by [callsSupported], not by this comment: it used to say the call UI was
    // "never offered" while the desktop detail rail rendered call buttons anyway.
    // Wiring desktop calls (build the host dylib with calls-audio) is the
    // documented follow-up.
    actual val callsSupported: Boolean = false

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
        SonarNotificationKind.Trill -> uniffi.sonar_ffi.SonarNotificationKindInfo.TRILL
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
        uniffi.sonar_ffi.SonarNotificationKindInfo.TRILL -> SonarNotificationKind.Trill
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
