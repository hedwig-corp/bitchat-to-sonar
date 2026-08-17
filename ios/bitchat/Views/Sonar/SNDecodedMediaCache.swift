//
// SNDecodedMediaCache.swift
// bitchat
//
// Compose MediaImageMemoryCache parity: decoded transcript thumbnails paint
// immediately when scrolling back / reopening a chat, within a 48 MB LRU.
//

import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if DEBUG
import BitLogger
#endif

/// Decoded transcript thumbnail ready to paint (static images only).
struct SNCachedDecodedThumb: @unchecked Sendable {
    let image: Image
    let pixelWidth: Int
    let pixelHeight: Int

    var costBytes: Int64 {
        max(1, Int64(pixelWidth) * Int64(pixelHeight) * 4)
    }
}

/// Process-wide decoded-thumbnail LRU (Signal ThumbnailView / Compose
/// `MediaImageMemoryCache`). Main-actor confined: reads from cell tasks after
/// decode, writes after off-main ImageIO work hops back.
@MainActor
final class SNDecodedMediaCache {
    static let shared = SNDecodedMediaCache()

    /// Mirror Compose `MAX_COST_BYTES`.
    static let maxCostBytes: Int64 = 48 * 1024 * 1024

    private var map: [String: SNCachedDecodedThumb] = [:]
    /// Eldest at index 0.
    private var order: [String] = []
    private(set) var totalCostBytes: Int64 = 0
    #if DEBUG
    private(set) var hitCount: UInt64 = 0
    private(set) var missCount: UInt64 = 0
    #endif

    func get(_ key: String) -> SNCachedDecodedThumb? {
        guard let hit = map[key] else {
            #if DEBUG
            missCount &+= 1
            snLogMediaDecode(hit: false, key: key)
            #endif
            return nil
        }
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
            order.append(key)
        }
        #if DEBUG
        hitCount &+= 1
        snLogMediaDecode(hit: true, key: key)
        #endif
        return hit
    }

    func put(_ key: String, _ decoded: SNCachedDecodedThumb) {
        if let old = map.removeValue(forKey: key) {
            totalCostBytes -= old.costBytes
            if let idx = order.firstIndex(of: key) {
                order.remove(at: idx)
            }
        }
        map[key] = decoded
        order.append(key)
        totalCostBytes += decoded.costBytes
        trimTo(Self.maxCostBytes, keep: key)
    }

    func trimTo(_ maxCostBytes: Int64, keep: String? = nil) {
        var i = 0
        while totalCostBytes > maxCostBytes, i < order.count {
            let eldest = order[i]
            if eldest == keep {
                i += 1
                continue
            }
            order.remove(at: i)
            if let removed = map.removeValue(forKey: eldest) {
                totalCostBytes -= removed.costBytes
            }
        }
    }

    func clear() {
        map.removeAll(keepingCapacity: false)
        order.removeAll(keepingCapacity: false)
        totalCostBytes = 0
    }

    /// Memory pressure: drop half the budget (Compose/Android trim parity).
    func trimForMemoryWarning() {
        trimTo(Self.maxCostBytes / 2)
    }
}

#if DEBUG
@MainActor
private func snLogMediaDecode(hit: Bool, key: String) {
    // Sampled: at most one line per second for the shared cache.
    struct Gate {
        static var last: CFAbsoluteTime = 0
        static var hits = 0
        static var misses = 0
    }
    if hit { Gate.hits += 1 } else { Gate.misses += 1 }
    let now = CFAbsoluteTimeGetCurrent()
    guard now - Gate.last >= 1 else { return }
    SecureLogger.info(
        "SONAR_BENCH media_decode window_s=\(String(format: "%.2f", now - Gate.last)) "
            + "hit=\(Gate.hits) miss=\(Gate.misses) cost_mb=\(SNDecodedMediaCache.shared.totalCostBytes / (1024 * 1024))",
        category: .session
    )
    Gate.hits = 0
    Gate.misses = 0
    Gate.last = now
    _ = key
}
#endif
