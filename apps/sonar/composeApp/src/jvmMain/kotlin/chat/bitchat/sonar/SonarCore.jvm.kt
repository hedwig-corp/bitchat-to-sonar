package chat.bitchat.sonar

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import uniffi.sonar_ffi.SonarIdentity
import uniffi.sonar_ffi.SonarNode
import java.io.File
import java.security.SecureRandom

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
    )

    private val lock = Mutex()
    private var node: SonarNode? = null
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
        requireNode().startDm(peer.trim(), "")
    }

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

    actual suspend fun fetchMedia(chatId: String, url: String): ByteArray =
        withContext(Dispatchers.IO) { requireNode().fetchMedia(chatId, url) }

    actual suspend fun messages(chatId: String): List<SonarMsg> = withContext(Dispatchers.IO) {
        val n = node ?: return@withContext emptyList()
        n.messages(chatId).map {
            SonarMsg(
                id = it.idHex,
                senderNpub = it.senderNpub,
                content = it.content,
                mine = it.mine,
                tsSecs = it.createdAtSecs.toLong(),
                media = it.media.map { m ->
                    SonarMedia(
                        url = m.url,
                        mimeType = m.mimeType,
                        filename = m.filename,
                        width = m.width?.toInt(),
                        height = m.height?.toInt(),
                        durationMs = m.durationMs?.toLong(),
                    )
                },
            )
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

    actual suspend fun sync() = withContext(Dispatchers.IO) {
        runCatching { node?.syncOnce() }
        Unit
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

    actual fun identityNsec(): String = DesktopEnv.getString("nsec", "") ?: ""

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
            node = null
            npub = ""; pubkeyHex = ""
            marmotDir().deleteRecursively()
            DesktopEnv.clear()
        }
    }

    actual suspend fun eraseChats() {
        withContext(Dispatchers.IO) {
            lock.withLock {
                node = null
                // Delete ONLY the encrypted Marmot DB — keep nsec, DB key,
                // nickname and prefs. start() reopens a fresh empty DB with the
                // SAME identity + key.
                marmotDir().deleteRecursively()
            }
        }
        start()
    }

    actual suspend fun deleteChat(chatId: String): Unit = withContext(Dispatchers.IO) {
        runCatching { node?.deleteGroup(chatId) }
        Unit
    }

    private fun requireNode(): SonarNode =
        node ?: error("SonarCore not started — call start() first")

    private fun loadOrCreateIdentity(): SonarIdentity {
        val saved = DesktopEnv.getString("nsec")
        if (saved != null) {
            runCatching { return SonarIdentity.import(saved) }
        }
        val id = SonarIdentity.generate()
        DesktopEnv.putString("nsec", id.nsec())
        return id
    }

    private fun loadOrCreateDbKey(): String {
        DesktopEnv.getString("dbKeyHex")?.let { return it }
        val bytes = ByteArray(32).also { SecureRandom().nextBytes(it) }
        val hex = bytes.joinToString("") { b -> "%02x".format(b) }
        DesktopEnv.putString("dbKeyHex", hex)
        return hex
    }
}
