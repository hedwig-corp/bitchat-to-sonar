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
    @Volatile private var nick: String = "sonar"

    actual fun available(): Boolean = BleBridge.available

    actual fun start() {
        BleBridge.start() // central: scan for nearby mesh advertisers
        // peripheral: advertise the bitchat service + serve our signed announce,
        // so phones discover this desktop and show it as a named peer.
        refreshAnnounce()
        BleBridge.startAdvertising()
    }

    actual fun stop() {
        BleBridge.stop()
        BleBridge.stopAdvertising()
    }

    /** Rebuild + push the announce (called on start and when the nickname changes). */
    private fun refreshAnnounce() {
        runCatching { BleBridge.setAnnounce(MeshIdentity.announce(nick)) }
    }

    actual fun peers(): List<MeshPeer> = BleBridge.peers().map { d ->
        MeshPeer(
            id = "mesh:" + d.id,
            name = d.name?.takeIf { it.isNotBlank() } ?: ("mesh·" + d.id.take(6)),
            rssi = d.rssi,
            sonar = false, // a full Sonar peer is only known after the 0x53 announce (GATT, next stage)
        )
    }

    // Transport (Noise-over-GATT messaging) not wired yet — discovery + announce only.
    actual fun setLocalSonarAnnounce(payload: ByteArray?) {}
    actual fun setMeshNickname(nick: String) {
        if (nick.isNotBlank() && nick != this.nick) {
            this.nick = nick
            if (available()) refreshAnnounce()
        }
    }
    actual fun sonarPeers(): Map<String, ByteArray> = emptyMap()

    actual fun sendMeshDm(peerId: String, messageId: String, text: String): Boolean = false
    actual fun hasMeshLink(peerId: String): Boolean = false
    actual fun drainMeshDm(): List<MeshDmIn> = emptyList()
    actual fun nowSecs(): Long = System.currentTimeMillis() / 1000

    actual fun sendMeshBroadcast(text: String): Boolean = false
    actual fun drainMeshBroadcast(): List<MeshBroadcastIn> = emptyList()
    actual fun connectedMeshPeerCount(): Int = 0
}
