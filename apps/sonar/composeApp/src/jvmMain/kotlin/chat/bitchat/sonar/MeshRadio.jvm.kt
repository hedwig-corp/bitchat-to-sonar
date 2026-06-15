package chat.bitchat.sonar

/**
 * Desktop (JVM) `actual`: BLE mesh is hardware-gated and there is no portable
 * desktop BLE peripheral/central stack (most desktops can't advertise a GATT
 * server), so the mesh radio is reported unavailable and every operation is an
 * inert no-op. The desktop app's cross-platform-testable surface is the internet
 * (White Noise / Nostr) transport in [SonarCore]; mesh requires phones.
 */
actual object MeshRadio {
    actual fun available(): Boolean = false
    actual fun start() {}
    actual fun stop() {}
    actual fun peers(): List<MeshPeer> = emptyList()

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
