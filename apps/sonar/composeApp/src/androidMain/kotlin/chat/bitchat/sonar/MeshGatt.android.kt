package chat.bitchat.sonar

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.os.SystemClock
import chat.bitchat.sonar.BuildConfig
import chat.bitchat.sonar.crypto.Sha256
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import uniffi.sonar_ffi.MeshAnnounceInfo
import uniffi.sonar_ffi.MeshEngineCommand
import uniffi.sonar_ffi.MeshEngineEvent
import uniffi.sonar_ffi.MeshEngineOutput
import uniffi.sonar_ffi.MeshLinkEngine
import uniffi.sonar_ffi.MeshPublicMessage
import uniffi.sonar_ffi.NoiseKeypairHex
import uniffi.sonar_ffi.noiseGenerateKeypair

/**
 * Android BLE **driver** for the Rust mesh link engine.
 *
 * The link state machine — announce/identity handling, dial policy,
 * per-instance links, liveness, Noise session lifecycle, fail-fast sends,
 * relay — lives in `sonar_core::mesh_engine` (one implementation for every
 * platform; see docs/brainstorms/2026-07-17-mesh-link-engine-rust-core.md).
 * This object only translates GATT callbacks into engine events, executes the
 * returned commands against the radio, and keeps the platform flow control
 * that genuinely belongs to Android:
 *
 *  - the one-outstanding-GATT-op-per-connection write queue (descriptor and
 *    characteristic writes share the hardware slot) and its stuck-op recovery
 *    (the stack can accept an op and never deliver its completion callback);
 *  - the 15s tick that drives the engine's heartbeat/liveness;
 *  - `after_ms` command scheduling.
 *
 * Wire behavior is byte-identical to the previous Kotlin implementation; the
 * public surface consumed by [MeshRadio] is unchanged.
 */
object MeshGatt {

    private const val TAG = "MeshGatt"
    private val SERVICE: UUID = UUID.fromString("F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C")
    private val CHAR: UUID = UUID.fromString("A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D")
    // Standard Client Characteristic Configuration descriptor. NB: the segment
    // is 8000, not 0000 — with the wrong UUID Android does not recognize it as
    // the CCC, so notifications never enable and the announce never flows.
    private val CCC: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    private const val TICK_MS = 15_000L
    /** Deadlines mirrored from the engine (it re-checks; these just schedule). */
    private const val CONNECT_ESTABLISH_MS = 5_000L
    private const val ANNOUNCE_TIMEOUT_MS = 6_000L
    private const val OP_STUCK_MS = 10_000L
    private const val MAX_FILE_TRANSFER_BYTES = 1024 * 1024

    private val ctx: Context get() = AppContextHolder.ctx
    private fun manager() = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private fun nowMs(): Long = SystemClock.elapsedRealtime()

    // ── This device's mesh identity (PERSISTED across launches) ──
    // The Noise static key + announce-signing seed are stored via AndroidSecrets
    // so the mesh peerID is stable without leaving private material in plaintext
    // prefs. Deriving these from the Nostr identity is tracked separately.

    /** Noise static keypair (X25519), loaded from secure storage or generated + saved once. */
    private val keypair by lazy {
        val priv = AndroidSecrets.getMigrating("mesh.noise.priv")
        val pub = AndroidSecrets.getMigrating("mesh.noise.pub")
        if (priv != null && pub != null) {
            NoiseKeypairHex(priv, pub)
        } else {
            noiseGenerateKeypair().also {
                AndroidSecrets.put("mesh.noise.priv", it.privateHex)
                AndroidSecrets.put("mesh.noise.pub", it.publicHex)
            }
        }
    }

    /** Ed25519 announce-signing seed (32 bytes, hex), loaded securely or made once. */
    private val ed25519SeedHex by lazy {
        AndroidSecrets.getMigrating("mesh.ed25519.seed") ?: ByteArray(32)
            .also { SecureRandom().nextBytes(it) }.toHex()
            .also { AndroidSecrets.put("mesh.ed25519.seed", it) }
    }

    /** bitchat peerID = SHA256(noise static pubkey)[:8], hex. */
    private val myPeerIdHex by lazy { Sha256.hash(keypair.publicHex.hexToBytes()).copyOf(8).toHex() }

    /** The Rust link state machine. All mesh decisions happen inside it. */
    private val engine: MeshLinkEngine by lazy {
        MeshLinkEngine(keypair.privateHex, keypair.publicHex, ed25519SeedHex, "")
    }

    private var server: BluetoothGattServer? = null
    private var characteristic: BluetoothGattCharacteristic? = null
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())

    // ── Driver-side radio state (no mesh semantics in here) ──
    private val gattByAddr = ConcurrentHashMap<String, BluetoothGatt>()
    /** Mesh characteristic per link key "addr#serviceInstanceId". */
    private val charByKey = ConcurrentHashMap<String, BluetoothGattCharacteristic>()
    private val serverDevices = ConcurrentHashMap<String, BluetoothDevice>()
    /** Devices from scan results / inbound connects, for executing Dial. */
    private val deviceByAddr = ConcurrentHashMap<String, BluetoothDevice>()

    // Listeners (fired from BLE callback threads → concurrent lists). The
    // String identity is the peer's stable FINGERPRINT.
    private val onText = java.util.concurrent.CopyOnWriteArrayList<(String, String, String) -> Unit>()
    private val onDelivery = java.util.concurrent.CopyOnWriteArrayList<(String, String) -> Unit>()
    private val onSonar = java.util.concurrent.CopyOnWriteArrayList<(String, ByteArray) -> Unit>()
    private val onAnnounce = java.util.concurrent.CopyOnWriteArrayList<(String, MeshAnnounceInfo, String) -> Unit>()
    private val onLink = java.util.concurrent.CopyOnWriteArrayList<(String) -> Unit>()
    private val onBroadcast = java.util.concurrent.CopyOnWriteArrayList<(String, MeshPublicMessage) -> Unit>()
    private val onFile = java.util.concurrent.CopyOnWriteArrayList<(String, String, String, String, ByteArray) -> Unit>()
    private val onSendFailure = java.util.concurrent.CopyOnWriteArrayList<(MeshSendFailure) -> Unit>()
    private val onMediaSendFailure = java.util.concurrent.CopyOnWriteArrayList<(MeshMediaSendFailure) -> Unit>()

    private sealed interface OutboundDelivery {
        val attemptId: Long
        val generation: Long
        val privacyEpoch: Long
        val peerId: String
        val messageId: String
        val tsSecs: Long
    }

    private data class TextDelivery(
        override val attemptId: Long,
        override val generation: Long,
        override val privacyEpoch: Long,
        override val peerId: String,
        override val messageId: String,
        val text: String,
        override val tsSecs: Long,
    ) : OutboundDelivery

    private data class MediaDelivery(
        override val attemptId: Long,
        override val generation: Long,
        override val privacyEpoch: Long,
        override val peerId: String,
        override val messageId: String,
        val bytes: ByteArray,
        val filename: String,
        val mimeType: String,
        override val tsSecs: Long,
    ) : OutboundDelivery

    fun addMessageListener(cb: (fingerprint: String, messageId: String, text: String) -> Unit) { onText.add(cb) }
    fun addDeliveryListener(cb: (fingerprint: String, messageId: String) -> Unit) { onDelivery.add(cb) }
    fun addSonarListener(cb: (fingerprint: String, payload: ByteArray) -> Unit) { onSonar.add(cb) }
    /** Fired when a peer's signed announce is received + verified. The third arg
     *  is the peer's stable fingerprint (SHA256 of its noise static pubkey). */
    fun addAnnounceListener(cb: (bleAddr: String, info: MeshAnnounceInfo, fingerprint: String) -> Unit) { onAnnounce.add(cb) }
    fun addLinkListener(cb: (fingerprint: String) -> Unit) { onLink.add(cb) }
    fun addBroadcastListener(cb: (senderFingerprint: String, message: MeshPublicMessage) -> Unit) { onBroadcast.add(cb) }
    fun addSendFailureListener(cb: (MeshSendFailure) -> Unit) { onSendFailure.add(cb) }
    fun addMediaSendFailureListener(cb: (MeshMediaSendFailure) -> Unit) { onMediaSendFailure.add(cb) }
    /** Incoming private file transfers. `fingerprint` is the sender's stable
     *  fingerprint, matching [addMessageListener]. */
    fun addFileListener(cb: (fingerprint: String, messageId: String, filename: String, mime: String, bytes: ByteArray) -> Unit) {
        onFile.add(cb)
    }

    /** Our 8-byte mesh node id (== peerID bytes), advertised for dialer election. */
    fun nodeId(): ByteArray = myPeerIdHex.hexToBytes().copyOf(8)

    fun localPeerIdHex(): String = myPeerIdHex

    /** Dialer election between two node-id-advertising Sonar-Androids (see the
     *  engine's `should_dial_first`); iOS / stock bitchat have no node id and
     *  are dialed immediately by the caller. */
    fun shouldDial(peerNodeId: ByteArray): Boolean = engine.shouldDialFirst(peerNodeId)

    fun setKnownOnlyPeerAllowlist(allowedFingerprints: Set<String>?) {
        transact(requireRunning = false) { engine.setAllowlist(allowedFingerprints?.toList()) }
    }

    fun updateNickname(value: String) {
        transact(requireRunning = false) { engine.setNickname(value.trim(), nowMs()) }
    }

    fun updateSonarPayload(payload: ByteArray?) {
        transact(requireRunning = false) { engine.setSonarPayload(payload?.copyOf(), nowMs()) }
    }

    // ── Lifecycle ──

    /** "The radio is running." Every engine transition is gated on this, and
     *  GATT callbacks arrive on binder threads, so it is set synchronously in
     *  [startServer] — arming it on the handler thread instead dropped any
     *  connect/discovery callback that landed before the handler drained. */
    @Volatile private var tickArmed = false
    /** "The tick timer is posted." Separate from [tickArmed] because this one
     *  exists only to stop two ticks rescheduling each other, which is a
     *  handler-thread concern. */
    @Volatile private var tickScheduled = false
    @Volatile private var requestedStartGeneration = -1L

    private val tick = object : Runnable {
        override fun run() {
            if (!tickArmed) return
            val now = nowMs()
            // Wire timestamps are wall-clock while deadlines are monotonic;
            // keep the engine's offset fresh (±one tick of NTP drift is fine).
            engine.setWallClock(now, System.currentTimeMillis())
            // Un-stick a lost GATT-op completion: the same stack that loses
            // disconnect callbacks can accept a write/CCC op and never call
            // back, freezing that connection's op queue (and any sibling
            // instance still waiting to subscribe).
            //
            // This RESETS the route instead of merely unblocking the queue, and
            // that is required, not defensive: the packet already went through
            // Noise `encrypt`, which consumed a transport nonce. If those bytes
            // never land, the peer's receive counter is permanently behind and
            // every later message on the session fails to authenticate. Draining
            // the next op over a desynchronized session would turn one lost
            // write into a silently dead route. Do not "optimize" this back into
            // a queue nudge.
            for (addr in clientWriting.toList()) {
                val since = opInFlightSinceMs[addr] ?: continue
                if (now - since >= OP_STUCK_MS) {
                    val delivery = clientInFlight[addr]?.delivery
                    android.util.Log.w(TAG, "gatt op stuck ${now - since}ms on $addr — resetting route")
                    if (delivery != null) failClientRoute(addr, delivery)
                    else {
                        disconnectClient(addr)
                        scheduleClientEngineDisconnect(addr)
                    }
                }
            }
            // Same recovery for the server notify slot: a lost
            // onNotificationSent would otherwise freeze that central forever.
            for (addr in serverNotifying.toList()) {
                val since = notifyInFlightSinceMs[addr] ?: continue
                if (now - since >= OP_STUCK_MS) {
                    val delivery = serverInFlight[addr]?.delivery
                    android.util.Log.w(TAG, "server notify stuck ${now - since}ms on $addr — resetting route")
                    if (delivery != null) failServerRoute(addr, delivery)
                    else {
                        cancelServer(addr)
                        scheduleServerEngineDisconnect(addr)
                    }
                }
            }
            // Bound the scan-fed device cache; keep entries with live links.
            if (deviceByAddr.size > 256) {
                deviceByAddr.keys.removeAll {
                    !gattByAddr.containsKey(it) && !serverDevices.containsKey(it)
                }
            }
            transact { engine.onTick(now) }
            if (tickArmed) handler.postDelayed(this, TICK_MS) else tickScheduled = false
        }
    }

    private val armTick = Runnable {
        synchronized(txLock) {
            if (requestedStartGeneration != deliveryGeneration.get() ||
                !tickArmed ||
                tickScheduled
            ) {
                return@Runnable
            }
            tickScheduled = true
        }
        handler.postDelayed(tick, TICK_MS)
    }

    fun startServer() {
        // The tick TIMER is armed on the handler thread (start()/stop() are
        // called off the main looper, and serializing the scheduling on the
        // tick's own looper avoids two ticks rescheduling each other forever).
        // The RUNNING flag is not: it gates every engine transition, and GATT
        // callbacks land on binder threads, so it must be visible before the
        // first callback rather than whenever the handler next drains.
        engine.setWallClock(nowMs(), System.currentTimeMillis())
        synchronized(txLock) {
            requestedStartGeneration = deliveryGeneration.get()
            tickArmed = true
        }
        handler.post(armTick)
        if (server != null) return
        android.util.Log.i(TAG, "MY node id = $myPeerIdHex")
        val mgr = manager() ?: return
        val s = try { mgr.openGattServer(ctx, serverCallback) } catch (_: Throwable) { return } ?: return
        val service = BluetoothGattService(SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        val ch = BluetoothGattCharacteristic(
            CHAR,
            BluetoothGattCharacteristic.PROPERTY_WRITE or
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE or
                BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_WRITE,
        )
        ch.addDescriptor(
            BluetoothGattDescriptor(CCC, BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE)
        )
        service.addCharacteristic(ch)
        s.addService(service)
        server = s
        characteristic = ch
    }

    /** Privacy teardown only. Suppresses every already-accepted delivery so a
     *  failure posted before an erase/wipe cannot hand erased plaintext back to
     *  the router. Deliberately NOT part of [stop]: an ordinary stop still owes
     *  the app its failures. Order-independent with respect to [stop] — whichever
     *  runs first, the epoch check in [reportSendFailures] drops the report. */
    fun discardAcceptedDeliveries() {
        synchronized(txLock) { privacyEpoch.incrementAndGet() }
    }

    fun stop() {
        handler.removeCallbacks(armTick)
        handler.removeCallbacks(tick)
        // Advance the command generation so a delayed WriteLink/NotifyConn cannot
        // inject stale ciphertext into a restarted radio's queue. This does NOT
        // suppress failure reporting: the queues are drained below and those
        // failures still reach the router, because with the engine no longer
        // queuing plaintext, dropping one leaves the row "Sent" with its bytes
        // neither delivered nor re-queued. Only discardAcceptedDeliveries()
        // suppresses reports, and only for an explicit privacy teardown.
        synchronized(txLock) {
            tickArmed = false
            tickScheduled = false
            requestedStartGeneration = -1L
            deliveryGeneration.incrementAndGet()
            engine.reset()
        }
        (gattByAddr.keys + clientWriteQueue.keys + clientInFlight.keys).toSet()
            .forEach(::disconnectClient)
        (serverDevices.keys + serverNotifyQueue.keys + serverInFlight.keys).toSet()
            .forEach(::cancelServer)
        try { server?.close() } catch (_: Throwable) {}
        server = null; characteristic = null
        gattByAddr.clear(); charByKey.clear(); serverDevices.clear(); deviceByAddr.clear()
        // A stuck in-flight flag surviving stop() would permanently block the
        // same address's queue after the next start().
        clientWriteQueue.clear(); clientInFlight.clear(); clientWriting.clear(); opInFlightSinceMs.clear()
        serviceDiscoveryInFlight.clear(); initialDiscoveryRequested.clear()
        serverNotifyQueue.clear(); serverInFlight.clear(); serverNotifying.clear(); notifyInFlightSinceMs.clear()
    }

    // ── Dialing ──

    /** Ask the engine to dial a discovered peer (it owns dedup/backoff/cap). */
    fun connect(device: BluetoothDevice) {
        deviceByAddr[device.address] = device
        transact { engine.onDialRequest(device.address, nowMs()) }
    }

    fun isLinkedAddr(addr: String): Boolean = engine.isLinkedConn(addr)

    fun hasLink(fingerprint: String): Boolean = engine.hasLink(fingerprint)

    fun connectedPeerCount(): Int = engine.connectedCount().toInt()

    // ── App-facing sends (engine decides routes; we execute) ──

    // Sends run inside transact: the Noise encrypt (nonce assignment) and the
    // write-queue enqueue must be one atomic step, or two threads' ciphertexts
    // can invert their nonce order on the wire.

    fun sendTextToPeer(fingerprint: String, messageId: String, text: String): Boolean {
        return transactDelivery(
            delivery = { generation, epoch ->
                TextDelivery(
                    nextDeliveryAttempt.incrementAndGet(), generation, epoch, fingerprint, messageId, text,
                    System.currentTimeMillis() / 1000,
                )
            },
        ) { engine.sendText(fingerprint, messageId, text, nowMs()) } != null
    }

    /** Immediate send for real-time controls. Never queues. */
    fun sendTextToPeerNow(fingerprint: String, messageId: String, text: String): Boolean {
        return transactDelivery(
            delivery = { generation, epoch ->
                TextDelivery(
                    nextDeliveryAttempt.incrementAndGet(), generation, epoch, fingerprint, messageId, text,
                    System.currentTimeMillis() / 1000,
                )
            },
        ) { engine.sendTextNow(fingerprint, messageId, text, nowMs()) } != null
    }

    /** Send a private file transfer to a live peer route (never queued). */
    fun sendFileToPeer(fingerprint: String, messageId: String, bytes: ByteArray, filename: String, mimeType: String): Boolean {
        if (bytes.isEmpty() || bytes.size > MAX_FILE_TRANSFER_BYTES) return false
        val mime = normalizedMime(mimeType, bytes) ?: return false
        val safeName = safeFileName(filename, mime, System.currentTimeMillis())
        val out = transactDelivery(
            delivery = { generation, epoch ->
                MediaDelivery(
                    nextDeliveryAttempt.incrementAndGet(), generation, epoch, fingerprint, messageId,
                    bytes.copyOf(), filename, mime, System.currentTimeMillis() / 1000,
                )
            },
        ) { engine.sendFile(fingerprint, messageId, bytes, safeName, mime, nowMs()) }
        if (BuildConfig.DEBUG && out != null) {
            android.util.Log.i(
                TAG,
                "media enqueue peer=${fingerprint.take(8)} message=${messageId.take(24)} bytes=${bytes.size} ops=${out.commands.size}",
            )
        }
        return out != null
    }

    fun sendDeliveryAck(fingerprint: String, messageId: String): Boolean =
        transact { engine.sendDeliveryAck(fingerprint, messageId, nowMs()) } != null

    /** Broadcast a PUBLIC message (the BLE "Mesh" channel) to every connected
     *  mesh peer. Returns false if no peer is connected. */
    fun broadcastPublic(text: String): Boolean {
        val out = transact { engine.broadcast(text, nowMs()) } ?: return false
        android.util.Log.i(TAG, "broadcast '${text.take(40)}' to ${out.commands.size} peer(s)")
        return true
    }

    // ── Command execution + event dispatch ──

    private val txLock = Any()

    /** Run one engine transition and dispatch its output. The lock spans the
     *  transition AND the command enqueue: engine transitions already
     *  serialize on the FFI mutex, but without covering the enqueue two
     *  threads' Noise ciphertexts could invert their nonce order between
     *  encryption and the write queue (transport nonces must arrive in
     *  sequence). Events fire outside the lock. Reentrant (`synchronized`) so
     *  command handlers may run nested transitions (dial failure paths). */
    private fun transact(
        requireRunning: Boolean = true,
        delivery: OutboundDelivery? = null,
        block: () -> MeshEngineOutput?,
    ): MeshEngineOutput? {
        val out: MeshEngineOutput?
        synchronized(txLock) {
            if (requireRunning && !tickArmed) return null
            out = block()
            out?.let { executeCommands(it, delivery) }
        }
        out?.let { dispatchEvents(it) }
        return out
    }

    /** Capture the privacy generation under the same lock as encryption and
     * queueing, so stop() cannot split generation capture from acceptance. */
    private fun transactDelivery(
        delivery: (Long, Long) -> OutboundDelivery,
        block: () -> MeshEngineOutput?,
    ): MeshEngineOutput? {
        val out: MeshEngineOutput?
        synchronized(txLock) {
            if (!tickArmed) return null
            val acceptedDelivery = delivery(deliveryGeneration.get(), privacyEpoch.get())
            out = block()
            out?.let { executeCommands(it, acceptedDelivery) }
        }
        out?.let { dispatchEvents(it) }
        return out
    }

    private fun executeCommands(out: MeshEngineOutput, delivery: OutboundDelivery? = null) {
        val commandGeneration = delivery?.generation ?: deliveryGeneration.get()
        for (cmd in out.commands) when (cmd) {
            is MeshEngineCommand.Dial -> dial(cmd.conn)
            is MeshEngineCommand.Disconnect -> disconnectClient(cmd.conn)
            is MeshEngineCommand.CancelServer -> cancelServer(cmd.conn)
            is MeshEngineCommand.RefreshInstances -> {
                android.util.Log.i(TAG, "re-discovering services on ${cmd.conn}")
                gattByAddr[cmd.conn]?.let(::discoverServicesOnce)
            }
            is MeshEngineCommand.Subscribe -> subscribe(cmd.conn, cmd.instance)
            is MeshEngineCommand.WriteLink -> {
                val run = Runnable {
                    synchronized(txLock) {
                        // Delayed engine commands may outlive stop(). Serialize
                        // the epoch check with teardown so an old encrypted
                        // packet cannot enter a newly started radio's queue.
                        if (commandGeneration != deliveryGeneration.get()) {
                            return@synchronized
                        }
                        val gatt = gattByAddr[cmd.conn]
                        val ch = charByKey["${cmd.conn}#${cmd.instance}"]
                        if (gatt == null || ch == null) {
                            delivery?.let { failClientRoute(cmd.conn, it) }
                            return@synchronized
                        }
                        writePacket(gatt, ch, cmd.bytes, delivery)
                    }
                }
                if (cmd.afterMs > 0) handler.postDelayed(run, cmd.afterMs) else run.run()
            }
            is MeshEngineCommand.NotifyConn -> {
                val run = Runnable {
                    synchronized(txLock) {
                        if (commandGeneration != deliveryGeneration.get()) {
                            return@synchronized
                        }
                        val device = serverDevices[cmd.conn]
                        if (device == null) {
                            delivery?.let { failServerRoute(cmd.conn, it) }
                            return@synchronized
                        }
                        notify(device, cmd.bytes, delivery)
                    }
                }
                if (cmd.afterMs > 0) handler.postDelayed(run, cmd.afterMs) else run.run()
            }
        }
    }

    private fun dispatchEvents(out: MeshEngineOutput) {
        for (event in out.events) when (event) {
            is MeshEngineEvent.PeerAnnounced -> {
                android.util.Log.i(
                    TAG,
                    "ANNOUNCE '${event.nickname}' peerId=${event.peerIdHex} fp=${event.fingerprint.take(8)}… direct=${event.direct}",
                )
                // Debug-only announce→Radar latency marker (PR #316 / R-008).
                // Parsed with radar_peer_paint by scripts/bench/android-mesh-radar-bench.sh.
                // Nick is URL-encoded so spaces/emoji stay one token for log parsers.
                if (BuildConfig.DEBUG) {
                    val nickToken = java.net.URLEncoder.encode(event.nickname, Charsets.UTF_8.name())
                    android.util.Log.i(
                        "SonarCore",
                        "SONAR_BENCH mesh_announce nick=$nickToken " +
                            "fp=${event.fingerprint.take(8)} direct=${if (event.direct) 1 else 0}",
                    )
                }
                val info = MeshAnnounceInfo(
                    nickname = event.nickname,
                    noisePublicKeyHex = "",
                    signingPublicKeyHex = "",
                    senderIdHex = event.peerIdHex,
                )
                onAnnounce.forEach { it(event.peerIdHex, info, event.fingerprint) }
            }
            is MeshEngineEvent.SonarPayload ->
                onSonar.forEach { it(event.fingerprint, event.payload) }
            is MeshEngineEvent.TextReceived ->
                onText.forEach { it(event.fingerprint, event.messageId, event.content) }
            is MeshEngineEvent.DeliveryReceived -> {
                if (BuildConfig.DEBUG) {
                    android.util.Log.i(
                        TAG,
                        "delivery receipt peer=${event.fingerprint.take(8)} message=${event.messageId.take(24)}",
                    )
                }
                onDelivery.forEach { it(event.fingerprint, event.messageId) }
            }
            is MeshEngineEvent.FileReceived -> {
                val bytes = event.content
                val mime = normalizedMime(event.mimeType, bytes) ?: continue
                val name = safeFileName(event.fileName, mime, event.timestampMs)
                val messageId = event.messageId ?: "${event.transferKey}-file"
                onFile.forEach { it(event.fingerprint, messageId, name, mime, bytes) }
            }
            is MeshEngineEvent.BroadcastReceived -> {
                android.util.Log.i(TAG, "rx broadcast from ${event.fingerprint.take(8)}: ${event.content.take(40)}")
                val pm = MeshPublicMessage(
                    content = event.content,
                    senderIdHex = event.senderIdHex,
                    timestampMs = event.timestampMs.toULong(),
                )
                onBroadcast.forEach { it(event.fingerprint, pm) }
            }
            is MeshEngineEvent.LinkEstablished -> {
                android.util.Log.i(TAG, "✅ Noise link ESTABLISHED fp=${event.fingerprint.take(8)}…")
                onLink.forEach { it(event.fingerprint) }
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun dial(conn: String) {
        val device = deviceByAddr[conn] ?: run {
            android.util.Log.w(TAG, "dial $conn: no cached device")
            transact { engine.onClientConnectFailed(conn) }
            return
        }
        // connectGatt MUST run on the main thread — calling it from a binder
        // thread is a classic cause of status 133 (every dial failing).
        handler.post {
            android.util.Log.i(TAG, "dialing $conn (TRANSPORT_LE)")
            val gatt = runCatching {
                device.connectGatt(ctx, false, clientCallback, BluetoothDevice.TRANSPORT_LE)
            }.getOrNull()
            if (gatt == null) {
                transact { engine.onClientConnectFailed(conn) }
                return@post
            }
            gattByAddr[conn] = gatt
        }
        // Fail fast when a rotated-away address hangs with no callback, and
        // when a connection never produces an announce. The engine re-checks
        // the state at each deadline; these only schedule the checks.
        handler.postDelayed({ transact { engine.onDialDeadline(conn, nowMs()) } }, CONNECT_ESTABLISH_MS)
        handler.postDelayed(
            { transact { engine.onDialDeadline(conn, nowMs()) } },
            CONNECT_ESTABLISH_MS + ANNOUNCE_TIMEOUT_MS,
        )
    }

    /** Client-role teardown only: a server leg the same peer holds toward us
     *  is a separate route and must survive. */
    @SuppressLint("MissingPermission")
    @Synchronized
    private fun disconnectClient(conn: String) {
        val failed = ArrayList<OutboundDelivery>()
        clientInFlight.remove(conn)?.delivery?.let(failed::add)
        clientWriteQueue.remove(conn)?.let { queue ->
            while (true) {
                val op = queue.poll() ?: break
                op.delivery?.let(failed::add)
            }
        }
        gattByAddr.remove(conn)?.let { runCatching { it.disconnect(); it.close() } }
        serviceDiscoveryInFlight.remove(conn); initialDiscoveryRequested.remove(conn)
        charByKey.keys.removeAll { it.startsWith("$conn#") }
        clientWriting.remove(conn); opInFlightSinceMs.remove(conn)
        reportSendFailures(failed)
    }

    /** Server-role teardown only: an outbound client GATT stays untouched. */
    @SuppressLint("MissingPermission")
    @Synchronized
    private fun cancelServer(conn: String) {
        val failed = ArrayList<OutboundDelivery>()
        serverInFlight.remove(conn)?.delivery?.let(failed::add)
        serverNotifyQueue.remove(conn)?.let { queue ->
            while (true) {
                val op = queue.poll() ?: break
                op.delivery?.let(failed::add)
            }
        }
        serverDevices.remove(conn)?.let { device -> runCatching { server?.cancelConnection(device) } }
        serverNotifying.remove(conn); notifyInFlightSinceMs.remove(conn)
        reportSendFailures(failed)
    }

    private fun failClientRoute(conn: String, extra: OutboundDelivery) {
        // Queue the engine transition before exposing the failure to the app.
        // Otherwise the outbox can immediately select the same stale route.
        scheduleClientEngineDisconnect(conn)
        reportSendFailures(listOf(extra))
        disconnectClient(conn)
    }

    private fun failServerRoute(conn: String, extra: OutboundDelivery) {
        scheduleServerEngineDisconnect(conn)
        reportSendFailures(listOf(extra))
        cancelServer(conn)
    }

    /** Never call back into the engine while a GATT queue monitor is held: an
     * app send holds [txLock] while entering that queue, so the reverse order
     * would deadlock a callback against a concurrent send. */
    private fun scheduleClientEngineDisconnect(conn: String) {
        handler.post { transact { engine.onClientDisconnected(conn) } }
    }

    private fun scheduleServerEngineDisconnect(conn: String) {
        handler.post { transact { engine.onServerDisconnected(conn) } }
    }

    @SuppressLint("MissingPermission")
    private fun subscribe(conn: String, instance: Int) {
        val gatt = gattByAddr[conn] ?: return
        val ch = charByKey["$conn#$instance"] ?: return
        gatt.setCharacteristicNotification(ch, true)
        val d = ch.getDescriptor(CCC)
        if (d == null) {
            // No CCC on this instance — we can't receive its notifies, but can
            // still write our announce to its server.
            android.util.Log.i(TAG, "client $conn#$instance: no CCC descriptor → write announce only")
            transact { engine.onSubscribeResult(conn, instance, false, nowMs()) }
        } else {
            subscribeChar(gatt, d)
        }
    }

    // ── GATT client callbacks → engine events ──

    private val clientCallback = object : BluetoothGattCallback() {
        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            val addr = gatt.device.address
            android.util.Log.i(TAG, "client $addr: state=$newState status=$status")
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                if (gattByAddr[addr] !== gatt) {
                    serviceDiscoveryInFlight.remove(addr)
                    initialDiscoveryRequested.remove(addr)
                }
                gattByAddr[addr] = gatt
                transact { engine.onClientConnected(addr, nowMs()) }
                gatt.requestMtu(517)
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                if (status != 0) gatt.close()
                // A late callback from an old, replaced GATT for this address
                // must not tear down a freshly-dialed connection.
                if (gattByAddr[addr] != null && gattByAddr[addr] !== gatt) {
                    runCatching { gatt.close() }
                    return
                }
                disconnectClient(addr)
                transact {
                    if (status != 0) engine.onClientConnectFailed(addr)
                    else engine.onClientDisconnected(addr)
                }
            }
        }

        @SuppressLint("MissingPermission")
        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            val addr = gatt.device.address
            if (gattByAddr[addr] !== gatt || !initialDiscoveryRequested.add(addr)) {
                android.util.Log.i(TAG, "client $addr: duplicate/stale mtu callback ignored")
            } else if (discoverServicesOnce(gatt)) {
                android.util.Log.i(TAG, "client $addr: mtu=$mtu status=$status → discoverServices")
            } else {
                initialDiscoveryRequested.remove(addr)
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            // A peer can expose SEVERAL instances of the mesh service (a Mac
            // running Sonar.app + the bitchat iOS-wrapper registers it twice in
            // the shared GATT database). Every instance is a distinct peer app.
            val addr = gatt.device.address
            if (gattByAddr[addr] !== gatt || !serviceDiscoveryInFlight.remove(addr)) {
                android.util.Log.i(TAG, "client $addr: duplicate/stale services callback ignored")
                return
            }
            if (status != BluetoothGatt.GATT_SUCCESS) {
                android.util.Log.w(TAG, "client $addr: services discovery failed status=$status")
                return
            }
            val chars = gatt.services.filter { it.uuid == SERVICE }.mapNotNull { it.getCharacteristic(CHAR) }
            android.util.Log.i(
                TAG,
                "client $addr: servicesDiscovered status=$status " +
                    "instances=${chars.size} ids=${chars.map { it.service.instanceId }}",
            )
            if (chars.isEmpty()) return
            handler.post {
                for (ch in chars) {
                    charByKey["$addr#${ch.service.instanceId}"] = ch
                }
                transact {
                    engine.onInstancesDiscovered(
                        addr,
                        chars.map { it.service.instanceId },
                        nowMs(),
                    )
                }
            }
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            val addr = gatt.device.address
            clientInFlight.remove(addr)
            opInFlightSinceMs.remove(addr)
            clientWriting.remove(addr)
            val instance = descriptor.characteristic.service.instanceId
            val ok = status == BluetoothGatt.GATT_SUCCESS
            android.util.Log.i(TAG, "client $addr#$instance: notify enabled=$ok (status=$status)")
            // A failed CCC write means no notifications: the engine must not
            // treat the link as subscribed (it would be a silent one-way link
            // until the stale cull).
            transact { engine.onSubscribeResult(addr, instance, ok, nowMs()) }
            pumpClientWrites(addr)
        }

        override fun onCharacteristicWrite(gatt: BluetoothGatt, ch: BluetoothGattCharacteristic, status: Int) {
            // status 0 = GATT_SUCCESS. Either way the slot is now free → drain
            // the next queued op (one outstanding op at a time is the hard
            // limit that was dropping handshake m1s).
            val addr = gatt.device.address
            val completed = clientInFlight.remove(addr)
            opInFlightSinceMs.remove(addr)
            clientWriting.remove(addr)
            if (status != BluetoothGatt.GATT_SUCCESS) {
                val delivery = completed?.delivery
                if (delivery != null) failClientRoute(addr, delivery)
                else {
                    disconnectClient(addr)
                    scheduleClientEngineDisconnect(addr)
                }
            } else {
                if (BuildConfig.DEBUG && completed?.delivery is MediaDelivery) {
                    android.util.Log.i(
                        TAG,
                        "media fragment wrote addr=$addr bytes=${(completed as GattOp.WriteChar).bytes.size} queued=${clientWriteQueue[addr]?.size ?: 0}",
                    )
                }
                pumpClientWrites(addr)
            }
        }

        override fun onCharacteristicChanged(gatt: BluetoothGatt, ch: BluetoothGattCharacteristic, value: ByteArray) {
            // Keep the per-packet rx trace the diagnostics bundle relied on
            // (the engine itself never logs).
            android.util.Log.i(TAG, "rx ${value.size}B ← ${gatt.device.address}#${ch.service.instanceId}")
            transact { engine.onClientRx(gatt.device.address, ch.service.instanceId, value, nowMs()) }
        }

        @Deprecated("compat")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, ch: BluetoothGattCharacteristic) {
            @Suppress("DEPRECATION") val value = ch.value ?: return
            transact { engine.onClientRx(gatt.device.address, ch.service.instanceId, value, nowMs()) }
        }
    }

    // ── GATT server callbacks → engine events ──

    private val serverCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                serverDevices[device.address] = device
                deviceByAddr[device.address] = device
                transact { engine.onServerConnected(device.address, nowMs()) }
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                cancelServer(device.address)
                transact { engine.onServerDisconnected(device.address) }
            }
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            // Slot free → drain the next queued notify (one outstanding at a time).
            val completed = serverInFlight.remove(device.address)
            notifyInFlightSinceMs.remove(device.address)
            serverNotifying.remove(device.address)
            if (status != BluetoothGatt.GATT_SUCCESS) {
                val delivery = completed?.delivery
                if (delivery != null) failServerRoute(device.address, delivery)
                else {
                    cancelServer(device.address)
                    scheduleServerEngineDisconnect(device.address)
                }
            } else {
                pumpServerNotify(device.address)
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice, requestId: Int, descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray,
        ) {
            if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            android.util.Log.i(TAG, "server ${device.address}: central subscribed → discovery burst")
            serverDevices[device.address] = device
            transact { engine.onServerSubscribed(device.address, nowMs()) }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice, requestId: Int, ch: BluetoothGattCharacteristic,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray,
        ) {
            if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            android.util.Log.i(TAG, "rx ${value.size}B ← ${device.address} (server)")
            transact { engine.onServerRx(device.address, value, nowMs()) }
        }
    }

    // ── Characteristic I/O: one padded packet per value, NO length prefix ──

    // Per-connection FIFO of pending GATT operations. Android allows only ONE
    // outstanding GATT op per connection — the next must wait for its
    // completion callback — and CCC descriptor writes share the hardware slot
    // with characteristic writes, so both ride the same queue.
    private sealed interface GattOp {
        val delivery: OutboundDelivery?
        class WriteChar(
            val ch: BluetoothGattCharacteristic,
            val bytes: ByteArray,
            override val delivery: OutboundDelivery? = null,
        ) : GattOp
        class WriteDesc(val desc: BluetoothGattDescriptor) : GattOp {
            override val delivery: OutboundDelivery? get() = null
        }
    }

    private val clientWriteQueue = ConcurrentHashMap<String, java.util.concurrent.ConcurrentLinkedQueue<GattOp>>()
    private val clientWriting = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
    private val clientInFlight = ConcurrentHashMap<String, GattOp>()
    /** Android may deliver duplicate MTU callbacks. Service discovery must be
     * single-flight or every CCC descriptor is enqueued twice, and the second
     * subscription commonly fails with GATT status 1 on multi-instance peers. */
    private val serviceDiscoveryInFlight = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
    private val initialDiscoveryRequested = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
    /** When the in-flight op was issued, for the tick's stuck-op recovery. */
    private val opInFlightSinceMs = ConcurrentHashMap<String, Long>()

    private fun writePacket(
        gatt: BluetoothGatt,
        ch: BluetoothGattCharacteristic,
        packet: ByteArray,
        delivery: OutboundDelivery? = null,
    ) {
        clientWriteQueue.getOrPut(gatt.device.address) { java.util.concurrent.ConcurrentLinkedQueue() }
            .add(GattOp.WriteChar(ch, packet, delivery))
        pumpClientWrites(gatt.device.address)
    }

    /** Queue a CCC-enable write (completion arrives in onDescriptorWrite). */
    private fun subscribeChar(gatt: BluetoothGatt, d: BluetoothGattDescriptor) {
        clientWriteQueue.getOrPut(gatt.device.address) { java.util.concurrent.ConcurrentLinkedQueue() }
            .add(GattOp.WriteDesc(d))
        pumpClientWrites(gatt.device.address)
    }

    @SuppressLint("MissingPermission")
    private fun discoverServicesOnce(gatt: BluetoothGatt): Boolean {
        val addr = gatt.device.address
        if (gattByAddr[addr] !== gatt || !serviceDiscoveryInFlight.add(addr)) return false
        if (gatt.discoverServices()) return true
        serviceDiscoveryInFlight.remove(addr)
        android.util.Log.w(TAG, "client $addr: discoverServices was not accepted")
        return false
    }

    /** Issue the next queued op for [addr] iff none is in flight. */
    @Synchronized
    private fun pumpClientWrites(addr: String) {
        if (clientWriting.contains(addr)) return
        val q = clientWriteQueue[addr] ?: return
        val next = q.poll() ?: return
        val gatt = gattByAddr[addr] ?: run {
            val delivery = next.delivery
            if (delivery != null) failClientRoute(addr, delivery)
            else {
                disconnectClient(addr)
                scheduleClientEngineDisconnect(addr)
            }
            return
        }
        clientWriting.add(addr)
        clientInFlight[addr] = next
        opInFlightSinceMs[addr] = nowMs()
        val accepted = when (next) {
            is GattOp.WriteChar -> issueWrite(gatt, next.ch, next.bytes)
            is GattOp.WriteDesc -> issueDescWrite(gatt, next.desc)
        }
        if (!accepted) {
            // The op wasn't accepted ⇒ its completion callback won't fire;
            // don't stall the queue — drop it and move on.
            android.util.Log.w(TAG, "gatt op not accepted for $addr — skipping")
            clientInFlight.remove(addr)
            opInFlightSinceMs.remove(addr)
            clientWriting.remove(addr)
            val delivery = next.delivery
            if (delivery != null) failClientRoute(addr, delivery)
            else {
                disconnectClient(addr)
                scheduleClientEngineDisconnect(addr)
            }
        }
    }

    /** The actual platform write. Android 13+ (all current Pixels): the legacy
     *  `ch.value = …; writeCharacteristic(ch)` is deprecated and can silently
     *  no-op — use the value-taking API on 33+. */
    @SuppressLint("MissingPermission")
    private fun issueWrite(gatt: BluetoothGatt, ch: BluetoothGattCharacteristic, packet: ByteArray): Boolean =
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            gatt.writeCharacteristic(ch, packet, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) ==
                android.bluetooth.BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION") run { ch.value = packet; gatt.writeCharacteristic(ch) }
        }

    @SuppressLint("MissingPermission")
    private fun issueDescWrite(gatt: BluetoothGatt, d: BluetoothGattDescriptor): Boolean {
        val enable = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        return if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            gatt.writeDescriptor(d, enable) == android.bluetooth.BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION") run { d.value = enable; gatt.writeDescriptor(d) }
        }
    }

    // Server notify queue — same one-outstanding-at-a-time rule as client
    // writes (the next notify must wait for onNotificationSent).
    private data class NotifyOp(val bytes: ByteArray, val delivery: OutboundDelivery? = null)
    private val serverNotifyQueue = ConcurrentHashMap<String, java.util.concurrent.ConcurrentLinkedQueue<NotifyOp>>()
    private val serverNotifying = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
    private val serverInFlight = ConcurrentHashMap<String, NotifyOp>()
    /** When the in-flight notify was issued, for the tick's stuck recovery. */
    private val notifyInFlightSinceMs = ConcurrentHashMap<String, Long>()

    private fun notify(device: BluetoothDevice, packet: ByteArray, delivery: OutboundDelivery? = null) {
        serverNotifyQueue.getOrPut(device.address) { java.util.concurrent.ConcurrentLinkedQueue() }
            .add(NotifyOp(packet, delivery))
        pumpServerNotify(device.address)
    }

    @Synchronized
    private fun pumpServerNotify(addr: String) {
        if (serverNotifying.contains(addr)) return
        val q = serverNotifyQueue[addr] ?: return
        val next = q.poll() ?: return
        val s = server ?: run { resetMissingServerRoute(addr, next.delivery); return }
        val ch = characteristic ?: run { resetMissingServerRoute(addr, next.delivery); return }
        val device = serverDevices[addr] ?: run { resetMissingServerRoute(addr, next.delivery); return }
        serverNotifying.add(addr)
        serverInFlight[addr] = next
        notifyInFlightSinceMs[addr] = nowMs()
        if (!issueNotify(s, device, ch, next.bytes)) {
            serverInFlight.remove(addr)
            notifyInFlightSinceMs.remove(addr)
            serverNotifying.remove(addr)
            resetMissingServerRoute(addr, next.delivery)
        }
    }

    private fun resetMissingServerRoute(addr: String, delivery: OutboundDelivery?) {
        if (delivery != null) failServerRoute(addr, delivery)
        else {
            cancelServer(addr)
            scheduleServerEngineDisconnect(addr)
        }
    }

    private val nextDeliveryAttempt = java.util.concurrent.atomic.AtomicLong()
    /** Incremented by [stop] so delayed callbacks cannot escape a completed
     * radio lifecycle and resurrect app-owned plaintext after erase/wipe. */
    private val deliveryGeneration = java.util.concurrent.atomic.AtomicLong()
    /** Separate from [deliveryGeneration] because the two answer different
     * questions. [deliveryGeneration] must advance on EVERY [stop] so a delayed
     * GATT command cannot inject stale ciphertext into a restarted radio's queue.
     * Whether a failure may still be handed to the app is a different question:
     * an ordinary stop (`MainActivity.onDestroy`) still owes the router its
     * failures — the engine no longer queues, so dropping one leaves the row
     * "Sent" with its plaintext neither delivered nor re-queued. Only an explicit
     * privacy discard may suppress them, so only that advances this. */
    private val privacyEpoch = java.util.concurrent.atomic.AtomicLong()
    private const val REPORTED_ATTEMPT_TTL_MS = 5 * 60_000L
    private const val REPORTED_ATTEMPT_MAX = 512
    @Volatile private var lastReportedSweepMs = 0L
    private val reportedDeliveryAttempts = ConcurrentHashMap<Long, Long>()

    private fun reportSendFailures(deliveries: List<OutboundDelivery>) {
        val now = System.currentTimeMillis()
        if (reportedDeliveryAttempts.size > REPORTED_ATTEMPT_MAX ||
            now - lastReportedSweepMs >= REPORTED_ATTEMPT_TTL_MS) {
            lastReportedSweepMs = now
            reportedDeliveryAttempts.entries.removeIf { (_, reportedAt) ->
                now - reportedAt > REPORTED_ATTEMPT_TTL_MS
            }
            if (reportedDeliveryAttempts.size > REPORTED_ATTEMPT_MAX) {
                reportedDeliveryAttempts.entries
                    .sortedByDescending { it.value }
                    .drop(REPORTED_ATTEMPT_MAX)
                    .forEach { (attemptId, _) -> reportedDeliveryAttempts.remove(attemptId) }
            }
        }
        val activePrivacyEpoch = privacyEpoch.get()
        deliveries.asSequence()
            .filter { it.privacyEpoch == activePrivacyEpoch }
            .distinctBy { it.attemptId }
            .forEach { delivery ->
                if (reportedDeliveryAttempts.putIfAbsent(delivery.attemptId, now) != null) return@forEach
                handler.post {
                    // Serialize this final epoch check with stop()'s invalidation.
                    // Listeners only append to lock-free inboxes and never re-enter
                    // the engine, so holding txLock here cannot invert its locks.
                    synchronized(txLock) {
                        if (delivery.privacyEpoch != privacyEpoch.get()) return@synchronized
                        when (delivery) {
                            is TextDelivery -> onSendFailure.forEach { listener ->
                                runCatching {
                                    listener(MeshSendFailure(delivery.peerId, delivery.messageId, delivery.text, delivery.tsSecs))
                                }
                            }
                            is MediaDelivery -> onMediaSendFailure.forEach { listener ->
                                runCatching {
                                    listener(
                                        MeshMediaSendFailure(
                                            delivery.peerId,
                                            delivery.messageId,
                                            delivery.bytes.copyOf(),
                                            delivery.filename,
                                            delivery.mimeType,
                                            delivery.tsSecs,
                                        )
                                    )
                                }
                            }
                        }
                    }
                }
            }
    }

    @SuppressLint("MissingPermission")
    private fun issueNotify(
        s: BluetoothGattServer, device: BluetoothDevice, ch: BluetoothGattCharacteristic, packet: ByteArray,
    ): Boolean =
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            s.notifyCharacteristicChanged(device, ch, false, packet) ==
                android.bluetooth.BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION") run {
                ch.value = packet; s.notifyCharacteristicChanged(device, ch, false)
            }
        }
}

private fun safeFileName(raw: String?, mime: String, timestampMs: Long): String {
    val cleaned = raw.orEmpty()
        .substringAfterLast('/')
        .substringAfterLast('\\')
        .replace(Regex("[\\u0000-\\u001F\\u007F]"), "_")
        .trim()
        .take(96)
    val fallback = "file-$timestampMs.${defaultExtension(mime)}"
    val name = cleaned.ifBlank { fallback }
    return if (name.contains('.')) name else "$name.${defaultExtension(mime)}"
}

private fun normalizedMime(raw: String?, bytes: ByteArray): String? {
    if (bytes.isEmpty()) return null
    val declared = raw?.trim()?.lowercase()
    val sniffed = sniffMime(bytes)
    return when {
        declared == null || declared.isBlank() -> sniffed ?: "application/octet-stream"
        declared == "application/octet-stream" -> declared
        declared in allowedMimes() && mimeMatches(declared, bytes) -> canonicalMime(declared)
        sniffed != null -> sniffed
        else -> null
    }
}

private fun canonicalMime(mime: String): String = when (mime) {
    "image/jpg" -> "image/jpeg"
    else -> mime
}

private fun allowedMimes(): Set<String> = setOf(
    "image/jpeg", "image/jpg", "image/png", "image/gif", "image/webp",
    "audio/mp4", "audio/m4a", "audio/aac", "audio/mpeg", "audio/mp3",
    "audio/wav", "audio/x-wav", "audio/ogg",
    "application/pdf", "application/octet-stream",
)

private fun sniffMime(bytes: ByteArray): String? = when {
    mimeMatches("image/jpeg", bytes) -> "image/jpeg"
    mimeMatches("image/png", bytes) -> "image/png"
    mimeMatches("image/gif", bytes) -> "image/gif"
    mimeMatches("image/webp", bytes) -> "image/webp"
    mimeMatches("audio/mpeg", bytes) -> "audio/mpeg"
    mimeMatches("audio/wav", bytes) -> "audio/wav"
    mimeMatches("audio/ogg", bytes) -> "audio/ogg"
    mimeMatches("application/pdf", bytes) -> "application/pdf"
    else -> null
}

private fun mimeMatches(mime: String, bytes: ByteArray): Boolean {
    fun b(i: Int) = bytes[i].toInt() and 0xFF
    return when (mime) {
        "image/jpeg", "image/jpg" -> bytes.size >= 3 && b(0) == 0xFF && b(1) == 0xD8 && b(2) == 0xFF
        "image/png" -> bytes.size >= 8 &&
            b(0) == 0x89 && b(1) == 0x50 && b(2) == 0x4E && b(3) == 0x47 &&
            b(4) == 0x0D && b(5) == 0x0A && b(6) == 0x1A && b(7) == 0x0A
        "image/gif" -> bytes.size >= 6 &&
            b(0) == 0x47 && b(1) == 0x49 && b(2) == 0x46 &&
            b(3) == 0x38 && (b(4) == 0x37 || b(4) == 0x39) && b(5) == 0x61
        "image/webp" -> bytes.size >= 12 &&
            b(0) == 0x52 && b(1) == 0x49 && b(2) == 0x46 && b(3) == 0x46 &&
            b(8) == 0x57 && b(9) == 0x45 && b(10) == 0x42 && b(11) == 0x50
        "audio/mp4", "audio/m4a", "audio/aac" -> bytes.size > 100
        "audio/mpeg", "audio/mp3" ->
            (bytes.size >= 3 && b(0) == 0x49 && b(1) == 0x44 && b(2) == 0x33) ||
                (bytes.size >= 2 && b(0) == 0xFF && (b(1) and 0xE0) == 0xE0)
        "audio/wav", "audio/x-wav" -> bytes.size >= 12 &&
            b(0) == 0x52 && b(1) == 0x49 && b(2) == 0x46 && b(3) == 0x46 &&
            b(8) == 0x57 && b(9) == 0x41 && b(10) == 0x56 && b(11) == 0x45
        "audio/ogg" -> bytes.size >= 4 && b(0) == 0x4F && b(1) == 0x67 && b(2) == 0x67 && b(3) == 0x53
        "application/pdf" -> bytes.size >= 4 && b(0) == 0x25 && b(1) == 0x50 && b(2) == 0x44 && b(3) == 0x46
        "application/octet-stream" -> true
        else -> false
    }
}

private fun defaultExtension(mime: String): String = when (mime) {
    "image/jpeg", "image/jpg" -> "jpg"
    "image/png" -> "png"
    "image/gif" -> "gif"
    "image/webp" -> "webp"
    "audio/mp4", "audio/m4a", "audio/aac" -> "m4a"
    "audio/mpeg", "audio/mp3" -> "mp3"
    "audio/wav", "audio/x-wav" -> "wav"
    "audio/ogg" -> "ogg"
    "application/pdf" -> "pdf"
    else -> "bin"
}

private fun String.hexToBytes(): ByteArray =
    ByteArray(length / 2) { ((this[it * 2].digitToInt(16) shl 4) or this[it * 2 + 1].digitToInt(16)).toByte() }

private fun ByteArray.toHex(): String =
    joinToString("") { (it.toInt() and 0xFF).toString(16).padStart(2, '0') }
