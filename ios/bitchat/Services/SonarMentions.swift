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
    /// Live Bluetooth route to this member, for the picker via-chip.
    let inRange: Bool

    var id: String { npub }

    init(npub: String, name: String, suffixHex4: String?, inRange: Bool = false) {
        self.npub = npub
        self.name = name
        self.suffixHex4 = suffixHex4
        self.inRange = inRange
    }
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

    /// Broadcast token from the design picker (`@everyone`).
    static let everyone = "everyone"

    /// Own-bubble mention chip fill: `rgba(255,255,255,0.26)` in theme.css.
    static let onOwnFill = Color.white.opacity(0.26)

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

    /// The part of a display name that can survive on the wire.
    ///
    /// A kind-0 name is free text — "John Doe", "alice (work)" — but the wire
    /// grammar stops at the first character outside the name class. Emitting
    /// `@John Doe` would put `@John` on the wire and resolve to nobody, so the
    /// token is built from this leading run instead, and a truncated name is
    /// forced to carry the `#abcd` suffix so it still resolves by key.
    static func wireName(_ name: String) -> String {
        String(name.prefix(while: isNameChar))
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
            .filter { isMentionable($0, roster: roster) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
            .prefix(limit)
            .map { $0 }
    }

    /// Whether a member can be written as a mention that will actually resolve.
    ///
    /// Two ways it cannot: the name has no leading run of wire-legal characters
    /// ("🎉 party"), so there is no token to build; or the name needs the `#abcd`
    /// key to identify its owner — it collides, or it had to be truncated — but
    /// the member has no usable key (an npub that would not parse). Offering
    /// either produces a mention that silently resolves to nobody, which reads to
    /// the sender as "I mentioned them" and to the recipient as nothing at all.
    static func isMentionable(_ pick: SNMentionCandidate, roster: [SNMentionCandidate]) -> Bool {
        let name = wireName(pick.name)
        if name.isEmpty { return false }
        let needsKey = needsSuffix(pick, roster: roster) || name != pick.name
        return !needsKey || pick.suffixHex4 != nil
    }

    /// True when the inserted token must carry the `#abcd` disambiguator.
    ///
    /// Either another roster member answers to the same display name, or the
    /// wire name is the reserved broadcast token `everyone` — a bare `@everyone`
    /// names the whole group (see `mentions_pubkey`), so a person who happens
    /// to be called that has to go out in the suffix form.
    static func needsSuffix(_ pick: SNMentionCandidate, roster: [SNMentionCandidate]) -> Bool {
        if wireName(pick.name).lowercased() == everyone { return true }
        return roster.contains { $0.npub != pick.npub && $0.name.lowercased() == pick.name.lowercased() }
    }

    /// The text a picked suggestion contributes: `@name`, or `@name#abcd` when
    /// the name alone is ambiguous within this group.
    ///
    /// Bare is preferred for readability and parity with the mesh composer. The
    /// cost is that a bare mention stops resolving if that member renames — the
    /// documented trade-off of keeping the wire plain text.
    static func token(_ pick: SNMentionCandidate, roster: [SNMentionCandidate]) -> String {
        let name = wireName(pick.name)
        // The suffix is required when the name alone cannot identify the member:
        // either another member answers to it, or it had to be truncated to fit
        // the wire grammar and so no longer equals the sender's display name.
        let needsKey = needsSuffix(pick, roster: roster) || name != pick.name
        if let suffix = pick.suffixHex4, needsKey {
            return "@\(name)#\(suffix)"
        }
        return "@\(name)"
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

    /// True when the design's `@everyone` row should appear: the active query
    /// is a prefix of `everyone` (including a lone `@`).
    static func showsEveryone(_ draft: String) -> Bool {
        guard let query = activeQuery(draft) else { return false }
        return everyone.hasPrefix(query.lowercased())
    }

    /// `draft` with the active `@token` replaced by `@everyone `.
    static func applyEveryone(_ draft: String) -> String {
        guard activeQuery(draft) != nil, let at = draft.lastIndex(of: "@") else { return draft }
        return String(draft[draft.startIndex..<at]) + "@\(everyone) "
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
