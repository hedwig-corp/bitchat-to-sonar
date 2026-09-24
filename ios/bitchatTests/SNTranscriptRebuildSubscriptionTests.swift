import Combine
import Testing
@testable import Sonar

@MainActor
struct SNTranscriptRebuildSubscriptionTests {
    @Test
    func detachStopsRebuildsWithoutClearingAttachmentContract() async throws {
        let subscription = SNTranscriptRebuildSubscription(debounceInterval: .milliseconds(20))
        let invalidations = PassthroughSubject<Void, Never>()
        var rebuildCount = 0

        subscription.attach(to: invalidations) {
            rebuildCount += 1
        }
        #expect(subscription.isAttached)

        invalidations.send()
        try await Task.sleep(for: .milliseconds(40))
        #expect(rebuildCount == 1)

        subscription.detach()
        #expect(!subscription.isAttached)

        invalidations.send()
        try await Task.sleep(for: .milliseconds(40))
        #expect(rebuildCount == 1)

        subscription.attach(to: invalidations) {
            rebuildCount += 1
        }
        #expect(subscription.isAttached)
        invalidations.send()
        try await Task.sleep(for: .milliseconds(40))
        #expect(rebuildCount == 2)
    }

    @Test
    func attachIsIdempotentWhileAlreadyAttached() async throws {
        let subscription = SNTranscriptRebuildSubscription(debounceInterval: .milliseconds(20))
        let invalidations = PassthroughSubject<Void, Never>()
        var rebuildCount = 0

        subscription.attach(to: invalidations) {
            rebuildCount += 1
        }
        subscription.attach(to: invalidations) {
            rebuildCount += 10
        }

        invalidations.send()
        try await Task.sleep(for: .milliseconds(40))
        #expect(rebuildCount == 1)
    }

    /// A store that never goes quiet must still rebuild the open transcript.
    /// With a debounce, invalidations arriving faster than the interval reset
    /// the timer forever: the ack for a sent message and incoming replies
    /// never reached the screen while a sync burst or feedback loop ran.
    @Test
    func sustainedInvalidationsStillRebuildDuringTheStorm() async throws {
        let subscription = SNTranscriptRebuildSubscription(debounceInterval: .milliseconds(20))
        let invalidations = PassthroughSubject<Void, Never>()
        var rebuildCount = 0
        subscription.attach(to: invalidations) {
            rebuildCount += 1
        }

        // 200 ms of invalidations every 5 ms — never a 20 ms quiet gap.
        for _ in 0..<40 {
            invalidations.send()
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(rebuildCount >= 2, "rebuilds must keep flowing while invalidations do")

        // Still coalesced: far fewer rebuilds than invalidations.
        #expect(rebuildCount <= 20)
    }
}
