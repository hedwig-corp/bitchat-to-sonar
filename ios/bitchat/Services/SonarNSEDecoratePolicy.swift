//
// SonarNSEDecoratePolicy.swift
// bitchat
//
// Pure title/body policy for the Notification Service Extension hydrate path.
// Kept free of UniFFI / UserNotifications so bitchatTests can pin privacy and
// expire invariants without launching the appex.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

enum SonarNSEDecoratePolicy {
    /// Per acquire-loop sleeps (100ms). Host `closeNode` often needs >4s when
    /// UniFFI teardown is queued behind other work; too-short waits leave
    /// banners on the generic placeholder (`storeBusy`).
    static let storeLockRetryAttempts = 80 // ~8s first attempt
    /// Shorter flock wait on hydrate retries so 3× acquire + wake stays inside
    /// the ~30s NSE budget (80×100ms × 4 would alone exceed it).
    static let storeLockRetryAttemptsOnHydrateRetry = 30 // ~3s
    /// Outer hydrate retries when the flock stays busy (stuck host or prior NSE).
    static let storeBusyHydrateRetries = 3
    static let storeBusyHydrateRetrySleepNs: UInt64 = 400_000_000

    static func shouldRetryHydrateAfterStoreBusy(attempt: Int, maxAttempts: Int = storeBusyHydrateRetries) -> Bool {
        attempt < maxAttempts
    }

    static func storeLockRetryAttempts(forHydrateAttempt attempt: Int) -> Int {
        attempt <= 1 ? storeLockRetryAttempts : storeLockRetryAttemptsOnHydrateRetry
    }

    struct Prefs: Equatable {
        var showNames: Bool
        var showPreview: Bool
    }

    struct Input: Equatable {
        var senderRaw: String
        var groupName: String
        var contentPreview: String
        /// Kind-0 alias from the App Group mirror. Must be passed separately —
        /// stuffing it into `senderRaw` makes `senderLabel` truncate names
        /// longer than 16 chars as if they were npubs.
        var cachedBestName: String? = nil
    }

    struct Output: Equatable {
        var title: String
        var body: String
        /// Content classified as a ⚡TRILL nudge — the NSE must attach the
        /// distinct trill sound instead of the generic message sound.
        var isTrill: Bool = false
    }

    /// Drop placeholder 1:1 names so the banner title is the peer, not
    /// "hex… in Sonar agent DM".
    static func meaningfulGroupName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        // ONLY the locally-generated placeholder. `groupName` comes from the
        // remote group, so treating generic strings as "this is a DM" lets an
        // attacker name a group "New chat" to route it through the DM branch
        // of the mute lookup and suppress its killed-app banner for anyone who
        // muted a DM with the sender — and "New chat" is a name a real user
        // would type, so it is a false positive even without an attacker.
        let placeholders: Set<String> = ["sonar agent dm"]
        if placeholders.contains(lowered) { return nil }
        return trimmed
    }

    /// Local-only sender label — never hits relays from the NSE.
    /// Prefer a cached kind-0 `bestName` from the App Group mirror; otherwise
    /// hex pubkeys use a short fingerprint (not the opaque "New message"
    /// string that looked like a second generic banner next to the host's
    /// named local notification).
    static func senderLabel(for raw: String, cachedBestName: String? = nil) -> String? {
        if let cached = cachedBestName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !cached.isEmpty {
            return cached
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count == 64, trimmed.allSatisfy(\.isHexDigit) {
            return String(trimmed.prefix(8)) + "…"
        }
        if trimmed.count > 16 {
            return String(trimmed.prefix(12)) + "…"
        }
        return trimmed
    }

    /// userInfo marker: NSE finished a titled hydrate (host may replace).
    static let nseDecoratedUserInfoKey = "sonar.nseDecorated"
    /// userInfo marker: still the privacy placeholder (host may wipe).
    static let nsePlaceholderUserInfoKey = "sonar.nsePlaceholder"

    /// App Group mirror key for the per-chat mute map (written by
    /// `SonarChatMuteStore` as write-through; JSON-encoded `[String: Date]`).
    /// Single declaration — `SonarChatMuteStore.defaultsKey` aliases this.
    static let mutesUserDefaultsKey = "sonar.chat.mutes.v1"

    /// Equivalent lookup keys for one raw conversation key, so the check
    /// works whichever id shape a path carries (see docs/CHAT-TYPES.md):
    /// the raw key, a 64-hex fingerprint's canonical 16-hex short form, and
    /// a `marmot:<groupId>` route's bare group id (and vice versa).
    ///
    /// This is the ONE normalization both sides use — `SonarChatMuteStore`
    /// delegates here (this file is compiled by the app target too), so the
    /// store's writes and the appex's reads cannot drift. Keys are
    /// lowercased: every other hex comparison in the NSE lowercases first,
    /// and a mixed-case id must still match its mute, not fail open.
    static func normalizedMuteCandidates(_ rawKey: String) -> [String] {
        let raw = rawKey.lowercased()
        var keys = [raw]
        if raw.hasPrefix("marmot:") {
            keys.append(String(raw.dropFirst("marmot:".count)))
        } else if raw.count == 64, raw.allSatisfy(\.isHexDigit) {
            keys.append(String(raw.prefix(16)))
            keys.append("marmot:" + raw)
        }
        return keys
    }

    /// Lookup keys for one drained notification. The group key always
    /// counts; the sender key counts ONLY for a direct chat. `muteKeys` for
    /// a DM stores the peer's npub (and its 64-hex twin), so matching the
    /// sender unconditionally would let a muted DM with Alice silence every
    /// group message *from Alice* — the asymmetry the host refuses in
    /// `SonarPushProcessor` (sender-keyed check gated on no group name).
    /// Directness is judged with `meaningfulGroupName`, not `.isEmpty`,
    /// because `enrichEmptyContentPreviews` can backfill a DM with the
    /// "Sonar agent DM" placeholder.
    static func mutedLookupCandidates(
        groupIdHex: String,
        senderNpub: String,
        groupName: String
    ) -> [String] {
        var keys: [String] = []
        if !groupIdHex.isEmpty {
            keys += normalizedMuteCandidates(groupIdHex)
        }
        let isDirectChat = meaningfulGroupName(groupName) == nil
        if isDirectChat, !senderNpub.isEmpty {
            keys += normalizedMuteCandidates(senderNpub)
        }
        return keys
    }

    /// Decode the App Group mirror once per drain (not once per row).
    /// Missing/undecodable data reads as an empty map — mute must fail
    /// open, never suppress a wanted banner. Keys are lowercased to match
    /// `normalizedMuteCandidates`, merging duplicates on the later expiry.
    static func decodeMutes(_ mutesJSON: Data?) -> [String: Date] {
        guard let mutesJSON,
              let map = try? JSONDecoder().decode([String: Date].self, from: mutesJSON) else {
            return [:]
        }
        var lowered: [String: Date] = [:]
        lowered.reserveCapacity(map.count)
        for (key, until) in map {
            let k = key.lowercased()
            lowered[k] = max(lowered[k] ?? .distantPast, until)
        }
        return lowered
    }

    /// Pure per-chat mute check over the decoded App Group mirror. Expired
    /// entries read as unmuted (lazy removal stays the store's job).
    static func isMuted(
        groupIdHex: String,
        senderNpub: String,
        groupName: String,
        mutes: [String: Date],
        now: Date
    ) -> Bool {
        guard !mutes.isEmpty else { return false }
        return mutedLookupCandidates(
            groupIdHex: groupIdHex,
            senderNpub: senderNpub,
            groupName: groupName
        )
        .contains { key in (mutes[key] ?? .distantPast) > now }
    }

    /// Convenience overload over the raw mirror blob (tests / one-off checks).
    static func isMuted(
        groupIdHex: String,
        senderNpub: String,
        groupName: String,
        mutesJSON: Data?,
        now: Date
    ) -> Bool {
        isMuted(
            groupIdHex: groupIdHex,
            senderNpub: senderNpub,
            groupName: groupName,
            mutes: decodeMutes(mutesJSON),
            now: now
        )
    }

    /// Pure `⚡TRILL|1|<id>` check mirroring core `parse_trill_line` —
    /// version-locked, no trailing fields, hex-or-dash id (1-64 chars).
    static func isTrillLine(_ content: String) -> Bool {
        // Drain previews can arrive with a trailing newline — trim first or
        // classification misses and the raw line leaks onto the banner.
        let parts = content.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "\u{26A1}TRILL", parts[1] == "1" else { return false }
        let id = parts[2]
        guard (1...64).contains(id.count) else { return false }
        // ASCII-only: Character.isHexDigit also matches Unicode full-width
        // hex, which core's parser would reject (mismatch = raw line leaks).
        return id.utf8.allSatisfy { $0 == 0x2D || ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) || ($0 >= 0x41 && $0 <= 0x46) }
    }

    /// Match SonarLocalNotificationRouter privacy: when names are off, never
    /// surface sender or group strings on the lock screen.
    static func render(input: Input, prefs: Prefs) -> Output {
        // ⚡TRILL nudge: mirror core render_notification — never expose the raw
        // control line on the lock screen; the body is fixed (no content to preview).
        if isTrillLine(input.contentPreview) {
            let sender = prefs.showNames ? senderLabel(for: input.senderRaw, cachedBestName: input.cachedBestName) : nil
            let group = prefs.showNames ? meaningfulGroupName(input.groupName) : nil
            let title: String
            if let sender, let group, group != sender {
                title = "\(sender) nudged \(group)"
            } else if let sender {
                title = "\(sender) nudged you"
            } else if let group {
                title = "Nudge in \(group)"
            } else {
                title = "Someone nudged you"
            }
            return Output(
                title: title,
                body: "\u{1F44B} They want your attention.",
                isTrill: true
            )
        }
        let body: String
        if prefs.showPreview {
            let preview = input.contentPreview.trimmingCharacters(in: .whitespacesAndNewlines)
            body = preview.isEmpty ? "Open Sonar to read it." : preview
        } else {
            body = "Open Sonar to read it."
        }

        guard prefs.showNames else {
            return Output(title: "New Sonar message", body: body)
        }

        let groupName = meaningfulGroupName(input.groupName)
        let sender = senderLabel(
            for: input.senderRaw,
            cachedBestName: input.cachedBestName
        )
        let title: String
        if let groupName, let sender, groupName != sender {
            title = "\(sender) in \(groupName)"
        } else if let sender {
            title = sender
        } else if let groupName {
            title = groupName
        } else {
            title = "New Sonar message"
        }
        return Output(title: title, body: body)
    }

    /// Expire must keep a finished hydrate; only re-apply the privacy
    /// placeholder when the banner is still marked as one.
    static func shouldReapplyPlaceholderOnExpire(isPlaceholder: Bool) -> Bool {
        isPlaceholder
    }

    /// Diagnostics must never persist message plaintext in the App Group.
    static func diagnosticDecorated(
        showNames: Bool,
        showPreview: Bool,
        extras: Int,
        title: String,
        body: String
    ) -> String {
        "decorated:showNames=\(showNames):showPreview=\(showPreview):extras=\(extras):titleLen=\(title.count):bodyLen=\(body.count)"
    }

    static func diagnosticExpireKeepingDecorated(title: String, body: String) -> String {
        "expire:keepingDecorated titleLen=\(title.count) bodyLen=\(body.count)"
    }

    static func diagnosticFallbackUnread(count: Int) -> String {
        "emptyDrain:fallbackUnread count=\(count)"
    }

    /// Prefer a push-hinted group when present so unread fallback does not
    /// banner an unrelated stale tip.
    static func filterUnreadTips(
        groupIdHexes: [String],
        hintGroupIdHex: String?
    ) -> [String] {
        let hint = hintGroupIdHex?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let hint, !hint.isEmpty else { return groupIdHexes }
        let matched = groupIdHexes.filter { $0.lowercased() == hint }
        return matched.isEmpty ? groupIdHexes : matched
    }

    /// Among candidate unread tips (already hint-filtered), prefer rows that
    /// still carry preview text. Otherwise the lock screen shows a resolved
    /// alias with the privacy body ("Open Sonar to read it.") — the
    /// "Vincenzo Palazzo generic" report.
    static func preferTipsWithPreview(
        groupIdHexes: [String],
        previewByGroupIdHex: [String: String]
    ) -> [String] {
        let withPreview = groupIdHexes.filter { id in
            let preview = previewByGroupIdHex[id] ?? previewByGroupIdHex[id.lowercased()] ?? ""
            return !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return withPreview.isEmpty ? groupIdHexes : withPreview
    }

    /// Empty-drain / expire-placeholder: the generic banner stands in for the
    /// hinted chat. If that chat is muted, do not keep a sounding placeholder
    /// (R-022). Missing hint fails open — we must not silence an unmuted chat
    /// we cannot name. Does NOT skip hydrate: a wake can drain other groups.
    static func shouldSuppressGenericBanner(
        hintGroupIdHex: String?,
        mutes: [String: Date],
        now: Date = Date()
    ) -> Bool {
        guard let hint = hintGroupIdHex?.trimmingCharacters(in: .whitespacesAndNewlines),
              !hint.isEmpty else { return false }
        return isMuted(
            groupIdHex: hint,
            senderNpub: "",
            groupName: "group",
            mutes: mutes,
            now: now
        )
    }

    static func hintGroupIdHex(from userInfo: [AnyHashable: Any]) -> String? {
        let keys = ["group_id", "groupId", "group_id_hex", "gid", "conversation_id"]
        for key in keys {
            if let value = userInfo[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("marmot:") {
                    return String(trimmed.dropFirst("marmot:".count))
                }
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }
}
