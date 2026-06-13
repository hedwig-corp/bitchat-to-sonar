package chat.bitchat.sonar

import android.content.Context
import kotlinx.coroutines.Dispatchers
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
 * every call hops to [Dispatchers.IO]. Identity + DB key persist in prefs
 * (NOTE: plain SharedPreferences for this test build — production must use the
 * Android Keystore / EncryptedSharedPreferences).
 */
actual object SonarCore {

    // Must match the iOS MarmotService relays so the two interop.
    private val relayUrls = listOf(
        "wss://relay.damus.io",
        "wss://nos.lol",
        "wss://relay.primal.net",
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

    actual suspend fun send(chatId: String, text: String) = withContext(Dispatchers.IO) {
        requireNode().sendText(chatId, text)
    }

    actual suspend fun messages(chatId: String): List<SonarMsg> = withContext(Dispatchers.IO) {
        val n = node ?: return@withContext emptyList()
        n.messages(chatId).map {
            SonarMsg(
                id = it.idHex,
                senderNpub = it.senderNpub,
                content = it.content,
                mine = it.mine,
                tsSecs = it.createdAtSecs.toLong(),
            )
        }
    }

    actual suspend fun sync() = withContext(Dispatchers.IO) {
        runCatching { node?.syncOnce() }
        Unit
    }

    actual fun nickname(): String = prefs().getString("nickname", "") ?: ""

    actual fun setNickname(value: String) {
        prefs().edit().putString("nickname", value.trim()).apply()
    }

    actual fun fingerprint(): String {
        var hex = pubkeyHex
        if (hex.isEmpty()) {
            val saved = prefs().getString("nsec", null)
            if (saved != null) hex = runCatching { SonarIdentity.import(saved).pubkeyHex() }.getOrDefault("")
        }
        if (hex.isEmpty()) return ""
        // First 32 hex chars grouped in 4s, uppercase — a stable key fingerprint.
        return hex.take(32).uppercase().chunked(4).joinToString(" ")
    }

    actual fun onboardingComplete(): Boolean = prefs().getBoolean("onboarding.complete", false)

    actual fun setOnboardingComplete(value: Boolean) {
        prefs().edit().putBoolean("onboarding.complete", value).apply()
    }

    actual fun isDark(): Boolean = prefs().getBoolean("appearance.dark", true)

    actual fun setDark(value: Boolean) {
        prefs().edit().putBoolean("appearance.dark", value).apply()
    }

    actual suspend fun wipe() = withContext(Dispatchers.IO) {
        lock.withLock {
            node = null
            npub = ""; pubkeyHex = ""
            // Drop the encrypted Marmot DB + all prefs.
            File(ctx.filesDir, "sonar-marmot").deleteRecursively()
            prefs().edit().clear().apply()
        }
    }

    private fun requireNode(): SonarNode =
        node ?: error("SonarCore not started — call start() first")

    private fun loadOrCreateIdentity(): SonarIdentity {
        val saved = prefs().getString("nsec", null)
        if (saved != null) {
            runCatching { return SonarIdentity.import(saved) }
        }
        val id = SonarIdentity.generate()
        prefs().edit().putString("nsec", id.nsec()).apply()
        return id
    }

    private fun loadOrCreateDbKey(): String {
        prefs().getString("dbKeyHex", null)?.let { return it }
        val bytes = ByteArray(32).also { SecureRandom().nextBytes(it) }
        val hex = bytes.joinToString("") { b -> "%02x".format(b) }
        prefs().edit().putString("dbKeyHex", hex).apply()
        return hex
    }
}
