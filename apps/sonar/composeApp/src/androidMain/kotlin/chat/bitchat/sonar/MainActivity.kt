package chat.bitchat.sonar

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
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
import androidx.core.content.IntentCompat
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

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

    /**
     * Airplane mode (and any manual Bluetooth toggle) powers the adapter down
     * without telling the app: the scan and advertiser die, `scanning` stays
     * true so `MeshRadio.start()` early-returns forever, and the cached
     * `BluetoothLeScanner` is invalidated by the power cycle so the watchdog's
     * restarts fail silently. Without this receiver the radio looks alive but is
     * deaf until the process is killed. Apple gets the equivalent for free from
     * `centralManagerDidUpdateState` (R-006).
     */
    private val adapterStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
            val state = when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
                BluetoothAdapter.STATE_ON -> BleAdapterState.On
                BluetoothAdapter.STATE_OFF -> BleAdapterState.Off
                else -> BleAdapterState.Transitioning
            }
            when (bleAdapterAction(state)) {
                BleAdapterAction.Restart -> startMeshRadio()
                BleAdapterAction.Teardown -> MeshRadio.stop()
                BleAdapterAction.Ignore -> Unit
            }
        }
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
        registerReceiver(
            adapterStateReceiver,
            IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED),
        )
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

    /**
     * System share sheet hand-off. Text and links arrive in EXTRA_TEXT; photos,
     * videos and documents arrive as content:// URIs in EXTRA_STREAM.
     *
     * The URI read grant is scoped to this intent, so the bytes are pulled here
     * rather than lazily from the picker screen — by the time the user chooses
     * a recipient the permission may be gone. The grant is tied to the Activity,
     * not to the calling thread, so the (potentially network-backed, up to 25 MiB)
     * reads run on [Dispatchers.IO] instead of blocking the main thread; a pure
     * text share with no URIs is still submitted synchronously to add no latency.
     */
    private fun handleShareIntent(intent: Intent?) {
        val action = intent?.action
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return

        val text = intent.getStringExtra(Intent.EXTRA_TEXT)?.takeIf { it.isNotBlank() }
        val uris: List<android.net.Uri> = when (action) {
            Intent.ACTION_SEND ->
                listOfNotNull(IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, android.net.Uri::class.java))
            else ->
                IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, android.net.Uri::class.java)
                    ?: emptyList()
        }

        // Consume the payload from the in-process Intent only once the copy has
        // been handed off to SonarLifecycle. Consuming after the hand-off is
        // what makes a cancelled copy retryable: a configuration change can
        // destroy the activity (cancelling the lifecycleScope read) before the
        // extras are cleared, and the recreated activity re-reads the same
        // Intent and retries — whereas clearing up front would lose the share
        // with nothing to resend. This still covers onNewIntent re-delivery of
        // the same Intent and same-process recreation. removeExtra mutates only
        // this in-process Intent, not the task's stored root intent, so a share
        // re-offered after a cold start (process death + task restore) is a
        // known remaining gap. Same pattern as handleNotificationIntent.

        // Pure text share: there is no content:// I/O to do, so submit
        // synchronously and avoid adding any latency before the picker opens.
        if (uris.isEmpty()) {
            if (text == null) return
            SonarLifecycle.submitSharedContent(SharedContent(text, DroppedFiles(emptyList(), 0)))
            intent.removeExtra(Intent.EXTRA_TEXT)
            intent.removeExtra(Intent.EXTRA_STREAM)
            return
        }

        // The content:// URIs can be backed by remote providers (Google Photos,
        // Drive) and total up to 25 MiB, so read them off the main thread to
        // avoid an ANR. The URI read grant is scoped to this Activity, not to
        // the calling thread, so resolving the bytes on Dispatchers.IO stays
        // within the grant.
        // Only the read goes to IO. The submit stays on the main dispatcher
        // because it lands in `handleSharedContent`, which writes Compose state
        // and mutates the navigation stack.
        lifecycleScope.launch {
            val files = withContext(Dispatchers.IO) { readSharedFiles(uris) }
            if (text == null && files.files.isEmpty()) {
                if (files.rejectedCount > 0) {
                    SonarLifecycle.submitSharedContent(SharedContent(null, files))
                    intent.removeExtra(Intent.EXTRA_TEXT)
                    intent.removeExtra(Intent.EXTRA_STREAM)
                }
                return@launch
            }
            SonarLifecycle.submitSharedContent(SharedContent(text, files))
            intent.removeExtra(Intent.EXTRA_TEXT)
            intent.removeExtra(Intent.EXTRA_STREAM)
        }
    }

    /**
     * Copy shared content:// URIs into memory, bounded by the largest cap any
     * send route accepts. The chosen chat's real transport cap is enforced
     * again at send time.
     */
    private fun readSharedFiles(uris: List<android.net.Uri>): DroppedFiles {
        if (uris.isEmpty()) return DroppedFiles(emptyList(), 0)
        val out = ArrayList<DroppedFile>()
        var rejected = maxOf(0, uris.size - MAX_DROPPED_FILES)
        var remaining = MAX_INTERNET_ATTACHMENT_BYTES

        for (uri in uris.take(MAX_DROPPED_FILES)) {
            val bytes = try {
                contentResolver.openInputStream(uri)?.use { readBounded(it, remaining) }
            } catch (t: Throwable) {
                null
            }
            if (bytes == null || bytes.isEmpty()) {
                rejected++
                continue
            }
            remaining -= bytes.size
            val mime = contentResolver.getType(uri) ?: "application/octet-stream"
            out.add(
                DroppedFile(
                    bytes = bytes,
                    filename = encryptedAttachmentFilename(sharedDisplayName(uri, mime)),
                    mime = encryptedAttachmentMime(mime),
                )
            )
        }
        return DroppedFiles(out, rejected)
    }

    /**
     * Read at most [maxBytes] from [stream], returning null if the source is
     * larger so an oversized file is rejected rather than silently truncated.
     *
     * Hand-rolled rather than `InputStream.readNBytes`, which Android only
     * added in API 33 — on minSdk 26 that call compiles and then throws
     * NoSuchMethodError on the device.
     */
    private fun readBounded(stream: java.io.InputStream, maxBytes: Long): ByteArray? {
        val out = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(64 * 1024)
        var total = 0L
        while (true) {
            val read = stream.read(buffer)
            if (read < 0) break
            total += read
            if (total > maxBytes) return null
            out.write(buffer, 0, read)
        }
        return out.toByteArray()
    }

    /** Prefer the provider's display name; fall back to a MIME-derived one. */
    private fun sharedDisplayName(uri: android.net.Uri, mime: String): String {
        val fromProvider = try {
            contentResolver.query(
                uri,
                arrayOf(android.provider.OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0)?.takeIf { it.isNotBlank() } else null
            }
        } catch (t: Throwable) {
            null
        }
        if (fromProvider != null) return fromProvider
        val extension = android.webkit.MimeTypeMap.getSingleton()
            .getExtensionFromMimeType(mime)
            ?.let { ".$it" }
            .orEmpty()
        val stem = when {
            mime.startsWith("image/") -> "photo"
            mime.startsWith("video/") -> "video"
            mime.startsWith("audio/") -> "audio"
            else -> "attachment"
        }
        return "$stem$extension"
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

    override fun onStart() {
        super.onStart()
        SonarLifecycle.appVisible = true
    }

    override fun onResume() {
        super.onResume()
        SonarLifecycle.onForeground?.invoke(true)
    }

    override fun onPause() {
        super.onPause()
        SonarLifecycle.onForeground?.invoke(false)
    }

    override fun onStop() {
        super.onStop()
        SonarLifecycle.appVisible = false
        // onPause also fires for a picker/permission dialog overlay; onStop is
        // the real "not visible" signal. A configuration change (rotation)
        // restarts the activity without suspending sockets.
        if (!isChangingConfigurations) SonarLifecycle.onProcessBackground?.invoke()
    }

    override fun onDestroy() {
        debugMeshGeneration++
        debugHandler.removeCallbacksAndMessages(null)
        runCatching { unregisterReceiver(adapterStateReceiver) }
        MeshRadio.stop()
        super.onDestroy()
    }
}
