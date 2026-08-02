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

    /// Whether a relay attach may proceed right now — the store-opening half of
    /// the background rule `shouldAutoReconnect` applies to timers.
    ///
    /// `connectRelaysIfNeeded()` opens/holds the SQLCipher store for the whole
    /// attach and ends by re-arming polling, so an attach that starts while the
    /// app is BACKGROUNDED with nobody owning a close leaves the store open for
    /// RunningBoard to kill at suspension (0xdead10cc, round 8: on 1.12.9 (38)
    /// a background backup's post-seal attach straggler reopened the store
    /// ~200ms after the executor logged "store closed"). The push wake is the
    /// one legitimate background caller — it brackets its whole drain in
    /// `pushWakeOwnership` and closes after itself (`closeStoreWithDeadline`).
    ///
    /// Compose has no RunningBoard file-lock kill, so `RelayConnectionPolicy.kt`
    /// deliberately has no mirror of this rule (documented platform gap).
    static func mayAttachRelays(foreground: Bool, pushWakeOwned: Bool) -> Bool {
        foreground || pushWakeOwned
    }

    /// Whether the LAZY store open (`connectIfNeeded`) may proceed right now —
    /// the local-open sibling of `mayAttachRelays`.
    ///
    /// Every non-explicit open funnels through `connectIfNeeded`:
    /// `ensureConnected`'s kick, chat-open warmups, send fallbacks, view appear
    /// hooks. Backgrounded, any of them can land in the window right after
    /// `suspendStoreForBackground()`'s close completes and `nodeClosing`
    /// clears, reopening SQLCipher with nobody scheduled to close it — on
    /// 1.12.10 (39), a build carrying rounds 1-8, one did exactly that 150ms
    /// after the executor logged "store closed" and RunningBoard killed the
    /// suspension (0xdead10cc round 9). The push wake opens lazily through this
    /// same funnel and owns a bounded close afterwards, so ownership admits it.
    ///
    /// Explicit flows (onboarding, nsec restore, erase-and-reconnect, the
    /// backup executors) call `performConnect` directly and are deliberately
    /// NOT gated: a refused connect during an nsec restore rolls back through
    /// `wipeDatabase()` (see `connectLocal`'s R-031 note), so the shared open
    /// must stay callable and the gate sits on the lazy funnel only.
    static func mayOpenStore(foreground: Bool, pushWakeOwned: Bool) -> Bool {
        foreground || pushWakeOwned
    }

    /// Whether a push wake should drop the relay latch.
    ///
    /// Only a real background scene can have had its sockets suspended. `.inactive`
    /// (Control Center, a system prompt, an incoming-call banner) is still
    /// foreground: the node there is healthy, and rebuilding it would close one
    /// that polling / sends / media work still hold. Mirrors the Compose
    /// `appVisible` gate, which spans `onStart`..`onStop` rather than focus.
    static func shouldInvalidateOnPushWake(appVisible: Bool) -> Bool { !appVisible }
}
