package chat.bitchat.sonar

import android.Manifest
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelUuid
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Android BLE mesh radio: scans for and advertises the bitchat mesh service
 * UUID so nearby Sonar/bitchat phones discover each other. Wire-compatible
 * with the iOS BLEService service UUID.
 */
actual object MeshRadio {

    // bitchat mainnet service + payload characteristic (from iOS BLEService).
    private val SERVICE_UUID: UUID = UUID.fromString("F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C")
    private const val STALE_MS = 20_000L

    private val seen = ConcurrentHashMap<String, MeshPeer>()
    private val lastSeen = ConcurrentHashMap<String, Long>()
    @Volatile private var scanning = false
    private var scanner: BluetoothLeScanner? = null
    private var advertiser: BluetoothLeAdvertiser? = null

    private val ctx: Context get() = AppContextHolder.ctx

    private fun hasPerm(p: String) =
        ctx.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    private fun permitted(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            hasPerm(Manifest.permission.BLUETOOTH_SCAN) && hasPerm(Manifest.permission.BLUETOOTH_ADVERTISE)
        } else {
            hasPerm(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    private fun adapter() =
        (ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    actual fun available(): Boolean {
        val a = adapter() ?: return false
        return a.isEnabled && permitted()
    }

    actual fun start() {
        if (scanning || !available()) return
        val a = adapter() ?: return
        scanning = true
        try {
            scanner = a.bluetoothLeScanner
            val filters = listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE_UUID)).build())
            val settings = ScanSettings.Builder()
                .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
                .build()
            scanner?.startScan(filters, settings, scanCallback)

            advertiser = a.bluetoothLeAdvertiser
            val advSettings = AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                .setConnectable(true)
                .build()
            val advData = AdvertiseData.Builder()
                .addServiceUuid(ParcelUuid(SERVICE_UUID))
                .build()
            advertiser?.startAdvertising(advSettings, advData, advCallback)
            MeshGatt.startServer()
        } catch (_: SecurityException) {
            scanning = false
        } catch (_: Throwable) {
            scanning = false
        }
    }

    actual fun stop() {
        scanning = false
        try { scanner?.stopScan(scanCallback) } catch (_: Throwable) {}
        try { advertiser?.stopAdvertising(advCallback) } catch (_: Throwable) {}
        MeshGatt.stop()
        seen.clear(); lastSeen.clear()
    }

    actual fun peers(): List<MeshPeer> {
        val now = System.currentTimeMillis()
        for ((id, t) in lastSeen) if (now - t > STALE_MS) { seen.remove(id); lastSeen.remove(id) }
        return seen.values.sortedByDescending { it.rssi }
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val id = result.device.address
            val name = runCatching { result.scanRecord?.deviceName }.getOrNull()
                ?: ("mesh·" + id.takeLast(5).replace(":", ""))
            val isNew = !seen.containsKey(id)
            seen[id] = MeshPeer(id = id, name = name, rssi = result.rssi)
            lastSeen[id] = System.currentTimeMillis()
            // Auto-link over GATT to newly-discovered peers (Noise XX). To avoid
            // dual-connect races, only the lexicographically-higher address dials.
            if (isNew) {
                val mine = runCatching { adapter()?.address }.getOrNull() ?: ""
                if (mine.isBlank() || mine > id) MeshGatt.connect(result.device)
            }
        }
    }

    private val advCallback = object : android.bluetooth.le.AdvertiseCallback() {}
}
