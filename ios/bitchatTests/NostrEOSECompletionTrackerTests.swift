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
        let second = tracker.recordEOSE(from: "wss://relay-b.test")

        #expect(!first)
        #expect(!duplicate)
        #expect(tracker.completedRelayCount == 1)
        #expect(second)
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
