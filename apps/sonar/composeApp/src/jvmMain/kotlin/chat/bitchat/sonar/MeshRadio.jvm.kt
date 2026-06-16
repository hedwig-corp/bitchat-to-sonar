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

    /** A peer learned from the announce it WROTE to our GATT server (named, stable
     *  by fingerprint). A phone suppresses its own advertising while connected to
     *  us, so this — not scanning — is how the desktop reliably learns it. */
    private data class Announced(val fp: String, val name: String, val ts: Long)
    private val announced = java.util.concurrent.ConcurrentHashMap<String, Announced>()
    private const val ANN_TTL_MS = 90_000L

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

    actual fun peers(): List<MeshPeer> {
        drainAnnounces()
        val now = System.currentTimeMillis()
        announced.entries.removeIf { now - it.value.ts > ANN_TTL_MS }
        // Named peers learned via the GATT announce (stable + deduped by
        // fingerprint) are the real radar peers. The raw scan returns rotating,
        // unnamed BLE addresses; surface those only as a fallback for peers that
        // haven't connected to us yet, keyed so they don't duplicate named ones.
        val named = announced.values.map { a ->
            MeshPeer(id = "mesh:" + a.fp, name = a.name.ifBlank { "mesh peer" }, rssi = -50, sonar = true)
        }
        if (named.isNotEmpty()) return named
        // No connected (named) peer yet → fast path: our FILTERED scan sees phones
        // advertising before they dial us, so the radar isn't empty for ~20s. A
        // phone rapidly rotates its BLE address, so collapse all current scan hits
        // into ONE "nearby phone" node (it becomes a named peer once it connects +
        // writes its announce). Imperfect if several phones are nearby, but matches
        // the common case and avoids a flickering cloud of rotating addresses.
        val scan = BleBridge.peers()
        if (scan.isEmpty()) return emptyList()
        val strongest = scan.maxByOrNull { it.rssi } ?: scan.first()
        return listOf(MeshPeer(id = "mesh:nearby", name = "nearby phone", rssi = strongest.rssi, sonar = false))
    }

    /** Decode packets centrals wrote to us; record each announce as a named peer
     *  via the SAME Rust core the phones use (meshDecodePacket + meshParseAnnounce). */
    private fun drainAnnounces() {
        val pkts = BleBridge.drainRx()
        if (pkts.isEmpty()) return
        val now = System.currentTimeMillis()
        for (pkt in pkts) {
            val info = runCatching { uniffi.sonar_ffi.meshDecodePacket(pkt) }.getOrNull() ?: continue
            if (info.packetType.toInt() != 0x1) continue // TYPE_ANNOUNCE
            val ann = runCatching { uniffi.sonar_ffi.meshParseAnnounce(pkt) }.getOrNull() ?: continue
            val fp = fingerprintOf(ann.noisePublicKeyHex)
            if (fp.isNotEmpty()) announced[fp] = Announced(fp, ann.nickname, now)
        }
        // A connected phone re-writes its announce only occasionally, but keeps
        // writing handshake/keepalive packets — so ANY inbound write means the
        // known peer is still here. Refresh so the radar doesn't flicker between
        // announces (the mobile apps keep a peer while its Noise link is live).
        announced.replaceAll { _, a -> a.copy(ts = now) }
    }

    /** Stable fingerprint = SHA256(noise static pubkey), hex (matches Android). */
    private fun fingerprintOf(noisePublicKeyHex: String): String = runCatching {
        val bytes = ByteArray(noisePublicKeyHex.length / 2) {
            ((noisePublicKeyHex[it * 2].digitToInt(16) shl 4) or noisePublicKeyHex[it * 2 + 1].digitToInt(16)).toByte()
        }
        chat.bitchat.sonar.crypto.Sha256.hash(bytes)
            .joinToString("") { ((it.toInt() and 0xFF) + 0x100).toString(16).substring(1) }
    }.getOrDefault("")

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
