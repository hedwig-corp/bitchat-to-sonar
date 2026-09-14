//
// SonarPushUnreadDelta.swift
// bitchat
//
// Pure unread-delta helper for Transponder push wakes. Kept free of UIKit so
// unit tests can pin the "do not re-alert stale unread" invariant.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

enum SonarPushUnreadDelta {
    struct Fingerprint: Equatable {
        let unread: UInt64
        let latestAt: Date
        let content: String
    }

    /// Whether `after` represents new activity versus a pre-refresh baseline.
    /// When `baselineHydrated` is false (in-memory cache never loaded), a key
    /// missing from `before` must NOT count as new — that is the cold-wake
    /// stale-unread fan-out. After a local summary load, missing keys are
    /// genuinely new conversations.
    ///
    /// `familyIds` are hist↔live aliases of `groupId`. Core hide remounts
    /// unread onto the live id; a hist-only baseline must not look like a
    /// brand-new chat.
    static func isNewlyAdvanced(
        groupId: String,
        after: Fingerprint,
        before: [String: Fingerprint],
        baselineHydrated: Bool,
        familyIds: Set<String> = []
    ) -> Bool {
        guard after.unread > 0 else { return false }
        var keys = familyIds
        keys.insert(groupId)
        let prior = keys.compactMap { before[$0] }.max { lhs, rhs in
            if lhs.unread != rhs.unread { return lhs.unread < rhs.unread }
            return lhs.latestAt < rhs.latestAt
        }
        guard let prior else { return baselineHydrated }
        return after.unread > prior.unread
            || after.latestAt > prior.latestAt
            || after.content != prior.content
    }
}
