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

    /// Listed live id for a hist↔live pair. Host remount keeps the hist key
    /// for home preview; wake banners must never tap-open that hidden id.
    static func liveGroupId(
        id: String,
        historicalFolds: [String: String]
    ) -> String {
        if let live = historicalFolds[id], !live.isEmpty, live != id { return live }
        if let live = historicalFolds.first(where: { $0.value == id })?.value,
           !live.isEmpty {
            return live
        }
        return id
    }

    static func familyIds(
        id: String,
        historicalFolds: [String: String]
    ) -> Set<String> {
        let live = liveGroupId(id: id, historicalFolds: historicalFolds)
        var family: Set<String> = [id, live]
        for (historical, target) in historicalFolds {
            if historical == id || target == id || historical == live || target == live {
                family.insert(historical)
                family.insert(target)
            }
        }
        return family.filter { !$0.isEmpty }
    }

    /// One fingerprint per conversation after hide. Prefer the newer / higher
    /// unread tip when hist and remounted live both still sit in the map.
    static func collapseFingerprints(
        _ fingerprints: [String: Fingerprint],
        historicalFolds: [String: String]
    ) -> [String: Fingerprint] {
        var out: [String: Fingerprint] = [:]
        for (groupId, fingerprint) in fingerprints where fingerprint.unread > 0 {
            let live = liveGroupId(id: groupId, historicalFolds: historicalFolds)
            if let existing = out[live] {
                let newer = fingerprint.unread > existing.unread
                    || fingerprint.latestAt > existing.latestAt
                    || (fingerprint.unread == existing.unread
                        && fingerprint.latestAt == existing.latestAt
                        && fingerprint.content != existing.content
                        && fingerprint.content.count > existing.content.count)
                if newer { out[live] = fingerprint }
            } else {
                out[live] = fingerprint
            }
        }
        return out
    }

    /// Live ids that advanced this wake. Hist+live both unread is one tip.
    static func newlyUnreadLiveGroupIds(
        afterByGroup: [String: Fingerprint],
        before: [String: Fingerprint],
        baselineHydrated: Bool,
        historicalFolds: [String: String]
    ) -> [String] {
        let afterLive = collapseFingerprints(afterByGroup, historicalFolds: historicalFolds)
        let beforeLive = collapseFingerprints(before, historicalFolds: historicalFolds)
        return afterLive.keys.sorted().filter { live in
            guard let after = afterLive[live] else { return false }
            return isNewlyAdvanced(
                groupId: live,
                after: after,
                before: beforeLive,
                baselineHydrated: baselineHydrated,
                familyIds: familyIds(id: live, historicalFolds: historicalFolds)
            )
        }
    }
}
