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
    /** Manufacturer-data company id under which we advertise our 8-byte mesh
     *  node id (for Sonar-Android dialer election). Distinct from Unify's
     *  0xFFFF; iOS / stock bitchat ignore it. */
    private const val NODE_ID_COMPANY = 0xFFFE

    private val seen = ConcurrentHashMap<String, MeshPeer>()
    private val lastSeen = ConcurrentHashMap<String, Long>()
    @Volatile private var scanning = false
    private var scanner: BluetoothLeScanner? = null
    private var advertiser: BluetoothLeAdvertiser? = null

    // ── Scan watchdog ──
    // On some controllers (seen on Pixel 10 Pro) a `connectGatt` dial starves the
    // LE scanner: after the first dial it stops delivering results entirely and
    // never auto-resumes, so the designated dialer can never re-discover (let
    // alone re-dial) its peer → mutual-discovery deadlock. A watchdog restarts
    // the scan whenever it has gone quiet, reviving the starved scanner. Restarts
    // are spaced ≥ WATCHDOG_GAP_MS apart to stay under Android's "5 scan starts /
    // 30 s" throttle (which would otherwise silently stop the scan for 30 s).
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())
    // Track the last NEW (distinct-address) discovery, not just any scan result:
    // the Pixel 10 Pro's scanner goes "tunnel-blind" after a dial — it keeps
    // re-reporting the ONE address it locked onto (so any-result staleness never
    // trips) while missing every other advertiser, including the peer we need.
    @Volatile private var lastNewDiscoveryMs = 0L
    @Volatile private var lastScanStartMs = 0L
    @Volatile private var scanResultCount = 0L
    private const val WATCHDOG_TICK_MS = 4_000L
    private const val WATCHDOG_STALE_MS = 7_000L
    private const val WATCHDOG_GAP_MS = 8_000L
    /** Head start the SMALLER node id gets before the larger node also dials, in
     *  the soft election (see [scanCallback]). */
    private const val FALLBACK_DIAL_MS = 5_000L

    // ── Sonar Discovery (0x53) + bitchat announce over the mesh ──
    private val sonarProfiles = ConcurrentHashMap<String, ByteArray>()
    /** Verified mesh peers keyed by their bitchat peerID (NOT the BLE address:
     *  a device advertises under a rotating Resolvable Private Address but its
     *  announce carries a stable peerID — keying by address loses the name). */
    private val announcedPeers = ConcurrentHashMap<String, MeshPeer>()
    private val announcedSeen = ConcurrentHashMap<String, Long>()
    /** Identified peers stay listed longer than raw scan blips (they re-announce
     *  over a live link, but tolerate gaps). */
    private const val ANNOUNCE_STALE_MS = 60_000L

    init {
        // Stash peers' 0x53 payloads + register named, verified announce peers.
        MeshGatt.addSonarListener { peerId, payload -> sonarProfiles[peerId] = payload }
        MeshGatt.addAnnounceListener { _, info ->
            announcedPeers[info.senderIdHex] = MeshPeer(
                id = "mesh:" + info.senderIdHex,
                name = info.nickname,
                rssi = -50, // connected ⇒ close; no per-packet RSSI on the GATT path
            )
            announcedSeen[info.senderIdHex] = System.currentTimeMillis()
        }
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
            startScanInternal()
            lastNewDiscoveryMs = System.currentTimeMillis()
            handler.postDelayed(scanWatchdog, WATCHDOG_TICK_MS)

            advertiser = a.bluetoothLeAdvertiser
            val advSettings = AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
                .setConnectable(true)
                .build()
            val advData = AdvertiseData.Builder()
                .addServiceUuid(ParcelUuid(SERVICE_UUID))
                .build()
            // Scan response carries our 8-byte node id (== peerID) in manufacturer
            // data, so a peer Sonar-Android can elect a single dialer (the actual
            // display name comes from the signed announce, not the advert). iOS /
            // stock bitchat ignore this manufacturer data.
            val scanResponse = AdvertiseData.Builder()
                .addManufacturerData(NODE_ID_COMPANY, MeshGatt.nodeId())
                .build()
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
        handler.removeCallbacks(scanWatchdog)
        try { scanner?.stopScan(scanCallback) } catch (_: Throwable) {}
        try { advertiser?.stopAdvertising(advCallback) } catch (_: Throwable) {}
        MeshGatt.stop()
        seen.clear(); lastSeen.clear(); announcedPeers.clear(); announcedSeen.clear()
    }

    /** (Re)start the LE scan with the mesh filters/settings. */
    private fun startScanInternal() {
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
        lastScanStartMs = System.currentTimeMillis()
    }

    /** Revive a scanner that a `connectGatt` dial has starved (no results for a
     *  while), spacing restarts to stay under Android's scan-start throttle. */
    private val scanWatchdog = object : Runnable {
        override fun run() {
            if (!scanning) return
            val now = System.currentTimeMillis()
            if (now - lastNewDiscoveryMs > WATCHDOG_STALE_MS && now - lastScanStartMs > WATCHDOG_GAP_MS) {
                android.util.Log.i(
                    TAG,
                    "scan tunnel-blind (${now - lastNewDiscoveryMs}ms no new peer, $scanResultCount results) — restarting",
                )
                runCatching { scanner?.stopScan(scanCallback) }
                runCatching { startScanInternal() }
                lastNewDiscoveryMs = now // give the fresh scan a grace period
            }
            handler.postDelayed(this, WATCHDOG_TICK_MS)
        }
    }

    actual fun peers(): List<MeshPeer> {
        val now = System.currentTimeMillis()
        // `seen` (raw scan results) is kept only to drive auto-dial — it is NOT
        // shown. BLE MAC rotation turns one device into a stream of addresses;
        // exposing those produced "zombie" peers. Only VERIFIED announce peers
        // (stable bitchat peerID + signed nickname) are real users, like iOS.
        for ((id, t) in lastSeen) if (now - t > STALE_MS) { seen.remove(id); lastSeen.remove(id) }
        for ((id, t) in announcedSeen) if (now - t > ANNOUNCE_STALE_MS) { announcedPeers.remove(id); announcedSeen.remove(id) }
        // Classify by richest protocol: a peer that also sent a 0x53 Sonar
        // announce is a full Sonar user, else a plain bitchat peer.
        return announcedPeers.entries
            .map { (peerId, p) -> p.copy(sonar = sonarProfiles.containsKey(peerId)) }
            .sortedByDescending { it.rssi }
    }

    actual fun setLocalSonarAnnounce(payload: ByteArray?) { MeshGatt.sonarPayload = payload }

    /** Push the display nickname carried in our bitchat announce. */
    actual fun setMeshNickname(nick: String) { if (nick.isNotBlank()) MeshGatt.nickname = nick }

    actual fun sonarPeers(): Map<String, ByteArray> = HashMap(sonarProfiles)

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            scanResultCount++
            val id = result.device.address
            val name = runCatching { result.scanRecord?.deviceName }.getOrNull()
                ?: ("mesh·" + id.takeLast(5).replace(":", ""))
            val isNew = !seen.containsKey(id)
            seen[id] = MeshPeer(id = id, name = name, rssi = result.rssi)
            lastSeen[id] = System.currentTimeMillis()
            if (isNew) {
                lastNewDiscoveryMs = System.currentTimeMillis()
                // SOFT dialer election. Two Sonar-Android phones dialing each
                // other at once race the controller (status 19), so the SMALLER
                // node id dials immediately and the larger holds back — BUT only
                // as a head start, not a veto: the larger ALSO dials after a short
                // fallback delay. A strict "larger never dials" deadlocks whenever
                // the smaller node's scanner is the weak one (e.g. Pixel 10 Pro,
                // whose mesh scan goes tunnel-blind after a dial) — it never
                // re-discovers the peer to dial it, and nobody else does either.
                // The larger node's healthy scanner then carries the link; the
                // peer's GATT server accepts inbound dials regardless of its own
                // scanner. connect()'s dedup + cap + backoff bound the churn, and
                // status 19 is cleaned up + retried like 133. A peer with NO node
                // id (iOS / stock bitchat) is dialed immediately (iPhone compat).
                val peerNodeId = runCatching {
                    result.scanRecord?.getManufacturerSpecificData(NODE_ID_COMPANY)
                }.getOrNull()
                val dialNow = peerNodeId == null || MeshGatt.shouldDial(peerNodeId)
                android.util.Log.i(TAG, "discovered $id rssi=${result.rssi} nodeId=${peerNodeId != null} dialNow=$dialNow")
                if (dialNow) {
                    runCatching { MeshGatt.connect(result.device) }
                } else {
                    handler.postDelayed({ runCatching { MeshGatt.connect(result.device) } }, FALLBACK_DIAL_MS)
                }
            }
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
