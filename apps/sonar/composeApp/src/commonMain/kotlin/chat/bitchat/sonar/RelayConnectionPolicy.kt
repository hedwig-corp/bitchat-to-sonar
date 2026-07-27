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
     *
     * iOS reached the same rule separately, for a harsher reason: there a
     * timer-driven reconnect reopens the SQLCipher store after the suspend hook
     * closed it, and RunningBoard kills the process (0xdead10cc, `R-020`). Its
     * gate is `RelayConnectionPolicy.shouldAutoReconnect(foreground:)`, kept as a
     * separate member because it covers any timer-driven reconnect rather than a
     * superseded in-flight attach. Same polarity on purpose — if you change one,
     * read the other.
     */
    fun shouldRetrySupersededAttach(foreground: Boolean): Boolean = foreground

    /**
     * Backoff before retrying an attach that failed outright — the core threw,
     * usually `NoRelayConnected` ("no relay connected within timeout").
     *
     * The core gives the quorum a fixed 5 s window (`RELAY_CONNECT_TIMEOUT` in
     * `client.rs`), which a radio waking from doze, a Wi-Fi/LTE handover, or a
     * captive-portal hop routinely misses. Because [shouldInvalidateOnBackground]
     * makes every ordinary resume re-run the attach, the common failure here is
     * a network that is a second away from usable — not an outage. Retry fast at
     * first so a resume heals in about a second, then settle into the slow
     * interval once the failures look sustained (the heartbeat re-triggers the
     * job at that cadence anyway).
     */
    fun connectRetryDelayMs(consecutiveFailures: Int): Long = when {
        consecutiveFailures <= 1 -> RELAY_RETRY_FAST_MS
        consecutiveFailures == 2 -> RELAY_RETRY_MEDIUM_MS
        else -> RELAY_RETRY_SLOW_MS
    }
}

private const val RELAY_RETRY_FAST_MS = 1_000L
private const val RELAY_RETRY_MEDIUM_MS = 3_000L
private const val RELAY_RETRY_SLOW_MS = 10_000L

/** Android/iOS-style process background: true. Desktop focus loss: false. */
internal expect fun platformShouldInvalidateRelayOnBackground(): Boolean
