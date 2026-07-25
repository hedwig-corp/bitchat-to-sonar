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

    @Test("push while app is visible keeps the healthy node")
    func pushWhileVisibleKeepsHealthyNode() {
        // `.inactive` maps to appVisible: true — Control Center or a system
        // prompt does not suspend sockets, so the node must not be rebuilt.
        #expect(RelayConnectionPolicy.shouldInvalidateOnPushWake(appVisible: true) == false)
        #expect(RelayConnectionPolicy.shouldInvalidateOnPushWake(appVisible: false))
    }
}
