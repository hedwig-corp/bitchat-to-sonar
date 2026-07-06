//
// SonarReceiveOfferCacheTests.swift
// bitchatTests
//
// Covers the BOLT12 receive-offer cache used by the real Breez wallet bridge.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
@testable import Sonar

@MainActor
final class SonarReceiveOfferCacheTests: XCTestCase {

    func testCachesOfferAfterFirstCreation() async throws {
        let cache = SonarReceiveOfferCache()
        var createCount = 0

        let first = try await cache.offer {
            createCount += 1
            return "lno1first"
        }
        let second = try await cache.offer {
            createCount += 1
            return "lno1second"
        }

        XCTAssertEqual(first, "lno1first")
        XCTAssertEqual(second, "lno1first")
        XCTAssertEqual(createCount, 1)
    }

    func testCoalescesConcurrentCreation() async throws {
        let cache = SonarReceiveOfferCache()
        var createCount = 0

        async let first: String = cache.offer {
            createCount += 1
            try await Task.sleep(nanoseconds: 10_000_000)
            return "lno1shared"
        }
        async let second: String = cache.offer {
            createCount += 1
            return "lno1second"
        }

        let values = try await (first, second)
        XCTAssertEqual(values.0, "lno1shared")
        XCTAssertEqual(values.1, "lno1shared")
        XCTAssertEqual(createCount, 1)
    }

    func testResetAllowsNewOffer() async throws {
        let cache = SonarReceiveOfferCache()
        var createCount = 0

        let first = try await cache.offer {
            createCount += 1
            return "lno1first"
        }
        cache.reset()
        let second = try await cache.offer {
            createCount += 1
            return "lno1second"
        }

        XCTAssertEqual(first, "lno1first")
        XCTAssertEqual(second, "lno1second")
        XCTAssertEqual(createCount, 2)
    }

    func testResetDuringInFlightDoesNotReturnStaleOffer() async throws {
        let cache = SonarReceiveOfferCache()
        let started = expectation(description: "offer creation started")
        var release: CheckedContinuation<Void, Never>?

        let firstTask = Task { @MainActor in
            try await cache.offer {
                started.fulfill()
                await withCheckedContinuation { continuation in
                    release = continuation
                }
                return "lno1stale"
            }
        }

        await fulfillment(of: [started], timeout: 1)
        cache.reset()
        release?.resume()

        do {
            _ = try await firstTask.value
            XCTFail("Expected reset in-flight offer creation to be cancelled")
        } catch is CancellationError {
        }

        let fresh = try await cache.offer {
            "lno1fresh"
        }
        XCTAssertEqual(fresh, "lno1fresh")
    }
}
