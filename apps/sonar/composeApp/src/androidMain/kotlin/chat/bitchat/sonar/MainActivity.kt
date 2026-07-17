package chat.bitchat.sonar

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.View
import android.view.ViewTreeObserver
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts

class MainActivity : ComponentActivity() {

    private companion object {
        const val STICKER_BENCHMARK_ENABLED = "sonar_sticker_benchmark"
        const val STICKER_BENCHMARK_AUTHOR = "sonar_sticker_author"
        const val STICKER_BENCHMARK_IDENTIFIER = "sonar_sticker_identifier"
        const val STICKER_BENCHMARK_IMAGE_LIMIT = "sonar_sticker_image_limit"
        const val STICKER_BENCHMARK_IMAGE_OFFSET = "sonar_sticker_image_offset"
        const val STICKER_BENCHMARK_RELAYS = "sonar_sticker_relays"
        const val DEBUG_MESH_DM = "sonar.debug.send_mesh_dm"
        const val DEBUG_MESH_IMAGE = "sonar.debug.send_mesh_image"
        const val DEBUG_MESH_PEER = "sonar.debug.mesh_peer"
        const val DEBUG_MESH_TIMEOUT_MS = 45_000L
        const val DEBUG_MESH_RETRY_MS = 1_000L
        const val DEBUG_MESH_TAG = "SonarBleDebug"
    }

    @Volatile
    private var firstLocalStateReady = false
    private var postFirstDrawStartupScheduled = false
    private val debugHandler = Handler(Looper.getMainLooper())
    private var debugMeshGeneration = 0L

    /** Every runtime permission the app needs, requested together so Android
     *  shows them in one sequence (firing three separate launchers in onCreate
     *  raced and some grants were silently dropped). */
    private val requiredPermissions: Array<String> = buildList {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            add(Manifest.permission.BLUETOOTH_SCAN)
            add(Manifest.permission.BLUETOOTH_ADVERTISE)
            add(Manifest.permission.BLUETOOTH_CONNECT)
        }
        add(Manifest.permission.ACCESS_FINE_LOCATION)
        add(Manifest.permission.ACCESS_COARSE_LOCATION)
        add(Manifest.permission.RECORD_AUDIO) // voice notes
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            add(Manifest.permission.POST_NOTIFICATIONS)
        }
    }.toTypedArray()

    private val permissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
            // Whatever the user granted, (re)try starting the mesh radio.
            startMeshRadio()
        }

    private fun startMeshRadio() {
        MeshRadio.setMeshNickname(SonarCore.nickname())
        val pref = SonarCore.loadBlob("pref.$BLE_DISCOVER_NEW_PEOPLE_PREF")
        val discoverNewPeople = pref.isEmpty() || pref == "1"
        val restricted = BatterySaver.enabled() || !discoverNewPeople
        MeshRadio.setDiscoveryMode(if (restricted) BleDiscoveryMode.KnownOnly else BleDiscoveryMode.Normal)
        MeshRadio.start()
    }

    /** Request any not-yet-granted permission in a single dialog sequence. */
    private fun requestAllPermissions() {
        val missing = requiredPermissions.filter {
            checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) startMeshRadio() else permissionLauncher.launch(missing.toTypedArray())
    }

    private var unlockCb: ((Boolean) -> Unit)? = null
    private val unlockLauncher =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { res ->
            unlockCb?.invoke(res.resultCode == RESULT_OK)
            unlockCb = null
        }

    /** Launch the device-credential (PIN/pattern/biometric) confirm screen. */
    private fun confirmDeviceCredential(onResult: (Boolean) -> Unit) {
        val km = getSystemService(android.app.KeyguardManager::class.java)
        @Suppress("DEPRECATION")
        val intent = km?.createConfirmDeviceCredentialIntent("Unlock Sonar", "Confirm it's you to continue")
        if (intent == null) { onResult(true); return } // no secure lock → nothing to confirm
        unlockCb = onResult
        unlockLauncher.launch(intent)
    }

    /**
     * Delay the activity's first draw—not its creation—until Compose has a
     * coherent local model. Android therefore keeps the native starting window
     * visible and swaps it directly for the hydrated Home screen on every API
     * level we support, without blocking local I/O or relay work on the UI thread.
     */
    private fun deferFirstDrawUntilLocalStateReady() {
        val content = findViewById<View>(android.R.id.content)
        content.viewTreeObserver.addOnPreDrawListener(object : ViewTreeObserver.OnPreDrawListener {
            override fun onPreDraw(): Boolean {
                if (!firstLocalStateReady) return false
                if (content.viewTreeObserver.isAlive) {
                    content.viewTreeObserver.removeOnPreDrawListener(this)
                }
                if (!postFirstDrawStartupScheduled) {
                    postFirstDrawStartupScheduled = true
                    content.post {
                        requestAllPermissions()
                        Thread(::meshNoiseSmokeTest, "sonar-noise-smoke").start()
                    }
                }
                return true
            }
        })
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        deferFirstDrawUntilLocalStateReady()
        ActivityBridge.requestUnlock = { cb -> confirmDeviceCredential(cb) }
        setContent {
            App(
                onFirstLocalStateReady = { firstLocalStateReady = true },
                stickerBenchmarkRequest = stickerBenchmarkRequest(intent),
            )
        }
        handleInviteIntent(intent)
        handleShareIntent(intent)
        handleNotificationIntent(intent)
        maybeDebugNotificationSound(intent)
        maybeDebugMeshSend(intent)
    }

    /** Debug-only: `adb shell am start -n chat.bitchat.sonar/.MainActivity \
     *  -f 0x14000000 --ez sonar.debug.notify_sound true` posts both sounds. */
    private fun maybeDebugNotificationSound(intent: Intent?) {
        if (!BuildConfig.DEBUG) return
        if (intent?.getBooleanExtra("sonar.debug.notify_sound", false) != true) return
        intent.removeExtra("sonar.debug.notify_sound")
        Notifier.ensureChannel()
        val nm = getSystemService(android.app.NotificationManager::class.java)
        nm.cancel(990_001)
        nm.cancel(990_002)
        Notifier.notify(
            id = 990_001,
            title = "Sonar sound test",
            body = "Default / Internet channel",
            sound = SonarNotificationSound.Default,
        )
        window.decorView.postDelayed({
            Notifier.notify(
                id = 990_002,
                title = "Sonar BLE sound test",
                body = "Bluetooth channel",
                sound = SonarNotificationSound.Ble,
            )
        }, 1800)
    }

    /** Explicit Debug-only device benchmark input. It never installs the pack
     * or clears account data; the shared app state only exercises verified
     * metadata/image caches after the normal relay attach completes. */
    private fun stickerBenchmarkRequest(intent: Intent?): StickerBenchmarkRequest? {
        if (!BuildConfig.DEBUG || intent?.getBooleanExtra(STICKER_BENCHMARK_ENABLED, false) != true) {
            return null
        }
        val author = intent.getStringExtra(STICKER_BENCHMARK_AUTHOR)?.trim().orEmpty()
        val identifier = intent.getStringExtra(STICKER_BENCHMARK_IDENTIFIER)?.trim().orEmpty()
        if (author.isEmpty() || identifier.isEmpty()) return null
        return StickerBenchmarkRequest(
            authorPubkeyHex = author,
            identifier = identifier,
            imageLimit = intent.getIntExtra(STICKER_BENCHMARK_IMAGE_LIMIT, 8).coerceIn(1, 20),
            imageOffset = intent.getIntExtra(STICKER_BENCHMARK_IMAGE_OFFSET, 0).coerceAtLeast(0),
            relayUrls = intent.getStringExtra(STICKER_BENCHMARK_RELAYS)
                ?.split(',')
                ?.map(String::trim)
                ?.filter(String::isNotEmpty)
                .orEmpty(),
        )
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleInviteIntent(intent)
        handleShareIntent(intent)
        handleNotificationIntent(intent)
        maybeDebugNotificationSound(intent)
        maybeDebugMeshSend(intent)
    }

    /**
     * Debug-only physical-device seam for deterministic BLE interop runs:
     *
     * `adb shell am start -n chat.bitchat.sonar/.MainActivity -f 0x14000000 \
     *   --es sonar.debug.send_mesh_dm "ble-e2e-<run-id>"`
     *
     * `adb shell am start -n chat.bitchat.sonar/.MainActivity -f 0x14000000 \
     *   --ez sonar.debug.send_mesh_image true --es sonar.debug.mesh_peer <fingerprint-prefix>`
     *
     * The hook waits for a verified Noise route rather than racing discovery,
     * sends to the first live mesh peer, and logs one correlated terminal result.
     * Release builds cannot enter this path.
     */
    private fun maybeDebugMeshSend(intent: Intent?) {
        if (!BuildConfig.DEBUG || intent == null) return
        val text = intent.getStringExtra(DEBUG_MESH_DM)?.takeIf(String::isNotBlank)
        val sendImage = intent.getBooleanExtra(DEBUG_MESH_IMAGE, false)
        val peerPrefix = intent.getStringExtra(DEBUG_MESH_PEER)?.trim()?.lowercase()?.takeIf(String::isNotEmpty)
        if (text == null && !sendImage) return
        intent.removeExtra(DEBUG_MESH_DM)
        intent.removeExtra(DEBUG_MESH_IMAGE)
        intent.removeExtra(DEBUG_MESH_PEER)

        val generation = ++debugMeshGeneration
        val startedAt = SystemClock.elapsedRealtime()
        val runId = "${System.currentTimeMillis()}-$generation"
        android.util.Log.i(
            DEBUG_MESH_TAG,
            "run=$runId waiting kind=${if (sendImage) "image" else "text"} peer=${peerPrefix ?: "any"}",
        )

        fun attempt() {
            if (generation != debugMeshGeneration || isFinishing || isDestroyed) return
            val peer = MeshRadio.peers().firstOrNull { candidate ->
                val fingerprint = candidate.id.removePrefix("mesh:")
                (peerPrefix == null || fingerprint.lowercase().startsWith(peerPrefix)) &&
                    MeshRadio.hasMeshLink(fingerprint)
            }
            if (peer == null) {
                if (SystemClock.elapsedRealtime() - startedAt < DEBUG_MESH_TIMEOUT_MS) {
                    debugHandler.postDelayed(::attempt, DEBUG_MESH_RETRY_MS)
                } else {
                    android.util.Log.e(DEBUG_MESH_TAG, "run=$runId failed reason=no_verified_mesh_peer")
                }
                return
            }

            val peerId = peer.id.removePrefix("mesh:")
            val messageId = "ble-debug-$runId"
            val accepted = if (sendImage) {
                val bytes = debugMeshJpeg(runId)
                MeshRadio.sendMeshMedia(
                    peerId = peerId,
                    messageId = messageId,
                    bytes = bytes,
                    filename = "$messageId.jpg",
                    mimeType = "image/jpeg",
                ).also {
                    android.util.Log.i(
                        DEBUG_MESH_TAG,
                        "run=$runId kind=image peer=${peerId.take(16)} message=$messageId bytes=${bytes.size} accepted=$it",
                    )
                }
            } else {
                MeshRadio.sendMeshDm(peerId, messageId, text.orEmpty()).also {
                    android.util.Log.i(
                        DEBUG_MESH_TAG,
                        "run=$runId kind=text peer=${peerId.take(16)} message=$messageId accepted=$it",
                    )
                }
            }
            if (!accepted) {
                android.util.Log.e(DEBUG_MESH_TAG, "run=$runId failed reason=driver_rejected_send")
            }
        }

        debugHandler.post(::attempt)
    }

    private fun debugMeshJpeg(runId: String): ByteArray {
        val bitmap = android.graphics.Bitmap.createBitmap(240, 240, android.graphics.Bitmap.Config.ARGB_8888)
        val canvas = android.graphics.Canvas(bitmap)
        canvas.drawColor(android.graphics.Color.rgb(22, 38, 56))
        val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
            color = android.graphics.Color.rgb(65, 211, 189)
            textAlign = android.graphics.Paint.Align.CENTER
            textSize = 25f
        }
        canvas.drawText("Sonar BLE", 120f, 105f, paint)
        paint.textSize = 15f
        canvas.drawText(runId.takeLast(18), 120f, 140f, paint)
        return java.io.ByteArrayOutputStream().use { output ->
            bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 85, output)
            bitmap.recycle()
            output.toByteArray()
        }
    }

    private fun handleInviteIntent(intent: Intent?) {
        val uri = intent?.data ?: return
        // Custom scheme carries the token in the last path segment; the https
        // universal link carries it in the fragment (kept off the server). The
        // core normalizes either form, so we just forward the candidate string.
        val candidate = when {
            uri.scheme == "sonar" && uri.host == "invite" -> uri.lastPathSegment
            uri.scheme == "https" && uri.host == JOIN_LINK_HOST -> uri.fragment
            else -> null
        } ?: return
        if (!candidate.contains("sinvite1")) return
        SonarLifecycle.submitInviteLink(candidate)
    }

    private fun handleShareIntent(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND) return
        val text = intent.getStringExtra(Intent.EXTRA_TEXT) ?: return
        SonarLifecycle.submitSharedText(text)
    }

    private fun handleNotificationIntent(intent: Intent?) {
        val chatId = intent?.getStringExtra(SonarNotificationHandoff.EXTRA_CONVERSATION_ID)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: return
        val jumpMessageId = intent.getStringExtra(SonarNotificationHandoff.EXTRA_MESSAGE_ID)
        intent.removeExtra(SonarNotificationHandoff.EXTRA_CONVERSATION_ID)
        intent.removeExtra(SonarNotificationHandoff.EXTRA_MESSAGE_ID)
        SonarLifecycle.submitOpenConversation(chatId, jumpMessageId = jumpMessageId)
    }

    /**
     * Runtime check that the BLE mesh's Noise XX crypto works through the Rust
     * .so on this device (the unit-tested core, exercised over the JNA FFI):
     * two in-process sessions handshake and exchange an encrypted message.
     */
    private fun meshNoiseSmokeTest() {
        try {
            val a = uniffi.sonar_ffi.noiseGenerateKeypair()
            val b = uniffi.sonar_ffi.noiseGenerateKeypair()
            val ini = uniffi.sonar_ffi.SonarNoise.initiator(a.privateHex)
            val res = uniffi.sonar_ffi.SonarNoise.responder(b.privateHex)
            res.readMessage(ini.writeMessage())   // m1
            ini.readMessage(res.writeMessage())    // m2
            res.readMessage(ini.writeMessage())    // m3
            val peerOk = ini.remoteStaticHex() == b.publicHex && res.remoteStaticHex() == a.publicHex
            ini.intoSession(); res.intoSession()
            val ct = ini.encrypt("mesh hello".encodeToByteArray())
            val pt = res.decrypt(ct).decodeToString()
            android.util.Log.i("MeshNoiseSmoke", "ok=${pt == "mesh hello" && peerOk} decrypted=$pt")
        } catch (t: Throwable) {
            android.util.Log.e("MeshNoiseSmoke", "noise FFI failed", t)
        }
    }

    override fun onResume() {
        super.onResume()
        SonarLifecycle.onForeground?.invoke(true)
    }

    override fun onPause() {
        super.onPause()
        SonarLifecycle.onForeground?.invoke(false)
    }

    override fun onDestroy() {
        debugMeshGeneration++
        debugHandler.removeCallbacksAndMessages(null)
        MeshRadio.stop()
        super.onDestroy()
    }
}
