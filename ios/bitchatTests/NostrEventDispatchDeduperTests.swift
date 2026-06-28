//
// NostrEventDispatchDeduperTests.swift
// bitchatTests
//
// Verifies relay fan-out only invokes each local subscription handler once per
// event while preserving delivery to distinct subscription IDs.
//

import Foundation
import Testing
@testable import Sonar

struct NostrEventDispatchDeduperTests {

    @Test func suppressesDuplicateForSameSubscriptionInsideTTL() {
        var deduper = NostrEventDispatchDeduper(ttl: 60, capacity: 16)
        let now = Date(timeIntervalSince1970: 1_000)
        let first = deduper.shouldDispatch(subscriptionId: "geo-u0", eventId: "evt-1", now: now)
        let second = deduper.shouldDispatch(subscriptionId: "geo-u0", eventId: "evt-1", now: now.addingTimeInterval(1))

        #expect(first)
        #expect(!second)
    }

    @Test func preservesDispatchForDifferentSubscriptionIds() {
        var deduper = NostrEventDispatchDeduper(ttl: 60, capacity: 16)
        let now = Date(timeIntervalSince1970: 1_000)
        let active = deduper.shouldDispatch(subscriptionId: "geo-u0", eventId: "evt-1", now: now)
        let sample = deduper.shouldDispatch(subscriptionId: "geo-sample-u0", eventId: "evt-1", now: now)

        #expect(active)
        #expect(sample)
    }

    @Test func allowsEventAfterTTL() {
        var deduper = NostrEventDispatchDeduper(ttl: 5, capacity: 16)
        let now = Date(timeIntervalSince1970: 1_000)
        let first = deduper.shouldDispatch(subscriptionId: "geo-u0", eventId: "evt-1", now: now)
        let afterTTL = deduper.shouldDispatch(subscriptionId: "geo-u0", eventId: "evt-1", now: now.addingTimeInterval(6))

        #expect(first)
        #expect(afterTTL)
    }

    @Test func clearingSubscriptionAllowsImmediateRedispatch() {
        var deduper = NostrEventDispatchDeduper(ttl: 60, capacity: 16)
        let now = Date(timeIntervalSince1970: 1_000)
        let first = deduper.shouldDispatch(subscriptionId: "geo-u0", eventId: "evt-1", now: now)

        deduper.removeSubscription("geo-u0")
        let afterClear = deduper.shouldDispatch(subscriptionId: "geo-u0", eventId: "evt-1", now: now.addingTimeInterval(1))

        #expect(first)
        #expect(afterClear)
    }

    @Test func clearingSubscriptionPreservesOtherSubscriptions() {
        var deduper = NostrEventDispatchDeduper(ttl: 60, capacity: 16)
        let now = Date(timeIntervalSince1970: 1_000)
        let firstActive = deduper.shouldDispatch(subscriptionId: "geo-u0", eventId: "evt-1", now: now)
        let firstSample = deduper.shouldDispatch(subscriptionId: "geo-sample-u0", eventId: "evt-1", now: now)

        deduper.removeSubscription("geo-u0")
        let activeAfterClear = deduper.shouldDispatch(subscriptionId: "geo-u0", eventId: "evt-1", now: now.addingTimeInterval(1))
        let sampleAfterClear = deduper.shouldDispatch(subscriptionId: "geo-sample-u0", eventId: "evt-1", now: now.addingTimeInterval(1))

        #expect(firstActive)
        #expect(firstSample)
        #expect(activeAfterClear)
        #expect(!sampleAfterClear)
    }

    @Test func evictsOldestEntryAtCapacity() {
        var deduper = NostrEventDispatchDeduper(ttl: 60, capacity: 2)
        let now = Date(timeIntervalSince1970: 1_000)
        let first = deduper.shouldDispatch(subscriptionId: "sub", eventId: "evt-1", now: now)
        let second = deduper.shouldDispatch(subscriptionId: "sub", eventId: "evt-2", now: now)
        let third = deduper.shouldDispatch(subscriptionId: "sub", eventId: "evt-3", now: now)
        let evicted = deduper.shouldDispatch(subscriptionId: "sub", eventId: "evt-1", now: now.addingTimeInterval(1))

        #expect(first)
        #expect(second)
        #expect(third)
        #expect(evicted)
    }
}
