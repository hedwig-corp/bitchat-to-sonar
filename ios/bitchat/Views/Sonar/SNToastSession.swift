//
// SNToastSession.swift
// bitchat
//
// Epoch-gated toast state so a late dismiss from an older showToast cannot
// clear a newer toast — and a cancelled parent Task cannot leave the latest
// toast stuck forever when paired with Task.detached dismissal.
//

import Foundation

struct SNToastSession: Equatable {
    private(set) var epoch: UInt64 = 0
    private(set) var text: String? = nil

    /// Auto-dismissible toast. Returns the epoch the dismiss task must match.
    @discardableResult
    mutating func show(_ value: String) -> UInt64 {
        epoch &+= 1
        text = value
        return epoch
    }

    /// Sticky toast (e.g. "Backing up…"): bumps epoch so pending dismissals
    /// no-op, and leaves `text` until the next `show` / `clear`.
    mutating func showSticky(_ value: String) {
        epoch &+= 1
        text = value
    }

    mutating func clear(ifEpoch expected: UInt64) {
        guard epoch == expected else { return }
        text = nil
    }

    /// Invalidate pending dismissals and drop visible text.
    mutating func reset() {
        epoch &+= 1
        text = nil
    }
}
