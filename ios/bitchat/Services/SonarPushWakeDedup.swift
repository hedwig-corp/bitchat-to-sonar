//
// SonarPushWakeDedup.swift
// bitchat
//
// Helpers for correlating push-wake drain previews with local transcript rows.
// Drain previews are truncated at 100 chars with a trailing ellipsis (core);
// live-path dedup must not key on display labels or full content alone.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

enum SonarPushWakeDedup {
    /// Whether a full local message body matches a drain/summary preview.
    /// Handles the core truncation form `"\(prefix)…"`.
    static func matchesPreview(fullContent: String, preview: String) -> Bool {
        if fullContent == preview { return true }
        guard preview.hasSuffix("…") else { return false }
        let prefix = String(preview.dropLast())
        guard !prefix.isEmpty else { return false }
        return fullContent.hasPrefix(prefix)
    }
}
