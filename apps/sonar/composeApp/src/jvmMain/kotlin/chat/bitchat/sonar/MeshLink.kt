package chat.bitchat.sonar

import uniffi.sonar_ffi.SonarNoise
import uniffi.sonar_ffi.MeshReassembler
import uniffi.sonar_ffi.meshDecodePacket
import uniffi.sonar_ffi.meshDecodePrivateMessage
import uniffi.sonar_ffi.meshEncodePrivateMessage
import uniffi.sonar_ffi.meshParseAnnounce
import uniffi.sonar_ffi.meshParseVerifiedSonarAnnounce
import uniffi.sonar_ffi.meshFragment
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ArrayBlockingQueue
import java.security.SecureRandom
import java.util.concurrent.atomic.AtomicLong

/** One detached latest packet per sender, with deterministic FIFO eviction. */
internal class PendingSonarPacketQueue(private val limit: Int) {
    private val packets = LinkedHashMap<String, ByteArray>()
    init { require(limit > 0) }

    fun offer(senderKey: String, packet: ByteArray) {
        if (!packets.containsKey(senderKey) && packets.size >= limit) {
            val oldest = packets.keys.iterator()
            if (oldest.hasNext()) {
                oldest.next()
                oldest.remove()
            }
        }
        packets.remove(senderKey)
        packets[senderKey] = packet.copyOf()
    }

    fun remove(senderKey: String): ByteArray? = packets.remove(senderKey)
    fun clear() = packets.clear()
    fun size(): Int = packets.size
}

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
    private const val TYPE_FRAGMENT = 0x20
    private const val TYPE_REQUEST_SYNC = 0x21
    private const val TYPE_SONAR = 0x53
    private const val NOISE_PRIVATE_MESSAGE = 0x01
    private const val NOISE_DELIVERED = 0x03
    private const val PEER_TTL_MS = 90_000L
    private const val DELIVERY_ACK_TIMEOUT_MS = 10_000L
    private const val MAX_SINGLE_GATT_PACKET_BYTES = 480
    private const val FRAGMENT_CHUNK_SIZE: UInt = 350u
    private const val MAX_PENDING_SONAR_PROFILES = 128

    private class Session(val noise: SonarNoise) {
        @Volatile var established = false
    }

    private val sessions = ConcurrentHashMap<String, Session>()        // fp -> Noise session
    private val fpByPeerId = ConcurrentHashMap<String, String>()       // peerId -> fp
    private val peerIdByFp = ConcurrentHashMap<String, String>()       // fp -> current peerId
    private val nameByFp = ConcurrentHashMap<String, String>()
    private val seenByFp = ConcurrentHashMap<String, Long>()           // fp -> last-activity ms
    private val sonarByPeerId = ConcurrentHashMap<String, ByteArray>() // peerId -> 0x53 payload
    private val sonarSeenAt = ConcurrentHashMap<String, Long>()        // peerId -> last 0x53 ms (for TTL)
    private val signingKeyByPeerId = ConcurrentHashMap<String, String>()
    private val announcedNoiseKeyByPeerId = ConcurrentHashMap<String, String>()
    /** Signed 0x53 can precede its verified 0x01. Retain only one detached
     * packet per sender in a bounded FIFO until the signing key arrives. */
    private val pendingSonarByPeerId = PendingSonarPacketQueue(MAX_PENDING_SONAR_PROFILES)
    private val rxDms = ArrayBlockingQueue<MeshDmIn>(512)
    private val deliveryAcks = ArrayBlockingQueue<MeshDeliveryAck>(512)
    private val pendingDeliveries = PendingMeshDeliveryTracker()
    private data class AwaitingAck(val messageId: String, val sentAtMs: Long)
    private val awaitingAck = mutableMapOf<String, AwaitingAck>()
    private var reassembler = MeshReassembler()

    /** Our encoded SonarAnnounce (npub + caps) to broadcast as a signed 0x53, so
     *  phones treat us as a full Sonar peer and continue our chat over White Noise
     *  when out of BLE range. Null = nothing to advertise yet. */
    @Volatile private var sonarPayload: ByteArray? = null
    @Volatile private var lastSonarSendMs = 0L

    @Volatile private var running = false
    private val loopGeneration = AtomicLong()
    private val lifecycleLock = Any()

    /** Set/clear the SonarAnnounce payload broadcast as our 0x53 (from the app). */
    fun setSonarPayload(payload: ByteArray?) { sonarPayload = payload }

    fun start() {
        if (running) return
        val generation = loopGeneration.incrementAndGet()
        running = true
        Thread({ loop(generation) }, "sonar-mesh-link").apply { isDaemon = true }.start()
    }

    fun stop() {
        running = false
        loopGeneration.incrementAndGet()
        synchronized(lifecycleLock) {
            // Native advertising/GATT is torn down by MeshRadio.stop(); Noise
            // nonces cannot be resumed across that raw-link generation.
            sessions.clear()
            // A Noise handshake is admitted only after a verified announce in
            // this raw BLE generation. Never reuse an old lifecycle's binding.
            announcedNoiseKeyByPeerId.clear()
            reassembler = MeshReassembler()
            pendingDeliveries.cancelInFlight()
            awaitingAck.clear()
        }
    }

    private fun loop(generation: Long) {
        while (running && loopGeneration.get() == generation) {
            runCatching {
                synchronized(lifecycleLock) {
                    if (running && loopGeneration.get() == generation) pump()
                }
            }
            try { Thread.sleep(120) } catch (_: InterruptedException) { break }
        }
    }

    private fun pump() {
        for (pkt in BleBridge.drainRx()) handlePacket(pkt)
        val now = System.currentTimeMillis()
        seenByFp.entries.removeIf { now - it.value > PEER_TTL_MS }
        // Expire stale 0x53 payloads too (parity with seenByFp) so a peer that left
        // range stops being reported as a live Sonar user by [sonarPeers].
        sonarSeenAt.entries.removeIf { now - it.value > PEER_TTL_MS }
        sonarByPeerId.keys.retainAll(sonarSeenAt.keys)
        awaitingAck.toMap().forEach { (fp, waiting) ->
            if (now - waiting.sentAtMs >= DELIVERY_ACK_TIMEOUT_MS &&
                pendingDeliveries.retryIfAwaiting(fp, waiting.messageId)
            ) {
                awaitingAck.remove(fp)
                // A lost native notify advanced our Noise send nonce but not the
                // peer's receive nonce. Never retry on that session; retain the
                // logical head for the next fresh phone handshake.
                sessions.remove(fp)
                BleBridge.restartAdvertising()
                sonarLog("MeshLink", "peer delivery ACK timed out ${waiting.messageId.take(12)}…; awaiting fresh handshake")
            }
        }

        // Broadcast our signed 0x53 Sonar announce every ~3s so connected phones
        // learn our npub and can continue the chat over White Noise out of range.
        // Only while a peer is actually around (a connected central writes its
        // announce → seenByFp) — no point signing + notifying into the void.
        val payload = sonarPayload
        if (payload != null && seenByFp.isNotEmpty() && now - lastSonarSendMs >= 3_000L) {
            lastSonarSendMs = now
            runCatching { notifyPacket(MeshIdentity.buildSonarPacket(payload), TYPE_SONAR, "") }
        }
    }

    private fun handlePacket(packet: ByteArray) {
        val info = runCatching { meshDecodePacket(packet) }.getOrNull() ?: return
        val sender = info.senderIdHex
        if (info.packetType.toInt() == TYPE_FRAGMENT) {
            val full = runCatching { reassembler.add(sender, info.payload) }.getOrNull() ?: return
            handlePacket(full)
            return
        }
        when (info.packetType.toInt()) {
            TYPE_ANNOUNCE -> {
                val ann = runCatching { meshParseAnnounce(packet) }.getOrNull() ?: return
                val senderKey = ann.senderIdHex.lowercase()
                if (ann.senderIdHex.equals(MeshIdentity.peerIdHex, ignoreCase = true)) return
                val existingSigningKey = signingKeyByPeerId.putIfAbsent(senderKey, ann.signingPublicKeyHex)
                if (!meshSigningKeyMatches(existingSigningKey, ann.signingPublicKeyHex)) {
                    sonarLog("MeshLink", "announce signing-key change rejected for ${ann.senderIdHex}")
                    return
                }
                val fp = MeshIdentity.fingerprintOf(ann.noisePublicKeyHex)
                if (fp.isNotEmpty()) {
                    announcedNoiseKeyByPeerId[senderKey] = ann.noisePublicKeyHex
                    fpByPeerId[senderKey] = fp; peerIdByFp[fp] = senderKey
                    nameByFp[fp] = ann.nickname; touch(fp)
                    pendingSonarByPeerId.remove(senderKey)?.let { pending ->
                        acceptVerifiedSonar(senderKey, pending, ann.signingPublicKeyHex)
                    }
                }
            }
            TYPE_NOISE_HANDSHAKE -> handleHandshake(sender, info.payload)
            TYPE_NOISE_ENCRYPTED -> handleEncrypted(sender, info.payload)
            // Safe tracked gap: do not fabricate a lossy sync response until the
            // Bounded GCS index + RSR flags are tracked in parity issue #284:
            // https://github.com/hedwig-corp/bitchat-to-sonar/issues/284
            TYPE_REQUEST_SYNC -> sonarLog(
                "MeshLink",
                "requestSync requires a bounded local GCS packet index and RSR flag support; refusing an incomplete response",
            )
            TYPE_SONAR -> {
                if (sender.equals(MeshIdentity.peerIdHex, ignoreCase = true)) return
                val senderKey = sender.lowercase()
                val signingKey = signingKeyByPeerId[senderKey]
                val fp = fpByPeerId[senderKey]
                if (signingKey == null || fp == null) {
                    queuePendingSonar(senderKey, packet)
                } else {
                    acceptVerifiedSonar(senderKey, packet, signingKey)
                }
            }
        }
    }

    private fun touch(fp: String) { seenByFp[fp] = System.currentTimeMillis() }

    private fun queuePendingSonar(senderKey: String, packet: ByteArray) {
        pendingSonarByPeerId.offer(senderKey, packet)
    }

    private fun acceptVerifiedSonar(senderKey: String, packet: ByteArray, signingKey: String) {
        val payload = runCatching {
            meshParseVerifiedSonarAnnounce(packet, signingKey)
        }.getOrNull()
        if (payload == null) {
            sonarLog("MeshLink", "Sonar announce signature rejected for $senderKey")
            return
        }
        sonarSeenAt[senderKey] = System.currentTimeMillis()
        if (sonarByPeerId.put(senderKey, payload) == null) {
            sonarLog(
                "MeshLink",
                "RX verified 0x53 Sonar announce from ${nameByFp[fpByPeerId[senderKey]] ?: senderKey}",
            )
        }
    }

    /** Noise XX responder: read m1 → reply m2 → read m3 → established.
     *
     *  A handshake packet arriving on an ALREADY-established session means the
     *  phone reconnected its GATT link and is starting a FRESH handshake — and we
     *  can't see the disconnect (bluster stubs the CoreBluetooth disconnect
     *  callback), so without this the desktop keeps the stale session, ignores the
     *  new m1, and the phone can never re-establish (its chat shows "out of
     *  range"). So tear down + start fresh whenever a handshake doesn't fit the
     *  current state. */
    private fun handleHandshake(senderPeerId: String, m: ByteArray) {
        val senderKey = senderPeerId.lowercase()
        val fp = fpByPeerId[senderKey] ?: return
        if (announcedNoiseKeyByPeerId[senderKey] == null) return
        pendingDeliveries.cancelInFlight(fp)
        awaitingAck.remove(fp)
        if (sessions[fp]?.established == true) {
            sonarLog("MeshLink", "re-handshake from ${nameByFp[fp] ?: fp.take(8)} → resetting session")
            sessions.remove(fp)
        }
        val s = sessions.getOrPut(fp) { Session(SonarNoise.responder(MeshIdentity.noisePrivHex())) }
        synchronized(s) {
            if (!feedHandshake(fp, senderKey, s, m)) {
                // Wrong message for this state (a fresh m1 mid-handshake) — restart.
                val fresh = Session(SonarNoise.responder(MeshIdentity.noisePrivHex()))
                sessions[fp] = fresh
                synchronized(fresh) { feedHandshake(fp, senderKey, fresh, m) }
            }
        }
        touch(fp)
    }

    /** Returns false if [m] couldn't be processed (caller restarts the handshake). */
    private fun feedHandshake(fp: String, senderPeerId: String, s: Session, m: ByteArray): Boolean =
        runCatching {
            s.noise.readMessage(m) // m1, then m3
            if (s.noise.isFinished()) {
                val announced = announcedNoiseKeyByPeerId[senderPeerId]
                val authenticated = s.noise.remoteStaticHex()
                check(meshNoiseStaticMatches(announced, authenticated)) {
                    "Noise static key does not match verified announce"
                }
                check(MeshIdentity.fingerprintOf(authenticated!!) == fp) {
                    "Noise fingerprint does not match verified announce"
                }
                s.noise.intoSession(); s.established = true
                sonarLog("MeshLink", "Noise link ESTABLISHED with ${nameByFp[fp] ?: fp.take(8)}")
                flushPending(fp)
            } else {
                val m2 = s.noise.writeMessage()
                check(notifyPacket(MeshIdentity.buildPacket(TYPE_NOISE_HANDSHAKE.toUByte(), senderPeerId, m2), TYPE_NOISE_HANDSHAKE, senderPeerId)) {
                    "native BLE bridge rejected handshake reply"
                }
            }
            true
        }.getOrElse { sessions.remove(fp); false }

    private fun handleEncrypted(senderPeerId: String, ciphertext: ByteArray) {
        val fp = fpByPeerId[senderPeerId] ?: senderPeerId
        val s = sessions[fp]?.takeIf { it.established } ?: return
        synchronized(s) {
            runCatching {
                val plain = s.noise.decrypt(ciphertext)
                when (plain.firstOrNull()?.toInt()?.and(0xFF)) {
                    NOISE_PRIVATE_MESSAGE -> meshDecodePrivateMessage(plain)?.let { pm ->
                        sonarLog("MeshLink", "RX DM from ${nameByFp[fp] ?: fp.take(8)} (${pm.content.length} chars)")
                        // Full means no host ACK; the peer retries this stable id.
                        rxDms.offer(MeshDmIn(fp, pm.messageId, pm.content, System.currentTimeMillis() / 1000))
                    }
                    NOISE_DELIVERED -> {
                        val messageId = meshDeliveryAckMessageId(plain)
                        if (messageId != null && pendingDeliveries.acknowledgeIf(fp, messageId) {
                                deliveryAcks.offer(MeshDeliveryAck(fp, messageId))
                            }
                        ) {
                            awaitingAck.remove(fp)
                            sonarLog("MeshLink", "peer delivery ACK ${messageId.take(12)}…")
                            flushPending(fp)
                        } else if (messageId != null && pendingDeliveries.awaitingAck(fp, messageId)) {
                            sonarLog("MeshLink", "retaining delivery ACK ${messageId.take(12)}…: host queue is full")
                        }
                    }
                }
            }
        }
        touch(fp)
    }

    fun hasLink(fp: String): Boolean = sessions[fp]?.established == true

    fun sendDm(fp: String, messageId: String, text: String): Boolean {
        synchronized(lifecycleLock) {
            if (!pendingDeliveries.enqueue(fp, messageId, text)) return false
            flushPending(fp)
            return true
        }
    }

    fun restorePendingDeliveries(records: List<MeshPendingDeliveryRecord>) = synchronized(lifecycleLock) {
        records.sortedWith(compareBy<MeshPendingDeliveryRecord> { it.peerId }.thenBy { it.sequence }).forEach { record ->
            pendingDeliveries.enqueue(record.peerId, record.messageId, record.text)
        }
        records.mapTo(linkedSetOf()) { it.peerId }.forEach(::flushPending)
    }

    fun discardPendingDeliveries(peerIds: Set<String>) = synchronized(lifecycleLock) {
        peerIds.forEach { peerId ->
            pendingDeliveries.clear(peerId)
            awaitingAck.remove(peerId)
        }
    }

    fun discardPendingDelivery(peerId: String, messageId: String) = synchronized(lifecycleLock) {
        if (pendingDeliveries.discard(peerId, messageId)) {
            if (awaitingAck[peerId]?.messageId == messageId) awaitingAck.remove(peerId)
            flushPending(peerId)
        }
    }

    fun claimPendingDeliveryExpiry(peerId: String, messageId: String): Boolean = synchronized(lifecycleLock) {
        pendingDeliveries.claimExpiry(peerId, messageId).also { claimed ->
            if (claimed && awaitingAck[peerId]?.messageId == messageId) awaitingAck.remove(peerId)
        }
    }

    fun releasePendingDeliveryExpiry(peerId: String, messageId: String) = synchronized(lifecycleLock) {
        pendingDeliveries.releaseExpiry(peerId, messageId)
        flushPending(peerId)
    }

    fun finishDeliveryAck(peerId: String, messageId: String) = synchronized(lifecycleLock) {
        pendingDeliveries.finishAcknowledgement(peerId, messageId)
    }

    fun sendDmNow(fp: String, messageId: String, text: String): Boolean = synchronized(lifecycleLock) {
        if (!running) return@synchronized false
        val s = sessions[fp]?.takeIf { it.established } ?: return false
        encryptAndSend(fp, s, messageId, text)
    }

    private fun encryptAndSend(fp: String, s: Session, messageId: String, text: String): Boolean {
        val peerId = peerIdByFp[fp] ?: return false
        val accepted = synchronized(s) {
            runCatching {
                val plain = meshEncodePrivateMessage(messageId, text)
                val ct = s.noise.encrypt(plain)
                if (!notifyPacket(MeshIdentity.buildPacket(TYPE_NOISE_ENCRYPTED.toUByte(), peerId, ct), TYPE_NOISE_ENCRYPTED, peerId)) {
                    return@runCatching false
                }
                sonarLog("MeshLink", "TX DM to ${nameByFp[fp] ?: fp.take(8)} (${text.length} chars)")
                true
            }.getOrDefault(false)
        }
        if (!accepted) {
            sessions.remove(fp, s)
            BleBridge.restartAdvertising()
        }
        return accepted
    }

    private fun flushPending(fp: String) {
        val s = sessions[fp]?.takeIf { it.established } ?: return
        val delivery = pendingDeliveries.beginNext(fp) ?: return
        val accepted = encryptAndSend(fp, s, delivery.messageId, delivery.text)
        pendingDeliveries.finishTransport(fp, delivery.messageId, accepted)
        if (accepted) {
            awaitingAck[fp] = AwaitingAck(delivery.messageId, System.currentTimeMillis())
        }
    }

    /** Apple/Android-compatible [0x03][UTF-8 stable message id] ACK. */
    fun acknowledgeDm(fp: String, messageId: String): Boolean = synchronized(lifecycleLock) {
        if (!running) return@synchronized false
        if (messageId.isBlank()) return@synchronized false
        val s = sessions[fp]?.takeIf { it.established } ?: return@synchronized false
        val peerId = peerIdByFp[fp] ?: return@synchronized false
        val accepted = synchronized(s) {
            runCatching {
                val plain = meshDeliveryAckPayload(messageId)
                val ct = s.noise.encrypt(plain)
                notifyPacket(MeshIdentity.buildPacket(TYPE_NOISE_ENCRYPTED.toUByte(), peerId, ct), TYPE_NOISE_ENCRYPTED, peerId)
            }.getOrDefault(false)
        }
        if (!accepted) {
            sessions.remove(fp, s)
            BleBridge.restartAdvertising()
        }
        accepted
    }

    /** Desktop uses the exact phone fragmentation envelope for logical packets
     * larger than the conservative cross-platform GATT payload. */
    private fun notifyPacket(packet: ByteArray, originalType: Int, recipientPeerId: String): Boolean {
        if (packet.size <= MAX_SINGLE_GATT_PACKET_BYTES) return BleBridge.notify(packet)
        val fragmentId = ByteArray(8).also { SecureRandom().nextBytes(it) }
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }
        val fragments = runCatching {
            meshFragment(packet, fragmentId, originalType.toUByte(), FRAGMENT_CHUNK_SIZE)
        }.getOrNull() ?: return false
        return fragments.all { payload ->
            BleBridge.notify(
                MeshIdentity.buildPacket(TYPE_FRAGMENT.toUByte(), recipientPeerId, payload),
            )
        }
    }

    fun drainDms(): List<MeshDmIn> {
        val out = ArrayList<MeshDmIn>()
        while (true) out.add(rxDms.poll() ?: break)
        return out
    }

    fun drainDeliveryAcks(): List<MeshDeliveryAck> {
        val out = ArrayList<MeshDeliveryAck>()
        while (true) out.add(deliveryAcks.poll() ?: break)
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

    fun wipe() = synchronized(lifecycleLock) {
        sessions.clear(); fpByPeerId.clear(); peerIdByFp.clear()
        nameByFp.clear(); seenByFp.clear(); sonarByPeerId.clear(); sonarSeenAt.clear(); rxDms.clear(); deliveryAcks.clear()
        signingKeyByPeerId.clear(); pendingSonarByPeerId.clear()
        pendingDeliveries.clear(); awaitingAck.clear()
        reassembler = MeshReassembler()
        sonarPayload = null
        lastSonarSendMs = 0L
    }
}
