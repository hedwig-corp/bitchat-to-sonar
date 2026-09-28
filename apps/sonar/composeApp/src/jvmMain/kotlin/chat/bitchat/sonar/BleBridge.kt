package chat.bitchat.sonar

import com.sun.jna.Library
import com.sun.jna.Native
import com.sun.jna.Pointer
import java.nio.file.Files

/** JNA view of the Rust BLE bridge (`core/sonar-ble`, libsonar_ble). */
private interface BleLib : Library {
    fun sonar_ble_mesh_supported(): Boolean
    fun sonar_ble_start()
    fun sonar_ble_stop()
    fun sonar_ble_peers_json(): Pointer?
    fun sonar_ble_free(ptr: Pointer?)
    fun sonar_ble_set_announce(data: ByteArray?, len: Long)
    fun sonar_ble_advertising_supported(): Boolean
    fun sonar_ble_start_advertising()
    fun sonar_ble_stop_advertising()
    fun sonar_ble_drain_rx_json(): Pointer?
    fun sonar_ble_notify(data: ByteArray?, len: Long)
    fun sonar_ble_send_link(link: Long, data: ByteArray?, len: Long): Boolean
}

/**
 * Desktop BLE radio, bridged to the native `sonar-ble` library (CoreBluetooth on
 * macOS / BlueZ on Linux) over JNA — the same "native shim behind the JVM"
 * pattern as `sonar-core`. This is what gives the Compose Desktop app real
 * Bluetooth discovery: the JVM "can't do BLE" wall is just "no pure-JVM BLE lib",
 * dissolved by loading native code.
 *
 * Both roles move mesh packets: phones dial our GATT server where the controller
 * advertises, and we dial them as a central where it refuses. The Noise protocol
 * on top is [MeshLink].
 */
object BleBridge {
    data class Dev(val id: String, val name: String?, val rssi: Int)

    /**
     * One thing the radio heard: a packet on [link], or, when [bytes] is null,
     * that link going down. Link [SERVER_LINK] is our GATT server, whose
     * centrals cannot be told apart; any other id is a central link we dialed.
     */
    class MeshRx(val link: Long, val bytes: ByteArray?)

    const val SERVER_LINK = 0L

    private val lib: BleLib? by lazy { load() }

    /** True when the native BLE library loaded for this OS/arch. */
    val available: Boolean get() = lib != null

    /**
     * True when this build can exchange mesh traffic at all.
     *
     * Separate from [advertisingSupported]: the desktop takes part as a GATT
     * central (scan, connect, subscribe, write), which carries both directions,
     * so mesh works on adapters that refuse to advertise. Advertising only
     * decides whether a phone can find us first.
     *
     * A compile-time answer in the bridge, so read once: it is consulted from
     * composition.
     */
    val meshSupported: Boolean by lazy {
        runCatching { lib?.sonar_ble_mesh_supported() == true }.getOrDefault(false)
    }

    /**
     * True when this platform can also play the peripheral role (advertise + GATT
     * server), so callers must not treat [available] as "phones can discover this
     * desktop".
     *
     * Deliberately NOT cached. On BlueZ this is a runtime answer, not a
     * compile-time one: the bridge reports optimistically until an advertisement
     * has actually been attempted, then reports what happened. An adapter can be
     * present, powered and unblocked and still refuse every LE advertisement, and
     * caching the optimistic first read would leave the app claiming phones can
     * find it on exactly those machines. Each call is one FFI hop reading two
     * atomics.
     */
    val advertisingSupported: Boolean
        get() = runCatching { lib?.sonar_ble_advertising_supported() == true }.getOrDefault(false)

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
    fun startAdvertising() { lib?.sonar_ble_start_advertising() }
    fun stopAdvertising() { lib?.sonar_ble_stop_advertising() }

    /** Send a raw mesh packet to every link: the GATT server's subscribers and
     *  every central link. */
    fun notify(bytes: ByteArray) { lib?.sonar_ble_notify(bytes, bytes.size.toLong()) }

    /** Send a raw mesh packet on ONE central link. False when the link is gone. */
    fun sendToLink(link: Long, bytes: ByteArray): Boolean =
        runCatching { lib?.sonar_ble_send_link(link, bytes, bytes.size.toLong()) == true }.getOrDefault(false)

    /** Everything the radio heard since the last call, in order, per link. */
    fun drainRx(): List<MeshRx> {
        val l = lib ?: return emptyList()
        val ptr = l.sonar_ble_drain_rx_json() ?: return emptyList()
        val json = try { ptr.getString(0) } finally { l.sonar_ble_free(ptr) }
        return parseRx(json)
    }

    /**
     * `[{"l":<link>,"p":"<hex>"}, {"d":true,"l":<link>}, …]` from the bridge.
     * Parsed by hand: no JSON dependency on the desktop classpath. Key order is
     * not relied on (serde sorts them).
     */
    internal fun parseRx(json: String): List<MeshRx> =
        OBJ.findAll(json).mapNotNull { m ->
            val o = m.value
            val link = LINK.find(o)?.groupValues?.get(1)?.toLongOrNull() ?: return@mapNotNull null
            when {
                DOWN.containsMatchIn(o) -> MeshRx(link, null)
                else -> PACKET.find(o)?.groupValues?.get(1)
                    ?.let { runCatching { hexToBytes(it) }.getOrNull() }
                    ?.let { MeshRx(link, it) }
            }
        }.toList()

    private val LINK = Regex(""""l"\s*:\s*(\d+)""")
    private val PACKET = Regex(""""p"\s*:\s*"([0-9a-fA-F]*)"""")
    private val DOWN = Regex(""""d"\s*:\s*true""")
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
