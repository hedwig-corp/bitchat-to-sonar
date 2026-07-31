//
// SonarWakeBudgetPolicy.swift
// bitchat
//
// How a Marmot push wake spends its ~30s of iOS background execution.
//
// The store close is not optional work at the end of a wake — it is the thing
// that keeps RunningBoard from killing us for holding the SQLCipher WAL and
// the App Group flock across suspension (0xdead10cc). So the budget is built
// close-first: reserve what the close needs, then let the drain have the rest.
//
// Extracted so the arithmetic is pinnable by a test. `SonarPushProcessor` is
// `@MainActor` and needs a live `MarmotChatModel`, so nothing constructs a
// wake in a unit test; the numbers are what regressed and the numbers are what
// this guards. iOS-only — Android/RunningBoard has no file-lock kill.
//

import Foundation

enum SonarWakeBudgetPolicy {
    /// iOS gives a silent-push wake ~30s of background execution
    /// (TransportConfig documents the window); keep 2s of margin.
    static let windowSeconds: Double = 28

    /// Yield so a concurrent NSE hydrate can take the App Group flock first.
    /// Charged against the window like everything else — it used to run
    /// off-budget, which is part of how the close became unreachable.
    static let nseYieldSeconds: Double = 2.5

    /// Window reserved for the store close: the latest point at which
    /// `closeNode()` may still be *started*. It aborts in-flight FFI off-queue
    /// (`interruptNodeForSuspend`) and then hops the serial `workQueue` to drop
    /// the node and release the flock.
    static let closeReserveSeconds: Double = 8

    /// Below this much remaining window a coalesced rerun cannot pay even a
    /// shrunk pass — skip it; the push syncs on the next wake/foreground.
    ///
    /// Derived, not tuned: a rerun must afford a real pass AND leave the close
    /// its reserve. Hardcoding this to `closeReserveSeconds` admitted a band
    /// (`remaining` in `(8, 11]`) where `passBudget`'s `minPassSeconds` clamp
    /// inflated a 1s slot back up to 3s and the pass then ate into the reserve.
    static var rerunMinSeconds: Double { closeReserveSeconds + minPassSeconds }

    /// A pass shorter than this cannot accomplish anything, but failing fast
    /// inside the window still beats overrunning it.
    static let minPassSeconds: Double = 3

    /// When the wake-deadline closer fires, measured from wake start.
    ///
    /// It must fire when the budgeted pass was *due to end*, not at the window
    /// edge: the close is not instant — it aborts in-flight FFI and then hops a
    /// serial queue — so arming it at `windowSeconds` would have it *start* at
    /// the moment iOS is entitled to suspend us, spending the whole reserve
    /// past the deadline and reproducing the very kill it exists to prevent.
    static var deadlineCloserSeconds: Double { windowSeconds - closeReserveSeconds }

    /// Budget for one wake pass — the NSE yield, the relay connect AND the
    /// sync, not just the sync.
    ///
    /// Charging only the sync is what shipped the 0xdead10cc in TestFlight
    /// 1.12.5 (33): the yield (2.5s) and `ensureConnected()` (10s) ran off
    /// budget on top of a flat 25s sync timeout, so a single pass could cost
    /// ~37s of a 28s window and the close below it was never reached.
    static func passBudget(
        remaining: Double,
        maxSyncSeconds: Double = TransportConfig.marmotPushSyncTimeoutSeconds
    ) -> Double {
        max(minPassSeconds, min(maxSyncSeconds, remaining - closeReserveSeconds))
    }

    /// Whether a coalesced rerun still fits in what is left of the window.
    ///
    /// Doubles as the guard against R-020's reopen shape: a rerun re-enters
    /// `runMarmotWakeup`, which calls `ensureConnected()` and would reopen the
    /// store the wake-deadline close just shut.
    static func mayRerun(remaining: Double) -> Bool { remaining > rerunMinSeconds }
}
