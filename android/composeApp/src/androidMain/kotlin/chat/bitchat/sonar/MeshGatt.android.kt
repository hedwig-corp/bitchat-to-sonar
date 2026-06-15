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
    private val CCC: UUID = UUID.fromString("00002902-0000-1000-0000-00805f9b34fb")

    // bitchat packet types (subset; full set in sonar_core::mesh::msg_type).
    private const val TYPE_ANNOUNCE: UByte = 0x01u
    private const val TYPE_NOISE_HANDSHAKE: UByte = 0x10u
    private const val TYPE_NOISE_ENCRYPTED: UByte = 0x11u
    private const val TYPE_SONAR_0X53: UByte = 0x53u
    private const val DEFAULT_TTL: UByte = 7u

    private val ctx: Context get() = AppContextHolder.ctx
    private fun manager() = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager

    // ── This device's mesh identity (per app session) ──
    /** Noise static keypair (X25519). */
    private val keypair by lazy { noiseGenerateKeypair() }
    /** Ed25519 announce-signing seed (32 bytes, hex). */
    private val ed25519SeedHex by lazy {
        ByteArray(32).also { SecureRandom().nextBytes(it) }.toHex()
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
        serverLinks.clear(); serverDevices.clear(); clientLinks.clear(); peerIdByAddr.clear()
    }

    private val serverCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                serverDevices[device.address] = device
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                serverLinks.remove(device.address); serverDevices.remove(device.address)
                peerIdByAddr.remove(device.address)
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice, requestId: Int, descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray,
        ) {
            if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            // The central just subscribed → broadcast our announce, then the 0x53.
            // GATT serializes writes/notifies, so defer the 0x53 so it doesn't
            // collide with the announce (the priority for discovery).
            announceBytes()?.let { notify(device, it) }
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

    /** Connect to a discovered peer to exchange announces (and enable DMs). */
    fun connect(device: BluetoothDevice) {
        if (clientGatt.containsKey(device.address)) return
        android.util.Log.i(TAG, "dialing ${device.address} (TRANSPORT_LE)")
        try {
            device.connectGatt(ctx, false, clientCallback, BluetoothDevice.TRANSPORT_LE)
        } catch (t: Throwable) {
            android.util.Log.e(TAG, "connectGatt failed for ${device.address}", t)
        }
    }

    private val clientCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                clientGatt[gatt.device.address] = gatt
                gatt.requestMtu(517)
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                if (status != 0) gatt.close()
                cleanupClient(gatt.device.address)
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) { gatt.discoverServices() }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            val ch = gatt.getService(SERVICE)?.getCharacteristic(CHAR) ?: return
            clientChar[gatt.device.address] = ch
            gatt.setCharacteristicNotification(ch, true)
            ch.getDescriptor(CCC)?.let {
                @Suppress("DEPRECATION")
                run { it.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE; gatt.writeDescriptor(it) }
            }
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            // Notifications enabled → send our announce, then (deferred, so the
            // back-to-back GATT writes don't collide) our 0x53.
            val ch = clientChar[gatt.device.address] ?: return
            announceBytes()?.let { writePacket(gatt, ch, it) }
            sonarBytes()?.let { p -> handler.postDelayed({ writePacket(gatt, ch, p) }, 150) }
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
        clientGatt.remove(addr)?.let { runCatching { it.close() } }
    }

    // ── Receive: route every characteristic value (one padded packet) by type ──

    private fun handlePacket(
        addr: String, value: ByteArray, fromServer: Boolean,
        device: BluetoothDevice? = null, gatt: BluetoothGatt? = null,
    ) {
        val info = runCatching { meshDecodePacket(value) }.getOrNull() ?: return
        when (info.packetType) {
            TYPE_ANNOUNCE -> {
                val ann = runCatching { meshParseAnnounce(value) }.getOrNull() ?: return
                peerIdByAddr[addr] = ann.senderIdHex
                onAnnounce.forEach { it(addr, ann) }
                // Central: now that we know the peer's peerID, open a Noise link
                // for DMs (initiator). Peripheral waits for the peer's 0x10.
                if (!fromServer && gatt != null && clientLinks[addr] == null) {
                    startHandshake(gatt, addr, ann.senderIdHex)
                }
            }
            TYPE_NOISE_HANDSHAKE -> handleHandshake(addr, info.payload, fromServer, device, gatt)
            TYPE_NOISE_ENCRYPTED -> handleEncrypted(addr, info.payload, fromServer)
            TYPE_SONAR_0X53 -> onSonar.forEach { it(addr, info.payload) }
            else -> android.util.Log.i(TAG, "ignoring mesh packet type=${info.packetType} from $addr")
        }
    }

    // ── Noise DM handshake (lazy) ──

    private fun startHandshake(gatt: BluetoothGatt, addr: String, peerIdHex: String) {
        val ch = clientChar[addr] ?: return
        val link = Link(SonarNoise.initiator(keypair.privateHex))
        clientLinks[addr] = link
        runCatching {
            val m1 = link.noise.writeMessage()
            writePacket(gatt, ch, handshakePacket(peerIdHex, m1))
        }
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

    private fun linkEstablished(peerId: String) { onLink.forEach { it(peerId) } }

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

    private fun writePacket(gatt: BluetoothGatt, ch: BluetoothGattCharacteristic, packet: ByteArray) {
        @Suppress("DEPRECATION") run { ch.value = packet; gatt.writeCharacteristic(ch) }
    }

    private fun notify(device: BluetoothDevice, packet: ByteArray) {
        val s = server ?: return
        val ch = characteristic ?: return
        @Suppress("DEPRECATION") run { ch.value = packet; s.notifyCharacteristicChanged(device, ch, false) }
    }
}

private fun String.hexToBytes(): ByteArray =
    ByteArray(length / 2) { ((this[it * 2].digitToInt(16) shl 4) or this[it * 2 + 1].digitToInt(16)).toByte() }

private fun ByteArray.toHex(): String =
    joinToString("") { (it.toInt() and 0xFF).toString(16).padStart(2, '0') }
