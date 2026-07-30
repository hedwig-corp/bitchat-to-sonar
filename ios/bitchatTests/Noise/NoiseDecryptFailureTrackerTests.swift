//
// NoiseDecryptFailureTrackerTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing

@testable import Sonar

/// A forged packet under a claimed sender ID must not cost that peer its
/// session, while a genuinely desynchronized session must still recover.
struct NoiseDecryptFailureTrackerTests {

    private let peer = PeerID(str: "aabbccddeeff0011")
    private let other = PeerID(str: "1100ffeeddccbbaa")

    @Test
    func singleFailureDoesNotResetTheSession() {
        var tracker = NoiseDecryptFailureTracker(threshold: 3, trackingCap: 8)
        #expect(tracker.recordFailure(for: peer) == false)
        #expect(tracker.failureCount(for: peer) == 1)
    }

    @Test
    func failuresBelowThresholdDoNotResetTheSession() {
        var tracker = NoiseDecryptFailureTracker(threshold: 3, trackingCap: 8)
        #expect(tracker.recordFailure(for: peer) == false)
        #expect(tracker.recordFailure(for: peer) == false)
        #expect(tracker.failureCount(for: peer) == 2)
    }

    @Test
    func thresholdConsecutiveFailuresResetTheSession() {
        var tracker = NoiseDecryptFailureTracker(threshold: 3, trackingCap: 8)
        #expect(tracker.recordFailure(for: peer) == false)
        #expect(tracker.recordFailure(for: peer) == false)
        #expect(tracker.recordFailure(for: peer) == true)
        // The run is cleared once consumed, so recovery starts fresh.
        #expect(tracker.failureCount(for: peer) == 0)
    }

    /// The "consecutive" part is what stops an attacker accumulating failures
    /// across a peer's healthy traffic until the session dies.
    @Test
    func successClearsTheRun() {
        var tracker = NoiseDecryptFailureTracker(threshold: 3, trackingCap: 8)
        _ = tracker.recordFailure(for: peer)
        _ = tracker.recordFailure(for: peer)
        tracker.recordSuccess(for: peer)
        #expect(tracker.failureCount(for: peer) == 0)
        #expect(tracker.recordFailure(for: peer) == false)
    }

    @Test
    func failuresAreTrackedPerPeer() {
        var tracker = NoiseDecryptFailureTracker(threshold: 2, trackingCap: 8)
        #expect(tracker.recordFailure(for: peer) == false)
        // A different peer's failure must not push the first peer over.
        #expect(tracker.recordFailure(for: other) == false)
        #expect(tracker.failureCount(for: peer) == 1)
        #expect(tracker.recordFailure(for: peer) == true)
    }

    /// The map stays bounded, and reaching the cap must not reset everyone.
    /// A wipe would let anyone who can get entries in here erase a genuinely
    /// desynchronized peer's run on demand, so it can never reach the threshold
    /// that recovers it.
    @Test
    func reachingTheCapEvictsOneEntryRatherThanWipingTheMap() {
        let cap = 4
        var tracker = NoiseDecryptFailureTracker(threshold: 5, trackingCap: cap)
        let tracked = (0..<12).map { PeerID(str: String(format: "%016x", $0)) }
        for peerID in tracked {
            _ = tracker.recordFailure(for: peerID)
        }

        let surviving = tracked.filter { tracker.failureCount(for: $0) > 0 }
        #expect(surviving.count == cap, "the map is bounded by the cap")
        // The most recent entry is always still there: eviction takes one
        // victim, so a peer recording failures now cannot be wiped by the cap.
        #expect(tracker.failureCount(for: tracked[tracked.count - 1]) == 1)
    }
}
