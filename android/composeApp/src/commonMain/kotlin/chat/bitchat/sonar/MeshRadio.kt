package chat.bitchat.sonar

/** A peer discovered over the BLE mesh radio. [id] is `"mesh:<fingerprint>"`,
 *  where the fingerprint = SHA256(peer's noise static pubkey) — a STABLE identity
 *  that survives the peer's peerID + BLE-address rotation (issue #12), so the same
 *  person is always one radar node. `sonar` = it emitted a rich Sonar Discovery
 *  (0x53) announce, so it's a full Sonar user (chat + pay), not a plain bitchat
 *  peer (chat only). */
data class MeshPeer(val id: String, val name: String, val rssi: Int, val sonar: Boolean = false)

/** An incoming mesh DM (decrypted Noise text). [peerId] is the sender's STABLE
 *  fingerprint (not the rotating bitchat peerID), so messages stay in one
 *  conversation across rotation. Drained by the app into the mesh-chat store. */
data class MeshDmIn(val peerId: String, val text: String, val tsSecs: Long)

/** An incoming PUBLIC broadcast (the BLE "Mesh" channel) from another peer. The
 *  wire carries only content + sender peerID + timestamp; the display nickname is
 *  resolved from the sender's announce by the app. */
data class MeshBroadcastIn(
    val senderId: String,
    val content: String,
    val tsSecs: Long,
)

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
    /** Display nickname carried in our signed bitchat mesh announce. */
    fun setMeshNickname(nick: String)
    /** Raw 0x53 payloads received from peers, keyed by peer id (BLE address).
     *  Decoded with [SonarAnnounce.decode] in shared code. */
    fun sonarPeers(): Map<String, ByteArray>

    /** Send an encrypted DM over the BLE mesh to the peer with stable [peerId]
     *  (fingerprint). Resolves the peer's CURRENT address/peerID at send time, so
     *  delivery survives rotation. Returns false only if it could not be queued. */
    fun sendMeshDm(peerId: String, messageId: String, text: String): Boolean
    /** True iff an encrypted Noise link to the peer with stable [peerId]
     *  (fingerprint) is established right now. */
    fun hasMeshLink(peerId: String): Boolean
    /** Pull (and clear) all mesh DMs received since the last call. */
    fun drainMeshDm(): List<MeshDmIn>
    /** Wall-clock seconds (platform clock) — for mesh message timestamps. */
    fun nowSecs(): Long

    /** Broadcast a PUBLIC message to all connected mesh peers (the "Mesh"
     *  channel). Returns false if no peer is currently connected. */
    fun sendMeshBroadcast(text: String): Boolean
    /** Pull (and clear) public Mesh-channel broadcasts received since last call. */
    fun drainMeshBroadcast(): List<MeshBroadcastIn>
    /** Mesh peers we can currently reach with a broadcast (for "N in range"). */
    fun connectedMeshPeerCount(): Int
}
