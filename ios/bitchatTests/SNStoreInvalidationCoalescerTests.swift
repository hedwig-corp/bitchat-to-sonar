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

        first.send()
        second.send()
        try await Task.sleep(for: .milliseconds(10))
        #expect(emissionCount == 1)

        first.send()
        second.send()
        try await Task.sleep(for: .milliseconds(70))
        #expect(emissionCount == 2)

        _ = cancellables
    }
}
