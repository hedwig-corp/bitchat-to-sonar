package chat.bitchat.sonar

import com.sun.jna.Library
import com.sun.jna.Native
import com.sun.jna.Pointer
import java.nio.file.Files
import java.util.concurrent.atomic.AtomicLong

/** JNA view of the Rust BLE bridge (`core/sonar-ble`, libsonar_ble). */
private interface BleLib : Library {
    fun sonar_ble_start()
    fun sonar_ble_stop()
    fun sonar_ble_peers_json(): Pointer?
    fun sonar_ble_free(ptr: Pointer?)
    fun sonar_ble_set_announce(data: ByteArray?, len: Long)
    fun sonar_ble_start_advertising()
    fun sonar_ble_stop_advertising()
    fun sonar_ble_advertising_loop_active(): Int
    fun sonar_ble_drain_rx_json(): Pointer?
    fun sonar_ble_notify(data: ByteArray?, len: Long): Int
}

/**
 * Desktop BLE radio, bridged to the native `sonar-ble` library (CoreBluetooth on
 * macOS / BlueZ on Linux) over JNA — the same "native shim behind the JVM"
 * pattern as `sonar-core`. This is what gives the Compose Desktop app real
 * Bluetooth discovery: the JVM "can't do BLE" wall is just "no pure-JVM BLE lib",
 * dissolved by loading native code.
 *
 * Scope: the central/scan role (discover nearby bitchat-mesh advertisers → radar
 * peers). Peripheral advertising + the Noise-over-GATT transport are next.
 */
object BleBridge {
    private val advertisingGeneration = AtomicLong()
    @Volatile private var advertisingWanted = false
    data class Dev(val id: String, val name: String?, val rssi: Int)

    private val lib: BleLib? by lazy { load() }

    /** True when the native BLE library loaded for this OS/arch. */
    val available: Boolean get() = lib != null

    private fun load(): BleLib? = runCatching {
        val mapped = System.mapLibraryName("sonar_ble") // libsonar_ble.dylib / .so / sonar_ble.dll
        val prefix = runCatching { com.sun.jna.Platform.RESOURCE_PREFIX }.getOrNull()
        val stream = listOfNotNull(prefix?.let { "/$it/$mapped" }, "/darwin/$mapped")
            .firstNotNullOfOrNull { javaClass.getResourceAsStream(it) }
            ?: return null
        val tmp = Files.createTempDirectory("sonar-ble").resolve(mapped)
        stream.use { Files.copy(it, tmp) }
        tmp.toFile().deleteOnExit()
        Native.load(tmp.toAbsolutePath().toString(), BleLib::class.java)
    }.getOrNull()

    fun start() { lib?.sonar_ble_start() }
    fun stop() { lib?.sonar_ble_stop() }

    /** Peripheral role: set the signed announce served on subscribe, then advertise. */
    fun setAnnounce(bytes: ByteArray) { lib?.sonar_ble_set_announce(bytes, bytes.size.toLong()) }
    fun startAdvertising() {
        advertisingWanted = true
        val l = lib ?: return
        val generation = advertisingGeneration.incrementAndGet()
        startAdvertisingWhenNativeOwnerIsFree(l, generation)
    }
    fun stopAdvertising() {
        advertisingWanted = false
        advertisingGeneration.incrementAndGet()
        lib?.sonar_ble_stop_advertising()
    }

    /** Drop the native GATT generation and start a fresh peripheral manager only
     * after the old CoreBluetooth/BlueZ owner has fully torn down. This runs on
     * a daemon worker so a missing callback can never block the UI or mesh pump. */
    fun restartAdvertising() {
        val l = lib ?: return
        if (!advertisingWanted) return
        val generation = advertisingGeneration.incrementAndGet()
        l.sonar_ble_stop_advertising()
        startAdvertisingWhenNativeOwnerIsFree(l, generation)
    }

    /** Preserve the newest wanted start across asynchronous native teardown.
     * Older waiters self-cancel through [advertisingGeneration]. */
    private fun startAdvertisingWhenNativeOwnerIsFree(l: BleLib, generation: Long) {
        if (!advertisingWanted || advertisingGeneration.get() != generation) return
        if (l.sonar_ble_advertising_loop_active() == 0) {
            l.sonar_ble_start_advertising()
            return
        }
        Thread({
            var backoffMs = 25L
            while (true) {
                if (!advertisingWanted || advertisingGeneration.get() != generation) return@Thread
                if (l.sonar_ble_advertising_loop_active() == 0) {
                    if (!advertisingWanted || advertisingGeneration.get() != generation) return@Thread
                    l.sonar_ble_start_advertising()
                    return@Thread
                }
                try {
                    Thread.sleep(backoffMs)
                } catch (_: InterruptedException) {
                    return@Thread
                }
                backoffMs = (backoffMs * 2).coerceAtMost(250L)
            }
        }, "sonar-ble-restart").apply { isDaemon = true }.start()
    }

    /** Send a raw mesh packet (Noise handshake reply / encrypted DM) to subscribed
     *  centrals via the GATT notify path. */
    /** True when the native bridge accepted the packet into its bounded queue. */
    fun notify(bytes: ByteArray): Boolean =
        lib?.sonar_ble_notify(bytes, bytes.size.toLong()) == 1

    /** Packets centrals wrote to our GATT characteristic (announce/handshake). */
    fun drainRx(): List<ByteArray> {
        val l = lib ?: return emptyList()
        val ptr = l.sonar_ble_drain_rx_json() ?: return emptyList()
        val json = try { ptr.getString(0) } finally { l.sonar_ble_free(ptr) }
        return HEX.findAll(json).mapNotNull { runCatching { hexToBytes(it.groupValues[1]) }.getOrNull() }.toList()
    }

    private val HEX = Regex("\"([0-9a-fA-F]+)\"")
    private fun hexToBytes(s: String): ByteArray =
        ByteArray(s.length / 2) { ((s[it * 2].digitToInt(16) shl 4) or s[it * 2 + 1].digitToInt(16)).toByte() }

    /** Fresh bitchat-mesh peers discovered by the background scan. */
    fun peers(): List<Dev> {
        val l = lib ?: return emptyList()
        val ptr = l.sonar_ble_peers_json() ?: return emptyList()
        val json = try { ptr.getString(0) } finally { l.sonar_ble_free(ptr) }
        return parse(json)
    }

    // The bridge emits a flat JSON array of {id,name,rssi,bitchat}; parse without
    // pulling a JSON dependency onto the desktop classpath.
    private val OBJ = Regex("""\{[^}]*\}""")
    private val ID = Regex(""""id"\s*:\s*"([^"]*)"""")
    private val RSSI = Regex(""""rssi"\s*:\s*(-?\d+)""")
    private val NAME = Regex(""""name"\s*:\s*"([^"]*)"""")

    private fun parse(json: String): List<Dev> =
        OBJ.findAll(json).mapNotNull { m ->
            val o = m.value
            val id = ID.find(o)?.groupValues?.get(1) ?: return@mapNotNull null
            val rssi = RSSI.find(o)?.groupValues?.get(1)?.toIntOrNull() ?: 0
            val name = NAME.find(o)?.groupValues?.get(1)
            Dev(id, name, rssi)
        }.toList()
}
