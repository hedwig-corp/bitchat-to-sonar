package chat.bitchat.sonar

import chat.bitchat.sonar.BleBridge.MeshRx
import chat.bitchat.sonar.BleBridge.SERVER_LINK
import uniffi.sonar_ffi.MeshReassembler
import uniffi.sonar_ffi.SonarNoise
import uniffi.sonar_ffi.meshDecodePacket
import uniffi.sonar_ffi.meshDecodePrivateMessage
import uniffi.sonar_ffi.meshEncodePrivateMessage
import uniffi.sonar_ffi.meshEncodePrivateMessageWithReply
import uniffi.sonar_ffi.meshFragment
import uniffi.sonar_ffi.meshParseAnnounce
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue

/**
 * The radio as [MeshLink] sees it: [BleBridge] in the app, a simulated radio
 * wired to real phone engines in `DesktopMeshInteropTest`.
 */
internal interface MeshWire {
    /** Everything heard since the last call, in order (see [MeshRx]). */
    fun drain(): List<MeshRx>

    /** To every link: the GATT server's subscribers and every central link. */
    fun broadcast(bytes: ByteArray)

    /** To ONE central link. False when that link is gone. */
    fun sendTo(link: Long, bytes: ByteArray): Boolean
}

private object BleWire : MeshWire {
    override fun drain(): List<MeshRx> = BleBridge.drainRx()
    override fun broadcast(bytes: ByteArray) = BleBridge.notify(bytes)
    override fun sendTo(link: Long, bytes: ByteArray): Boolean = BleBridge.sendToLink(link, bytes)
}

/**
 * Desktop BLE mesh protocol engine — the Noise-over-GATT transport, the desktop
 * twin of the Android `MeshGatt`'s protocol half. It runs a fast pump thread that
 * drains what the radio heard (via [BleBridge], per link), decodes it with the
 * SAME byte-exact Rust core the phones use, and:
 *  - **announce (0x01)** → learns a named peer (keyed by fingerprint),
 *  - **handshake (0x10)** → drives Noise XX,
 *  - **encrypted (0x11)** → decrypts a private message into the DM queue.
 *
 * Who initiates follows Android's engine, which keeps a Noise session per ROUTE:
 * the side that dialed initiates. A phone that dialed our GATT server initiates
 * and we answer (the path verified with iPhone and Pixel); on a link WE dialed as
 * a central, a phone never initiates (Android's server side waits for the
 * peer's 0x10), so we do, on its direct announce. The bridge links out only
 * while we cannot advertise, so a phone never has both routes to us.
 *
 * Replies go back on the link the peer was last heard on; packets on the GATT
 * server path cannot be attributed and go out as a notify to every subscriber,
 * so that path serves a single phone (bluster does not attribute writes to a
 * central). Outbound DMs fail fast until a link forms; the shared app outbox owns
 * retry and transport fallback.
 */
object MeshLink {
    private const val TYPE_ANNOUNCE = 0x01
    private const val TYPE_NOISE_HANDSHAKE = 0x10
    private const val TYPE_NOISE_ENCRYPTED = 0x11
    private const val TYPE_FRAGMENT = 0x20
    private const val TYPE_SONAR = 0x53
    private const val PEER_TTL_MS = 90_000L

    /** A packet from a peer on the link, not relayed (bitchat's full TTL). */
    private const val DIRECT_TTL = 7

    /** Noise XX m1 is the bare 32-byte ephemeral key. */
    private const val NOISE_XX_M1_BYTES = 32

    /**
     * An unfinished handshake is abandoned after this long. Android's engine
     * retries its own on the same 8 s cadence; without a bound, one lost m1 or m2
     * left the session "in flight" forever, and since [beginHandshake] no-ops
     * while a session exists, nothing ever retried.
     */
    internal const val HANDSHAKE_TIMEOUT_MS = 8_000L

    /**
     * One GATT value per packet up to this size; anything larger goes out as
     * 0x20 fragments of [FRAGMENT_CHUNK_BYTES]. Both are the Android engine's
     * (`MAX_SINGLE_GATT_PACKET_BYTES`, `FRAGMENT_CHUNK_SIZE` in mesh_engine.rs),
     * sized so every write fits an ATT MTU and iOS's reliable 256-byte block.
     * A DM of a couple of hundred characters pads to 512 bytes and did not fit.
     */
    internal const val MAX_SINGLE_PACKET_BYTES = 480
    private const val FRAGMENT_CHUNK_BYTES = 205u

    /** Phones fragment the same way, so their long DMs arrive as 0x20 pieces. */
    private val reassembler = MeshReassembler()

    private class Session(val noise: SonarNoise, val initiator: Boolean, val startedAtMs: Long) {
        @Volatile var established = false
    }

    private val sessions = ConcurrentHashMap<String, Session>()        // fp -> Noise session
    private val fpByPeerId = ConcurrentHashMap<String, String>()       // peerId -> fp
    private val peerIdByFp = ConcurrentHashMap<String, String>()       // fp -> current peerId
    private val linkByFp = ConcurrentHashMap<String, Long>()           // fp -> link it was last heard on
    private val nameByFp = ConcurrentHashMap<String, String>()
    private val seenByFp = ConcurrentHashMap<String, Long>()           // fp -> last-activity ms
    private val sonarByPeerId = ConcurrentHashMap<String, ByteArray>() // peerId -> 0x53 payload
    private val sonarSeenAt = ConcurrentHashMap<String, Long>()        // peerId -> last 0x53 ms (for TTL)
    private val rxDms = ConcurrentLinkedQueue<MeshDmIn>()
    private val rxDeliveries = ConcurrentLinkedQueue<MeshDeliveryReceipt>()

    /** Our encoded SonarAnnounce (npub + caps) to broadcast as a signed 0x53, so
     *  phones treat us as a full Sonar peer and continue our chat over White Noise
     *  when out of BLE range. Null = nothing to advertise yet. */
    @Volatile private var sonarPayload: ByteArray? = null
    @Volatile private var lastSonarSendMs = 0L
    @Volatile private var peerUpdateListener: (() -> Unit)? = null

    @Volatile private var running = false

    /** The radio. Replaced only by tests. */
    @Volatile internal var wire: MeshWire = BleWire

    /** Wall clock in ms. Replaced only by tests, which drive time by hand. */
    @Volatile internal var clock: () -> Long = System::currentTimeMillis

    /** Set/clear the SonarAnnounce payload broadcast as our 0x53 (from the app). */
    fun setSonarPayload(payload: ByteArray?) { sonarPayload = payload }

    fun setPeerUpdateListener(listener: (() -> Unit)?) {
        peerUpdateListener = listener
    }

    private fun notifyPeerUpdate() {
        peerUpdateListener?.let { listener -> runCatching(listener) }
    }

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

    /** One pump turn, driven by hand from tests (no thread, no sleep). */
    internal fun pumpForTest() = pump()

    private fun pump() {
        for (rx in wire.drain()) {
            val pkt = rx.bytes
            if (pkt == null) onLinkDown(rx.link) else handlePacket(pkt, rx.link, reassembled = false)
        }
        afterPump()
    }

    private fun handlePacket(pkt: ByteArray, link: Long, reassembled: Boolean) {
        val info = runCatching { meshDecodePacket(pkt) }.getOrNull() ?: return
        val sender = info.senderIdHex
        when (info.packetType.toInt()) {
            TYPE_FRAGMENT -> {
                // A long DM from a phone. The whole packet goes through the
                // same rules as one that fit, on the link its pieces came in.
                if (reassembled) return
                val whole = runCatching { reassembler.add(sender, info.payload) }.getOrNull() ?: return
                handlePacket(whole, link, reassembled = true)
            }
            TYPE_ANNOUNCE -> {
                val ann = runCatching { meshParseAnnounce(pkt) }.getOrNull() ?: return
                val fp = MeshIdentity.fingerprintOf(ann.noisePublicKeyHex)
                if (fp.isNotEmpty()) {
                    val now = clock()
                    val wasVisible = now - (seenByFp[fp] ?: 0L) < PEER_TTL_MS
                    fpByPeerId[sender] = fp; peerIdByFp[fp] = sender
                    val previousName = nameByFp.put(fp, ann.nickname)
                    seenByFp[fp] = now
                    if (!wasVisible || previousName != ann.nickname) notifyPeerUpdate()
                    // Only a direct announce binds the peer to this link; a
                    // relayed one says nothing about where the peer is.
                    if (info.ttl.toInt() == DIRECT_TTL) {
                        linkByFp[fp] = link
                        // On a link WE dialed, start the handshake: the phone
                        // will not (Android's server side waits for our 0x10,
                        // iOS only initiates when it has something to send),
                        // and without a session hasLink() stays false, which
                        // the UI reads as "out of range". Never on the GATT
                        // server path, where the phone dialed and initiates:
                        // an m1 from us there resets its own in-flight one.
                        if (link != SERVER_LINK) beginHandshake(fp, sender)
                    }
                }
            }
            TYPE_NOISE_HANDSHAKE -> handleHandshake(sender, info.payload, link)
            TYPE_NOISE_ENCRYPTED -> handleEncrypted(sender, info.payload, link)
            TYPE_SONAR -> {
                sonarSeenAt[sender] = clock()
                val previous = sonarByPeerId.put(sender, info.payload)
                if (previous == null) {
                    sonarLog("MeshLink", "RX 0x53 Sonar announce from ${nameByFp[fpByPeerId[sender]] ?: sender} → peer is a full Sonar user (npub for WN fallback)")
                }
                if (previous == null || !previous.contentEquals(info.payload)) notifyPeerUpdate()
            }
        }
    }

    private fun afterPump() {
        val now = clock()
        expireStalledHandshakes(now)
        val peersExpired = seenByFp.entries.removeIf { now - it.value > PEER_TTL_MS }
        // Expire stale 0x53 payloads too (parity with seenByFp) so a peer that left
        // range stops being reported as a live Sonar user by [sonarPeers].
        val sonarExpired = sonarSeenAt.entries.removeIf { now - it.value > PEER_TTL_MS }
        val sonarRemoved = sonarByPeerId.keys.retainAll(sonarSeenAt.keys)
        if (peersExpired || sonarExpired || sonarRemoved) notifyPeerUpdate()

        // Broadcast our signed 0x53 Sonar announce every ~3s so connected phones
        // learn our npub and can continue the chat over White Noise out of range.
        // Only while a peer is actually around (a connected central writes its
        // announce → seenByFp) — no point signing + notifying into the void.
        val payload = sonarPayload
        if (payload != null && seenByFp.isNotEmpty() && now - lastSonarSendMs >= 3_000L) {
            lastSonarSendMs = now
            runCatching { wire.broadcast(MeshIdentity.buildSonarPacket(payload)) }
        }
    }

    private fun touch(fp: String) { seenByFp[fp] = clock() }

    /** Remember where [fp] was heard, so replies go back on that link. */
    private fun heardOn(fp: String, link: Long) { linkByFp[fp] = link }

    /**
     * To [fp] on the link it was last heard on. Packets on the GATT server path
     * cannot be attributed to one central, so they go to every subscriber, as
     * before; a central link gets only its own peer's packets. Broadcasting there
     * too was not harmless: Android answers a 0x10 whatever its recipient id
     * says, so an m1 meant for one phone reset every other phone's responder.
     */
    private fun sendTo(fp: String, recipientPeerId: String, type: Int, payload: ByteArray): Boolean {
        val link = linkByFp[fp]
        return packetsFor(recipientPeerId, type, payload).all { packet ->
            if (link == null || link == SERVER_LINK) {
                wire.broadcast(packet)
                true
            } else {
                wire.sendTo(link, packet)
            }
        }
    }

    /** The packet, or its 0x20 fragments when it would not fit one GATT value. */
    private fun packetsFor(recipientPeerId: String, type: Int, payload: ByteArray): List<ByteArray> {
        val packet = MeshIdentity.buildPacket(type.toUByte(), recipientPeerId, payload)
        if (packet.size <= MAX_SINGLE_PACKET_BYTES) return listOf(packet)
        // A wire id: the CSPRNG seam, per the Randomness Rule.
        val id = secureRandomHex(8)
        return meshFragment(packet, id, type.toUByte(), FRAGMENT_CHUNK_BYTES).map { piece ->
            MeshIdentity.buildPacket(TYPE_FRAGMENT.toUByte(), recipientPeerId, piece)
        }
    }

    /**
     * A central link we dialed went down. The phone throws away its Noise state
     * with the GATT connection (Android keys it by route) and never initiates
     * toward us, so a session kept past the drop would look established here
     * forever while every DM we encrypted was silently discarded there. Drop it:
     * the next direct announce on the relinked route starts a fresh handshake.
     */
    private fun onLinkDown(link: Long) {
        if (link == SERVER_LINK) return
        for (fp in linkByFp.filterValues { it == link }.keys) {
            linkByFp.remove(fp, link)
            if (sessions.remove(fp) != null) {
                sonarLog("MeshLink", "link to ${nameByFp[fp] ?: fp.take(8)} dropped → Noise session reset")
            }
        }
    }

    /**
     * Abandon handshakes that stopped moving (a lost m1/m2/m3), and retry at once
     * where we are the initiator and still hold the link: the phone's next
     * announce can be 30 s away.
     */
    private fun expireStalledHandshakes(now: Long) {
        for ((fp, s) in sessions) {
            if (s.established || now - s.startedAtMs < HANDSHAKE_TIMEOUT_MS) continue
            if (!sessions.remove(fp, s)) continue
            sonarLog("MeshLink", "Noise handshake with ${nameByFp[fp] ?: fp.take(8)} timed out")
            val link = linkByFp[fp]
            val peerId = peerIdByFp[fp]
            if (s.initiator && link != null && link != SERVER_LINK && peerId != null) beginHandshake(fp, peerId)
        }
    }

    /** Noise XX responder: read m1 → reply m2 → read m3 → established.
     *
     *  A handshake packet arriving on an ALREADY-established session means the
     *  phone reconnected its GATT link and is starting a FRESH handshake — and we
     *  can't see the disconnect on the GATT server path (bluster stubs the
     *  CoreBluetooth disconnect callback), so without this the desktop keeps the
     *  stale session, ignores the new m1, and the phone can never re-establish
     *  (its chat shows "out of range"). So tear down + start fresh whenever a
     *  handshake doesn't fit the current state. */
    private fun handleHandshake(senderPeerId: String, m: ByteArray, link: Long) {
        val fp = fpByPeerId[senderPeerId] ?: senderPeerId
        heardOn(fp, link)
        val current = sessions[fp]
        if (current != null && current.initiator && !current.established && m.size == NOISE_XX_M1_BYTES) {
            // Both ends opened at once on a link we dialed. Keep ours: iOS
            // abandons its own initiator when our m1 reaches it, and Android never
            // initiates toward a central. Answering theirs as well left each end
            // holding a responder for the other's abandoned m1, and the pair
            // churned through resets (and iOS's 10-per-minute handshake limit).
            sonarLog("MeshLink", "simultaneous Noise open with ${nameByFp[fp] ?: fp.take(8)} → keeping ours")
            return
        }
        if (current?.established == true) {
            sonarLog("MeshLink", "re-handshake from ${nameByFp[fp] ?: fp.take(8)} → resetting session")
            sessions.remove(fp)
        }
        // getOrPut, so an initiator session we started is reused for its m2 rather
        // than replaced by a responder.
        val s = sessions.getOrPut(fp) { responder() }
        synchronized(s) {
            if (!feedHandshake(fp, senderPeerId, s, m)) {
                // Wrong message for this state (a fresh m1 mid-handshake) — restart.
                val fresh = responder()
                sessions[fp] = fresh
                synchronized(fresh) { feedHandshake(fp, senderPeerId, fresh, m) }
            }
        }
        touch(fp)
    }

    private fun responder() = Session(SonarNoise.responder(MeshIdentity.noisePrivHex()), initiator = false, startedAtMs = clock())

    /**
     * Noise XX initiator: write m1 → read m2 → write m3 → established.
     *
     * No-op when a session already exists, so repeated announces do not restart a
     * handshake in flight (Android re-announces three times on subscribe and then
     * every 30 s).
     */
    private fun beginHandshake(fp: String, peerId: String) {
        if (sessions.containsKey(fp)) return
        val s = Session(SonarNoise.initiator(MeshIdentity.noisePrivHex()), initiator = true, startedAtMs = clock())
        if (sessions.putIfAbsent(fp, s) != null) return
        synchronized(s) {
            runCatching {
                val m1 = s.noise.writeMessage()
                check(sendTo(fp, peerId, TYPE_NOISE_HANDSHAKE, m1)) { "link gone" }
                sonarLog("MeshLink", "Noise handshake started with ${nameByFp[fp] ?: fp.take(8)}")
            }.onFailure { sessions.remove(fp, s) }
        }
    }

    /** Returns false if [m] couldn't be processed (caller restarts the handshake). */
    private fun feedHandshake(fp: String, senderPeerId: String, s: Session, m: ByteArray): Boolean =
        runCatching {
            s.noise.readMessage(m) // m1, then m3 (responder) or m2 (initiator)
            if (s.noise.isFinished()) {
                s.noise.intoSession(); s.established = true
                sonarLog("MeshLink", "Noise link ESTABLISHED with ${nameByFp[fp] ?: fp.take(8)}")
            } else {
                val next = s.noise.writeMessage()
                sendTo(fp, senderPeerId, TYPE_NOISE_HANDSHAKE, next)
                // The responder finishes after READING m3; the initiator finishes
                // after WRITING it. Without this check the initiator sends m3 and
                // then waits forever for a fourth message that never comes.
                if (s.noise.isFinished()) {
                    s.noise.intoSession(); s.established = true
                    sonarLog("MeshLink", "Noise link ESTABLISHED with ${nameByFp[fp] ?: fp.take(8)}")
                }
            }
            true
        }.getOrElse { sessions.remove(fp, s); false }

    private fun handleEncrypted(senderPeerId: String, ciphertext: ByteArray, link: Long) {
        val fp = fpByPeerId[senderPeerId] ?: senderPeerId
        val s = sessions[fp]?.takeIf { it.established } ?: return
        heardOn(fp, link)
        synchronized(s) {
            runCatching {
                val plain = s.noise.decrypt(ciphertext)
                when (plain.firstOrNull()?.toInt()?.and(0xff)) {
                    MeshNoisePayload.PRIVATE_MESSAGE -> meshDecodePrivateMessage(plain)?.let { pm ->
                        sonarLog("MeshLink", "RX DM from ${nameByFp[fp] ?: fp.take(8)} (${pm.content.length} chars)")
                        rxDms.add(MeshDmIn(fp, pm.messageId, pm.content, clock() / 1000, pm.replyTo))
                    }
                    MeshNoisePayload.DELIVERED -> plain.copyOfRange(1, plain.size).decodeToString().takeIf(String::isNotEmpty)?.let { messageId ->
                        sonarLog("MeshLink", "RX delivery receipt from ${nameByFp[fp] ?: fp.take(8)} id=${messageId.take(12)}")
                        rxDeliveries.add(MeshDeliveryReceipt(fp, messageId))
                    }
                }
            }
        }
        touch(fp)
    }

    fun hasLink(fp: String): Boolean = sessions[fp]?.established == true

    fun sendDm(fp: String, messageId: String, text: String, replyTo: String? = null): Boolean {
        val s = sessions[fp]?.takeIf { it.established } ?: return false
        return encryptAndSend(fp, s, messageId, text, replyTo)
    }

    fun sendDmNow(fp: String, messageId: String, text: String): Boolean {
        val s = sessions[fp]?.takeIf { it.established } ?: return false
        return encryptAndSend(fp, s, messageId, text)
    }

    fun sendDeliveryAck(fp: String, messageId: String): Boolean {
        if (messageId.isEmpty()) return false
        val s = sessions[fp]?.takeIf { it.established } ?: return false
        val peerId = peerIdByFp[fp] ?: return false
        return synchronized(s) {
            runCatching {
                val plain = byteArrayOf(MeshNoisePayload.DELIVERED.toByte()) + messageId.encodeToByteArray()
                val ct = s.noise.encrypt(plain)
                sendTo(fp, peerId, TYPE_NOISE_ENCRYPTED, ct)
            }.getOrDefault(false)
        }
    }

    private fun encryptAndSend(
        fp: String,
        s: Session,
        messageId: String,
        text: String,
        replyTo: String? = null,
    ): Boolean {
        val peerId = peerIdByFp[fp] ?: return false
        return synchronized(s) {
            runCatching {
                val parent = replyTo?.trim()?.takeIf { it.isNotEmpty() }
                val plain = if (parent == null) {
                    meshEncodePrivateMessage(messageId, text)
                } else {
                    meshEncodePrivateMessageWithReply(messageId, text, parent)
                }
                val ct = s.noise.encrypt(plain)
                val sent = sendTo(fp, peerId, TYPE_NOISE_ENCRYPTED, ct)
                if (sent) sonarLog("MeshLink", "TX DM to ${nameByFp[fp] ?: fp.take(8)} (${text.length} chars)")
                sent
            }.getOrDefault(false)
        }
    }

    fun drainDms(): List<MeshDmIn> {
        val out = ArrayList<MeshDmIn>()
        while (true) out.add(rxDms.poll() ?: break)
        return out
    }

    fun drainDeliveryReceipts(): List<MeshDeliveryReceipt> {
        val out = ArrayList<MeshDeliveryReceipt>()
        while (true) out.add(rxDeliveries.poll() ?: break)
        return out
    }

    /** Named, deduped mesh peers (from the announce), fresh within the TTL. */
    fun namedPeers(): List<MeshPeer> {
        val now = clock()
        val sonarFingerprints = sonarByPeerId.keys.mapNotNullTo(hashSetOf<String>()) { fpByPeerId[it] }
        return nameByFp.entries
            .filter { (fp, _) -> now - (seenByFp[fp] ?: 0L) < PEER_TTL_MS }
            .map { (fp, name) ->
                MeshPeer(
                    "mesh:$fp",
                    name.ifBlank { "mesh peer" },
                    rssi = -50,
                    sonar = fp in sonarFingerprints,
                )
            }
    }

    /** Sonar Discovery (0x53) payloads, keyed by the radar peer id (the fp). */
    fun sonarPeers(): Map<String, ByteArray> {
        val out = HashMap<String, ByteArray>()
        for ((peerId, payload) in sonarByPeerId) fpByPeerId[peerId]?.let { out[it] = payload }
        return out
    }

    fun wipe() {
        sessions.clear(); fpByPeerId.clear(); peerIdByFp.clear(); linkByFp.clear()
        nameByFp.clear(); seenByFp.clear(); sonarByPeerId.clear(); sonarSeenAt.clear(); rxDms.clear(); rxDeliveries.clear()
        notifyPeerUpdate()
    }
}
