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
import chat.bitchat.sonar.mesh.BitchatPacket
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import uniffi.sonar_ffi.SonarNoise
import uniffi.sonar_ffi.noiseGenerateKeypair

/**
 * BLE GATT link for the mesh transport: drives the Noise XX handshake (using
 * the unit-tested core crypto via [SonarNoise]) over the bitchat characteristic,
 * then exchanges [BitchatPacket]-framed, Noise-encrypted messages.
 *
 * Roles: a [BluetoothGattServer] (peripheral) accepts inbound links and acts as
 * the Noise responder; [connect] (central) initiates a link to a discovered
 * peer and acts as the Noise initiator. The characteristic carries length-
 * prefixed records (handshake messages, then encrypted packets).
 *
 * STATUS: compiles and runs; the live link/handshake is verified on two BLE
 * devices (emulator has no radio). The crypto + framing it composes are
 * independently unit-tested (and the Noise path is proven on-device via the
 * MainActivity smoke). This is the radio-integration layer pending two-phone
 * verification — see issue #6.
 */
@SuppressLint("MissingPermission")
object MeshGatt {

    private val SERVICE: UUID = UUID.fromString("F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C")
    private val CHAR: UUID = UUID.fromString("A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D")
    private val CCC: UUID = UUID.fromString("00002902-0000-1000-0000-00805f9b34fb")

    private val ctx: Context get() = AppContextHolder.ctx
    private fun manager() = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager

    /** A static Noise identity for this device (kept for the app lifetime). */
    private val keypair by lazy { noiseGenerateKeypair() }

    private var server: BluetoothGattServer? = null
    private var characteristic: BluetoothGattCharacteristic? = null

    /** Per-link state keyed by remote device address. */
    private class Link(val noise: SonarNoise, var established: Boolean = false)
    private val serverLinks = ConcurrentHashMap<String, Link>()
    private val clientLinks = ConcurrentHashMap<String, Link>()
    private val onText: MutableList<(String, String) -> Unit> = mutableListOf()

    fun addMessageListener(cb: (peerId: String, text: String) -> Unit) { onText.add(cb) }

    /** Start the peripheral GATT server so peers can link to us. */
    fun startServer() {
        if (server != null) return
        val mgr = manager() ?: return
        val s = try { mgr.openGattServer(ctx, serverCallback) } catch (_: Throwable) { return } ?: return
        val service = BluetoothGattService(SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        val ch = BluetoothGattCharacteristic(
            CHAR,
            BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_WRITE,
        )
        ch.addDescriptor(BluetoothGattDescriptor(CCC, BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE))
        service.addCharacteristic(ch)
        s.addService(service)
        server = s
        characteristic = ch
    }

    fun stop() {
        try { server?.close() } catch (_: Throwable) {}
        server = null; characteristic = null
        serverLinks.clear(); clientLinks.clear()
    }

    // ── Central: initiate a link to a discovered peer ──
    fun connect(device: BluetoothDevice) {
        if (clientLinks.containsKey(device.address)) return
        clientLinks[device.address] = Link(SonarNoise.initiator(keypair.privateHex))
        try { device.connectGatt(ctx, false, clientCallback) } catch (_: Throwable) {
            clientLinks.remove(device.address)
        }
    }

    /** Send an encrypted text to an established peer (central side). */
    fun sendText(peerAddress: String, text: String): Boolean {
        val link = clientLinks[peerAddress] ?: return false
        if (!link.established) return false
        return runCatching {
            val packet = BitchatPacket(
                type = 1, ttl = 7, timestampMs = 0L,
                senderId = keypair.publicHex.hexToBytes().copyOf(8),
                recipientId = BitchatPacket.BROADCAST,
                payload = text.encodeToByteArray(), signature = null,
            ).encode()
            val ciphertext = link.noise.encrypt(packet)
            clientGatt[peerAddress]?.let { gatt ->
                clientChar[peerAddress]?.let { ch ->
                    writeRecord(gatt, ch, ciphertext)
                    true
                } ?: false
            } ?: false
        }.getOrDefault(false)
    }

    // ── GATT plumbing ──
    private val clientGatt = ConcurrentHashMap<String, BluetoothGatt>()
    private val clientChar = ConcurrentHashMap<String, BluetoothGattCharacteristic>()

    private val clientCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                clientGatt[gatt.device.address] = gatt
                gatt.requestMtu(517)
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                cleanupClient(gatt.device.address)
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            gatt.discoverServices()
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            val ch = gatt.getService(SERVICE)?.getCharacteristic(CHAR) ?: return
            clientChar[gatt.device.address] = ch
            // Enable notifications, then kick off the handshake (initiator m1).
            gatt.setCharacteristicNotification(ch, true)
            ch.getDescriptor(CCC)?.let {
                it.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                @Suppress("DEPRECATION") gatt.writeDescriptor(it)
            }
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            val link = clientLinks[gatt.device.address] ?: return
            val ch = clientChar[gatt.device.address] ?: return
            runCatching { writeRecord(gatt, ch, link.noise.writeMessage()) } // m1
        }

        override fun onCharacteristicChanged(gatt: BluetoothGatt, ch: BluetoothGattCharacteristic, value: ByteArray) {
            handleInboundClient(gatt, value)
        }

        @Deprecated("compat")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, ch: BluetoothGattCharacteristic) {
            @Suppress("DEPRECATION") handleInboundClient(gatt, ch.value ?: return)
        }
    }

    private fun handleInboundClient(gatt: BluetoothGatt, record: ByteArray) {
        val addr = gatt.device.address
        val link = clientLinks[addr] ?: return
        val ch = clientChar[addr] ?: return
        try {
            if (!link.established) {
                link.noise.readMessage(record) // m2
                if (link.noise.isFinished()) {
                    link.noise.finalize()
                    link.established = true
                } else {
                    writeRecord(gatt, ch, link.noise.writeMessage()) // m3
                    if (link.noise.isFinished()) { link.noise.finalize(); link.established = true }
                }
            } else {
                val packet = BitchatPacket.decode(link.noise.decrypt(record)) ?: return
                onText.forEach { it(addr, packet.payload.decodeToString()) }
            }
        } catch (_: Throwable) { cleanupClient(addr) }
    }

    private fun cleanupClient(addr: String) {
        clientLinks.remove(addr); clientChar.remove(addr)
        clientGatt.remove(addr)?.let { runCatching { it.close() } }
    }

    private val serverCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                serverLinks[device.address] = Link(SonarNoise.responder(keypair.privateHex))
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                serverLinks.remove(device.address)
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice, requestId: Int, ch: BluetoothGattCharacteristic,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray,
        ) {
            if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            val link = serverLinks[device.address] ?: return
            val record = stripLength(value) ?: return
            try {
                if (!link.established) {
                    link.noise.readMessage(record) // m1 (then m3)
                    if (link.noise.isFinished()) {
                        link.noise.finalize(); link.established = true
                    } else {
                        notify(device, link.noise.writeMessage()) // m2
                    }
                } else {
                    val packet = BitchatPacket.decode(link.noise.decrypt(record)) ?: return
                    onText.forEach { it(device.address, packet.payload.decodeToString()) }
                }
            } catch (_: Throwable) { serverLinks.remove(device.address) }
        }
    }

    private fun notify(device: BluetoothDevice, record: ByteArray) {
        val s = server ?: return
        val ch = characteristic ?: return
        val framed = withLength(record)
        @Suppress("DEPRECATION")
        run { ch.value = framed; s.notifyCharacteristicChanged(device, ch, false) }
    }

    // Records on the characteristic are 2-byte big-endian length-prefixed.
    private fun writeRecord(gatt: BluetoothGatt, ch: BluetoothGattCharacteristic, record: ByteArray) {
        val framed = withLength(record)
        @Suppress("DEPRECATION") run { ch.value = framed; gatt.writeCharacteristic(ch) }
    }

    private fun withLength(record: ByteArray): ByteArray =
        byteArrayOf(((record.size ushr 8) and 0xFF).toByte(), (record.size and 0xFF).toByte()) + record

    private fun stripLength(value: ByteArray): ByteArray? {
        if (value.size < 2) return null
        val len = ((value[0].toInt() and 0xFF) shl 8) or (value[1].toInt() and 0xFF)
        if (value.size < 2 + len) return null
        return value.copyOfRange(2, 2 + len)
    }
}

private fun String.hexToBytes(): ByteArray =
    ByteArray(length / 2) { ((this[it * 2].digitToInt(16) shl 4) or this[it * 2 + 1].digitToInt(16)).toByte() }
