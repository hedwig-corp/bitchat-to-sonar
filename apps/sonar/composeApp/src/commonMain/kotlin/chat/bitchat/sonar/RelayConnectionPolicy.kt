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
     * Whether the slow housekeeping heartbeat may start a relay attach.
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
     * A backgrounded process does not need this: its existing sockets keep
     * feeding `waitForMarmotEvent` (the invalidate drops only the host latch, not
     * the node), and a genuinely dead connection is rebuilt by the push wake or
     * the next foreground resume — both of which #354 made responsible for it.
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
    fun shouldReconnectOnHeartbeat(foreground: Boolean, invalidatesOnBackground: Boolean): Boolean =
        foreground || !invalidatesOnBackground
}

/** Android/iOS-style process background: true. Desktop focus loss: false. */
internal expect fun platformShouldInvalidateRelayOnBackground(): Boolean
