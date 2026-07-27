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

    /// A flood of unknown sender IDs must not grow the map without bound.
    @Test
    func trackingIsBounded() {
        var tracker = NoiseDecryptFailureTracker(threshold: 5, trackingCap: 4)
        for index in 0..<12 {
            _ = tracker.recordFailure(for: PeerID(str: String(format: "%016x", index)))
        }
        // Cap reached at least once, so earlier entries were dropped rather
        // than retained forever.
        #expect(tracker.failureCount(for: PeerID(str: String(format: "%016x", 0))) == 0)
    }
}
