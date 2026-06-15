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
import chat.bitchat.sonar.crypto.Sha256
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import uniffi.sonar_ffi.MeshAnnounceInfo
import uniffi.sonar_ffi.NoiseKeypairHex
import uniffi.sonar_ffi.SonarNoise
import uniffi.sonar_ffi.meshBuildAnnounce
import uniffi.sonar_ffi.meshBuildPacket
import uniffi.sonar_ffi.meshDecodePacket
import uniffi.sonar_ffi.meshDecodePrivateMessage
import uniffi.sonar_ffi.meshEncodePrivateMessage
import uniffi.sonar_ffi.meshParseAnnounce
import uniffi.sonar_ffi.noiseGenerateKeypair

/**
 * BLE GATT link for the bitchat mesh transport — **wire-compatible with the iOS
 * BLEService**. Each characteristic write/notify carries exactly one padded
 * `BitchatPacket` (built/parsed by the byte-exact Rust core via the `mesh_*`
 * FFI); there is NO extra length framing.
 *
 * Choreography (matches iOS):
 *  1. On connect (central) / subscribe (peripheral) each side broadcasts a
 *     signed identity announce (type 0x01, UNENCRYPTED) → peers learn each
 *     other's nickname + keys + peerID. This is discovery — no Noise needed.
 *  2. A 1:1 DM lazily runs a Noise XX handshake (0x10 packets, directed to the
 *     peer's announced peerID; central = initiator, peripheral = responder),
 *     then exchanges encrypted messages (0x11, inner `[0x01][PrivateMessage]`).
 *
 * The Noise crypto is the unit-tested core via [SonarNoise]; the packet framing,
 * announce signing, and inner TLVs are the unit-tested `sonar_core::mesh`.
 */
@SuppressLint("MissingPermission")
object MeshGatt {

    private const val TAG = "MeshGatt"
    private val SERVICE: UUID = UUID.fromString("F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C")
    private val CHAR: UUID = UUID.fromString("A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D")
    // Standard Client Characteristic Configuration descriptor. NB: the segment
    // is 8000, not 0000 — with the wrong UUID Android does not recognize it as
    // the CCC, so notifications never enable and the announce never flows (and
    // standard peers like iOS show "no CCC descriptor").
    private val CCC: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    // bitchat packet types (subset; full set in sonar_core::mesh::msg_type).
    private const val TYPE_ANNOUNCE: UByte = 0x01u
    private const val TYPE_NOISE_HANDSHAKE: UByte = 0x10u
    private const val TYPE_NOISE_ENCRYPTED: UByte = 0x11u
    private const val TYPE_SONAR_0X53: UByte = 0x53u
    private const val DEFAULT_TTL: UByte = 7u

    private val ctx: Context get() = AppContextHolder.ctx
    private fun manager() = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager

    // ── This device's mesh identity (PERSISTED across launches) ──
    // The Noise static key + announce-signing seed are stored in the app-private
    // "sonar" prefs (same store + sensitivity tier as the Nostr nsec) so the mesh
    // peerID is STABLE — it used to regenerate every process, giving the phone a
    // brand-new identity on each launch (iOS persists its Noise key in the
    // Keychain; this is the Android-parity equivalent). Deriving these from the
    // Nostr identity instead is tracked separately (issue #10).
    private fun prefs() = ctx.getSharedPreferences("sonar", Context.MODE_PRIVATE)

    /** Noise static keypair (X25519), loaded from prefs or generated + saved once. */
    private val keypair by lazy {
        val p = prefs()
        val priv = p.getString("mesh.noise.priv", null)
        val pub = p.getString("mesh.noise.pub", null)
        if (priv != null && pub != null) {
            NoiseKeypairHex(priv, pub)
        } else {
            noiseGenerateKeypair().also {
                p.edit().putString("mesh.noise.priv", it.privateHex)
                    .putString("mesh.noise.pub", it.publicHex).apply()
            }
        }
    }
    /** Ed25519 announce-signing seed (32 bytes, hex), loaded from prefs or made once. */
    private val ed25519SeedHex by lazy {
        val p = prefs()
        p.getString("mesh.ed25519.seed", null) ?: ByteArray(32)
            .also { SecureRandom().nextBytes(it) }.toHex()
            .also { p.edit().putString("mesh.ed25519.seed", it).apply() }
    }
    /** bitchat peerID = SHA256(noise static pubkey)[:8], hex. */
    private val myPeerIdHex by lazy { Sha256.hash(keypair.publicHex.hexToBytes()).copyOf(8).toHex() }
    /** Display nickname carried in our announce (set by the host). */
    @Volatile var nickname: String = "sonar"
    /** Our latest Sonar Discovery (0x53) payload, broadcast alongside the announce. */
    @Volatile var sonarPayload: ByteArray? = null

    private var server: BluetoothGattServer? = null
    private var characteristic: BluetoothGattCharacteristic? = null
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())

    /** Per-link Noise state (DMs only), keyed by remote BLE address. */
    private class Link(val noise: SonarNoise, var established: Boolean = false)
    private val serverLinks = ConcurrentHashMap<String, Link>()
    private val serverDevices = ConcurrentHashMap<String, BluetoothDevice>()
    private val clientLinks = ConcurrentHashMap<String, Link>()
    /** The peer's announced bitchat peerID, keyed by BLE address. */
    private val peerIdByAddr = ConcurrentHashMap<String, String>()

    // Listeners (fired from BLE callback threads → concurrent lists).
    private val onText = java.util.concurrent.CopyOnWriteArrayList<(String, String) -> Unit>()
    private val onSonar = java.util.concurrent.CopyOnWriteArrayList<(String, ByteArray) -> Unit>()
    private val onAnnounce = java.util.concurrent.CopyOnWriteArrayList<(String, MeshAnnounceInfo) -> Unit>()
    private val onLink = java.util.concurrent.CopyOnWriteArrayList<(String) -> Unit>()

    fun addMessageListener(cb: (peerId: String, text: String) -> Unit) { onText.add(cb) }
    fun addSonarListener(cb: (peerId: String, payload: ByteArray) -> Unit) { onSonar.add(cb) }
    /** Fired when a peer's signed announce is received + verified. */
    fun addAnnounceListener(cb: (bleAddr: String, info: MeshAnnounceInfo) -> Unit) { onAnnounce.add(cb) }
    fun addLinkListener(cb: (peerId: String) -> Unit) { onLink.add(cb) }

    /** This device's 8-byte mesh node id (== bitchat peerID). MeshRadio puts it
     *  in the advert so two Sonar-Android peers can elect a single dialer. */
    fun nodeId(): ByteArray = myPeerIdHex.hexToBytes().copyOf(8)

    /**
     * Dialer election to avoid Android↔Android bidirectional GATT contention
     * (both sides dialing at once → the stack tears one down with status 19, so
     * the subscribe never completes and no announce flows). The node with the
     * lexicographically SMALLER id dials; the larger waits to be dialed. Applies
     * ONLY between two node-id-advertising peers — a peer with no node id (iOS /
     * stock bitchat) is handled by the caller's existing dial path, so iPhone
     * compatibility is unchanged.
     */
    fun shouldDial(peerNodeId: ByteArray): Boolean {
        val mine = nodeId()
        val n = minOf(mine.size, peerNodeId.size)
        for (i in 0 until n) {
            val a = mine[i].toInt() and 0xFF
            val b = peerNodeId[i].toInt() and 0xFF
            if (a != b) return a < b
        }
        return mine.size < peerNodeId.size
    }

    // ── Packet builders (via the byte-exact Rust core) ──

    private fun announceBytes(): ByteArray? = runCatching {
        meshBuildAnnounce(
            ed25519SeedHex, myPeerIdHex, nickname, keypair.publicHex,
            DEFAULT_TTL, System.currentTimeMillis().toULong(),
        )
    }.getOrNull()

    private fun sonarBytes(): ByteArray? = sonarPayload?.let { p ->
        runCatching {
            meshBuildPacket(TYPE_SONAR_0X53, myPeerIdHex, "", DEFAULT_TTL, System.currentTimeMillis().toULong(), p)
        }.getOrNull()
    }

    // ── GATT server (peripheral) ──

    fun startServer() {
        if (server != null) return
        android.util.Log.i(TAG, "MY node id = $myPeerIdHex  nickname='$nickname'")
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
        try { server?.close() } catch (_: Throwable) {}
        server = null; characteristic = null
        clientGatt.values.forEach { runCatching { it.disconnect(); it.close() } }
        clientGatt.clear(); clientChar.clear(); clientLinks.clear(); clientPending.clear(); clientConnected.clear()
        serverLinks.clear(); serverDevices.clear(); peerIdByAddr.clear(); recentDials.clear()
    }

    private val serverCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                serverDevices[device.address] = device
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                serverLinks.remove(device.address); serverDevices.remove(device.address)
                peerIdByAddr.remove(device.address)
                serverNotifyQueue.remove(device.address); serverNotifying.remove(device.address)
            }
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            // Slot free → drain the next queued notify (one outstanding at a time).
            serverNotifying.remove(device.address)
            pumpServerNotify(device.address)
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice, requestId: Int, descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray,
        ) {
            if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            // The central just subscribed → broadcast our announce, then the 0x53.
            // GATT serializes writes/notifies, so defer the 0x53 so it doesn't
            // collide with the announce (the priority for discovery).
            val ann = announceBytes()
            android.util.Log.i(TAG, "server ${device.address}: central subscribed → notify announce (${ann?.size}B)")
            ann?.let { notify(device, it) }
            sonarBytes()?.let { p -> handler.postDelayed({ notify(device, p) }, 150) }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice, requestId: Int, ch: BluetoothGattCharacteristic,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray,
        ) {
            if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            handlePacket(device.address, value, fromServer = true, device = device)
        }
    }

    // ── GATT client (central) ──

    private val clientGatt = ConcurrentHashMap<String, BluetoothGatt>()
    private val clientChar = ConcurrentHashMap<String, BluetoothGattCharacteristic>()
    /** Dials that haven't produced an announce yet (still "probing"). */
    private val clientPending = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
    /** Last dial time per address, to avoid re-dialing the same one in a storm. */
    private val recentDials = ConcurrentHashMap<String, Long>()

    /** Cap concurrent outgoing links: BLE MAC rotation means a single nearby
     *  device appears as a stream of fresh addresses, and dialing each one
     *  floods the controller (status 133) and drains battery. */
    private const val MAX_CLIENTS = 4
    /** Time to wait for the TCP-like GATT connection to ESTABLISH (reach
     *  CONNECTED). Dialing a discovered BLE address often hangs with no callback
     *  at all because the peer's Resolvable Private Address has already rotated
     *  away — so fail fast and free the slot to try the peer's current address,
     *  rather than burning the full announce window on a dead MAC. A real connect
     *  lands in well under a second (≈0.7 s observed). */
    private const val CONNECT_ESTABLISH_MS = 5_000L
    /** Once CONNECTED, time to wait for the peer's announce before giving up. */
    private const val ANNOUNCE_TIMEOUT_MS = 6_000L
    private const val REDIAL_BACKOFF_MS = 30_000L

    /** Addresses that have reached CONNECTED — they get the longer announce
     *  window; un-established dials are dropped at CONNECT_ESTABLISH_MS. */
    private val clientConnected = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()

    /** Connect to a discovered peer to exchange announces (and enable DMs).
     *  Bounded + timed-out so a rotating-MAC advertiser can't churn the radio. */
    fun connect(device: BluetoothDevice) {
        val addr = device.address
        if (clientGatt.containsKey(addr) || clientPending.contains(addr)) return
        val now = System.currentTimeMillis()
        recentDials[addr]?.let { if (now - it < REDIAL_BACKOFF_MS) return }
        if (clientGatt.size + clientPending.size >= MAX_CLIENTS) return // at capacity
        recentDials[addr] = now
        if (recentDials.size > 256) recentDials.entries.removeAll { now - it.value > REDIAL_BACKOFF_MS }
        clientPending.add(addr) // reserve the slot before the async connect
        // connectGatt MUST run on the main thread — calling it from the scan
        // callback's binder thread is a classic cause of status 133 (every dial
        // failing immediately). Hop to the main looper.
        handler.post {
            if (!clientPending.contains(addr)) return@post
            android.util.Log.i(TAG, "dialing $addr (TRANSPORT_LE) [${clientGatt.size}/$MAX_CLIENTS]")
            val gatt = runCatching {
                device.connectGatt(ctx, false, clientCallback, BluetoothDevice.TRANSPORT_LE)
            }.getOrNull()
            if (gatt == null) { cleanupClient(addr); return@post }
            clientGatt[addr] = gatt
        }
        // Fail fast if the connection never ESTABLISHES (rotated-away RPA hangs
        // with no callback) — frees the slot to dial the peer's live address.
        handler.postDelayed({
            if (clientPending.contains(addr) && !clientConnected.contains(addr)) {
                android.util.Log.i(TAG, "dial $addr not established in ${CONNECT_ESTABLISH_MS}ms — closing")
                cleanupClient(addr)
            }
        }, CONNECT_ESTABLISH_MS)
        // For a connection that DID establish, drop it if no announce arrives.
        handler.postDelayed({
            if (clientPending.contains(addr)) {
                android.util.Log.i(TAG, "dial $addr timed out (no announce) — closing")
                cleanupClient(addr)
            }
        }, CONNECT_ESTABLISH_MS + ANNOUNCE_TIMEOUT_MS)
    }

    private val clientCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            val addr = gatt.device.address
            android.util.Log.i(TAG, "client $addr: state=$newState status=$status")
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                clientGatt[addr] = gatt
                clientConnected.add(addr) // earns the longer announce window
                gatt.requestMtu(517)
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                if (status != 0) gatt.close()
                cleanupClient(addr)
                // Any failed connect (133 transient, 19 peer-terminate from a
                // dial race, …) is frequently retryable — clear the backoff so the
                // next scan hit (or the soft-election fallback) can re-dial right
                // away rather than waiting out REDIAL_BACKOFF_MS.
                if (status != 0) recentDials.remove(addr)
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            android.util.Log.i(TAG, "client ${gatt.device.address}: mtu=$mtu status=$status → discoverServices")
            gatt.discoverServices()
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            val svc = gatt.getService(SERVICE)
            val ch = svc?.getCharacteristic(CHAR)
            android.util.Log.i(TAG, "client ${gatt.device.address}: servicesDiscovered status=$status svc=${svc != null} char=${ch != null}")
            if (ch == null) return
            val addr = gatt.device.address
            clientChar[addr] = ch
            // Subscribe on the MAIN thread (like connectGatt) — GATT ops issued
            // from the discovery callback thread can silently fail to queue.
            handler.post {
                gatt.setCharacteristicNotification(ch, true)
                val d = ch.getDescriptor(CCC)
                if (d == null) {
                    // No CCC on the peer — can't receive notifies, but we can still
                    // WRITE our announce to its server. Send it directly.
                    android.util.Log.i(TAG, "client $addr: no CCC descriptor → write announce only")
                    announceBytes()?.let { writePacket(gatt, ch, it) }
                    return@post
                }
                val enable = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                val rc = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                    gatt.writeDescriptor(d, enable)
                } else {
                    @Suppress("DEPRECATION") run { d.value = enable; if (gatt.writeDescriptor(d)) 0 else -1 }
                }
                android.util.Log.i(TAG, "client $addr: writeDescriptor(subscribe) rc=$rc")
            }
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            // Notifications enabled → send our announce, then (deferred, so the
            // back-to-back GATT writes don't collide) our 0x53.
            val ch = clientChar[gatt.device.address] ?: return
            val ann = announceBytes()
            android.util.Log.i(TAG, "client ${gatt.device.address}: notify enabled (status=$status) → send announce (${ann?.size}B)")
            ann?.let { writePacket(gatt, ch, it) }
            sonarBytes()?.let { p -> handler.postDelayed({ writePacket(gatt, ch, p) }, 150) }
        }

        override fun onCharacteristicWrite(gatt: BluetoothGatt, ch: BluetoothGattCharacteristic, status: Int) {
            // status 0 = GATT_SUCCESS. Either way the slot is now free → drain the
            // next queued write (one outstanding write at a time is the hard limit
            // that was dropping our handshake m1).
            val addr = gatt.device.address
            clientWriting.remove(addr)
            pumpClientWrites(addr)
        }

        override fun onCharacteristicChanged(gatt: BluetoothGatt, ch: BluetoothGattCharacteristic, value: ByteArray) {
            handlePacket(gatt.device.address, value, fromServer = false, gatt = gatt)
        }

        @Deprecated("compat")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, ch: BluetoothGattCharacteristic) {
            @Suppress("DEPRECATION") handlePacket(gatt.device.address, ch.value ?: return, fromServer = false, gatt = gatt)
        }
    }

    private fun cleanupClient(addr: String) {
        clientLinks.remove(addr); clientChar.remove(addr); peerIdByAddr.remove(addr)
        clientPending.remove(addr); clientConnected.remove(addr)
        clientWriteQueue.remove(addr); clientWriting.remove(addr)
        clientGatt.remove(addr)?.let { runCatching { it.disconnect(); it.close() } }
    }

    // ── Receive: route every characteristic value (one padded packet) by type ──

    private fun handlePacket(
        addr: String, value: ByteArray, fromServer: Boolean,
        device: BluetoothDevice? = null, gatt: BluetoothGatt? = null,
    ) {
        val info = runCatching { meshDecodePacket(value) }.getOrNull()
        if (info == null) {
            android.util.Log.i(TAG, "rx undecodable value (${value.size}B) from $addr")
            return
        }
        android.util.Log.i(TAG, "rx type=0x${info.packetType.toString(16)} (${value.size}B) from $addr server=$fromServer")
        when (info.packetType) {
            TYPE_ANNOUNCE -> {
                val ann = runCatching { meshParseAnnounce(value) }.getOrNull()
                if (ann == null) { android.util.Log.w(TAG, "announce verify FAILED from $addr"); return }
                android.util.Log.i(TAG, "ANNOUNCE from $addr → '${ann.nickname}' peerId=${ann.senderIdHex}")
                peerIdByAddr[addr] = ann.senderIdHex
                clientPending.remove(addr) // a real peer answered — keep this link
                onAnnounce.forEach { it(addr, ann) }
                // Central: now that we know the peer's peerID, open a Noise link
                // for DMs (initiator). Peripheral waits for the peer's 0x10.
                if (!fromServer && gatt != null && clientLinks[addr] == null) {
                    android.util.Log.i(TAG, "starting Noise handshake (initiator) → $addr")
                    startHandshake(gatt, addr, ann.senderIdHex)
                } else {
                    android.util.Log.i(TAG, "no handshake: fromServer=$fromServer gatt=${gatt != null} link=${clientLinks[addr] != null}")
                }
            }
            TYPE_NOISE_HANDSHAKE -> handleHandshake(addr, info.payload, fromServer, device, gatt)
            TYPE_NOISE_ENCRYPTED -> handleEncrypted(addr, info.payload, fromServer)
            TYPE_SONAR_0X53 -> {
                // Tag the 0x53 with the peer's stable bitchat peerID (learned
                // from its 0x01 announce, which precedes the 0x53) so it can be
                // correlated to the mesh peer despite BLE address rotation.
                val peerId = peerIdByAddr[addr] ?: return
                onSonar.forEach { it(peerId, info.payload) }
            }
            else -> android.util.Log.i(TAG, "ignoring mesh packet type=${info.packetType} from $addr")
        }
    }

    // ── Noise DM handshake (lazy) ──

    private fun startHandshake(gatt: BluetoothGatt, addr: String, peerIdHex: String) {
        val ch = clientChar[addr] ?: run {
            android.util.Log.w(TAG, "startHandshake $addr: no clientChar"); return
        }
        val link = Link(SonarNoise.initiator(keypair.privateHex))
        clientLinks[addr] = link
        runCatching {
            val m1 = link.noise.writeMessage()
            android.util.Log.i(TAG, "writing handshake m1 (${m1.size}B) → $addr")
            writePacket(gatt, ch, handshakePacket(peerIdHex, m1))
        }.onFailure { android.util.Log.w(TAG, "startHandshake $addr failed: $it") }
    }

    private fun handleHandshake(
        addr: String, noiseMsg: ByteArray, fromServer: Boolean,
        device: BluetoothDevice?, gatt: BluetoothGatt?,
    ) {
        try {
            if (fromServer) {
                val link = serverLinks.getOrPut(addr) { Link(SonarNoise.responder(keypair.privateHex)) }
                if (link.established) return
                link.noise.readMessage(noiseMsg) // m1 (then m3)
                if (link.noise.isFinished()) {
                    link.noise.intoSession(); link.established = true; linkEstablished(addr)
                } else {
                    device?.let { notify(it, handshakePacket(peerIdByAddr[addr] ?: "", link.noise.writeMessage())) } // m2
                }
            } else {
                val link = clientLinks[addr] ?: return
                val ch = clientChar[addr] ?: return
                if (link.established) return
                link.noise.readMessage(noiseMsg) // m2
                if (!link.noise.isFinished()) {
                    gatt?.let { writePacket(it, ch, handshakePacket(peerIdByAddr[addr] ?: "", link.noise.writeMessage())) } // m3
                }
                if (link.noise.isFinished()) {
                    link.noise.intoSession(); link.established = true; linkEstablished(addr)
                }
            }
        } catch (_: Throwable) {
            if (fromServer) serverLinks.remove(addr) else cleanupClient(addr)
        }
    }

    private fun handleEncrypted(addr: String, ciphertext: ByteArray, fromServer: Boolean) {
        val link = (if (fromServer) serverLinks[addr] else clientLinks[addr])?.takeIf { it.established } ?: return
        runCatching {
            val plain = link.noise.decrypt(ciphertext)
            meshDecodePrivateMessage(plain)?.let { pm -> onText.forEach { it(addr, pm.content) } }
        }
    }

    private fun handshakePacket(peerIdHex: String, noiseMsg: ByteArray): ByteArray =
        meshBuildPacket(TYPE_NOISE_HANDSHAKE, myPeerIdHex, peerIdHex, DEFAULT_TTL, System.currentTimeMillis().toULong(), noiseMsg)

    private fun linkEstablished(peerId: String) {
        android.util.Log.i(TAG, "✅ Noise link ESTABLISHED with $peerId (peerId=${peerIdByAddr[peerId]})")
        onLink.forEach { it(peerId) }
    }

    /** Send an encrypted DM to an established peer (private message TLV inside). */
    fun sendText(peerAddress: String, messageId: String, text: String): Boolean = runCatching {
        val link = (clientLinks[peerAddress] ?: serverLinks[peerAddress])?.takeIf { it.established } ?: return false
        val plain = meshEncodePrivateMessage(messageId, text)
        val ciphertext = link.noise.encrypt(plain)
        val peerId = peerIdByAddr[peerAddress] ?: ""
        val packet = meshBuildPacket(TYPE_NOISE_ENCRYPTED, myPeerIdHex, peerId, DEFAULT_TTL, System.currentTimeMillis().toULong(), ciphertext)
        if (clientLinks.containsKey(peerAddress)) {
            val gatt = clientGatt[peerAddress] ?: return false
            val ch = clientChar[peerAddress] ?: return false
            writePacket(gatt, ch, packet); true
        } else {
            serverDevices[peerAddress]?.let { notify(it, packet); true } ?: false
        }
    }.getOrDefault(false)

    /** Broadcast our Sonar Discovery (0x53) payload to an established peer. */
    fun sendSonar(peerId: String, payload: ByteArray): Boolean = runCatching {
        val packet = meshBuildPacket(TYPE_SONAR_0X53, myPeerIdHex, "", DEFAULT_TTL, System.currentTimeMillis().toULong(), payload)
        clientGatt[peerId]?.let { gatt -> clientChar[peerId]?.let { ch -> writePacket(gatt, ch, packet); return@runCatching true } }
        serverDevices[peerId]?.let { device -> notify(device, packet); return@runCatching true }
        false
    }.getOrDefault(false)

    // ── Characteristic I/O: one padded packet per value, NO length prefix ──

    // Per-address FIFO of pending characteristic writes. Android allows only ONE
    // outstanding writeCharacteristic per connection — the next must wait for
    // onCharacteristicWrite — so issuing announce + Noise m1 + 0x53 back-to-back
    // silently DROPPED the middle write (the handshake m1), and the Noise DM never
    // established. Serialize: enqueue, issue one at a time, drain on completion.
    private val clientWriteQueue = ConcurrentHashMap<String, java.util.concurrent.ConcurrentLinkedQueue<ByteArray>>()
    private val clientWriting = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()

    private fun writePacket(gatt: BluetoothGatt, ch: BluetoothGattCharacteristic, packet: ByteArray) {
        clientWriteQueue.getOrPut(gatt.device.address) { java.util.concurrent.ConcurrentLinkedQueue() }.add(packet)
        pumpClientWrites(gatt.device.address)
    }

    /** Issue the next queued write for [addr] iff none is in flight. */
    @Synchronized
    private fun pumpClientWrites(addr: String) {
        if (clientWriting.contains(addr)) return
        val q = clientWriteQueue[addr] ?: return
        val next = q.poll() ?: return
        val gatt = clientGatt[addr] ?: return
        val ch = clientChar[addr] ?: return
        clientWriting.add(addr)
        if (!issueWrite(gatt, ch, next)) {
            // The write wasn't accepted ⇒ onCharacteristicWrite won't fire; don't
            // stall the queue — drop it and move on.
            android.util.Log.w(TAG, "write not accepted for $addr — skipping")
            clientWriting.remove(addr)
            pumpClientWrites(addr)
        }
    }

    /** The actual platform write. Returns true if the stack accepted it (a
     *  completion callback will follow). Android 13+ (all current Pixels): the
     *  legacy `ch.value = …; writeCharacteristic(ch)` is deprecated and can
     *  silently no-op — use the value-taking API on 33+. */
    private fun issueWrite(gatt: BluetoothGatt, ch: BluetoothGattCharacteristic, packet: ByteArray): Boolean =
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            gatt.writeCharacteristic(ch, packet, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) ==
                android.bluetooth.BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION") run { ch.value = packet; gatt.writeCharacteristic(ch) }
        }

    // Server notify queue — same one-outstanding-at-a-time rule as client writes
    // (the next notify must wait for onNotificationSent), so the announce + 0x53 +
    // handshake m2 a server emits back-to-back must be serialized or they drop.
    private val serverNotifyQueue = ConcurrentHashMap<String, java.util.concurrent.ConcurrentLinkedQueue<ByteArray>>()
    private val serverNotifying = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()

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
        if (!issueNotify(s, device, ch, next)) {
            serverNotifying.remove(addr)
            pumpServerNotify(addr)
        }
    }

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

private fun String.hexToBytes(): ByteArray =
    ByteArray(length / 2) { ((this[it * 2].digitToInt(16) shl 4) or this[it * 2 + 1].digitToInt(16)).toByte() }

private fun ByteArray.toHex(): String =
    joinToString("") { (it.toInt() and 0xFF).toString(16).padStart(2, '0') }
