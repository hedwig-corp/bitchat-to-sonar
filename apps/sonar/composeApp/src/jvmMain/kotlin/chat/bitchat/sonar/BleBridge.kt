package chat.bitchat.sonar

import com.sun.jna.Library
import com.sun.jna.Native
import com.sun.jna.Pointer
import java.nio.file.Files

/** JNA view of the Rust BLE bridge (`core/sonar-ble`, libsonar_ble). */
private interface BleLib : Library {
    fun sonar_ble_start()
    fun sonar_ble_stop()
    fun sonar_ble_peers_json(): Pointer?
    fun sonar_ble_free(ptr: Pointer?)
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
