//
// RelayConnectionPolicy.swift
// bitchat
//
// Host-side latch policy for Marmot relay attach (Compose mirror:
// RelayConnectionPolicy.kt). Background suspension can tear down websockets
// without clearing the latch; push wakes must invalidate first.
//

import Foundation

enum RelayConnectionPolicy {
    /// True when `connect` / `connectRelays` would no-op and keep the existing node.
    static func wouldSkipConnect(latched: Bool) -> Bool { latched }

    /// Latch value after an explicit invalidate (background or push wake).
    static func afterInvalidate() -> Bool { false }

    /// iOS scene background suspends sockets — always invalidate. (Compose
    /// Desktop returns false so alt-tab does not rebuild a healthy node.)
    static func shouldInvalidateOnBackground() -> Bool { true }

    /// Latch value for an attach that started at `startEpoch` and completed while
    /// the current epoch is `currentEpoch`.
    ///
    /// An invalidate that lands mid-attach bumps the epoch, so the completing
    /// connect must not restore the latch — its sockets were built before the
    /// suspension signal and may be dead too. The node is still installed (local
    /// reads keep working); only the latch stays down so the next connect rebuilds.
    static func latchAfterAttach(startEpoch: UInt64, currentEpoch: UInt64) -> Bool {
        startEpoch == currentEpoch
    }

    /// Whether a *self-healing* relay reconnect may open the store right now.
    ///
    /// These fire on a timer with nobody waiting on them — the polling loop's
    /// idle-timeout retry, a failed connect's backoff retry, the post-local-open
    /// attach. While the app is backgrounded that makes them the paths that can
    /// REOPEN the SQLCipher store after `closeNode()` released it for
    /// suspension, and RunningBoard then kills the process with 0xdead10cc
    /// (R-020). Note the reopen is self-sustaining: `connect()` ends with
    /// `startPolling()`, whose next idle timeout arms the retry again.
    ///
    /// Deliberate reopens are NOT gated here and must keep calling
    /// `connectRelaysIfNeeded()` directly: the push wake
    /// (`ensureRelayConnected`) legitimately needs relays while backgrounded and
    /// owns its own bounded close afterwards, and the foreground resume is not
    /// backgrounded by definition.
    ///
    /// Takes `foreground` rather than `backgrounded` to match the Compose
    /// sibling `RelayConnectionPolicy.shouldRetrySupersededAttach(foreground:)`,
    /// which reached the same rule independently — "once genuinely backgrounded,
    /// do not retry — looping would rebuild sockets the OS is suspending". The
    /// two are not interchangeable (Kotlin's is scoped to a superseded in-flight
    /// attach, this to any timer-driven reconnect), so they stay separate; they
    /// read in the same direction so the mirror stays diffable.
    static func shouldAutoReconnect(foreground: Bool) -> Bool { foreground }

    /// Whether a push wake should drop the relay latch.
    ///
    /// Only a real background scene can have had its sockets suspended. `.inactive`
    /// (Control Center, a system prompt, an incoming-call banner) is still
    /// foreground: the node there is healthy, and rebuilding it would close one
    /// that polling / sends / media work still hold. Mirrors the Compose
    /// `appVisible` gate, which spans `onStart`..`onStop` rather than focus.
    static func shouldInvalidateOnPushWake(appVisible: Bool) -> Bool { !appVisible }
}
