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
data class MeshDmIn(val peerId: String, val messageId: String, val text: String, val tsSecs: Long)
data class MeshDeliveryAck(val peerId: String, val messageId: String)
data class MeshPendingDeliveryRecord(
    val peerId: String,
    val messageId: String,
    val text: String,
    val timestampSecs: Long,
    /** False for idempotent protocol controls that must be retried durably but
     * never rendered as user-authored transcript bubbles. */
    val surfaceInTranscript: Boolean = true,
    /** Per-peer durable admission order. Zero means "assign atomically". */
    val sequence: Long = 0L,
)

/** An incoming PUBLIC broadcast (the BLE "Mesh" channel) from another peer. The
 *  wire carries only content + sender peerID + timestamp; the display nickname is
 *  resolved from the sender's announce by the app. */
data class MeshBroadcastIn(
    val senderId: String,
    val content: String,
    val tsSecs: Long,
)

/** An incoming BLE mesh file transfer from a private peer. [peerId] is the
 * stable fingerprint, matching [MeshDmIn]. */
data class MeshMediaIn(
    val peerId: String,
    val messageId: String,
    val filename: String,
    val mimeType: String,
    val bytes: ByteArray,
    val tsSecs: Long,
) {
    override fun equals(other: Any?): Boolean =
        other is MeshMediaIn &&
            peerId == other.peerId &&
            messageId == other.messageId &&
            filename == other.filename &&
            mimeType == other.mimeType &&
            bytes.contentEquals(other.bytes) &&
            tsSecs == other.tsSecs

    override fun hashCode(): Int {
        var result = peerId.hashCode()
        result = 31 * result + messageId.hashCode()
        result = 31 * result + filename.hashCode()
        result = 31 * result + mimeType.hashCode()
        result = 31 * result + bytes.contentHashCode()
        result = 31 * result + tsSecs.hashCode()
        return result
    }
}

enum class BleDiscoveryMode {
    Normal,
    KnownOnly,
}

/**
 * Android keeps the mesh radio process-local and foreground-only. A background
 * radio would need a user-visible `connectedDevice` foreground service; without
 * one, BLE Binder callbacks can keep targeting a cached/frozen process.
 */
internal fun shouldRunAndroidMeshRadio(
    activityStarted: Boolean,
    postFirstDrawStartupReady: Boolean,
    onboarded: Boolean,
    radioAvailable: Boolean,
): Boolean = activityStarted && postFirstDrawStartupReady && onboarded && radioAvailable

/** Avoid touching permission-protected Bluetooth APIs until every lifecycle and
 * account gate that can be evaluated without them is open. */
internal fun shouldQueryAndroidMeshAvailability(
    activityStarted: Boolean,
    postFirstDrawStartupReady: Boolean,
    onboarded: Boolean,
): Boolean = activityStarted && postFirstDrawStartupReady && onboarded

/** A queued watchdog tick must neither touch BLE nor schedule another tick once
 * Activity.onStop has closed the process-wide lifecycle gate. */
internal fun shouldRunAndroidMeshWatchdog(
    scanning: Boolean,
    lifecycleAllowed: Boolean,
): Boolean = scanning && lifecycleAllowed

/** Closing the lifecycle gate is an idempotent teardown request, including when
 * the process-local flag was already false but radio state drifted to running. */
internal fun shouldStopAndroidMeshRadio(allowed: Boolean): Boolean = !allowed

/** Pure callback fence shared by the Android GATT server/client callbacks. */
internal fun acceptsMeshLifecycleCallback(
    active: Boolean,
    currentGeneration: Long,
    callbackGeneration: Long,
    expectedConnection: Boolean = true,
): Boolean = active && currentGeneration == callbackGeneration && expectedConnection

internal data class PendingMeshDelivery(
    val messageId: String,
    val text: String,
)

internal const val MESH_PENDING_PER_PEER_LIMIT = 100

/** Retransmissions carry the same stable id. They still need another ACK, but
 * only the first copy may be appended/notified. */
internal fun isNewMeshMessage(messageId: String, storedMessageIds: Iterable<String>): Boolean =
    storedMessageIds.none { it == messageId }

/** Wire-compatible with Apple's `NoisePayloadType.delivered`: one 0x03 byte
 * followed by the UTF-8 stable message id. */
internal fun meshDeliveryAckPayload(messageId: String): ByteArray =
    byteArrayOf(0x03) + messageId.encodeToByteArray()

internal fun meshDeliveryAckMessageId(payload: ByteArray): String? {
    if (payload.size < 2 || payload[0] != 0x03.toByte()) return null
    return payload.copyOfRange(1, payload.size).decodeToString().takeIf { it.isNotBlank() }
}

/**
 * Logical mesh sends survive a foreground lifecycle stop, while byte-level GATT
 * work does not. The head remains pending until the peer returns its encrypted
 * stable-id delivery ACK; an account reset is the only operation that discards it.
 *
 * Android serializes access with the MeshGatt monitor, so this deliberately
 * stays platform-neutral and allocation-light rather than adding another lock.
 */
internal class PendingMeshDeliveryTracker {
    private data class InFlight(val messageId: String, val routeId: String?)
    private val queues = mutableMapOf<String, MutableList<PendingMeshDelivery>>()
    private val inFlight = mutableMapOf<String, InFlight>()
    /** Stable ids whose ACK is admitted to the host queue but whose durable
     * transcript/outbox retirement has not completed yet. */
    private val acknowledged = mutableSetOf<Pair<String, String>>()
    /** Two-phase TTL claims fence a late ACK while durable projection/deletion
     * is in progress. Keep the logical queue so a failed disk transition can
     * release the claim and resume delivery without reconstructing state. */
    private val expiryClaims = mutableSetOf<Pair<String, String>>()

    /** False only when a new logical message exceeds the bounded per-peer
     * in-memory window. Its durable file remains authoritative and can be
     * admitted after an earlier ACK frees a slot. */
    fun enqueue(peerId: String, messageId: String, text: String): Boolean {
        val key = peerId to messageId
        // A generic durable-window restore must not resurrect a stable id whose
        // ACK or terminal TTL transition already owns completion in this process.
        if (key in acknowledged || key in expiryClaims) return true
        val queue = queues.getOrPut(peerId) { mutableListOf() }
        if (queue.any { it.messageId == messageId }) return true
        if (queue.size >= MESH_PENDING_PER_PEER_LIMIT) return false
        queue.add(PendingMeshDelivery(messageId, text))
        return true
    }

    fun beginNext(peerId: String, routeId: String? = null): PendingMeshDelivery? {
        if (inFlight.containsKey(peerId)) return null
        val next = queues[peerId]?.firstOrNull() ?: return null
        if ((peerId to next.messageId) in expiryClaims) return null
        inFlight[peerId] = InFlight(next.messageId, routeId)
        return next
    }

    /** Finish only the local transport operation. A successful controller
     * callback leaves the logical message in flight until the peer returns its
     * encrypted, message-id-scoped delivery acknowledgement. */
    fun finishTransport(
        peerId: String,
        messageId: String,
        accepted: Boolean,
        routeId: String? = null,
    ) {
        val current = inFlight[peerId] ?: return
        if (current.messageId != messageId || (routeId != null && current.routeId != routeId)) return
        if (!accepted) inFlight.remove(peerId)
    }

    /** Remove the head only when the same peer acknowledges the same stable id. */
    fun acknowledge(peerId: String, messageId: String): Boolean {
        return acknowledgeIf(peerId, messageId) { true }
    }

    /** Commit completion only if the host completion queue admits it. This keeps
     * the logical head/in-flight state retryable when a bounded UI queue is full. */
    fun acknowledgeIf(peerId: String, messageId: String, admitCompletion: () -> Boolean): Boolean {
        val key = peerId to messageId
        if (key in expiryClaims || key in acknowledged) return false
        val queue = queues[peerId] ?: return false
        if (queue.firstOrNull()?.messageId != messageId) return false
        if (!admitCompletion()) return false
        queue.removeAt(0)
        if (inFlight[peerId]?.messageId == messageId) inFlight.remove(peerId)
        if (queue.isEmpty()) queues.remove(peerId)
        acknowledged += key
        return true
    }

    /** Atomically arbitrate terminal TTL retirement against ACK admission. */
    fun claimExpiry(peerId: String, messageId: String): Boolean {
        val key = peerId to messageId
        if (key in acknowledged || key in expiryClaims) return false
        expiryClaims += key
        if (inFlight[peerId]?.messageId == messageId) inFlight.remove(peerId)
        return true
    }

    /** Roll back a failed durable TTL transition and make its head sendable. */
    fun releaseExpiry(peerId: String, messageId: String) {
        expiryClaims.remove(peerId to messageId)
    }

    /** Release the ACK fence after durable host processing is complete. */
    fun finishAcknowledgement(peerId: String, messageId: String) {
        acknowledged.remove(peerId to messageId)
    }

    /** Retire one exact durable obligation after its terminal projection and
     * on-disk deletion commit. Unlike [clear], this is safe for expiry while
     * newer messages for the same peer remain queued. */
    fun discard(peerId: String, messageId: String): Boolean {
        val queue = queues[peerId]
        val removed = queue?.removeAll { it.messageId == messageId } == true
        if (inFlight[peerId]?.messageId == messageId) inFlight.remove(peerId)
        if (queue?.isEmpty() == true) queues.remove(peerId)
        val claimed = expiryClaims.remove(peerId to messageId)
        val wasAcknowledged = acknowledged.remove(peerId to messageId)
        return removed || claimed || wasAcknowledged
    }

    /** Make an unacknowledged transport eligible for retransmission. */
    fun retryIfAwaiting(peerId: String, messageId: String, routeId: String? = null): Boolean {
        val current = inFlight[peerId] ?: return false
        if (current.messageId != messageId || (routeId != null && current.routeId != routeId)) return false
        inFlight.remove(peerId)
        return true
    }

    fun cancelInFlightForRoute(peerId: String, routeId: String): Boolean {
        if (inFlight[peerId]?.routeId != routeId) return false
        inFlight.remove(peerId)
        return true
    }

    /** A lifecycle stop cancels raw I/O but retains every logical delivery. */
    fun cancelInFlight() {
        inFlight.clear()
    }

    fun cancelInFlight(peerId: String) {
        inFlight.remove(peerId)
    }

    /** Account teardown must not carry messages into the next identity. */
    fun clear() {
        queues.clear()
        inFlight.clear()
        acknowledged.clear()
        expiryClaims.clear()
    }

    fun clear(peerId: String) {
        queues.remove(peerId)
        inFlight.remove(peerId)
        acknowledged.removeAll { it.first == peerId }
        expiryClaims.removeAll { it.first == peerId }
    }

    fun pendingCount(peerId: String): Int = queues[peerId]?.size ?: 0

    fun awaitingAck(peerId: String, messageId: String): Boolean =
        inFlight[peerId]?.messageId == messageId

    internal fun acknowledgementPending(peerId: String, messageId: String): Boolean =
        (peerId to messageId) in acknowledged
}

internal enum class BleScanRestartReason(val logValue: String) {
    NoCallbacks("no_callbacks"),
    RepeatingKnownWithoutUsableLink("no_new_address_no_link"),
}

/**
 * Classifies a verified announce by its relationship to the physical BLE link.
 *
 * A mesh relay legitimately forwards announces from peers other than itself, so
 * only a full-TTL announce may bind the relay's BLE address. Announcements that
 * originated here can loop back over a second central/peripheral connection and
 * must not be published as a nearby peer.
 */
internal enum class MeshAnnounceRoute {
    SelfEcho,
    Direct,
    Relayed,
}

internal fun meshAnnounceRoute(
    localPeerIdHex: String,
    senderPeerIdHex: String,
    ttl: UByte,
    directTtl: UByte = 7u,
): MeshAnnounceRoute = when {
    senderPeerIdHex.equals(localPeerIdHex, ignoreCase = true) -> MeshAnnounceRoute.SelfEcho
    ttl == directTtl -> MeshAnnounceRoute.Direct
    else -> MeshAnnounceRoute.Relayed
}

/** Once a sender ID has established an Ed25519 signing key, later announces
 * must not replace it. Reinstall/reset rotates the Noise key and therefore the
 * sender ID as well, so an in-place signing-key change is an impersonation. */
internal fun meshSigningKeyMatches(existingKeyHex: String?, announcedKeyHex: String): Boolean =
    existingKeyHex == null || existingKeyHex.equals(announcedKeyHex, ignoreCase = true)

/** A Noise XX handshake authenticates its remote static key, but that key only
 * belongs to the advertised Sonar identity after it matches the key carried by
 * the verified direct 0x01 announce. Missing/malformed keys fail closed. */
internal fun meshNoiseStaticMatches(
    announcedKeyHex: String?,
    authenticatedKeyHex: String?,
): Boolean {
    val announced = announcedKeyHex?.trim()?.takeIf { it.length == 64 && it.all(Char::isHexDigit) }
        ?: return false
    val authenticated = authenticatedKeyHex?.trim()?.takeIf { it.length == 64 && it.all(Char::isHexDigit) }
        ?: return false
    return announced.equals(authenticated, ignoreCase = true)
}

private fun Char.isHexDigit(): Boolean =
    this in '0'..'9' || this in 'a'..'f' || this in 'A'..'F'

/**
 * Decide whether Android's BLE scan needs recovery without confusing repeated
 * advertisements from a connected peer with scanner starvation.
 */
internal fun bleScanRestartReason(
    nowMs: Long,
    lastCallbackMs: Long,
    lastNewDiscoveryMs: Long,
    lastScanStartMs: Long,
    hasUsableLink: Boolean,
    staleMs: Long,
    gapMs: Long,
): BleScanRestartReason? {
    if (nowMs - lastScanStartMs < gapMs) return null
    if (nowMs - lastCallbackMs >= staleMs) return BleScanRestartReason.NoCallbacks
    if (nowMs - lastNewDiscoveryMs >= staleMs && !hasUsableLink) {
        return BleScanRestartReason.RepeatingKnownWithoutUsableLink
    }
    return null
}

/** Exponential recovery avoids an 8-second restart loop in legitimately empty
 * rooms while still repairing the first Pixel scanner starvation quickly. */
internal fun bleWatchdogGapMs(baseMs: Long, consecutiveRestarts: Int, maxMs: Long): Long {
    var gap = baseMs
    repeat(consecutiveRestarts.coerceIn(0, 16)) {
        gap = (gap * 2).coerceAtMost(maxMs)
    }
    return gap
}

/** Repeated callbacks for an already-known address are not scanner recovery:
 * the Pixel can keep reporting that one address while remaining blind to every
 * other advertiser. Preserve exponential backoff until discovery progresses or
 * an encrypted route is actually usable. */
internal fun bleWatchdogBackoffAfterScanResult(
    consecutiveRestarts: Int,
    newAddress: Boolean,
    hasUsableLink: Boolean,
): Int = if (newAddress || hasUsableLink) 0 else consecutiveRestarts

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
    /** Restrict open discovery while keeping known chat peers reachable. */
    fun setDiscoveryMode(mode: BleDiscoveryMode)
    /** Stable mesh peer ids/fingerprints that already have a local chat. */
    fun setKnownPeerIds(ids: Set<String>)
    /** Begin scanning + advertising (no-op if unavailable). */
    fun start()
    /** Stop the radio. */
    fun stop()
    /** Stop synchronously and discard all account-bound transport buffers. */
    fun resetAccountState()
    /** Currently-visible mesh peers (pruned of stale entries). */
    fun peers(): List<MeshPeer>

    /** Cheap "is any announce peer around" probe for hot-path polling — does
     *  NOT build/filter/sort the peer list (see the adaptive mesh-drain loop). */
    fun hasActivePeer(): Boolean

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
    /** Send an encrypted DM only if a Noise link is established right now.
     *  Unlike [sendMeshDm], this must not queue. Call signaling uses this so a
     *  stale OFFER/ANSWER/END is never delivered after the peer leaves BLE. */
    fun sendMeshDmNow(peerId: String, messageId: String, text: String): Boolean
    /** True iff an encrypted Noise link to the peer with stable [peerId]
     *  (fingerprint) is established right now. */
    fun hasMeshLink(peerId: String): Boolean
    /** This device's current 8-byte bitchat mesh peer id, lowercase hex. */
    fun localPeerIdHex(): String
    /** Pull (and clear) all mesh DMs received since the last call. */
    fun drainMeshDm(): List<MeshDmIn>
    /** Rehydrate durable logical sends before radio startup/process recovery. */
    fun restorePendingDeliveries(records: List<MeshPendingDeliveryRecord>)
    /** Explicit chat deletion cancels this account's queued logical sends. */
    fun discardPendingDeliveries(peerIds: Set<String>)
    /** Retire one terminal stable id without dropping later sends to the peer. */
    fun discardPendingDelivery(peerId: String, messageId: String)
    /** Atomically arbitrate TTL retirement against an ACK awaiting host drain. */
    fun claimPendingDeliveryExpiry(peerId: String, messageId: String): Boolean
    /** Re-enable a logical send when its durable TTL retirement did not commit. */
    fun releasePendingDeliveryExpiry(peerId: String, messageId: String)
    /** Release the ACK fence after durable host processing is complete. */
    fun finishMeshDeliveryAck(peerId: String, messageId: String)
    /** Stable ids peer-ACKed since the last drain; the host removes their
     * per-message durable outbox files only after receiving these records. */
    fun drainMeshDeliveryAcks(): List<MeshDeliveryAck>
    /** Send the encrypted stable-id delivery acknowledgement only after the
     * inbound DM has been accepted and written through to local storage. */
    fun acknowledgeMeshDm(peerId: String, messageId: String): Boolean
    /** Send a private BLE file transfer to a live mesh peer. This does not queue:
     * callers should fall back to White Noise or show a route error when false. */
    fun sendMeshMedia(peerId: String, messageId: String, bytes: ByteArray, filename: String, mimeType: String): Boolean
    /** Pull (and clear) mesh media transfers received since the last call. */
    fun drainMeshMedia(): List<MeshMediaIn>
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
