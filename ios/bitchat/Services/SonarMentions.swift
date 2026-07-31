//
// SonarMentions.swift
// Composer-side `@mention` logic for Marmot group chats.
//
// This is the *authoring* half only. Deciding whether a received message
// mentions you, and where its spans are, belongs to the Rust core
// (`sonarParseMentions` / `sonarMentionsPubkey`) — exactly one decoder reads
// message content, the same rule `MessageClassification` follows (R-017 in
// docs/REGRESSIONS.md). Nothing here parses an incoming message.
//
// Mirrors `apps/sonar/.../Mentions.kt`; keep the two in step.
//

import Foundation
import SwiftUI

/// What a tapped `@mention` should do, injected once per screen.
///
/// An environment value rather than a parameter because the bubble sits three
/// view layers below the screen that owns navigation, and threading a closure
/// through every transcript host is exactly the kind of call-site plumbing that
/// gets forgotten on one path (see R-001 in `docs/REGRESSIONS.md`).
private struct SNMentionTapKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    var snMentionTap: ((String) -> Void)? {
        get { self[SNMentionTapKey.self] }
        set { self[SNMentionTapKey.self] = newValue }
    }
}

/// One `@mention` located inside message content by the Rust core.
///
/// `start`/`end` are UTF-16 offsets, which is what `NSRange` and
/// `String.Index(utf16Offset:in:)` both speak.
struct SNMentionSpan: Equatable, Hashable {
    let start: Int
    let end: Int
    let name: String
    let suffixHex4: String?

    var nsRange: NSRange { NSRange(location: start, length: max(0, end - start)) }
}

/// A group member the picker can offer. `suffixHex4` is the last 4 hex of their
/// public key, used to disambiguate two members sharing a display name.
struct SNMentionCandidate: Equatable, Hashable, Identifiable {
    let npub: String
    let name: String
    let suffixHex4: String?

    var id: String { npub }
}

/// A mention paired with the group member it names. `npub` is nil when the name
/// answers to nobody in this group — a hand-typed mention, an ambiguous bare
/// name, or a member who has since renamed.
struct SNResolvedMention: Equatable, Hashable {
    let span: SNMentionSpan
    let npub: String?
}

/// Per-conversation inputs to mention decoding: who can be mentioned, and who
/// "me" is. Built once per transcript page rather than per row — resolving the
/// roster costs a bech32 decode per member.
struct SNMentionContext {
    let roster: [SNMentionCandidate]
    let myPubkeyHex: String?
    let myNickname: String?

    static let empty = SNMentionContext(roster: [], myPubkeyHex: nil, myNickname: nil)
}

/// Everything a transcript row needs to know about its mentions, decoded once
/// per message and cached by the caller — never recomputed per frame.
struct SNMentionInfo: Equatable, Hashable {
    let mentions: [SNResolvedMention]
    let mentionsMe: Bool

    static let empty = SNMentionInfo(mentions: [], mentionsMe: false)
    var isEmpty: Bool { mentions.isEmpty }
}

enum SNMentions {
    /// Cap on offered suggestions, matching the mesh composer's list.
    static let maxSuggestions = 5

    /// URL scheme a rendered mention links to. Intercepted by the bubble's own
    /// `OpenURLAction`, so it never reaches the system opener.
    static let scheme = "sonar-mention"

    static func url(forNpub npub: String) -> URL? {
        URL(string: "\(scheme)://\(npub)")
    }

    static func npub(fromURL url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        let host = url.host ?? ""
        return host.isEmpty ? nil : host
    }

    /// Normalize an npub (or an already-hex key) to lowercase 32-byte hex, the
    /// form the core's mention matching speaks.
    static func pubkeyHex(fromNpubOrHex value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 64, trimmed.allSatisfy(\.isHexDigit) {
            return trimmed.lowercased()
        }
        guard trimmed.hasPrefix("npub1"),
              let decoded = try? Bech32.decode(trimmed),
              decoded.hrp == "npub",
              decoded.data.count == 32 else { return nil }
        return decoded.data.map { String(format: "%02x", $0) }.joined()
    }

    /// Mirrors the core scanner's name class (`[\p{L}0-9_]`).
    private static func isNameChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    /// The `@token` currently being typed at the end of `draft`, without its
    /// `@`, or nil when the caret is not inside a mention.
    ///
    /// Returns an empty string for a lone trailing `@`, which opens the picker
    /// with the whole roster. Like the mesh composer, this assumes the caret
    /// sits at the end of the draft.
    static func activeQuery(_ draft: String) -> String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        // Same left boundary as the core scanner: start-of-text or whitespace,
        // so `a@b.com` never opens the picker.
        if at > draft.startIndex {
            let before = draft[draft.index(before: at)]
            if !before.isWhitespace { return nil }
        }
        let token = draft[draft.index(after: at)...]
        guard token.allSatisfy(isNameChar) else { return nil }
        return String(token)
    }

    /// Roster members whose name starts with the active query, case-insensitively.
    /// Empty when the caret is not in a mention, so callers can treat emptiness
    /// as "hide the picker".
    static func matches(
        draft: String,
        roster: [SNMentionCandidate],
        limit: Int = maxSuggestions
    ) -> [SNMentionCandidate] {
        guard let query = activeQuery(draft) else { return [] }
        let needle = query.lowercased()
        return roster
            .filter { !$0.name.isEmpty && $0.name.lowercased().hasPrefix(needle) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
            .prefix(limit)
            .map { $0 }
    }

    /// True when `pick` shares a display name with another roster member, so the
    /// inserted token must carry the `#abcd` disambiguator.
    static func needsSuffix(_ pick: SNMentionCandidate, roster: [SNMentionCandidate]) -> Bool {
        roster.contains { $0.npub != pick.npub && $0.name.lowercased() == pick.name.lowercased() }
    }

    /// The text a picked suggestion contributes: `@name`, or `@name#abcd` when
    /// the name alone is ambiguous within this group.
    ///
    /// Bare is preferred for readability and parity with the mesh composer. The
    /// cost is that a bare mention stops resolving if that member renames — the
    /// documented trade-off of keeping the wire plain text.
    static func token(_ pick: SNMentionCandidate, roster: [SNMentionCandidate]) -> String {
        if let suffix = pick.suffixHex4, needsSuffix(pick, roster: roster) {
            return "@\(pick.name)#\(suffix)"
        }
        return "@\(pick.name)"
    }

    /// `draft` with the active `@token` replaced by `pick`'s mention plus a
    /// trailing space. Returns `draft` unchanged when the caret is not inside a
    /// mention, so a stale tap cannot corrupt the draft.
    static func applyPick(
        draft: String,
        pick: SNMentionCandidate,
        roster: [SNMentionCandidate]
    ) -> String {
        guard activeQuery(draft) != nil, let at = draft.lastIndex(of: "@") else { return draft }
        return String(draft[draft.startIndex..<at]) + token(pick, roster: roster) + " "
    }

    /// The group member a rendered mention points at, or nil when the name
    /// answers to nobody. Suffix form wins: it is derived from the key.
    static func target(for span: SNMentionSpan, roster: [SNMentionCandidate]) -> SNMentionCandidate? {
        if let suffix = span.suffixHex4 {
            return roster.first { $0.suffixHex4 == suffix }
        }
        let hits = roster.filter { $0.name.lowercased() == span.name.lowercased() }
        // An ambiguous bare name resolves to nobody rather than to a coin flip.
        return hits.count == 1 ? hits[0] : nil
    }
}
