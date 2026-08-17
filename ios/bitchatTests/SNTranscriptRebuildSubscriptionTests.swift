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
}
