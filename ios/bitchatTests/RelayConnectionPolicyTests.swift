//
// RelayConnectionPolicyTests.swift
// bitchatTests
//
// Pins the host-side relay latch policy: after background invalidate,
// connect must rebuild sockets. Process-alive background delivery failed
// when the latch stayed true against dead websockets (killed-app still
// worked because a fresh process starts unlatched).
//

import Testing
@testable import Sonar

struct RelayConnectionPolicyTests {

    @Test("latched attach skips reconnect")
    func latchedAttachSkipsReconnect() {
        #expect(RelayConnectionPolicy.wouldSkipConnect(latched: true))
    }

    @Test("invalidate clears latch so push wake reconnects")
    func invalidateClearsLatchSoPushWakeReconnects() {
        #expect(RelayConnectionPolicy.afterInvalidate() == false)
        #expect(
            RelayConnectionPolicy.wouldSkipConnect(
                latched: RelayConnectionPolicy.afterInvalidate()
            ) == false
        )
    }

    @Test("iOS background invalidates the relay latch")
    func iosBackgroundInvalidatesRelayLatch() {
        // Consumed by SonarAppStore.setForeground's wentToBackground branch, so
        // flipping this to false stops process-alive background delivery from
        // ever reconnecting — the bug this PR fixes. Compose Desktop's actual
        // returns false, which is why the decision lives in the policy at all.
        #expect(RelayConnectionPolicy.shouldInvalidateOnBackground() == true)
    }

    @Test("invalidate during attach keeps the latch down")
    func invalidateDuringAttachKeepsLatchDown() {
        // Epoch bumped mid-attach: the completing connect must not restore the
        // latch, or the next push wake syncs against background-staled sockets.
        #expect(RelayConnectionPolicy.latchAfterAttach(startEpoch: 4, currentEpoch: 5) == false)
    }

    @Test("undisturbed attach latches connected")
    func undisturbedAttachLatchesConnected() {
        #expect(RelayConnectionPolicy.latchAfterAttach(startEpoch: 4, currentEpoch: 4))
    }

    @Test("a backgrounded app must not self-heal its relay connection")
    func backgroundedAppMustNotSelfHealRelayConnection() {
        // Consumed by `MarmotChatModel.scheduleRelayConnect`, which is the timer
        // behind all three self-healing retries (polling idle, connect backoff,
        // post-local-open attach). Flipping this to true reopens the SQLCipher
        // store that `suspendStoreForBackground()` just closed, and because
        // `connect()` ends with `startPolling()` whose idle timeout arms the
        // retry again, the reopen sustains itself until RunningBoard kills the
        // process with 0xdead10cc — TestFlight 1.12.3 (31), R-020.
        #expect(RelayConnectionPolicy.shouldAutoReconnect(foreground: false) == false)
    }

    @Test("a foreground app still self-heals its relay connection")
    func foregroundAppStillSelfHealsRelayConnection() {
        // The gate must be background-only: returning false here would strand a
        // foreground app on a dead websocket after any relay drop, since the
        // polling loop's idle branch is the only thing that retries.
        #expect(RelayConnectionPolicy.shouldAutoReconnect(foreground: true))
    }

    @Test("push while app is visible keeps the healthy node")
    func pushWhileVisibleKeepsHealthyNode() {
        // `.inactive` maps to appVisible: true — Control Center or a system
        // prompt does not suspend sockets, so the node must not be rebuilt.
        #expect(RelayConnectionPolicy.shouldInvalidateOnPushWake(appVisible: true) == false)
        #expect(RelayConnectionPolicy.shouldInvalidateOnPushWake(appVisible: false))
    }

    @Test("a backgrounded attach with no push-wake owner must be refused")
    func backgroundedAttachWithoutOwnerRefused() {
        // Consumed by `MarmotChatModel.connectRelaysIfNeeded`. Flipping this to
        // true lets a straggler attach (e.g. a backup's post-seal reconnect)
        // open/hold SQLCipher while backgrounded with nobody left to close it —
        // on 1.12.9 (38) the store reopened ~200ms after the BGTask executor
        // logged "store closed" and RunningBoard killed the suspension with
        // 0xdead10cc (round 8).
        #expect(RelayConnectionPolicy.mayAttachRelays(foreground: false, pushWakeOwned: false) == false)
    }

    @Test("the push wake may attach relays while backgrounded")
    func pushWakeMayAttachRelaysBackgrounded() {
        // The wake brackets its drain in `pushWakeOwnership` and closes after
        // itself (`closeStoreWithDeadline`); refusing it would kill background
        // message delivery entirely.
        #expect(RelayConnectionPolicy.mayAttachRelays(foreground: false, pushWakeOwned: true))
    }

    @Test("a foreground attach is never gated")
    func foregroundAttachNeverGated() {
        #expect(RelayConnectionPolicy.mayAttachRelays(foreground: true, pushWakeOwned: false))
    }
}
