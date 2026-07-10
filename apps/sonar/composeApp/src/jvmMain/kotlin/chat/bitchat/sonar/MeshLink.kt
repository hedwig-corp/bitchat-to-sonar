package chat.bitchat.sonar

import uniffi.sonar_ffi.SonarNoise
import uniffi.sonar_ffi.meshDecodePacket
import uniffi.sonar_ffi.meshDecodePrivateMessage
import uniffi.sonar_ffi.meshEncodePrivateMessage
import uniffi.sonar_ffi.meshParseAnnounce
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicLong

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
 * the responder. Outbound DMs are fail-fast: [sendDm] writes only over a fresh
 * established session and reports native pre-flush drops back to the app, so the
 * app-level outbox (not this transport) owns plaintext retry and White Noise
 * fallback.
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

    private class Session(
        val noise: SonarNoise,
        val subscriptionToken: Long,
    ) {
        @Volatile var established = false
    }

    private data class PendingSend(
        val peerId: String,
        val messageId: String,
        val text: String,
        val tsSecs: Long,
        val session: Session,
    )

    private val sessions = ConcurrentHashMap<String, Session>()        // fp -> Noise session
    private val fpByPeerId = ConcurrentHashMap<String, String>()       // peerId -> fp
    private val peerIdByFp = ConcurrentHashMap<String, String>()       // fp -> current peerId
    private val nameByFp = ConcurrentHashMap<String, String>()
    private val seenByFp = ConcurrentHashMap<String, Long>()           // fp -> last-activity ms
    private val sonarByPeerId = ConcurrentHashMap<String, ByteArray>() // peerId -> 0x53 payload
    private val sonarSeenAt = ConcurrentHashMap<String, Long>()        // peerId -> last 0x53 ms (for TTL)
    private val rxDms = ConcurrentLinkedQueue<MeshDmIn>()
    private val linkUps = ConcurrentLinkedQueue<String>()              // fps whose link just established
    private val nextDeliveryId = AtomicLong(1)
    private val pendingSends = ConcurrentHashMap<Long, PendingSend>()
    private val sendFailures = ConcurrentLinkedQueue<MeshSendFailure>()

    /** Our encoded SonarAnnounce (npub + caps) to broadcast as a signed 0x53, so
     *  phones treat us as a full Sonar peer and continue our chat over White Noise
     *  when out of BLE range. Null = nothing to advertise yet. */
    @Volatile private var sonarPayload: ByteArray? = null
    @Volatile private var lastSonarSendMs = 0L
    @Volatile private var peerUpdateListener: (() -> Unit)? = null

    @Volatile private var running = false

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

    private fun pump() {
        processTxResults()
        for (rx in BleBridge.drainRx()) {
            val subscriptionToken = BleBridge.subscriptionToken()
            if (rx.subscriptionToken == 0L || rx.subscriptionToken != subscriptionToken) continue
            val pkt = rx.bytes
            val info = runCatching { meshDecodePacket(pkt) }.getOrNull() ?: continue
            val sender = info.senderIdHex
            // Keep radar activity fresh for every well-formed packet. Outbound
            // reachability does not trust this timestamp: it is bound to the
            // native CoreBluetooth subscription token in freshSession().
            fpByPeerId[sender]?.let { touch(it) }
            when (info.packetType.toInt()) {
                TYPE_ANNOUNCE -> {
                    val ann = runCatching { meshParseAnnounce(pkt) }.getOrNull() ?: continue
                    val fp = MeshIdentity.fingerprintOf(ann.noisePublicKeyHex)
                    if (fp.isNotEmpty()) {
                        val now = System.currentTimeMillis()
                        val wasVisible = now - (seenByFp[fp] ?: 0L) < PEER_TTL_MS
                        fpByPeerId[sender] = fp; peerIdByFp[fp] = sender
                        val previousName = nameByFp.put(fp, ann.nickname)
                        seenByFp[fp] = now
                        if (!wasVisible || previousName != ann.nickname) notifyPeerUpdate()
                    }
                }
                TYPE_NOISE_HANDSHAKE -> handleHandshake(sender, info.payload, rx.subscriptionToken)
                TYPE_NOISE_ENCRYPTED -> handleEncrypted(sender, info.payload, rx.subscriptionToken)
                TYPE_SONAR -> {
                    sonarSeenAt[sender] = System.currentTimeMillis()
                    val previous = sonarByPeerId.put(sender, info.payload)
                    if (previous == null) {
                        sonarLog("MeshLink", "RX 0x53 Sonar announce from ${nameByFp[fpByPeerId[sender]] ?: sender} → peer is a full Sonar user (npub for WN fallback)")
                    }
                    if (previous == null || !previous.contentEquals(info.payload)) notifyPeerUpdate()
                }
            }
        }
        val now = System.currentTimeMillis()
        val peersExpired = seenByFp.entries.removeIf { now - it.value > PEER_TTL_MS }
        // Expire stale 0x53 payloads too (parity with seenByFp) so a peer that left
        // range stops being reported as a live Sonar user by [sonarPeers].
        val sonarExpired = sonarSeenAt.entries.removeIf { now - it.value > PEER_TTL_MS }
        val sonarRemoved = sonarByPeerId.keys.retainAll(sonarSeenAt.keys)
        if (peersExpired || sonarExpired || sonarRemoved) notifyPeerUpdate()

        // Broadcast our signed 0x53 Sonar announce every ~3s so connected phones
        // learn our npub and can continue the chat over White Noise out of range.
        // Only while CoreBluetooth has an active subscriber — no point signing +
        // notifying into the void.
        val payload = sonarPayload
        val subscriptionToken = BleBridge.subscriptionToken()
        if (payload != null && subscriptionToken != 0L && now - lastSonarSendMs >= 3_000L) {
            lastSonarSendMs = now
            BleBridge.notify(MeshIdentity.buildSonarPacket(payload), subscriptionToken)
        }
    }

    private fun touch(fp: String) { seenByFp[fp] = System.currentTimeMillis() }

    /** Noise XX responder: read m1 → reply m2 → read m3 → established.
     *
     *  A handshake packet arriving on an ALREADY-established session means the
     *  phone is starting a FRESH handshake. Subscription tokens normally
     *  invalidate the previous link first, but resetting here also handles a
     *  peer-initiated rekey within the same GATT subscription. */
    private fun handleHandshake(senderPeerId: String, m: ByteArray, subscriptionToken: Long) {
        val fp = fpByPeerId[senderPeerId] ?: senderPeerId
        if (subscriptionToken == 0L || subscriptionToken != BleBridge.subscriptionToken()) return
        val current = sessions[fp]
        if (current != null && (current.established || current.subscriptionToken != subscriptionToken)) {
            sonarLog("MeshLink", "re-handshake from ${nameByFp[fp] ?: fp.take(8)} → resetting session")
            sessions.remove(fp)
        }
        val s = sessions.getOrPut(fp) {
            Session(SonarNoise.responder(MeshIdentity.noisePrivHex()), subscriptionToken)
        }
        synchronized(s) {
            if (!feedHandshake(fp, senderPeerId, s, m)) {
                // Wrong message for this state (a fresh m1 mid-handshake) — restart.
                val fresh = Session(SonarNoise.responder(MeshIdentity.noisePrivHex()), subscriptionToken)
                sessions[fp] = fresh
                synchronized(fresh) { feedHandshake(fp, senderPeerId, fresh, m) }
            }
        }
        touch(fp)
    }

    /** Returns false if [m] couldn't be processed (caller restarts the handshake). */
    private fun feedHandshake(fp: String, senderPeerId: String, s: Session, m: ByteArray): Boolean =
        runCatching {
            check(BleBridge.subscriptionToken() == s.subscriptionToken)
            s.noise.readMessage(m) // m1, then m3
            check(BleBridge.subscriptionToken() == s.subscriptionToken)
            if (s.noise.isFinished()) {
                s.noise.intoSession(); s.established = true
                linkUps.add(fp) // surface the re-link so the app flushes queued work
                sonarLog("MeshLink", "Noise link ESTABLISHED with ${nameByFp[fp] ?: fp.take(8)}")
            } else {
                val m2 = s.noise.writeMessage()
                check(
                    BleBridge.notify(
                        MeshIdentity.buildPacket(TYPE_NOISE_HANDSHAKE.toUByte(), senderPeerId, m2),
                        s.subscriptionToken,
                    )
                )
            }
            true
        }.getOrElse { sessions.remove(fp); false }

    private fun handleEncrypted(senderPeerId: String, ciphertext: ByteArray, subscriptionToken: Long) {
        val fp = fpByPeerId[senderPeerId] ?: senderPeerId
        val s = freshSession(fp) ?: return
        if (s.subscriptionToken != subscriptionToken) return
        synchronized(s) {
            val decrypted = runCatching {
                val plain = s.noise.decrypt(ciphertext)
                meshDecodePrivateMessage(plain)?.let { pm ->
                    sonarLog("MeshLink", "RX DM from ${nameByFp[fp] ?: fp.take(8)} (${pm.content.length} chars)")
                    rxDms.add(MeshDmIn(fp, pm.messageId, pm.content, System.currentTimeMillis() / 1000))
                }
            }.isSuccess
            if (decrypted) touch(fp)
        }
    }

    /** An established session owned by the current native GATT subscription.
     *  This predicate is shared by receive, reachability, and send paths. Quiet
     *  links stay live indefinitely; disconnected and replaced links fail closed
     *  without waiting for traffic or a wall-clock TTL. */
    private fun freshSession(fp: String): Session? {
        val s = sessions[fp]?.takeIf { it.established } ?: return null
        val subscriptionToken = BleBridge.subscriptionToken()
        return if (subscriptionToken != 0L && s.subscriptionToken == subscriptionToken) s else null
    }

    fun hasLink(fp: String): Boolean = freshSession(fp) != null

    fun sendDm(fp: String, messageId: String, text: String): Boolean {
        // No hidden queue and no stale-session write: report failure honestly so
        // the app-level outbox can retry or continue over White Noise (mirrors
        // Android, and matches hasLink so callers that skip the reachability gate
        // — e.g. flushPendingFavoriteControl — can't "succeed" into the void).
        val s = freshSession(fp) ?: return false
        return encryptAndSend(fp, s, messageId, text)
    }

    fun sendDmNow(fp: String, messageId: String, text: String): Boolean {
        val s = freshSession(fp) ?: return false
        return encryptAndSend(fp, s, messageId, text)
    }

    private fun encryptAndSend(fp: String, s: Session, messageId: String, text: String): Boolean {
        val peerId = peerIdByFp[fp] ?: return false
        return synchronized(s) {
            val deliveryId = nextDeliveryId.getAndIncrement()
            try {
                val plain = meshEncodePrivateMessage(messageId, text)
                val ct = s.noise.encrypt(plain)
                pendingSends[deliveryId] = PendingSend(
                    fp,
                    messageId,
                    text,
                    System.currentTimeMillis() / 1000,
                    s,
                )
                if (!BleBridge.notify(
                        MeshIdentity.buildPacket(TYPE_NOISE_ENCRYPTED.toUByte(), peerId, ct),
                        s.subscriptionToken,
                        deliveryId,
                    )
                ) {
                    pendingSends.remove(deliveryId)
                    sessions.remove(fp, s)
                    return@synchronized false
                }
                sonarLog("MeshLink", "TX DM to ${nameByFp[fp] ?: fp.take(8)} (${text.length} chars)")
                true
            } catch (_: Throwable) {
                pendingSends.remove(deliveryId)
                sessions.remove(fp, s)
                false
            }
        }
    }

    private fun processTxResults() {
        for (result in BleBridge.drainTxResults()) {
            val pending = pendingSends.remove(result.deliveryId) ?: continue
            if (!result.accepted) {
                sessions.remove(pending.peerId, pending.session)
                sendFailures.add(
                    MeshSendFailure(
                        pending.peerId,
                        pending.messageId,
                        pending.text,
                        pending.tsSecs,
                    ),
                )
            }
        }
    }

    fun drainDms(): List<MeshDmIn> {
        val out = ArrayList<MeshDmIn>()
        while (true) out.add(rxDms.poll() ?: break)
        return out
    }

    fun drainSendFailures(): List<MeshSendFailure> {
        // Also process native results here so failures remain visible while the
        // protocol pump is stopped during a radio policy transition.
        processTxResults()
        val out = ArrayList<MeshSendFailure>()
        while (true) out.add(sendFailures.poll() ?: break)
        return out
    }

    /** Fingerprints whose Noise link established since the last call. */
    fun drainLinkUps(): List<String> {
        val out = ArrayList<String>()
        while (true) out.add(linkUps.poll() ?: break)
        return out
    }

    /** Named, deduped mesh peers (from the announce), fresh within the TTL. */
    fun namedPeers(): List<MeshPeer> {
        val now = System.currentTimeMillis()
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
        sessions.clear(); fpByPeerId.clear(); peerIdByFp.clear()
        nameByFp.clear(); seenByFp.clear(); sonarByPeerId.clear(); sonarSeenAt.clear(); rxDms.clear(); pending.clear()
        notifyPeerUpdate()
    }
}
