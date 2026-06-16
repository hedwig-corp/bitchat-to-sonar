package chat.bitchat.sonar

/**
 * Desktop (JVM) `actual`: BLE **discovery** via the native `sonar-ble` bridge
 * ([BleBridge]) — CoreBluetooth on macOS / BlueZ on Linux. This gives the desktop
 * radar real nearby bitchat-mesh devices, disproving the "JVM can't do BLE" idea
 * (the wall was the lack of a pure-JVM BLE library, not the JVM or the hardware).
 *
 * Implemented today: the central/scan role — peers() surfaces nearby advertisers
 * of the bitchat mesh service. NOT yet implemented (still no-ops): peripheral
 * advertising (so phones discover the desktop), and the encrypted Noise-over-GATT
 * message transport. Those are the next stages toward full mesh interop, so mesh
 * DMs / broadcasts return false / empty here for now.
 */
actual object MeshRadio {
    actual fun available(): Boolean = BleBridge.available
    actual fun start() { BleBridge.start() }
    actual fun stop() { BleBridge.stop() }

    actual fun peers(): List<MeshPeer> = BleBridge.peers().map { d ->
        MeshPeer(
            id = "mesh:" + d.id,
            name = d.name?.takeIf { it.isNotBlank() } ?: ("mesh·" + d.id.take(6)),
            rssi = d.rssi,
            sonar = false, // a full Sonar peer is only known after the 0x53 announce (GATT, next stage)
        )
    }

    // Transport (Noise-over-GATT) not wired yet — discovery only.
    actual fun setLocalSonarAnnounce(payload: ByteArray?) {}
    actual fun setMeshNickname(nick: String) {}
    actual fun sonarPeers(): Map<String, ByteArray> = emptyMap()

    actual fun sendMeshDm(peerId: String, messageId: String, text: String): Boolean = false
    actual fun hasMeshLink(peerId: String): Boolean = false
    actual fun drainMeshDm(): List<MeshDmIn> = emptyList()
    actual fun nowSecs(): Long = System.currentTimeMillis() / 1000

    actual fun sendMeshBroadcast(text: String): Boolean = false
    actual fun drainMeshBroadcast(): List<MeshBroadcastIn> = emptyList()
    actual fun connectedMeshPeerCount(): Int = 0
}
