package chat.bitchat.sonar

/**
 * Desktop (JVM) `actual`: BLE mesh via the native `sonar-ble` bridge ([BleBridge],
 * CoreBluetooth/BlueZ) for the radio (scan + advertise + GATT) and [MeshLink] for
 * the protocol (Noise-over-GATT handshake + encrypted DMs). Together they bring
 * the desktop to parity with the Android mesh: phones discover the desktop and
 * vice-versa, and DMs are end-to-end encrypted over the Bluetooth link.
 *
 * Note: a phone suppresses its own advertising while connected to us, so the
 * desktop learns it from the announce it WRITES over GATT (not from scanning) —
 * see [MeshLink]. The filtered scan is a fast fallback before a phone connects.
 */
actual object MeshRadio {
    @Volatile private var nick: String = "sonar"
    @Volatile private var discoveryMode: BleDiscoveryMode = BleDiscoveryMode.Normal
    private val knownPeerIds = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()

    actual fun available(): Boolean = BleBridge.available

    actual fun setPeerUpdateListener(listener: (() -> Unit)?) {
        MeshLink.setPeerUpdateListener(listener)
    }

    actual fun setDiscoveryMode(mode: BleDiscoveryMode) {
        if (discoveryMode == mode) return
        discoveryMode = mode
        if (mode == BleDiscoveryMode.KnownOnly && knownPeerIds.isEmpty()) {
            stop()
        } else if (available()) {
            start()
        }
    }

    actual fun setKnownPeerIds(ids: Set<String>) {
        val normalized = changedKnownMeshPeerIds(knownPeerIds, ids) ?: return
        knownPeerIds.clear()
        knownPeerIds.addAll(normalized)
        if (discoveryMode == BleDiscoveryMode.KnownOnly) {
            if (knownPeerIds.isEmpty()) stop()
            else if (available()) start()
        }
    }

    /**
     * Forces [meshMessagingSupported] for tests.
     *
     * The notice this gates used to be testable simply because Linux could never
     * do mesh; now that it can, the only way to exercise the unsupported path is
     * to say so. Testing "the notice appears on Linux" would now pin the platform
     * rather than the behaviour, and would go green for the wrong reason on any
     * machine whose adapter happens to refuse advertising.
     */
    @Volatile
    internal var meshMessagingOverrideForTest: Boolean? = null

    // The central link carries messages; advertising only decides whether a phone
    // can find us first. See the expect declaration.
    actual val meshMessagingSupported: Boolean
        get() = meshMessagingOverrideForTest ?: BleBridge.meshSupported

    actual fun start() {
        if (discoveryMode == BleDiscoveryMode.KnownOnly && knownPeerIds.isEmpty()) return
        BleBridge.start()            // central: filtered scan
        refreshAnnounce()
        // The scan loop links to every bitchat peer it finds as a GATT central,
        // and that carries traffic both ways, so the protocol engine runs
        // wherever scanning does.
        MeshLink.start()
        // Advertising is additive: it lets a phone initiate instead of waiting to
        // be connected to. An adapter that refuses it does not stop mesh working.
        if (BleBridge.advertisingSupported) {
            BleBridge.startAdvertising()
            Thread({
                Thread.sleep(6_000)
                if (!BleBridge.advertisingSupported) {
                    sonarLog(
                        "MeshRadio",
                        "BLE adapter refused to advertise: this desktop reaches peers by connecting to them, but phones cannot initiate",
                    )
                }
            }, "sonar-mesh-advcheck").apply { isDaemon = true }.start()
        } else {
            sonarLog(
                "MeshRadio",
                "peripheral role unavailable: this desktop reaches peers by connecting to them, but phones cannot initiate",
            )
        }
    }

    actual fun stop() {
        MeshLink.stop()
        BleBridge.stop()
        BleBridge.stopAdvertising()
    }

    private fun refreshAnnounce() {
        runCatching { BleBridge.setAnnounce(MeshIdentity.announce(nick)) }
    }

    private fun isKnownPeer(peerId: String): Boolean =
        discoveryMode == BleDiscoveryMode.Normal || knownPeerIds.contains(peerId.lowercase())

    actual fun hasActivePeer(): Boolean =
        MeshLink.namedPeers().isNotEmpty() || BleBridge.peers().isNotEmpty()

    actual fun peers(): List<MeshPeer> {
        val named = MeshLink.namedPeers().filter { isKnownPeer(it.id.removePrefix("mesh:")) }
        if (named.isNotEmpty()) return named
        if (discoveryMode == BleDiscoveryMode.KnownOnly) return emptyList()
        // Fast path before any phone connects: collapse the filtered scan's
        // rotating BLE addresses into one "nearby phone" node. It becomes a named
        // peer once the phone connects + writes its announce (see MeshLink).
        val scan = BleBridge.peers()
        if (scan.isEmpty()) return emptyList()
        val strongest = scan.maxByOrNull { it.rssi } ?: scan.first()
        return listOf(MeshPeer(id = "mesh:nearby", name = "nearby phone", rssi = strongest.rssi, sonar = false))
    }

    actual fun setLocalSonarAnnounce(payload: ByteArray?) {
        // Broadcast our npub/capabilities as a signed 0x53 so phones treat us as a
        // full Sonar peer (enables the White Noise fallback out of BLE range).
        MeshLink.setSonarPayload(payload)
    }
    actual fun setMeshNickname(nick: String) {
        if (nick.isNotBlank() && nick != this.nick) {
            this.nick = nick
            if (available()) refreshAnnounce()
        }
    }
    actual fun sonarPeers(): Map<String, ByteArray> =
        MeshLink.sonarPeers().filterKeys { isKnownPeer(it) }

    actual fun sendMeshDm(peerId: String, messageId: String, text: String, replyTo: String?): Boolean =
        MeshLink.sendDm(peerId, messageId, text, replyTo)
    actual fun drainMeshSendFailures(): List<MeshSendFailure> = emptyList()
    actual fun sendMeshDmNow(peerId: String, messageId: String, text: String): Boolean =
        MeshLink.sendDmNow(peerId, messageId, text)
    actual fun hasMeshLink(peerId: String): Boolean = MeshLink.hasLink(peerId)
    actual fun localPeerIdHex(): String = MeshIdentity.peerIdHex
    actual fun drainMeshDm(): List<MeshDmIn> =
        MeshLink.drainDms().filter { isKnownPeer(it.peerId) }
    actual fun sendMeshDeliveryAck(peerId: String, messageId: String): Boolean =
        MeshLink.sendDeliveryAck(peerId, messageId)
    actual fun drainMeshDeliveryReceipts(): List<MeshDeliveryReceipt> =
        MeshLink.drainDeliveryReceipts().filter { isKnownPeer(it.peerId) }
    actual fun discardPendingDeliverySignals() {
        // The desktop bridge has no asynchronous GATT completion boundary, so
        // there are no buffered send failures; only receipts need dropping.
        MeshLink.drainDeliveryReceipts()
    }
    actual fun sendMeshMedia(peerId: String, messageId: String, bytes: ByteArray, filename: String, mimeType: String): Boolean = false
    actual fun drainMeshMediaSendFailures(): List<MeshMediaSendFailure> = emptyList()
    actual fun drainMeshMedia(): List<MeshMediaIn> = emptyList()
    actual fun nowSecs(): Long = System.currentTimeMillis() / 1000

    // Public Mesh-channel broadcast (0x02) — not wired on desktop yet.
    actual fun sendMeshBroadcast(text: String): Boolean = false
    actual fun drainMeshBroadcast(): List<MeshBroadcastIn> = emptyList()
    actual fun connectedMeshPeerCount(): Int = MeshLink.namedPeers().size
}
