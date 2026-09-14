//
// SNUnreadCounts.swift
// bitchat
//
// Pure unread-map helpers shared by MarmotChatModel summary refresh.
// Mirrors Compose `UnreadCounts.kt`: suppress groups that were already marked
// read so an in-flight markConversationRead cannot flash the badge back.
//

import Foundation

enum SNUnreadCounts {
    /// A failed summaries probe must not look like a successful empty inbox.
    static func shouldPublish<T>(_ loaded: [T]?) -> Bool {
        loaded != nil
    }

    /// Compose `shouldRetireOpenChatUnread`. Do not abandon the unread
    /// divider while bak / a hidden 0.8 sibling may still hold incoming
    /// unread rows. `nil` feed newest is treated as older than a known
    /// expected newest (same as Compose `feedNewestTsSecs == 0`).
    static func shouldRetireOpenUnread(
        unreadAtOpen: UInt64,
        anchorFound: Bool,
        feedNewest: Date?,
        expectedNewest: Date?,
        familyHasOlder: Bool
    ) -> Bool {
        SNTranscriptScrollPolicy.shouldRetireOpenUnread(
            unreadAtOpen: unreadAtOpen,
            anchorFound: anchorFound,
            feedNewest: feedNewest,
            expectedNewest: expectedNewest,
            familyHasOlder: familyHasOlder
        )
    }

    /// Open-time unread from the conversation index. `nil` summaries must
    /// not settle as `0` (fully-read / jump-to-tail). Empty success is 0.
    static func openCount(
        from summaries: [(groupIdHex: String, unreadCount: UInt64)]?,
        wanted: Set<String>
    ) -> UInt64? {
        guard let summaries else { return nil }
        return summaries
            .filter { wanted.contains($0.groupIdHex) }
            .reduce(UInt64(0)) { $0 + $1.unreadCount }
    }

    /// `conversation_summaries()` hides folded hist. Keep the previous hist
    /// badge only while live unread is still 0 — after `copy_summary` live
    /// already holds the sum. Empty success still clears.
    /// Compose `remountFoldedUnread`.
    static func remountFoldedUnread(
        next: [String: UInt64],
        previous: [String: UInt64],
        historicalFolds: [String: String]
    ) -> [String: UInt64] {
        guard !historicalFolds.isEmpty else { return next }
        var out = next
        for (historical, live) in historicalFolds {
            guard !live.isEmpty, live != historical else { continue }
            guard out[historical] == nil else { continue }
            let histUnread = previous[historical] ?? 0
            guard histUnread > 0 else { continue }
            guard (out[live] ?? 0) == 0 else { continue }
            out[historical] = histUnread
        }
        return out
    }

    /// Build the published unread map, skipping suppressed group ids.
    static func unreadByGroup(
        from summaries: [(groupIdHex: String, unreadCount: UInt64)],
        suppressing suppressed: Set<String>
    ) -> [String: UInt64] {
        var unread: [String: UInt64] = [:]
        for summary in summaries where summary.unreadCount > 0 {
            if suppressed.contains(summary.groupIdHex) { continue }
            unread[summary.groupIdHex] = summary.unreadCount
        }
        return unread
    }

    /// Keep suppress entries only while core still reports unread for them.
    static func pruneConfirmedSuppressions(
        _ suppressed: Set<String>,
        summaries: [(groupIdHex: String, unreadCount: UInt64)]
    ) -> Set<String> {
        guard !suppressed.isEmpty else { return [] }
        let stillUnread = Set(
            summaries.compactMap { summary -> String? in
                summary.unreadCount > 0 ? summary.groupIdHex : nil
            }
        )
        return suppressed.intersection(stillUnread)
    }
}
