package chat.bitchat.sonar

import uniffi.sonar_ffi.SonarNoise
import uniffi.sonar_ffi.meshDecodePacket
import uniffi.sonar_ffi.meshDecodePrivateMessage
import uniffi.sonar_ffi.meshEncodePrivateMessage
import uniffi.sonar_ffi.meshParseAnnounce
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue

/**
 * Desktop BLE mesh protocol engine — the Noise-over-GATT transport, the desktop
 * twin of the Android `MeshGatt`'s protocol half. It runs a fast pump thread that
 * drains the packets phones write to our GATT characteristic (via [BleBridge]),
 * decodes them with the SAME byte-exact Rust core the phones use, and:
 *  - **announce (0x01)** → learns a named peer (keyed by fingerprint),
 *  - **handshake (0x10)** → drives the Noise XX **responder** (we are the GATT
 *    server, the phone initiates): read m1 → reply m2 → read m3 → session,
 *  - **encrypted (0x11)** → decrypts a private message into the DM queue.
 *
 * Replies (m2, encrypted DMs) go back out through the bridge's notify path. The
 * phone, not the desktop, initiates the handshake, so the desktop only ever plays
 * the responder; outbound DMs queue until that link forms.
 *
 * Scope: a single connected phone (bluster doesn't attribute writes to a specific
 * central, and notify reaches all subscribers) — enough for desktop↔phone DMs.
 */
object MeshLink {
    private const val TYPE_ANNOUNCE = 0x01
    private const val TYPE_NOISE_HANDSHAKE = 0x10
    private const val TYPE_NOISE_ENCRYPTED = 0x11
    private const val TYPE_SONAR = 0x53
    private const val PEER_TTL_MS = 90_000L

    private class Session(val noise: SonarNoise) {
        @Volatile var established = false
    }

    private val sessions = ConcurrentHashMap<String, Session>()        // fp -> Noise session
    private val fpByPeerId = ConcurrentHashMap<String, String>()       // peerId -> fp
    private val peerIdByFp = ConcurrentHashMap<String, String>()       // fp -> current peerId
    private val nameByFp = ConcurrentHashMap<String, String>()
    private val seenByFp = ConcurrentHashMap<String, Long>()           // fp -> last-activity ms
    private val sonarByPeerId = ConcurrentHashMap<String, ByteArray>() // peerId -> 0x53 payload
    private val rxDms = ConcurrentLinkedQueue<MeshDmIn>()
    private val pending = ConcurrentHashMap<String, ConcurrentLinkedQueue<Pair<String, String>>>()

    @Volatile private var running = false

    fun start() {
        if (running) return
        running = true
        Thread({ loop() }, "sonar-mesh-link").apply { isDaemon = true }.start()
    }

    fun stop() { running = false }

    private fun loop() {
        while (running) {
            runCatching { pump() }
            try { Thread.sleep(120) } catch (_: InterruptedException) { break }
        }
    }

    private fun pump() {
        for (pkt in BleBridge.drainRx()) {
            val info = runCatching { meshDecodePacket(pkt) }.getOrNull() ?: continue
            val sender = info.senderIdHex
            when (info.packetType.toInt()) {
                TYPE_ANNOUNCE -> {
                    val ann = runCatching { meshParseAnnounce(pkt) }.getOrNull() ?: continue
                    val fp = MeshIdentity.fingerprintOf(ann.noisePublicKeyHex)
                    if (fp.isNotEmpty()) {
                        fpByPeerId[sender] = fp; peerIdByFp[fp] = sender
                        nameByFp[fp] = ann.nickname; touch(fp)
                    }
                }
                TYPE_NOISE_HANDSHAKE -> handleHandshake(sender, info.payload)
                TYPE_NOISE_ENCRYPTED -> handleEncrypted(sender, info.payload)
                TYPE_SONAR -> sonarByPeerId[sender] = info.payload
            }
        }
        val now = System.currentTimeMillis()
        seenByFp.entries.removeIf { now - it.value > PEER_TTL_MS }
    }

    private fun touch(fp: String) { seenByFp[fp] = System.currentTimeMillis() }

    /** Noise XX responder: read m1 → reply m2 → read m3 → established. */
    private fun handleHandshake(senderPeerId: String, m: ByteArray) {
        val fp = fpByPeerId[senderPeerId] ?: senderPeerId
        val s = sessions.getOrPut(fp) { Session(SonarNoise.responder(MeshIdentity.noisePrivHex())) }
        if (s.established) { touch(fp); return }
        synchronized(s) {
            runCatching {
                s.noise.readMessage(m) // m1, then m3
                if (s.noise.isFinished()) {
                    s.noise.intoSession(); s.established = true
                    sonarLog("MeshLink", "Noise link ESTABLISHED with ${nameByFp[fp] ?: fp.take(8)}")
                    flushPending(fp)
                } else {
                    val m2 = s.noise.writeMessage()
                    BleBridge.notify(MeshIdentity.buildPacket(TYPE_NOISE_HANDSHAKE.toUByte(), senderPeerId, m2))
                }
            }.onFailure { sessions.remove(fp) }
        }
        touch(fp)
    }

    private fun handleEncrypted(senderPeerId: String, ciphertext: ByteArray) {
        val fp = fpByPeerId[senderPeerId] ?: senderPeerId
        val s = sessions[fp]?.takeIf { it.established } ?: return
        synchronized(s) {
            runCatching {
                val plain = s.noise.decrypt(ciphertext)
                meshDecodePrivateMessage(plain)?.let { pm ->
                    sonarLog("MeshLink", "RX DM from ${nameByFp[fp] ?: fp.take(8)} (${pm.content.length} chars)")
                    rxDms.add(MeshDmIn(fp, pm.content, System.currentTimeMillis() / 1000))
                }
            }
        }
        touch(fp)
    }

    fun hasLink(fp: String): Boolean = sessions[fp]?.established == true

    fun sendDm(fp: String, messageId: String, text: String): Boolean {
        val s = sessions[fp]?.takeIf { it.established }
        if (s == null) {
            // No live link yet — the phone initiates the handshake, so queue and
            // deliver on establish (mirrors Android's pending-send behavior).
            pending.getOrPut(fp) { ConcurrentLinkedQueue() }.add(messageId to text)
            return true
        }
        return encryptAndSend(fp, s, messageId, text)
    }

    private fun encryptAndSend(fp: String, s: Session, messageId: String, text: String): Boolean {
        val peerId = peerIdByFp[fp] ?: return false
        return synchronized(s) {
            runCatching {
                val plain = meshEncodePrivateMessage(messageId, text)
                val ct = s.noise.encrypt(plain)
                BleBridge.notify(MeshIdentity.buildPacket(TYPE_NOISE_ENCRYPTED.toUByte(), peerId, ct))
                sonarLog("MeshLink", "TX DM to ${nameByFp[fp] ?: fp.take(8)} (${text.length} chars)")
                true
            }.getOrDefault(false)
        }
    }

    private fun flushPending(fp: String) {
        val q = pending[fp] ?: return
        val s = sessions[fp]?.takeIf { it.established } ?: return
        while (true) {
            val (mid, text) = q.poll() ?: break
            encryptAndSend(fp, s, mid, text)
        }
    }

    fun drainDms(): List<MeshDmIn> {
        val out = ArrayList<MeshDmIn>()
        while (true) out.add(rxDms.poll() ?: break)
        return out
    }

    /** Named, deduped mesh peers (from the announce), fresh within the TTL. */
    fun namedPeers(): List<MeshPeer> {
        val now = System.currentTimeMillis()
        return nameByFp.entries
            .filter { (fp, _) -> now - (seenByFp[fp] ?: 0L) < PEER_TTL_MS }
            .map { (fp, name) -> MeshPeer("mesh:$fp", name.ifBlank { "mesh peer" }, rssi = -50, sonar = true) }
    }

    /** Sonar Discovery (0x53) payloads, keyed by the radar peer id (the fp). */
    fun sonarPeers(): Map<String, ByteArray> {
        val out = HashMap<String, ByteArray>()
        for ((peerId, payload) in sonarByPeerId) fpByPeerId[peerId]?.let { out[it] = payload }
        return out
    }

    fun wipe() {
        sessions.clear(); fpByPeerId.clear(); peerIdByFp.clear()
        nameByFp.clear(); seenByFp.clear(); sonarByPeerId.clear(); rxDms.clear(); pending.clear()
    }
}
