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
    struct Prefs: Equatable {
        var showNames: Bool
        var showPreview: Bool
    }

    struct Input: Equatable {
        var senderRaw: String
        var groupName: String
        var contentPreview: String
    }

    struct Output: Equatable {
        var title: String
        var body: String
    }

    /// Drop placeholder 1:1 names so the banner title is the peer, not
    /// "hex… in Sonar agent DM".
    static func meaningfulGroupName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        let placeholders: Set<String> = [
            "sonar agent dm",
            "dm",
            "direct message",
            "new chat",
        ]
        if placeholders.contains(lowered) { return nil }
        return trimmed
    }

    /// Local-only sender label — never hits relays from the NSE.
    /// Hex pubkeys without a kind-0 cache use a short fingerprint (not the
    /// opaque "New message" string that looked like a second generic banner
    /// next to the host's named local notification).
    static func senderLabel(for raw: String) -> String? {
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

    /// Match SonarLocalNotificationRouter privacy: when names are off, never
    /// surface sender or group strings on the lock screen.
    static func render(input: Input, prefs: Prefs) -> Output {
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
        let sender = senderLabel(for: input.senderRaw)
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
