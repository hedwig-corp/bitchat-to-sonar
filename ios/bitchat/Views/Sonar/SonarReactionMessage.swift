//
// SonarReactionMessage.swift
// bitchat
//
// ⚡REACT: emoji reactions for mesh (BLE) chats, riding normal encrypted chat
// content like ⚡PAY (SonarPayLedger.swift). Marmot chats use real NIP-25
// kind-7 events in the Rust core instead; this codec exists only for
// transports with no Nostr events.
//
//   ⚡REACT|1|<targetMessageId>|<emoji>|<add|remove>
//
// Lines persist with the transcript like any message and are folded into the
// target message's aggregate at render time (last-write-wins per sender, one
// reaction per person — Signal tapback semantics). Old peers render the line
// as plain text — the same accepted forward-compat as ⚡PAY.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// One ⚡REACT control line. Field separator is `|`.
enum SonarReactionMessage: Equatable {

    private static let reactPrefix = "\u{26A1}REACT|"
    /// Emoji payload cap: a single emoji, at most this many unicode scalars
    /// (flags/ZWJ sequences are several scalars each).
    static let maxEmojiScalars = 16

    /// Set (or replace) the sender's reaction on the target message.
    case add(targetId: String, emoji: String)
    /// Clear the sender's reaction (emoji names what is being removed).
    case remove(targetId: String, emoji: String)

    var targetId: String {
        switch self {
        case .add(let id, _), .remove(let id, _): return id
        }
    }

    var emoji: String {
        switch self {
        case .add(_, let emoji), .remove(_, let emoji): return emoji
        }
    }

    func encoded() -> String {
        switch self {
        case .add(let id, let emoji):
            return "\(Self.reactPrefix)1|\(id)|\(emoji)|add"
        case .remove(let id, let emoji):
            return "\(Self.reactPrefix)1|\(id)|\(emoji)|remove"
        }
    }

    /// Cheap prefilter so hot paths (previews, folds) skip the full decode
    /// for ordinary chat lines.
    static func isReactionLine(_ text: String) -> Bool {
        text.hasPrefix(reactPrefix)
    }

    /// Decode a ⚡REACT control line. Unknown versions or malformed fields
    /// return nil and the line falls through as plain text.
    static func decode(_ text: String) -> SonarReactionMessage? {
        guard text.hasPrefix(reactPrefix) else { return nil }
        let rest = text.dropFirst(reactPrefix.count)
        let parts = rest.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 4,
              Int(parts[0]) == 1,
              isValidTargetID(parts[1]),
              let emoji = validatedEmoji(parts[2])
        else { return nil }
        switch parts[3] {
        case "add": return .add(targetId: String(parts[1]), emoji: emoji)
        case "remove": return .remove(targetId: String(parts[1]), emoji: emoji)
        default: return nil
        }
    }

    /// Trimmed, non-empty, and at most `maxEmojiScalars` unicode scalars.
    static func validatedEmoji(_ raw: Substring) -> String? {
        let emoji = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !emoji.isEmpty, emoji.unicodeScalars.count <= maxEmojiScalars,
              !emoji.contains("|")
        else { return nil }
        return emoji
    }

    private static func isValidTargetID(_ s: Substring) -> Bool {
        !s.isEmpty && s.count <= 64 && s.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    // MARK: - Transcript folding

    /// A ⚡REACT line that arrived on ANOTHER transport leg (e.g. the Marmot
    /// fallback when the peer is out of BLE range) but references a mesh
    /// message id. Applied after the mesh leg's own lines, ordered by date.
    struct ExternalLine {
        let date: Date
        let line: SonarReactionMessage
        let mine: Bool
        /// Stable per-sender key (e.g. npub) for last-write-wins folding.
        let senderKey: String
    }

    /// Fold a stored mesh transcript into its visible form: ⚡REACT control
    /// lines are removed from the rendered list and aggregated (in arrival
    /// order, last-write-wins per sender) into each target message's
    /// `reactions`. Runs in the data layer, never in SwiftUI view bodies.
    static func fold(
        _ messages: [BitchatMessage],
        myPeerID: PeerID?,
        externalLines: [ExternalLine] = []
    ) -> [BitchatMessage] {
        var visible: [BitchatMessage] = []
        visible.reserveCapacity(messages.count)
        // Current reaction per (target message id, sender key).
        var current: [String: [String: (emoji: String, mine: Bool)]] = [:]
        for message in messages {
            guard let line = decode(message.content) else {
                visible.append(message)
                continue
            }
            let mine = myPeerID != nil && message.senderPeerID == myPeerID
            // A local reaction send that FAILED must not fold: the peer never
            // got it, so showing the chip would lie. (Pending/sent lines fold
            // optimistically like normal local echoes.)
            if mine, case .failed = message.deliveryStatus { continue }
            let senderKey = mine ? "me" : (message.senderPeerID?.id ?? message.sender)
            apply(line, senderKey: senderKey, mine: mine, to: &current)
        }
        for external in externalLines.sorted(by: { $0.date < $1.date }) {
            // "me" folds cross-leg with the mesh key so my own toggle is one
            // slot regardless of which transport carried it.
            let senderKey = external.mine ? "me" : external.senderKey
            apply(external.line, senderKey: senderKey, mine: external.mine, to: &current)
        }
        // No early-out on "no reaction lines": BitchatMessage is a class and a
        // PREVIOUS fold may have set `reactions` on these same instances — if
        // the last line disappeared from the input (blocked sender, removed
        // fallback group, page window), the stale chip must clear below.
        for message in visible {
            let byEmoji = (current[message.id] ?? [:]).values
            var counts: [String: (count: Int, mine: Bool)] = [:]
            for entry in byEmoji {
                let prior = counts[entry.emoji] ?? (0, false)
                counts[entry.emoji] = (prior.count + 1, prior.mine || entry.mine)
            }
            // Match the core's ordering: count desc, then emoji asc.
            let aggregate = counts
                .map { MessageReaction(emoji: $0.key, count: $0.value.count, mine: $0.value.mine) }
                .sorted { $0.count == $1.count ? $0.emoji < $1.emoji : $0.count > $1.count }
            // BitchatMessage is a class: assign unconditionally so a removed
            // reaction also clears a previously folded aggregate.
            message.reactions = aggregate
        }
        return visible
    }

    /// Apply one REACT line to the per-(target, sender) fold state.
    private static func apply(
        _ line: SonarReactionMessage,
        senderKey: String,
        mine: Bool,
        to current: inout [String: [String: (emoji: String, mine: Bool)]]
    ) {
        switch line {
        case .add(let targetId, let emoji):
            current[targetId, default: [:]][senderKey] = (emoji, mine)
        case .remove(let targetId, let emoji):
            // Clear only when it names the sender's current reaction, so a
            // late-arriving remove never wipes a newer replacement.
            if current[targetId]?[senderKey]?.emoji == emoji {
                current[targetId]?[senderKey] = nil
            }
        }
    }

    /// The local user's current reaction emoji on `targetId`, from the stored
    /// transcript's REACT lines (nil = not currently reacting). Drives the
    /// toggle: same emoji again → remove, different emoji → replace.
    static func myCurrentReaction(in messages: [BitchatMessage], targetId: String, myPeerID: PeerID?) -> String? {
        var mine: String?
        for message in messages {
            guard myPeerID != nil && message.senderPeerID == myPeerID,
                  let line = decode(message.content),
                  line.targetId == targetId
            else { continue }
            switch line {
            case .add(_, let emoji): mine = emoji
            case .remove(_, let emoji): if mine == emoji { mine = nil }
            }
        }
        return mine
    }
}
