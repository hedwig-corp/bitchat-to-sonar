//
// SNStoreInvalidationCoalescerTests.swift
// bitchatTests
//

import Combine
import Testing
@testable import Sonar

@MainActor
struct SNStoreInvalidationCoalescerTests {
    @Test
    func independentSourcesShareOneThrottleWindow() async throws {
        let coalescer = SNStoreInvalidationCoalescer(interval: .milliseconds(40))
        let first = PassthroughSubject<Void, Never>()
        let second = PassthroughSubject<Void, Never>()
        var emissionCount = 0
        var cancellables = Set<AnyCancellable>()

        coalescer.publisher()
            .sink { emissionCount += 1 }
            .store(in: &cancellables)
        first
            .sink { coalescer.invalidate() }
            .store(in: &cancellables)
        second
            .sink { coalescer.invalidate() }
            .store(in: &cancellables)

        // Two services fire back to back, as overlapping BLE, relay and Marmot
        // updates do. Combine's throttle schedules even its leading emission
        // on the main queue, behind both hops, so one shared window renders
        // once; a throttle per source (the R-037 bug) renders once per source.
        // Counting emissions instead of sampling at fixed sleeps keeps this
        // independent of how busy the main thread is: the parallel suite
        // holds it for seconds at a time.
        first.send()
        second.send()
        try await waitForQuiet(atLeast: 1, count: { emissionCount })
        #expect(emissionCount == 1)

        first.send()
        second.send()
        try await waitForQuiet(atLeast: 2, count: { emissionCount })
        #expect(emissionCount == 2)

        _ = cancellables
    }

    /// Waits for `count` to reach `atLeast`, then for three more throttle
    /// windows so a surplus emission would land before the caller checks.
    private func waitForQuiet(atLeast target: Int, count: () -> Int) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while count() < target, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(120))
    }
}
