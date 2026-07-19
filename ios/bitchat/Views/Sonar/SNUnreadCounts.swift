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
