package chat.bitchat.sonar.unify

/** A nearby Unify Wallet user discovered over BLE (payments-only, no chat). */
data class UnifyPeer(val id: String, val name: String, val rssi: Int)

/**
 * Unify nearby-payments BLE radio, mirroring the iOS `UnifyNearbyService`
 * (payer / central) + `UnifyReceiverService` (receiver / peripheral). Kept
 * fully isolated from the bitchat mesh radio: its own scanner + GATT server on
 * the Unify service UUID, never touching [chat.bitchat.sonar.MeshRadio].
 *
 *  - Payer role: [startScanning] discovers Unify peers advertising the service;
 *    [fetchOffer] connects and reads their framed BOLT12 offer so we can pay.
 *  - Receiver role: [startAdvertising] serves our own amountless BOLT12 offer on
 *    a GATT read characteristic so a Unify user can pay us.
 *
 * `iosMain` already ships the CoreBluetooth originals; this is the Android
 * `actual`. Live payer↔receiver verification needs two devices.
 */
expect object UnifyRadio {
    /** True when BLE hardware + runtime permissions are available. */
    fun available(): Boolean

    // ── Payer (central) ──
    /** Begin scanning for Unify peers (no-op if unavailable). */
    fun startScanning()
    /** Stop scanning and clear the discovered-peer list. */
    fun stopScanning()
    /** Currently-visible Unify peers (pruned of stale entries). */
    fun peers(): List<UnifyPeer>
    /** Connect to [peerId], read its framed BOLT12 offer, disconnect. Null on
     *  failure/timeout. The returned string is the raw payload the peer serves
     *  (a `bitcoin:?lno=…` URI or bare offer), to be parsed with [UnifyBIP321]. */
    suspend fun fetchOffer(peerId: String): String?

    // ── Receiver (peripheral) ──
    /** Advertise + serve [offer] (an amountless BOLT12) under display [name] so a
     *  Unify user can pay us. Re-call to update the offer/name. */
    fun startAdvertising(offer: String, name: String)
    /** Stop advertising and tear down the GATT server. */
    fun stopAdvertising()
    /** Whether we are currently advertising a receivable offer. */
    fun isAdvertising(): Boolean
}
