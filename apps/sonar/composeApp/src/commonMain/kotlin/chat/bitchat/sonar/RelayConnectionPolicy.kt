package chat.bitchat.sonar

/**
 * Host-side latch policy for Marmot relay attach.
 *
 * [SonarCore.connectRelays] skips work while the latch is true. Background
 * suspension can tear down websockets without clearing that latch, so push
 * wakes must [invalidate] first — otherwise sync runs against a dead node
 * while a killed-app cold start (latch false) still delivers.
 */
object RelayConnectionPolicy {
    /** True when [connectRelays] would no-op and keep the existing node. */
    fun wouldSkipConnect(latched: Boolean): Boolean = latched

    /** Latch value after an explicit invalidate (background or push wake). */
    fun afterInvalidate(): Boolean = false

    /**
     * Latch value for an attach that started at [startEpoch] and finished while
     * the current epoch is [currentEpoch].
     *
     * An invalidate that lands mid-attach bumps the epoch, so the completing
     * connect must not restore the latch — its sockets were built before the
     * suspension signal and may be dead too. The node still gets installed
     * (local reads work); only the latch stays down so the next
     * `connectRelays()` rebuilds.
     */
    fun latchAfterAttach(startEpoch: Long, currentEpoch: Long): Boolean =
        startEpoch == currentEpoch

    /**
     * Whether leaving the foreground should drop the relay latch.
     *
     * Mobile backgrounds suspend/doze sockets; desktop window focus loss does
     * not — alt-tab must not rebuild a healthy node.
     */
    fun shouldInvalidateOnBackground(): Boolean = platformShouldInvalidateRelayOnBackground()

    /**
     * Whether a push wake should drop the relay latch.
     *
     * Only a background/doze wake can have had its sockets suspended. A push
     * that lands while the UI is visible reaches a healthy node, and rebuilding
     * it would close a node that in-flight sends/media hold via `requireNode()`.
     */
    fun shouldInvalidateOnPushWake(appVisible: Boolean): Boolean = !appVisible

    /**
     * Whether an attach that an invalidate superseded mid-flight should retry now.
     *
     * A successful `SonarCore.connectRelays()` whose latch [latchAfterAttach] left
     * down means an invalidate landed while it was attaching, so the caller is not
     * attached even though nothing failed. In the foreground that invalidate was a
     * background blip the user has already returned from, and the relay job would
     * otherwise end with the latch down: `startRelayConnection()` no-ops while the
     * job is alive, so a resume racing the attach waits out its bounded poll and
     * then sits on dead sockets until the heartbeat (up to 30 s). Once genuinely
     * backgrounded, do not retry — looping would rebuild sockets the OS is
     * suspending, and both the push wake and the next foreground resume start a
     * fresh job.
     */
    fun shouldRetrySupersededAttach(foreground: Boolean): Boolean = foreground

    /**
     * What the slow housekeeping heartbeat should do about the relay this beat.
     *
     * The whole three-way choice lives here rather than as a boolean the caller
     * branches on, so [HeartbeatRelayAction.Idle] — the case that regressed — is
     * an assertable value instead of an untested `else`.
     *
     * The heartbeat re-*enters* `startRelayConnection()` from scratch every beat,
     * so [shouldRetrySupersededAttach] — which only stops the retry loop *inside*
     * an already-running job — cannot hold it back. Left ungated it fights
     * [shouldInvalidateOnBackground]: backgrounding drops the latch so the next
     * wake rebuilds, the heartbeat reads that down latch as "reconnect now", and
     * `connectRelays()` tears down and rebuilds the node (`SonarNode.connect` +
     * `previousNode?.close()` + a KeyPackage republish) every beat for as long as
     * the app stays backgrounded — closing the node the live wake loop,
     * conversation listener, and in-flight sends are holding. On Android that is
     * exactly the state the user is in when they expect a notification.
     *
     * A backgrounded process does not need that rebuild, and the reason is a
     * layer below this one: `nostr-relay-pool` defaults to `reconnect: true` and
     * the core builds its client with those defaults (`client.rs`
     * `Client::new(identity.keys().clone())`), so **socket-level recovery is
     * owned by the Rust relay pool**. Rebuilding an entire `SonarNode` — new
     * SQLCipher handle, new relay pool, KeyPackage republish — to recover a
     * websocket the pool already reconnects on its own is the sledgehammer this
     * removes. The host latch is bookkeeping, not the transport. What genuinely
     * needs a rebuilt node (a superseded attach, a suspended process) is driven
     * by the push wake and the foreground resume, which #354 made responsible.
     *
     * Desktop must still reconnect while unfocused: `Main.kt` bridges every
     * `windowLostFocus` to `setForeground(false)`, and there is no push wake to
     * take over. It never invalidates on background, so its latch only goes down
     * on a genuine failure — precisely the case the heartbeat has to recover.
     * Hence [invalidatesOnBackground] is a parameter, not a direct
     * [shouldInvalidateOnBackground] read: it keeps this a pure function whose
     * whole matrix is assertable from `commonTest`, which compiles into every KMP
     * test target and so cannot depend on one platform's actual.
     */
    fun heartbeatRelayAction(
        relayConnected: Boolean,
        foreground: Boolean,
        invalidatesOnBackground: Boolean,
    ): HeartbeatRelayAction = when {
        relayConnected -> HeartbeatRelayAction.SyncAndEnsureSubscriptions
        foreground || !invalidatesOnBackground -> HeartbeatRelayAction.Reconnect
        else -> HeartbeatRelayAction.Idle
    }
}

/** Outcome of [RelayConnectionPolicy.heartbeatRelayAction]. */
enum class HeartbeatRelayAction {
    /** Latch is up: run the periodic relay upkeep. */
    SyncAndEnsureSubscriptions,

    /** Latch is down and this process should rebuild now. */
    Reconnect,

    /** Latch is down because we backgrounded on purpose — leave the node alone. */
    Idle,
}

/** Android/iOS-style process background: true. Desktop focus loss: false. */
internal expect fun platformShouldInvalidateRelayOnBackground(): Boolean
