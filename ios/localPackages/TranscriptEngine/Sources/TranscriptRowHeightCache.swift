import CoreGraphics
import Foundation

/// Width-scoped cache of exact row heights for pre-measured transcript lists.
public final class TranscriptRowHeightCache {
    public private(set) var width: CGFloat = 0
    private var heights: [String: CGFloat] = [:]

    public init() {}

    @discardableResult
    public func updateWidth(_ newWidth: CGFloat) -> Bool {
        guard abs(newWidth - width) > 0.5 else { return false }
        width = newWidth
        heights.removeAll()
        return true
    }

    public func height(forKey key: String, measure: () -> CGFloat) -> CGFloat {
        if let cached = heights[key] { return cached }
        let measured = measure()
        heights[key] = measured
        return measured
    }

    public var count: Int { heights.count }

    public func removeAll() { heights.removeAll() }
}
