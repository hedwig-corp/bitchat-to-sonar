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
import uniffi.sonar_ffi.MeshPacketInfo
import uniffi.sonar_ffi.MeshReassembler
import uniffi.sonar_ffi.MeshPublicMessage
import uniffi.sonar_ffi.NoiseKeypairHex
import uniffi.sonar_ffi.SonarNoise
import uniffi.sonar_ffi.meshBuildAnnounce
import uniffi.sonar_ffi.meshBuildPacket
import uniffi.sonar_ffi.meshBuildSignedPacket
import uniffi.sonar_ffi.meshBuildSignedPacketV2
import uniffi.sonar_ffi.meshBuildPublicMessage
import uniffi.sonar_ffi.meshDecodeFilePacket
import uniffi.sonar_ffi.meshDecodePacket
import uniffi.sonar_ffi.meshDecodePrivateMessage
import uniffi.sonar_ffi.meshEncodeFilePacket
import uniffi.sonar_ffi.meshEncodePrivateMessage
import uniffi.sonar_ffi.meshFragment
import uniffi.sonar_ffi.meshParseAnnounce
import uniffi.sonar_ffi.meshParsePublicMessage
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
    private const val TYPE_MESSAGE: UByte = 0x02u // public broadcast (Mesh channel)
    private const val TYPE_NOISE_HANDSHAKE: UByte = 0x10u
    private const val TYPE_NOISE_ENCRYPTED: UByte = 0x11u
    private const val TYPE_FRAGMENT: UByte = 0x20u
    private const val TYPE_FILE_TRANSFER: UByte = 0x22u
    private const val TYPE_SONAR_0X53: UByte = 0x53u
    private const val DEFAULT_TTL: UByte = 7u
    private const val MAX_SINGLE_GATT_PACKET_BYTES = 480
    private const val FRAGMENT_CHUNK_SIZE: UInt = 350u
    private const val MAX_FILE_TRANSFER_BYTES = 1024 * 1024
    private const val MAX_V1_FILE_PAYLOAD_BYTES = 0xFFFF

    private val ctx: Context get() = AppContextHolder.ctx
    private fun manager() = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager

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
    /** Display nickname carried in our announce (set by the host). */
    @Volatile private var nickname: String = ""
    /** Our latest Sonar Discovery (0x53) payload, broadcast alongside the announce. */
    @Volatile private var sonarPayload: ByteArray? = null

    private var server: BluetoothGattServer? = null
    private var characteristic: BluetoothGattCharacteristic? = null
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())

    /** Per-link Noise state (DMs only), keyed by remote BLE address. [startedMs]
     *  is when the current handshake attempt began, so a half-open handshake (m1
     *  sent but m2/m3 lost to an intermittent BLE link) can be retried instead of
     *  blocking forever. */
    private class Link(val noise: SonarNoise, var established: Boolean = false, var startedMs: Long = 0L)
    private val serverLinks = ConcurrentHashMap<String, Link>()
    private val serverDevices = ConcurrentHashMap<String, BluetoothDevice>()
    private val clientLinks = ConcurrentHashMap<String, Link>()
    /** The peer's announced bitchat peerID (ROTATES ~2 min), keyed by BLE address.
     *  Used only to address packets on the wire to the peer's CURRENT id. */
    private val peerIdByAddr = ConcurrentHashMap<String, String>()
    /** The peer's STABLE identity = fingerprint SHA256(noise static pubkey), keyed
     *  by BLE address. This is what the app keys conversations/radar by, so a peer
     *  stays one identity across peerID + MAC rotation (issue #12). */
    private val fingerprintByAddr = ConcurrentHashMap<String, String>()
    /** A 0x53 can arrive before the 0x01 announce on a fresh GATT link. Keep the
     *  raw payload until the announce supplies the stable fingerprint. */
    private val pendingSonarByAddr = ConcurrentHashMap<String, ByteArray>()
    private val reassembler = MeshReassembler()

    // Listeners (fired from BLE callback threads → concurrent lists). The String
    // identity passed to onText/onSonar/onLink is the stable FINGERPRINT.
    private val onText = java.util.concurrent.CopyOnWriteArrayList<(String, String, String) -> Unit>()
    private val onSonar = java.util.concurrent.CopyOnWriteArrayList<(String, ByteArray) -> Unit>()
    private val onAnnounce = java.util.concurrent.CopyOnWriteArrayList<(String, MeshAnnounceInfo, String) -> Unit>()
    private val onLink = java.util.concurrent.CopyOnWriteArrayList<(String) -> Unit>()
    private val onBroadcast = java.util.concurrent.CopyOnWriteArrayList<(MeshPublicMessage) -> Unit>()
    private val onFile = java.util.concurrent.CopyOnWriteArrayList<(String, String, String, String, ByteArray) -> Unit>()
    /** Dedup public broadcasts by message id (we receive from multiple links). */
    private val seenBroadcastIds = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
    /** Dedup file transfers by packet sender + packet timestamp. */
    private val seenFileIds = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()

    fun addMessageListener(cb: (fingerprint: String, messageId: String, text: String) -> Unit) { onText.add(cb) }
    fun addSonarListener(cb: (fingerprint: String, payload: ByteArray) -> Unit) { onSonar.add(cb) }
    /** Fired when a peer's signed announce is received + verified. The third arg
     *  is the peer's stable fingerprint (SHA256 of its noise static pubkey). */
    fun addAnnounceListener(cb: (bleAddr: String, info: MeshAnnounceInfo, fingerprint: String) -> Unit) { onAnnounce.add(cb) }
    fun addLinkListener(cb: (fingerprint: String) -> Unit) { onLink.add(cb) }

    /** Stable fingerprint for a peer = SHA256(noise static pubkey), full hex. */
    private fun fingerprintOf(noisePublicKeyHex: String): String =
        runCatching { Sha256.hash(noisePublicKeyHex.hexToBytes()).toHex() }.getOrDefault("")
    /** Fired for an incoming public broadcast (Mesh channel) message. */
    fun addBroadcastListener(cb: (MeshPublicMessage) -> Unit) { onBroadcast.add(cb) }
    /** Fired for an incoming private file transfer. The first arg is the peer's
     * stable fingerprint, matching [addMessageListener]. */
    fun addFileListener(cb: (fingerprint: String, messageId: String, filename: String, mime: String, bytes: ByteArray) -> Unit) {
        onFile.add(cb)
    }

    /** This device's 8-byte mesh node id (== bitchat peerID). MeshRadio puts it
     *  in the advert so two Sonar-Android peers can elect a single dialer. */
    fun nodeId(): ByteArray = myPeerIdHex.hexToBytes().copyOf(8)

    fun updateNickname(value: String) {
        val next = value.trim()
        if (next == nickname) return
        nickname = next
        broadcastDiscoveryNow(if (next.isBlank()) "nickname-clear" else "nickname")
    }

    fun updateSonarPayload(payload: ByteArray?) {
        val current = sonarPayload
        val changed = when {
            current == null && payload == null -> false
            current == null || payload == null -> true
            else -> !current.contentEquals(payload)
        }
        if (!changed) return
        sonarPayload = payload?.copyOf()
        broadcastDiscoveryNow("sonar")
    }

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

    private fun announceBytes(): ByteArray? {
        val nick = nickname.takeIf { it.isNotBlank() } ?: return null
        return runCatching {
            meshBuildAnnounce(
                ed25519SeedHex, myPeerIdHex, nick, keypair.publicHex,
                DEFAULT_TTL, System.currentTimeMillis().toULong(),
            )
        }.getOrNull()
    }

    private fun sonarBytes(): ByteArray? = sonarPayload?.let { p ->
        runCatching {
            // The 0x53 MUST be signed with the same Ed25519 key as the announce —
            // iOS `handleSonarAnnounce` rejects an unsigned/invalid one as
            // "unverified", so an unsigned 0x53 broke the npub exchange entirely.
            meshBuildSignedPacket(
                ed25519SeedHex, TYPE_SONAR_0X53, myPeerIdHex, "",
                DEFAULT_TTL, System.currentTimeMillis().toULong(), p,
            )
        }.getOrNull()
    }

    private fun broadcastDiscoveryNow(reason: String) {
        handler.post {
            val ann = announceBytes()
            val sonar = sonarBytes()
            android.util.Log.i(
                TAG,
                "refresh discovery ($reason) announce=${ann?.size ?: 0}B sonar=${sonar?.size ?: 0}B",
            )
            clientGatt.forEach { (_, gatt) ->
                val ch = clientChar[gatt.device.address] ?: return@forEach
                ann?.let { writePacket(gatt, ch, it) }
                sonar?.let { p -> handler.postDelayed({ writePacket(gatt, ch, p) }, 150) }
            }
            serverDevices.forEach { (_, device) ->
                ann?.let { notify(device, it) }
                sonar?.let { p -> handler.postDelayed({ notify(device, p) }, 150) }
            }
        }
    }

    private fun sendDiscoveryToAddr(addr: String, reason: String) {
        val ann = announceBytes()
        val sonar = sonarBytes()
        android.util.Log.i(
            TAG,
            "refresh discovery ($reason) addr=$addr announce=${ann?.size ?: 0}B sonar=${sonar?.size ?: 0}B",
        )
        val gatt = clientGatt[addr]
        val ch = clientChar[addr]
        if (gatt != null && ch != null) {
            ann?.let { writePacket(gatt, ch, it) }
            sonar?.let { writePacket(gatt, ch, it) }
        }
        val device = serverDevices[addr]
        if (device != null) {
            ann?.let { notify(device, it) }
            sonar?.let { notify(device, it) }
        }
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
        serverLinks.clear(); serverDevices.clear(); peerIdByAddr.clear(); fingerprintByAddr.clear(); recentDials.clear()
        pendingSonarByAddr.clear()
        pendingSends.clear()
        seenFileIds.clear()
    }

    private val serverCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                serverDevices[device.address] = device
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                serverLinks.remove(device.address); serverDevices.remove(device.address)
                peerIdByAddr.remove(device.address); fingerprintByAddr.remove(device.address)
                pendingSonarByAddr.remove(device.address)
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
            // The central just subscribed → send a short discovery burst. iOS only
            // accepts 0x53 after it has verified the base 0x01 announce, and the
            // first GATT notification pair is easy to lose during role setup.
            android.util.Log.i(TAG, "server ${device.address}: central subscribed → notify discovery burst")
            notifyDiscoveryBurst(device)
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
    /** Retry a half-open Noise handshake (m1 sent, m2/m3 never arrived) no sooner
     *  than this — driven by the peer's ~15s announce cadence. */
    private const val HANDSHAKE_RETRY_MS = 8_000L

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
        clientLinks.remove(addr); clientChar.remove(addr); peerIdByAddr.remove(addr); fingerprintByAddr.remove(addr)
        pendingSonarByAddr.remove(addr)
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
                val fp = fingerprintOf(ann.noisePublicKeyHex)
                android.util.Log.i(TAG, "ANNOUNCE from $addr → '${ann.nickname}' peerId=${ann.senderIdHex} fp=${fp.take(8)}…")
                peerIdByAddr[addr] = ann.senderIdHex
                if (fp.isNotEmpty()) fingerprintByAddr[addr] = fp
                clientPending.remove(addr) // a real peer answered — keep this link
                onAnnounce.forEach { it(addr, ann, fp) }
                pendingSonarByAddr.remove(addr)?.let { pending ->
                    if (fp.isNotEmpty()) onSonar.forEach { it(fp, pending) }
                }
                // Central: now that we know the peer's peerID, open a Noise link
                // for DMs (initiator). Peripheral waits for the peer's 0x10.
                // Re-handshake if there is no link OR the current one is still
                // half-open after HANDSHAKE_RETRY_MS — an m1 whose m2/m3 was lost
                // to a flaky BLE link must not block re-handshaking forever (that
                // left `hasMeshLink` false even with the peer right there, so DMs
                // silently fell back to "internet" / never sent).
                val existing = clientLinks[addr]
                val stale = existing != null && !existing.established &&
                    System.currentTimeMillis() - existing.startedMs > HANDSHAKE_RETRY_MS
                if (!fromServer && gatt != null && (existing == null || stale)) {
                    android.util.Log.i(TAG, "starting Noise handshake (initiator) → $addr${if (stale) " [retry]" else ""}")
                    startHandshake(gatt, addr, ann.senderIdHex)
                } else {
                    android.util.Log.i(TAG, "no handshake: fromServer=$fromServer gatt=${gatt != null} established=${existing?.established}")
                }
            }
            TYPE_MESSAGE -> {
                // Public broadcast (Mesh channel). Parse the whole packet; dedup
                // by message id since we may hear it on several links.
                val pm = runCatching { meshParsePublicMessage(value) }.getOrNull() ?: return
                if (seenBroadcastIds.add("${pm.senderIdHex}-${pm.timestampMs}")) {
                    if (seenBroadcastIds.size > 1024) seenBroadcastIds.clear()
                    android.util.Log.i(TAG, "rx broadcast from ${pm.senderIdHex}: ${pm.content.take(40)}")
                    onBroadcast.forEach { it(pm) }
                    // Multi-hop: flood the packet onward so the mesh extends past
                    // our direct neighbours (this is how a message crosses A↔relay↔B
                    // when A and B aren't directly connected).
                    relayPacket(value, addr)
                }
            }
            TYPE_NOISE_HANDSHAKE -> handleHandshake(addr, info.payload, fromServer, device, gatt)
            TYPE_NOISE_ENCRYPTED -> handleEncrypted(addr, info.payload, fromServer)
            TYPE_FRAGMENT -> handleFragment(addr, info.senderIdHex, info.payload, fromServer, device, gatt)
            TYPE_FILE_TRANSFER -> handleFileTransfer(addr, value, info)
            TYPE_SONAR_0X53 -> {
                // Tag the 0x53 with the peer's STABLE fingerprint (from its 0x01
                // announce) so its Sonar profile/npub stays correlated to the
                // peer across peerID + BLE rotation. Packet order is not
                // guaranteed, so cache until the announce lands.
                val fp = fingerprintByAddr[addr]
                if (fp == null) {
                    pendingSonarByAddr[addr] = info.payload
                    return
                }
                onSonar.forEach { it(fp, info.payload) }
            }
            else -> android.util.Log.i(TAG, "ignoring mesh packet type=${info.packetType} from $addr")
        }
    }

    private fun handleFragment(
        addr: String,
        senderIdHex: String,
        payload: ByteArray,
        fromServer: Boolean,
        device: BluetoothDevice?,
        gatt: BluetoothGatt?,
    ) {
        val full = runCatching { reassembler.add(senderIdHex, payload) }.getOrNull() ?: return
        android.util.Log.i(TAG, "reassembled fragment stream from $addr (${full.size}B)")
        handlePacket(addr, full, fromServer, device, gatt)
    }

    // ── Noise DM handshake (lazy) ──

    private fun startHandshake(gatt: BluetoothGatt, addr: String, peerIdHex: String) {
        val ch = clientChar[addr] ?: run {
            android.util.Log.w(TAG, "startHandshake $addr: no clientChar"); return
        }
        val link = Link(SonarNoise.initiator(keypair.privateHex), startedMs = System.currentTimeMillis())
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

    /** The established Noise session for a peer identity, across connections.
     *  bitchat keeps ONE Noise session per peer and uses it over either BLE
     *  connection (each device connects to the other → two GATT links). Android
     *  keys sessions by BLE address, so a packet arriving on the OTHER connection
     *  than the handshake had no session → dropped (iOS delivery acks + iOS→Android
     *  DMs were silently lost). Resolve the session by fingerprint: prefer the
     *  client link (we were initiator), else any established link for that fp. */
    private fun establishedLinkForFp(fp: String): Link? {
        for ((a, f) in fingerprintByAddr) {
            if (f != fp) continue
            clientLinks[a]?.takeIf { it.established }?.let { return it }
            serverLinks[a]?.takeIf { it.established }?.let { return it }
        }
        return null
    }

    private fun handleEncrypted(addr: String, ciphertext: ByteArray, fromServer: Boolean) {
        val fp = fingerprintByAddr[addr]
        // Prefer this connection's own session; fall back to the peer's session on
        // its OTHER connection (snow does not advance the nonce on a failed decrypt,
        // so this fallback can't desync a healthy session).
        val link = (if (fromServer) serverLinks[addr] else clientLinks[addr])?.takeIf { it.established }
            ?: fp?.let { establishedLinkForFp(it) }
            ?: return
        runCatching {
            val plain = link.noise.decrypt(ciphertext)
            // inner NoisePayloadType: 0x01 privateMessage, 0x02 readReceipt,
            // 0x03 delivered ack. We currently surface only 0x01; the others are
            // logged (a 0x03 confirms the peer received + stored our DM).
            android.util.Log.i(TAG, "rx 0x11 inner type=0x${(plain.firstOrNull()?.toInt()?.and(0xFF) ?: -1).toString(16)} (${plain.size}B) from $addr")
            // Surface the STABLE fingerprint so the app keys the conversation by
            // peer identity across peerID + BLE-address rotation (issue #12).
            val idFp = fp ?: peerIdByAddr[addr] ?: addr
            meshDecodePrivateMessage(plain)?.let { pm -> onText.forEach { it(idFp, pm.messageId, pm.content) } }
        }
    }

    private fun handleFileTransfer(addr: String, packetBytes: ByteArray, info: MeshPacketInfo) {
        val recipient = info.recipientIdHex.lowercase()
        val broadcast = "ff".repeat(8)
        if (recipient.isNotEmpty() && recipient != myPeerIdHex && recipient != broadcast) return

        val fp = fingerprintByAddr[addr] ?: peerIdByAddr[addr] ?: return
        val tsMs = packetTimestampMs(packetBytes) ?: System.currentTimeMillis()
        val payloadHash = Sha256.hash(info.payload).copyOf(8).toHex()
        val transferKey = "${info.senderIdHex}-$tsMs-$payloadHash"
        if (!seenFileIds.add(transferKey)) return
        if (seenFileIds.size > 1024) seenFileIds.clear()

        val file = runCatching { meshDecodeFilePacket(info.payload) }.getOrNull() ?: return
        val bytes = file.content
        if (bytes.isEmpty() || bytes.size > MAX_FILE_TRANSFER_BYTES) {
            android.util.Log.w(TAG, "dropping file transfer size=${bytes.size} from $addr")
            return
        }
        val mime = normalizedMime(file.mimeType, bytes) ?: run {
            android.util.Log.w(TAG, "dropping file transfer mime=${file.mimeType} size=${bytes.size} from $addr")
            return
        }
        val filename = safeFileName(file.fileName, mime, tsMs)
        val messageId = "$transferKey-file"
        onFile.forEach { it(fp, messageId, filename, mime, bytes) }
    }

    private fun handshakePacket(peerIdHex: String, noiseMsg: ByteArray): ByteArray =
        meshBuildPacket(TYPE_NOISE_HANDSHAKE, myPeerIdHex, peerIdHex, DEFAULT_TTL, System.currentTimeMillis().toULong(), noiseMsg)

    private fun linkEstablished(addr: String) {
        // Resolve the stable fingerprint so listeners + the pending-send flush key
        // by peer identity, not the rotating peerID/address (issue #12).
        val fp = fingerprintByAddr[addr] ?: peerIdByAddr[addr] ?: addr
        android.util.Log.i(TAG, "✅ Noise link ESTABLISHED with $addr (peerId=${peerIdByAddr[addr]} fp=${fp.take(8)}…)")
        onLink.forEach { it(fp) }
        flushPending(fp)
    }

    private fun encryptedPrivatePacket(peerAddress: String, link: Link, messageId: String, text: String): ByteArray {
        val plain = meshEncodePrivateMessage(messageId, text)
        val ciphertext = link.noise.encrypt(plain)
        val peerId = peerIdByAddr[peerAddress] ?: ""
        return meshBuildPacket(TYPE_NOISE_ENCRYPTED, myPeerIdHex, peerId, DEFAULT_TTL, System.currentTimeMillis().toULong(), ciphertext)
    }

    private fun fileTransferPacket(peerAddress: String, bytes: ByteArray, filename: String, mimeType: String): ByteArray? {
        if (bytes.isEmpty() || bytes.size > MAX_FILE_TRANSFER_BYTES) return null
        val ts = System.currentTimeMillis()
        val mime = normalizedMime(mimeType, bytes) ?: return null
        val safeName = safeFileName(filename, mime, ts)
        val payload = runCatching {
            meshEncodeFilePacket(safeName, bytes.size.toULong(), mime, bytes)
        }.getOrNull() ?: return null
        val peerId = peerIdByAddr[peerAddress] ?: return null
        return runCatching {
            if (payload.size <= MAX_V1_FILE_PAYLOAD_BYTES) {
                meshBuildSignedPacket(ed25519SeedHex, TYPE_FILE_TRANSFER, myPeerIdHex, peerId, DEFAULT_TTL, ts.toULong(), payload)
            } else {
                meshBuildSignedPacketV2(
                    ed25519SeedHex,
                    TYPE_FILE_TRANSFER,
                    myPeerIdHex,
                    peerId,
                    emptyList<String>(),
                    DEFAULT_TTL,
                    ts.toULong(),
                    payload,
                )
            }
        }.getOrNull()
    }

    private fun randomFragmentIdHex(): String =
        ByteArray(8).also { SecureRandom().nextBytes(it) }.toHex()

    private fun writePacketMaybeFragmented(
        peerAddress: String,
        packet: ByteArray,
        originalType: UByte = TYPE_NOISE_ENCRYPTED,
        write: (ByteArray) -> Unit,
    ): Boolean = runCatching {
        if (packet.size <= MAX_SINGLE_GATT_PACKET_BYTES) {
            write(packet)
            return@runCatching true
        }

        val peerId = peerIdByAddr[peerAddress] ?: ""
        val fragments = meshFragment(packet, randomFragmentIdHex(), originalType, FRAGMENT_CHUNK_SIZE)
        android.util.Log.i(TAG, "fragmenting 0x${originalType.toString(16)} packet ${packet.size}B into ${fragments.size} chunk(s) → $peerAddress")
        fragments.forEach { payload ->
            val fragmentPacket = meshBuildPacket(
                TYPE_FRAGMENT,
                myPeerIdHex,
                peerId,
                DEFAULT_TTL,
                System.currentTimeMillis().toULong(),
                payload,
            )
            write(fragmentPacket)
        }
        true
    }.getOrElse {
        android.util.Log.w(TAG, "fragment/write failed for $peerAddress: ${it.message}")
        false
    }

    /** Send an encrypted DM to an established, writable peer route. */
    fun sendText(peerAddress: String, messageId: String, text: String): Boolean = runCatching {
        val client = clientLinks[peerAddress]?.takeIf { it.established }
        val gatt = clientGatt[peerAddress]
        val ch = clientChar[peerAddress]
        if (client != null && gatt != null && ch != null) {
            return@runCatching writePacketMaybeFragmented(
                peerAddress,
                encryptedPrivatePacket(peerAddress, client, messageId, text),
            ) { writePacket(gatt, ch, it) }
        }
        val server = serverLinks[peerAddress]?.takeIf { it.established }
        val device = serverDevices[peerAddress]
        if (server != null && device != null) {
            return@runCatching writePacketMaybeFragmented(
                peerAddress,
                encryptedPrivatePacket(peerAddress, server, messageId, text),
            ) { notify(device, it) }
        }
        false
    }.getOrElse {
        android.util.Log.w(TAG, "sendText failed for $peerAddress: ${it.message}")
        false
    }

    /** DMs queued for a peer that has no live link yet, flushed when one forms.
     *  Mesh links are intermittent (BLE MAC rotation + scanner stalls), so a peer
     *  can be visible on the radar without a live encrypted link this instant —
     *  queue the message instead of failing, and deliver it on (re)connect. */
    private val pendingSends = ConcurrentHashMap<String, java.util.concurrent.ConcurrentLinkedQueue<Pair<String, String>>>()

    private fun canSendOnAddr(addr: String): Boolean =
        (clientLinks[addr]?.established == true && clientGatt[addr] != null && clientChar[addr] != null) ||
            (serverLinks[addr]?.established == true && serverDevices[addr] != null)

    /** The BLE address with an established, writable Noise route to [fingerprint].
     *  Resolves the current address after peerID/MAC rotation. */
    private fun sendableAddrFor(fingerprint: String): String? =
        fingerprintByAddr.entries.firstOrNull { (a, fp) ->
            fp == fingerprint && canSendOnAddr(a)
        }?.key

    /** Send a DM addressed by the peer's stable fingerprint (the radar/UI key).
     *  Sends immediately over a live Noise link, else QUEUES it to deliver when a
     *  link (re)establishes. Always returns true — the message is accepted (the
     *  UI echoes it optimistically); "false" used to surface a scary "not
     *  connected" toast even though the peer was right there. */
    fun sendTextToPeer(fingerprint: String, messageId: String, text: String): Boolean {
        val addr = sendableAddrFor(fingerprint)
        if (addr != null && sendText(addr, messageId, text)) return true
        pendingSends.getOrPut(fingerprint) { java.util.concurrent.ConcurrentLinkedQueue() }.add(messageId to text)
        return true
    }

    /** Immediate send for real-time controls. Never queues. */
    fun sendTextToPeerNow(fingerprint: String, messageId: String, text: String): Boolean {
        val addr = sendableAddrFor(fingerprint) ?: return false
        sendDiscoveryToAddr(addr, "pre-control")
        return sendText(addr, messageId, text)
    }

    /** Send a private file transfer to a live peer route. Binary media is not
     * queued: large stale transfers after a BLE reconnect are worse than an
     * immediate route failure, and Marmot remains the out-of-range fallback. */
    fun sendFileToPeer(fingerprint: String, messageId: String, bytes: ByteArray, filename: String, mimeType: String): Boolean {
        val addr = sendableAddrFor(fingerprint) ?: return false
        sendDiscoveryToAddr(addr, "pre-file")
        return sendFile(addr, bytes, filename, mimeType)
    }

    private fun sendFile(peerAddress: String, bytes: ByteArray, filename: String, mimeType: String): Boolean = runCatching {
        val packet = fileTransferPacket(peerAddress, bytes, filename, mimeType) ?: return@runCatching false
        val gatt = clientGatt[peerAddress]
        val ch = clientChar[peerAddress]
        if (gatt != null && ch != null) {
            return@runCatching writePacketMaybeFragmented(peerAddress, packet, TYPE_FILE_TRANSFER) { writePacket(gatt, ch, it) }
        }
        val device = serverDevices[peerAddress]
        if (device != null) {
            return@runCatching writePacketMaybeFragmented(peerAddress, packet, TYPE_FILE_TRANSFER) { notify(device, it) }
        }
        false
    }.getOrElse {
        android.util.Log.w(TAG, "sendFile failed for $peerAddress: ${it.message}")
        false
    }

    /** Flush any queued DMs to [fingerprint] now that an encrypted link is up. */
    private fun flushPending(fingerprint: String) {
        val q = pendingSends[fingerprint] ?: return
        while (true) {
            val (mid, txt) = q.poll() ?: break
            if (!sendTextToPeerNow(fingerprint, mid, txt)) {
                q.add(mid to txt)
                break
            }
        }
    }

    /** True iff there is an established encrypted route we can write to right now. */
    fun hasLink(fingerprint: String): Boolean = sendableAddrFor(fingerprint) != null

    /** True iff [addr] is currently linked (dialed, dialing, or accepted as a
     *  server) — used by the scanner to decide whether a re-sighting should
     *  trigger a recovery re-dial. Covers a live client GATT, an in-flight dial,
     *  and an inbound server connection so we don't pile redundant links on a
     *  peer we already reach. */
    fun isLinkedAddr(addr: String): Boolean =
        clientGatt.containsKey(addr) || clientPending.contains(addr) || serverDevices.containsKey(addr)

    /** Broadcast a PUBLIC message (the BLE "Mesh" channel) to every connected mesh
     *  peer — raw UTF-8 content + Ed25519-signed (type 0x02, no recipient), exactly
     *  like a bitchat public message (BLEService payload = Data(content.utf8)).
     *  Returns false if no peer is connected. */
    fun broadcastPublic(text: String): Boolean = runCatching {
        val ts = System.currentTimeMillis().toULong()
        val packet = meshBuildPublicMessage(ed25519SeedHex, myPeerIdHex, text, DEFAULT_TTL, ts)
        seenBroadcastIds.add("$myPeerIdHex-$ts") // skip our own echo if it loops back
        var peers = 0
        clientGatt.forEach { (addr, gatt) ->
            clientChar[addr]?.let { ch -> writePacket(gatt, ch, packet); peers++ }
        }
        serverDevices.forEach { (_, device) -> notify(device, packet); peers++ }
        android.util.Log.i(TAG, "broadcast '${text.take(40)}' to $peers peer(s)")
        peers > 0
    }.getOrDefault(false)

    /** Number of mesh peers we can currently reach with a broadcast. */
    fun connectedPeerCount(): Int = (clientChar.keys + serverDevices.keys).size

    /** Flood a received broadcast packet onward (TTL gossip), so messages cross
     *  the mesh past our direct neighbours. TTL lives at header byte 2 and is NOT
     *  part of the signature (it's signed as 0), so decrementing it is safe.
     *  [fromAddr] is excluded so we don't echo it straight back. */
    private fun relayPacket(packet: ByteArray, fromAddr: String) {
        if (packet.size < 3) return
        val ttl = packet[2].toInt() and 0xFF
        if (ttl <= 1) return // would reach 0 — drop
        val relayed = packet.copyOf()
        relayed[2] = (ttl - 1).toByte()
        clientGatt.forEach { (addr, gatt) ->
            if (addr != fromAddr) clientChar[addr]?.let { ch -> writePacket(gatt, ch, relayed) }
        }
        serverDevices.forEach { (addr, device) ->
            if (addr != fromAddr) notify(device, relayed)
        }
    }

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

    private fun notifyDiscoveryBurst(device: BluetoothDevice) {
        listOf(0L, 350L, 1_200L).forEach { delayMs ->
            handler.postDelayed({
                val ann = announceBytes()
                val sonar = sonarBytes()
                android.util.Log.i(
                    TAG,
                    "server ${device.address}: discovery notify announce=${ann?.size ?: 0}B sonar=${sonar?.size ?: 0}B delay=${delayMs}ms",
                )
                ann?.let { notify(device, it) }
                sonar?.let { p -> handler.postDelayed({ notify(device, p) }, 150) }
            }, delayMs)
        }
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

private fun packetTimestampMs(packet: ByteArray): Long? {
    if (packet.size < 11) return null
    var ts = 0L
    for (i in 3 until 11) ts = (ts shl 8) or (packet[i].toLong() and 0xFF)
    return ts
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
