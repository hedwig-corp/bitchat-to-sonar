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

    private const val TAG = "MeshRadio"

    // bitchat mainnet service + payload characteristic (from iOS BLEService).
    private val SERVICE_UUID: UUID = UUID.fromString("F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C")
    private const val STALE_MS = 20_000L

    private val seen = ConcurrentHashMap<String, MeshPeer>()
    private val lastSeen = ConcurrentHashMap<String, Long>()
    @Volatile private var scanning = false
    private var scanner: BluetoothLeScanner? = null
    private var advertiser: BluetoothLeAdvertiser? = null

    // ── Sonar Discovery (0x53) over the established mesh links ──
    @Volatile private var localSonarAnnounce: ByteArray? = null
    private val sonarProfiles = ConcurrentHashMap<String, ByteArray>()
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())

    init {
        // When a Noise link comes up, send our announce; stash peers' announces.
        // The send is deferred ~150ms: on the initiator side the link finishes
        // the instant handshake m3 is written, and GATT serializes writes — the
        // delay lets m3 drain before the 0x53 write rides the same characteristic.
        MeshGatt.addLinkListener { peerId ->
            localSonarAnnounce?.let { payload ->
                handler.postDelayed({ MeshGatt.sendSonar(peerId, payload) }, 150)
            }
        }
        MeshGatt.addSonarListener { peerId, payload -> sonarProfiles[peerId] = payload }
    }

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
        if (scanning || !available()) {
            android.util.Log.i(TAG, "start skipped: scanning=$scanning available=${available()}")
            return
        }
        val a = adapter() ?: return
        scanning = true
        try {
            scanner = a.bluetoothLeScanner
            val filters = listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE_UUID)).build())
            val settings = ScanSettings.Builder()
                .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
                // Aggressive matching reports even weak/intermittent advertisers,
                // and ALL_MATCHES keeps reporting them so they don't time out.
                .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
                .setMatchMode(ScanSettings.MATCH_MODE_AGGRESSIVE)
                .setNumOfMatches(ScanSettings.MATCH_NUM_MAX_ADVERTISEMENT)
                .setReportDelay(0)
                .build()
            scanner?.startScan(filters, settings, scanCallback)

            advertiser = a.bluetoothLeAdvertiser
            val advSettings = AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
                .setConnectable(true)
                .build()
            val advData = AdvertiseData.Builder()
                .addServiceUuid(ParcelUuid(SERVICE_UUID))
                .build()
            // Device name rides the scan response (a second 31-byte packet) so it
            // can't overflow the primary advert that carries the 128-bit UUID.
            val scanResponse = AdvertiseData.Builder().setIncludeDeviceName(true).build()
            advertiser?.startAdvertising(advSettings, advData, scanResponse, advCallback)
            MeshGatt.startServer()
            android.util.Log.i(TAG, "scanning + advertising $SERVICE_UUID (advertiser=${advertiser != null})")
        } catch (e: SecurityException) {
            scanning = false
            android.util.Log.e(TAG, "start failed (permission)", e)
        } catch (e: Throwable) {
            scanning = false
            android.util.Log.e(TAG, "start failed", e)
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

    actual fun setLocalSonarAnnounce(payload: ByteArray?) { localSonarAnnounce = payload }

    actual fun sonarPeers(): Map<String, ByteArray> = HashMap(sonarProfiles)

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val id = result.device.address
            val name = runCatching { result.scanRecord?.deviceName }.getOrNull()
                ?: ("mesh·" + id.takeLast(5).replace(":", ""))
            val isNew = !seen.containsKey(id)
            seen[id] = MeshPeer(id = id, name = name, rssi = result.rssi)
            lastSeen[id] = System.currentTimeMillis()
            if (isNew) {
                android.util.Log.i(TAG, "discovered peer $name [$id] rssi=${result.rssi}")
            }
            // NB: we no longer auto-dial GATT on every discovery — the failing
            // connects (status 133) churned the BLE controller and could starve
            // the scan, hiding real peers. The Noise link is established on demand
            // when the user opens a mesh DM (MeshGatt.connect), not during scan.
        }

        override fun onScanFailed(errorCode: Int) {
            android.util.Log.e(TAG, "scan failed: $errorCode")
        }
    }

    private val advCallback = object : android.bluetooth.le.AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: android.bluetooth.le.AdvertiseSettings?) {
            android.util.Log.i(TAG, "advertising started")
        }
        override fun onStartFailure(errorCode: Int) {
            android.util.Log.e(TAG, "advertise failed: $errorCode")
        }
    }
}
