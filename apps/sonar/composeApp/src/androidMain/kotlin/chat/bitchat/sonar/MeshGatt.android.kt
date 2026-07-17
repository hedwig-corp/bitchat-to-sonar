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
 * per-instance links, liveness, Noise session lifecycle, pending sends,
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
    private val onSonar = java.util.concurrent.CopyOnWriteArrayList<(String, ByteArray) -> Unit>()
    private val onAnnounce = java.util.concurrent.CopyOnWriteArrayList<(String, MeshAnnounceInfo, String) -> Unit>()
    private val onLink = java.util.concurrent.CopyOnWriteArrayList<(String) -> Unit>()
    private val onBroadcast = java.util.concurrent.CopyOnWriteArrayList<(String, MeshPublicMessage) -> Unit>()
    private val onFile = java.util.concurrent.CopyOnWriteArrayList<(String, String, String, String, ByteArray) -> Unit>()

    fun addMessageListener(cb: (fingerprint: String, messageId: String, text: String) -> Unit) { onText.add(cb) }
    fun addSonarListener(cb: (fingerprint: String, payload: ByteArray) -> Unit) { onSonar.add(cb) }
    /** Fired when a peer's signed announce is received + verified. The third arg
     *  is the peer's stable fingerprint (SHA256 of its noise static pubkey). */
    fun addAnnounceListener(cb: (bleAddr: String, info: MeshAnnounceInfo, fingerprint: String) -> Unit) { onAnnounce.add(cb) }
    fun addLinkListener(cb: (fingerprint: String) -> Unit) { onLink.add(cb) }
    fun addBroadcastListener(cb: (senderFingerprint: String, message: MeshPublicMessage) -> Unit) { onBroadcast.add(cb) }
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
        transact { engine.setAllowlist(allowedFingerprints?.toList()) }
    }

    fun updateNickname(value: String) {
        transact { engine.setNickname(value.trim(), nowMs()) }
    }

    fun updateSonarPayload(payload: ByteArray?) {
        transact { engine.setSonarPayload(payload?.copyOf(), nowMs()) }
    }

    // ── Lifecycle ──

    @Volatile private var tickArmed = false

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
            for (addr in clientWriting) {
                val since = opInFlightSinceMs[addr] ?: continue
                if (now - since >= OP_STUCK_MS) {
                    android.util.Log.w(TAG, "gatt op stuck ${now - since}ms on $addr — unblocking queue")
                    opInFlightSinceMs.remove(addr)
                    clientWriting.remove(addr)
                    pumpClientWrites(addr)
                }
            }
            // Same recovery for the server notify slot: a lost
            // onNotificationSent would otherwise freeze that central forever.
            for (addr in serverNotifying) {
                val since = notifyInFlightSinceMs[addr] ?: continue
                if (now - since >= OP_STUCK_MS) {
                    android.util.Log.w(TAG, "server notify stuck ${now - since}ms on $addr — unblocking queue")
                    notifyInFlightSinceMs.remove(addr)
                    serverNotifying.remove(addr)
                    pumpServerNotify(addr)
                }
            }
            // Bound the scan-fed device cache; keep entries with live links.
            if (deviceByAddr.size > 256) {
                deviceByAddr.keys.removeAll {
                    !gattByAddr.containsKey(it) && !serverDevices.containsKey(it)
                }
            }
            transact { engine.onTick(now) }
            if (tickArmed) handler.postDelayed(this, TICK_MS)
        }

        /** Re-read the clock so rx that landed since the decision spares the link. */
        private fun stillStale(lastRx: Long?): Boolean =
            lastRx != null && nowMonotonic() - lastRx >= LINK_STALE_MS
    }

    fun startServer() {
        // Arm on the handler thread: start()/stop() are called off the main
        // looper; (dis)arming serialized on the tick's own looper avoids two
        // ticks rescheduling each other forever.
        engine.setWallClock(nowMs(), System.currentTimeMillis())
        handler.post {
            if (tickArmed) return@post
            tickArmed = true
            handler.postDelayed(tick, TICK_MS)
        }
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

    fun stop() {
        tickArmed = false
        handler.removeCallbacks(tick)
        engine.reset()
        try { server?.close() } catch (_: Throwable) {}
        server = null; characteristic = null
        gattByAddr.values.forEach { runCatching { it.disconnect(); it.close() } }
        gattByAddr.clear(); charByKey.clear(); serverDevices.clear(); deviceByAddr.clear()
        // A stuck in-flight flag surviving stop() would permanently block the
        // same address's queue after the next start().
        clientWriteQueue.clear(); clientWriting.clear(); opInFlightSinceMs.clear()
        serverNotifyQueue.clear(); serverNotifying.clear(); notifyInFlightSinceMs.clear()
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

    fun sendTextToPeer(fingerprint: String, messageId: String, text: String): Boolean =
        transact { engine.sendText(fingerprint, messageId, text, nowMs()) } != null

    /** Immediate send for real-time controls. Never queues. */
    fun sendTextToPeerNow(fingerprint: String, messageId: String, text: String): Boolean =
        transact { engine.sendTextNow(fingerprint, messageId, text, nowMs()) } != null

    /** Send a private file transfer to a live peer route (never queued).
     *  Mesh file message ids are derived on the receive side, so [messageId]
     *  is accepted for interface parity only. */
    fun sendFileToPeer(fingerprint: String, messageId: String, bytes: ByteArray, filename: String, mimeType: String): Boolean {
        if (bytes.isEmpty() || bytes.size > MAX_FILE_TRANSFER_BYTES) return false
        val mime = normalizedMime(mimeType, bytes) ?: return false
        val safeName = safeFileName(filename, mime, System.currentTimeMillis())
        return transact { engine.sendFile(fingerprint, bytes, safeName, mime, nowMs()) } != null
    }

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
    private fun transact(block: () -> MeshEngineOutput?): MeshEngineOutput? {
        val out: MeshEngineOutput?
        synchronized(txLock) {
            out = block()
            out?.let { executeCommands(it) }
        }
        out?.let { dispatchEvents(it) }
        return out
    }

    private fun execute(out: MeshEngineOutput) {
        synchronized(txLock) { executeCommands(out) }
        dispatchEvents(out)
    }

    private fun executeCommands(out: MeshEngineOutput) {
        for (cmd in out.commands) when (cmd) {
            is MeshEngineCommand.Dial -> dial(cmd.conn)
            is MeshEngineCommand.Disconnect -> disconnectClient(cmd.conn)
            is MeshEngineCommand.CancelServer -> cancelServer(cmd.conn)
            is MeshEngineCommand.RefreshInstances -> {
                android.util.Log.i(TAG, "re-discovering services on ${cmd.conn}")
                @SuppressLint("MissingPermission")
                gattByAddr[cmd.conn]?.discoverServices()
            }
            is MeshEngineCommand.Subscribe -> subscribe(cmd.conn, cmd.instance)
            is MeshEngineCommand.WriteLink -> {
                val run = Runnable {
                    val gatt = gattByAddr[cmd.conn] ?: return@Runnable
                    val ch = charByKey["${cmd.conn}#${cmd.instance}"] ?: return@Runnable
                    writePacket(gatt, ch, cmd.bytes)
                }
                if (cmd.afterMs > 0) handler.postDelayed(run, cmd.afterMs) else run.run()
            }
            is MeshEngineCommand.NotifyConn -> {
                val run = Runnable {
                    val device = serverDevices[cmd.conn] ?: return@Runnable
                    notify(device, cmd.bytes)
                }
                if (cmd.afterMs > 0) handler.postDelayed(run, cmd.afterMs) else run.run()
            }
        }
        // Client links: policy per instance link (several peer apps can share
        // one address); dropClientLink closes the connection once empty.
        val keys = HashSet<String>()
        keys.addAll(clientChar.keys)
        keys.addAll(clientLinks.keys)
        keys.forEach { key ->
            if (!addrAllowedByPolicy(key)) {
                val fp = fingerprintByAddr[key]
                android.util.Log.i(TAG, "dropping non-allowlisted mesh link $key fp=${fp?.take(8) ?: "unknown"}")
                dropClientLink(key)
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
            is MeshEngineEvent.FileReceived -> {
                val bytes = event.content
                val mime = normalizedMime(event.mimeType, bytes) ?: continue
                val name = safeFileName(event.fileName, mime, event.timestampMs)
                onFile.forEach { it(event.fingerprint, "${event.transferKey}-file", name, mime, bytes) }
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
    private fun disconnectClient(conn: String) {
        gattByAddr.remove(conn)?.let { runCatching { it.disconnect(); it.close() } }
        charByKey.keys.removeAll { it.startsWith("$conn#") }
        clientWriteQueue.remove(conn); clientWriting.remove(conn); opInFlightSinceMs.remove(conn)
    }

    /** Server-role teardown only: an outbound client GATT stays untouched. */
    @SuppressLint("MissingPermission")
    private fun cancelServer(conn: String) {
        serverDevices.remove(conn)?.let { device -> runCatching { server?.cancelConnection(device) } }
        serverNotifyQueue.remove(conn); serverNotifying.remove(conn); notifyInFlightSinceMs.remove(conn)
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
            android.util.Log.i(TAG, "client ${gatt.device.address}: mtu=$mtu status=$status → discoverServices")
            gatt.discoverServices()
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            // A peer can expose SEVERAL instances of the mesh service (a Mac
            // running Sonar.app + the bitchat iOS-wrapper registers it twice in
            // the shared GATT database). Every instance is a distinct peer app.
            val addr = gatt.device.address
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
                execute(
                    engine.onInstancesDiscovered(
                        addr,
                        chars.map { it.service.instanceId },
                        nowMs(),
                    )
                )
            }
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            val addr = gatt.device.address
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
            opInFlightSinceMs.remove(addr)
            clientWriting.remove(addr)
            pumpClientWrites(addr)
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
                serverDevices.remove(device.address)
                serverNotifyQueue.remove(device.address); serverNotifying.remove(device.address)
                transact { engine.onServerDisconnected(device.address) }
            }
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            // Slot free → drain the next queued notify (one outstanding at a time).
            notifyInFlightSinceMs.remove(device.address)
            serverNotifying.remove(device.address)
            pumpServerNotify(device.address)
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
        class WriteChar(val ch: BluetoothGattCharacteristic, val bytes: ByteArray) : GattOp
        class WriteDesc(val desc: BluetoothGattDescriptor) : GattOp
    }

    private val clientWriteQueue = ConcurrentHashMap<String, java.util.concurrent.ConcurrentLinkedQueue<GattOp>>()
    private val clientWriting = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
    /** When the in-flight op was issued, for the tick's stuck-op recovery. */
    private val opInFlightSinceMs = ConcurrentHashMap<String, Long>()

    private fun writePacket(gatt: BluetoothGatt, ch: BluetoothGattCharacteristic, packet: ByteArray) {
        clientWriteQueue.getOrPut(gatt.device.address) { java.util.concurrent.ConcurrentLinkedQueue() }
            .add(GattOp.WriteChar(ch, packet))
        pumpClientWrites(gatt.device.address)
    }

    /** Queue a CCC-enable write (completion arrives in onDescriptorWrite). */
    private fun subscribeChar(gatt: BluetoothGatt, d: BluetoothGattDescriptor) {
        clientWriteQueue.getOrPut(gatt.device.address) { java.util.concurrent.ConcurrentLinkedQueue() }
            .add(GattOp.WriteDesc(d))
        pumpClientWrites(gatt.device.address)
    }

    /** Issue the next queued op for [addr] iff none is in flight. */
    @Synchronized
    private fun pumpClientWrites(addr: String) {
        if (clientWriting.contains(addr)) return
        val q = clientWriteQueue[addr] ?: return
        val next = q.poll() ?: return
        val gatt = gattByAddr[addr] ?: return
        clientWriting.add(addr)
        opInFlightSinceMs[addr] = nowMs()
        val accepted = when (next) {
            is GattOp.WriteChar -> issueWrite(gatt, next.ch, next.bytes)
            is GattOp.WriteDesc -> issueDescWrite(gatt, next.desc)
        }
        if (!accepted) {
            // The op wasn't accepted ⇒ its completion callback won't fire;
            // don't stall the queue — drop it and move on.
            android.util.Log.w(TAG, "gatt op not accepted for $addr — skipping")
            opInFlightSinceMs.remove(addr)
            clientWriting.remove(addr)
            pumpClientWrites(addr)
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
    private val serverNotifyQueue = ConcurrentHashMap<String, java.util.concurrent.ConcurrentLinkedQueue<ByteArray>>()
    private val serverNotifying = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
    /** When the in-flight notify was issued, for the tick's stuck recovery. */
    private val notifyInFlightSinceMs = ConcurrentHashMap<String, Long>()

    private fun notify(device: BluetoothDevice, packet: ByteArray) {
        serverNotifyQueue.getOrPut(device.address) { java.util.concurrent.ConcurrentLinkedQueue() }.add(packet)
        pumpServerNotify(device.address)
    }

    @Synchronized
    private fun pumpServerNotify(addr: String) {
        if (serverNotifying.contains(addr)) return
        val q = serverNotifyQueue[addr] ?: return
        val next = q.poll() ?: return
        val s = server ?: return
        val ch = characteristic ?: return
        val device = serverDevices[addr] ?: return
        serverNotifying.add(addr)
        notifyInFlightSinceMs[addr] = nowMs()
        if (!issueNotify(s, device, ch, next)) {
            notifyInFlightSinceMs.remove(addr)
            serverNotifying.remove(addr)
            pumpServerNotify(addr)
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
