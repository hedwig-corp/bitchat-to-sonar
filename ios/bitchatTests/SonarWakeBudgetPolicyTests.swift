//
// SonarWakeBudgetPolicyTests.swift
// bitchatTests
//
// Pins the Marmot push-wake budget: the store close must still be startable
// inside the iOS background window. TestFlight 1.12.5 (33) died on
// RUNNINGBOARD 0xdead10cc 51s into a background launch because one wake pass
// could cost more than the whole window, so `closeNode()` was never reached
// and `sync_once` / `register_push_token` were still parked on the SQLCipher
// handle at suspension.
//

import Testing
@testable import Sonar

struct SonarWakeBudgetPolicyTests {

    @Test("a full-window pass still leaves the close its reserve")
    func fullWindowPassLeavesCloseReserve() {
        // The regression in one line: with the flat 25s sync timeout the pass
        // cost 25 + 2.5 (NSE yield) + up to 10 (ensureConnected) = 37.5s of a
        // 28s window, so the close below it could not start at all.
        let budget = SonarWakeBudgetPolicy.passBudget(
            remaining: SonarWakeBudgetPolicy.windowSeconds
        )
        #expect(
            budget + SonarWakeBudgetPolicy.closeReserveSeconds
                <= SonarWakeBudgetPolicy.windowSeconds
        )
    }

    @Test("raising the sync timeout cannot eat the close reserve")
    func syncTimeoutCannotEatCloseReserve() {
        // `TransportConfig.marmotPushSyncTimeoutSeconds` is a shared constant
        // tuned for foreground sync. Bumping it must never be able to push the
        // close back out of the window again — the budget clamps, not the
        // caller.
        for maxSync in [25.0, 30.0, 120.0] {
            let budget = SonarWakeBudgetPolicy.passBudget(
                remaining: SonarWakeBudgetPolicy.windowSeconds,
                maxSyncSeconds: maxSync
            )
            #expect(
                budget + SonarWakeBudgetPolicy.closeReserveSeconds
                    <= SonarWakeBudgetPolicy.windowSeconds
            )
        }
    }

    @Test("a pass never shrinks below the floor even when the window is gone")
    func passNeverShrinksBelowFloor() {
        // Overrun: a rerun asking for budget with nothing left must get the
        // floor and fail fast, not a negative timeout that returns instantly
        // and spins the outer loop.
        #expect(SonarWakeBudgetPolicy.passBudget(remaining: 0) == SonarWakeBudgetPolicy.minPassSeconds)
        #expect(SonarWakeBudgetPolicy.passBudget(remaining: -5) == SonarWakeBudgetPolicy.minPassSeconds)
    }

    @Test("a rerun is refused once the close reserve is all that is left")
    func rerunRefusedWhenOnlyCloseReserveRemains() {
        // A rerun re-enters runMarmotWakeup -> ensureConnected(), which REOPENS
        // the store the wake-deadline close just shut. That is R-020's shape,
        // so the rerun gate must be closed by the time the deadline closer can
        // have fired.
        #expect(SonarWakeBudgetPolicy.mayRerun(remaining: 0) == false)
        #expect(SonarWakeBudgetPolicy.mayRerun(remaining: SonarWakeBudgetPolicy.closeReserveSeconds) == false)
        #expect(SonarWakeBudgetPolicy.mayRerun(remaining: 20) == true)
    }

    @Test("the NSE yield is charged against the window, not free")
    func nseYieldIsChargedAgainstWindow() {
        // It used to run before the budget started, which is how a "25s" pass
        // actually cost 27.5s.
        #expect(SonarWakeBudgetPolicy.nseYieldSeconds > 0)
        #expect(
            SonarWakeBudgetPolicy.nseYieldSeconds
                + SonarWakeBudgetPolicy.closeReserveSeconds
                < SonarWakeBudgetPolicy.windowSeconds
        )
    }
}
