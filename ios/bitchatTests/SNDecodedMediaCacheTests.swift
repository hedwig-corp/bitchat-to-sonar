//
// SNDecodedMediaCacheTests.swift
// bitchatTests
//

import SwiftUI
import Testing
@testable import Sonar

@MainActor
struct SNDecodedMediaCacheTests {
    private func thumb(id: String, pixels: Int) -> SNCachedDecodedThumb {
        // Cost = pixels * pixels * 4 via square geometry.
        SNCachedDecodedThumb(
            image: Image(systemName: "photo"),
            pixelWidth: pixels,
            pixelHeight: pixels
        )
    }

    @Test
    func lruEvictsEldestWhenOverBudget() {
        let cache = SNDecodedMediaCache.shared
        cache.clear()
        // Force a tiny budget via trim after puts of large entries.
        let a = thumb(id: "a", pixels: 1024) // ~4MB
        let b = thumb(id: "b", pixels: 1024)
        let c = thumb(id: "c", pixels: 1024)
        cache.put("a", a)
        cache.put("b", b)
        cache.put("c", c)
        // Keep only ~8MB → should drop eldest "a" when trimming.
        cache.trimTo(a.costBytes + b.costBytes, keep: "c")
        #expect(cache.get("a") == nil)
        #expect(cache.get("b") != nil)
        #expect(cache.get("c") != nil)
        cache.clear()
    }

    @Test
    func getPromotesToNewest() {
        let cache = SNDecodedMediaCache.shared
        cache.clear()
        let a = thumb(id: "a", pixels: 512)
        let b = thumb(id: "b", pixels: 512)
        let c = thumb(id: "c", pixels: 512)
        cache.put("a", a)
        cache.put("b", b)
        cache.put("c", c)
        _ = cache.get("a") // promote a
        cache.trimTo(a.costBytes + c.costBytes, keep: nil)
        // Eldest after promote should be b.
        #expect(cache.get("b") == nil)
        #expect(cache.get("a") != nil)
        #expect(cache.get("c") != nil)
        cache.clear()
    }

    @Test
    func memoryWarningHalvesBudget() {
        let cache = SNDecodedMediaCache.shared
        cache.clear()
        // Fill well under 48MB then trimForMemoryWarning should still run.
        cache.put("x", thumb(id: "x", pixels: 256))
        cache.put("y", thumb(id: "y", pixels: 256))
        let before = cache.totalCostBytes
        cache.trimForMemoryWarning()
        #expect(cache.totalCostBytes <= before)
        #expect(cache.totalCostBytes <= SNDecodedMediaCache.maxCostBytes / 2)
        cache.clear()
    }

    @Test
    func gifFingerprintStableForSameBytes() {
        let data = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x02, 0x03, 0x04])
        #expect(snGifDataFingerprint(data) == snGifDataFingerprint(data))
        var other = data
        other[other.count - 1] = 0xFF
        #expect(snGifDataFingerprint(data) != snGifDataFingerprint(other))
    }
}
