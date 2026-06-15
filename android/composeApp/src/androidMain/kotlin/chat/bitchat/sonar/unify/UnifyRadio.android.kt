package chat.bitchat.sonar.unify

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
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
import chat.bitchat.sonar.AppContextHolder
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.resume
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Android Unify nearby-payments radio (see [UnifyRadio]). Payer = a private
 * [BluetoothLeScanner] + on-demand GATT reads; receiver = a private
 * [BluetoothLeAdvertiser] + [BluetoothGattServer] serving the framed offer.
 * Both use their OWN BLE objects — never the mesh radio's.
 */
@SuppressLint("MissingPermission")
actual object UnifyRadio {

    private const val TAG = "UnifyRadio"
    private val SERVICE: UUID = UUID.fromString(UnifyContract.SERVICE_UUID)
    private val PAYLOAD_CHAR: UUID = UUID.fromString(UnifyContract.PAYLOAD_CHARACTERISTIC_UUID)
    private const val STALE_MS = 20_000L
    private const val FETCH_TIMEOUT_MS = 15_000L
    /** BLE manufacturer-data company id carrying the display name (== iOS). */
    private const val NAME_COMPANY_ID = 0xFFFF
    /** A private marker (in our scan response) that says "this Unify advertiser
     *  is actually a Sonar app". Other Sonar scanners skip it — a Sonar peer is
     *  shown via the mesh, not as a generic "Unify user". The real Unify Wallet
     *  has no marker, so it still lists correctly. */
    private const val SONAR_MARKER_COMPANY = 0x53A0

    private val ctx: Context get() = AppContextHolder.ctx

    // ── Payer (central) state ──
    private val seen = ConcurrentHashMap<String, UnifyPeer>()
    private val lastSeen = ConcurrentHashMap<String, Long>()
    @Volatile private var scanning = false
    private var scanner: BluetoothLeScanner? = null

    // ── Receiver (peripheral) state ──
    @Volatile private var advertising = false
    private var advertiser: BluetoothLeAdvertiser? = null
    private var server: BluetoothGattServer? = null
    /** The framed payload we serve on a read: `frame("bitcoin:?lno=<offer>")`. */
    @Volatile private var framedOffer: ByteArray = ByteArray(0)

    private fun hasPerm(p: String) =
        ctx.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    private fun permitted(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            hasPerm(Manifest.permission.BLUETOOTH_SCAN) &&
                hasPerm(Manifest.permission.BLUETOOTH_CONNECT) &&
                hasPerm(Manifest.permission.BLUETOOTH_ADVERTISE)
        } else {
            hasPerm(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    private fun adapter() =
        (ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    actual fun available(): Boolean {
        val a = adapter() ?: return false
        return a.isEnabled && permitted()
    }

    // ── Payer role ───────────────────────────────────────────────────────────

    actual fun startScanning() {
        if (scanning || !available()) return
        val a = adapter() ?: return
        scanning = true
        try {
            scanner = a.bluetoothLeScanner
            val filters = listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE)).build())
            val settings = ScanSettings.Builder()
                .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
                .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
                .setMatchMode(ScanSettings.MATCH_MODE_AGGRESSIVE)
                .setNumOfMatches(ScanSettings.MATCH_NUM_MAX_ADVERTISEMENT)
                .setReportDelay(0)
                .build()
            scanner?.startScan(filters, settings, scanCallback)
            android.util.Log.i(TAG, "scanning for Unify $SERVICE")
        } catch (e: Throwable) {
            scanning = false
            android.util.Log.e(TAG, "startScanning failed", e)
        }
    }

    actual fun stopScanning() {
        scanning = false
        try { scanner?.stopScan(scanCallback) } catch (_: Throwable) {}
        seen.clear(); lastSeen.clear()
    }

    actual fun peers(): List<UnifyPeer> {
        val now = System.currentTimeMillis()
        for ((id, t) in lastSeen) if (now - t > STALE_MS) { seen.remove(id); lastSeen.remove(id) }
        // Dedupe rotating-MAC "zombies": one real device advertises under many
        // addresses, so collapse by display name, keeping the strongest signal.
        return seen.values
            .groupBy { it.name }
            .map { (_, dupes) -> dupes.maxByOrNull { it.rssi }!! }
            .sortedByDescending { it.rssi }
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            // Skip Sonar apps advertising the Unify receiver — they're shown as
            // Sonar peers via the mesh, not as generic "Unify users".
            if (result.scanRecord?.getManufacturerSpecificData(SONAR_MARKER_COMPANY) != null) return
            val id = result.device.address
            seen[id] = UnifyPeer(id = id, name = advertisedName(result), rssi = result.rssi)
            lastSeen[id] = System.currentTimeMillis()
        }
        override fun onScanFailed(errorCode: Int) {
            android.util.Log.e(TAG, "Unify scan failed: $errorCode")
        }
    }

    /** Name precedence (== iOS): BLE local name → manufacturer 0xFFFF → default. */
    private fun advertisedName(result: ScanResult): String {
        val record = result.scanRecord
        val local = record?.deviceName?.takeIf { it.isNotBlank() }
        val mfg = record?.getManufacturerSpecificData(NAME_COMPANY_ID)
            ?.takeIf { it.isNotEmpty() }?.decodeToString()
        return sanitizeName(local ?: mfg ?: UnifyContract.DEFAULT_NAME)
    }

    actual suspend fun fetchOffer(peerId: String): String? {
        if (!available()) return null
        val device = runCatching { adapter()?.getRemoteDevice(peerId) }.getOrNull() ?: return null
        return withTimeoutOrNull(FETCH_TIMEOUT_MS) { readOfferBlocking(device) }
    }

    private suspend fun readOfferBlocking(device: BluetoothDevice): String? =
        suspendCancellableCoroutine { cont ->
            val reassembler = UnifyFraming.Reassembler()
            var gattRef: BluetoothGatt? = null
            // finish() is reachable from BLE callback threads AND the timeout
            // cancellation — gate the single resume so the two can't race into a
            // double-resume (which CancellableContinuation would reject).
            val done = java.util.concurrent.atomic.AtomicBoolean(false)
            fun finish(result: String?) {
                if (!done.compareAndSet(false, true)) return
                runCatching { gattRef?.disconnect(); gattRef?.close() }
                if (cont.isActive) cont.resume(result)
            }
            val cb = object : BluetoothGattCallback() {
                override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
                    if (newState == BluetoothProfile.STATE_CONNECTED) {
                        // Negotiate a large MTU first: Android's readCharacteristic
                        // returns only one ATT-MTU-sized value (no auto Read Blob),
                        // so the full BOLT12 offer (hundreds of bytes) needs it.
                        if (!runCatching { gatt.requestMtu(517) }.getOrDefault(false)) {
                            runCatching { gatt.discoverServices() }
                        }
                    } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                        finish(null)
                    }
                }
                override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
                    runCatching { gatt.discoverServices() }
                }
                override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
                    val ch = gatt.getService(SERVICE)?.getCharacteristic(PAYLOAD_CHAR)
                    if (ch == null) { finish(null); return }
                    @Suppress("DEPRECATION")
                    if (!gatt.readCharacteristic(ch)) finish(null)
                }
                @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
                override fun onCharacteristicRead(
                    gatt: BluetoothGatt, ch: BluetoothGattCharacteristic, status: Int,
                ) {
                    // Android's stack performs the ATT long-read and hands us the
                    // full value (offers are < 512B), so one append completes it.
                    val payload = if (status == BluetoothGatt.GATT_SUCCESS)
                        reassembler.append(ch.value ?: ByteArray(0)) else null
                    finish(payload)
                }
            }
            cont.invokeOnCancellation { finish(null) }
            gattRef = runCatching {
                device.connectGatt(ctx, false, cb, BluetoothDevice.TRANSPORT_LE)
            }.getOrNull()
            if (gattRef == null) finish(null)
        }

    // ── Receiver role ────────────────────────────────────────────────────────

    actual fun startAdvertising(offer: String, name: String) {
        if (!available()) return
        val a = adapter() ?: return
        framedOffer = UnifyFraming.frame("bitcoin:?lno=$offer")
        try {
            if (server == null) {
                val mgr = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
                val s = mgr?.openGattServer(ctx, serverCallback) ?: return
                val service = BluetoothGattService(SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY)
                service.addCharacteristic(
                    BluetoothGattCharacteristic(
                        PAYLOAD_CHAR,
                        BluetoothGattCharacteristic.PROPERTY_READ,
                        BluetoothGattCharacteristic.PERMISSION_READ,
                    )
                )
                s.addService(service)
                server = s
            }
            // (Re)advertise with the current display name in manufacturer data.
            advertiser?.let { runCatching { it.stopAdvertising(advCallback) } }
            advertiser = a.bluetoothLeAdvertiser
            val settings = AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
                .setConnectable(true)
                .build()
            val data = AdvertiseData.Builder()
                .addServiceUuid(ParcelUuid(SERVICE))
                .addManufacturerData(NAME_COMPANY_ID, sanitizeName(name).encodeToByteArray())
                .build()
            // Scan response carries the "I am Sonar" marker so peer Sonar apps
            // don't double-list us as a generic Unify user.
            val scanResponse = AdvertiseData.Builder()
                .addManufacturerData(SONAR_MARKER_COMPANY, byteArrayOf(0x01))
                .build()
            advertiser?.startAdvertising(settings, data, scanResponse, advCallback)
            advertising = true
            android.util.Log.i(TAG, "advertising Unify offer as '${sanitizeName(name)}'")
        } catch (e: Throwable) {
            advertising = false
            android.util.Log.e(TAG, "startAdvertising failed", e)
        }
    }

    actual fun stopAdvertising() {
        advertising = false
        try { advertiser?.stopAdvertising(advCallback) } catch (_: Throwable) {}
        try { server?.close() } catch (_: Throwable) {}
        advertiser = null; server = null; framedOffer = ByteArray(0)
    }

    actual fun isAdvertising(): Boolean = advertising

    private val serverCallback = object : BluetoothGattServerCallback() {
        override fun onCharacteristicReadRequest(
            device: BluetoothDevice, requestId: Int, offset: Int, ch: BluetoothGattCharacteristic,
        ) {
            val full = framedOffer
            if (ch.uuid != PAYLOAD_CHAR || offset > full.size) {
                server?.sendResponse(device, requestId, BluetoothGatt.GATT_INVALID_OFFSET, offset, null)
                return
            }
            // Serve the framed payload sliced at the requested offset; the central
            // stack issues successive offset reads and concatenates them.
            val slice = full.copyOfRange(offset, full.size)
            server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, slice)
        }
    }

    private val advCallback = object : AdvertiseCallback() {
        override fun onStartFailure(errorCode: Int) {
            android.util.Log.e(TAG, "Unify advertise failed: $errorCode")
        }
    }

    /** Collapse control/whitespace, trim, cap to 20 chars (display-only). */
    private fun sanitizeName(raw: String): String {
        val cleaned = raw.map { if (it.isISOControl()) ' ' else it }.joinToString("")
            .replace(Regex("\\s+"), " ").trim()
        val name = cleaned.ifEmpty { UnifyContract.DEFAULT_NAME }
        return if (name.length > 20) name.take(20) else name
    }
}
