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

/** Android adapter power transitions are reduced to this platform-neutral
 * decision so the route-demotion invariant can run in common CI. */
internal enum class BleAdapterLifecycleState {
    TurningOff,
    Off,
    TurningOn,
    On,
}

internal enum class BleRadioLifecycleAction {
    Ignore,
    Suspend,
    Resume,
}

internal fun bleRadioLifecycleAction(
    state: BleAdapterLifecycleState,
    radioRequested: Boolean,
): BleRadioLifecycleAction = when (state) {
    BleAdapterLifecycleState.TurningOff,
    BleAdapterLifecycleState.Off,
    -> BleRadioLifecycleAction.Suspend
    BleAdapterLifecycleState.On ->
        if (radioRequested) BleRadioLifecycleAction.Resume else BleRadioLifecycleAction.Ignore
    BleAdapterLifecycleState.TurningOn -> BleRadioLifecycleAction.Ignore
}

/** A platform link cannot remain a route after its radio is unusable, even if
 * the OS has not delivered the asynchronous GATT disconnect callback yet. */
internal fun meshRouteAvailable(radioUsable: Boolean, gattLinked: Boolean): Boolean =
    radioUsable && gattLinked

/** Serializes live-route publication with radio teardown.
 *
 * A BLE callback may already be in flight when the adapter-off broadcast is
 * delivered. Checking a volatile flag and then publishing is not sufficient:
 * teardown can clear the maps between those two operations and the callback can
 * repopulate stale reachability afterward. Callers publish through
 * [publishIfUsable] and retire/clear through [retire] so one operation always
 * completes before the other. */
internal class BleRadioRouteGate {
    private val lifecycleLock = Any()

    @Volatile
    var isUsable: Boolean = false
        private set

    fun <T> withLifecycleLock(block: () -> T): T = synchronized(lifecycleLock, block)

    fun activate() {
        synchronized(lifecycleLock) { isUsable = true }
    }

    fun <T> retire(clearLiveState: () -> T): T = synchronized(lifecycleLock) {
        isUsable = false
        clearLiveState()
    }

    fun <T> publishIfUsable(publish: () -> T): T? = synchronized(lifecycleLock) {
        if (isUsable) publish() else null
    }
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

/**
 * Mesh links whose receive side has gone silent for [staleMs].
 *
 * The Pixel 10 BLE stack can silently stop delivering a link's data without
 * ever firing a disconnect callback. The stale address then stays in the
 * client/server link maps, `isLinkedAddr` keeps gating off every re-dial, and a
 * static-address peer (e.g. a Mac) becomes permanently undetectable while the
 * scanner still reports it. Culling such zombies lets the next scan result
 * re-dial and recover the link. Addresses with no recorded receive time are
 * left alone — the caller seeds them first so a fresh link gets a full window.
 *
 * Called once per GATT role with that role's own linked set and rx times: one
 * address can hold a client and a server link at once, and a shared per-address
 * entry would let a healthy role mask a dead one. Timestamps must come from a
 * MONOTONIC clock — a wall-clock jump would otherwise cull every live link.
 */
internal fun meshStaleLinkAddrs(
    nowMs: Long,
    linkedAddrs: Set<String>,
    lastRxMsByAddr: Map<String, Long>,
    staleMs: Long,
): List<String> = linkedAddrs.filter { addr ->
    val lastRx = lastRxMsByAddr[addr] ?: return@filter false
    nowMs - lastRx >= staleMs
}

/**
 * True when the liveness sweep did not run for [gapMs], i.e. our own process was
 * frozen (Android caches a backgrounded app and stops its handler callbacks) or
 * the device dozed.
 *
 * The monotonic clock keeps advancing through that downtime, so every link would
 * look silent and be culled for OUR outage rather than the peer's. On such a tick
 * the caller re-seeds and skips the cull. [lastSweepMs] of 0 means "first tick" —
 * never a gap.
 */
internal fun meshSweepResumedFromGap(
    nowMs: Long,
    lastSweepMs: Long,
    gapMs: Long,
): Boolean = lastSweepMs != 0L && nowMs - lastSweepMs >= gapMs

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

/** Normalize a requested discovery allow-list and return it only when applying
 * it would change the radio policy. This keeps repeated state reconciliation
 * idempotent and, critically, prevents policy application from feeding back
 * into peer-update invalidation forever. */
internal fun changedKnownMeshPeerIds(
    current: Set<String>,
    requested: Set<String>,
): Set<String>? {
    val normalized = requested.mapTo(linkedSetOf()) { it.lowercase() }
    return normalized.takeUnless { it == current }
}

/** A fresh announce is retained without crossing the Kotlin/UniFFI boundary.
 * Link liveness is needed only after the announce grace window expires. */
internal inline fun shouldExpireAnnouncedMeshPeer(
    nowMs: Long,
    lastSeenMs: Long,
    staleMs: Long,
    hasLiveLink: () -> Boolean,
): Boolean = nowMs - lastSeenMs > staleMs && !hasLiveLink()

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
    /** Currently-visible mesh peers (pruned of stale entries). */
    fun peers(): List<MeshPeer>

    /** Install the UI invalidation hook for verified peer/profile changes. The
     *  radio invokes it after updating its snapshot; callers re-read [peers]
     *  and [sonarPeers]. Passing null removes the hook. */
    fun setPeerUpdateListener(listener: (() -> Unit)?)

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
