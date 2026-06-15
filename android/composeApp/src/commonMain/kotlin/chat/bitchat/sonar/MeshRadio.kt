package chat.bitchat.sonar

/** A peer discovered over the BLE mesh radio. */
data class MeshPeer(val id: String, val name: String, val rssi: Int)

/**
 * The BLE mesh radio: scans for and advertises the bitchat mesh service so
 * nearby Sonar/bitchat phones discover each other over Bluetooth. This is the
 * radio/discovery layer of the mesh transport; the Noise handshake + bitchat
 * packet messaging build on top (tracked in issue #6 / #21).
 *
 * `iosMain` (later, at the CMP shift) provides a CoreBluetooth `actual`.
 */
expect object MeshRadio {
    /** True when BLE hardware + runtime permissions are available. */
    fun available(): Boolean
    /** Begin scanning + advertising (no-op if unavailable). */
    fun start()
    /** Stop the radio. */
    fun stop()
    /** Currently-visible mesh peers (pruned of stale entries). */
    fun peers(): List<MeshPeer>

    /** Our encoded Sonar Discovery (0x53) announce to send to peers as Noise
     *  links come up. Null clears it (e.g. before an identity exists). */
    fun setLocalSonarAnnounce(payload: ByteArray?)
    /** Raw 0x53 payloads received from peers, keyed by peer id (BLE address).
     *  Decoded with [SonarAnnounce.decode] in shared code. */
    fun sonarPeers(): Map<String, ByteArray>
}
