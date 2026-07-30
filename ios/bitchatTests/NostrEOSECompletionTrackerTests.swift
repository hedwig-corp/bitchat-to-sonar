//
// NostrEOSECompletionTrackerTests.swift
// bitchatTests
//
// Verifies subscription EOSE completion uses a relay quorum instead of waiting
// for every relay before initial subscription hydration can continue.
//

import Testing
@testable import Sonar

struct NostrEOSECompletionTrackerTests {

    @Test func oneRelayRequiresOneEOSE() {
        var tracker = NostrEOSECompletionTracker(relays: ["wss://relay-a.test"])

        #expect(!tracker.isComplete)
        let completed = tracker.recordEOSE(from: "wss://relay-a.test")
        #expect(completed)
        #expect(tracker.completedRelayCount == 1)
    }

    @Test func threeRelaysCompleteAfterTwoEOSEs() {
        var tracker = NostrEOSECompletionTracker(relays: [
            "wss://relay-a.test",
            "wss://relay-b.test",
            "wss://relay-c.test"
        ])

        let first = tracker.recordEOSE(from: "wss://relay-a.test")
        let second = tracker.recordEOSE(from: "wss://relay-b.test")

        #expect(!first)
        #expect(second)
        #expect(tracker.completedRelayCount == 2)
        #expect(tracker.pendingRelays == ["wss://relay-c.test"])
    }

    @Test func duplicateEOSEDoesNotAdvanceCompletion() {
        var tracker = NostrEOSECompletionTracker(relays: [
            "wss://relay-a.test",
            "wss://relay-b.test",
            "wss://relay-c.test"
        ])

        let first = tracker.recordEOSE(from: "wss://relay-a.test")
        let duplicate = tracker.recordEOSE(from: "wss://relay-a.test")
        // Capture here, not after `second`: the whole point is that the
        // duplicate did not advance the count, and reading it at the end
        // measures the state after relay-b has also reported.
        let countAfterDuplicate = tracker.completedRelayCount
        let second = tracker.recordEOSE(from: "wss://relay-b.test")

        #expect(!first)
        #expect(!duplicate)
        #expect(countAfterDuplicate == 1)
        #expect(second)
        #expect(tracker.completedRelayCount == 2)
    }

    @Test func explicitRequiredRelayCountIsClampedToRelaySet() {
        var tracker = NostrEOSECompletionTracker(
            relays: ["wss://relay-a.test", "wss://relay-b.test"],
            requiredRelayCount: 99
        )

        let first = tracker.recordEOSE(from: "wss://relay-a.test")
        let second = tracker.recordEOSE(from: "wss://relay-b.test")

        #expect(!first)
        #expect(second)
        #expect(tracker.requiredRelayCount == 2)
    }
}
