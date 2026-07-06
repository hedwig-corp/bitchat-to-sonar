//
// MessageTextHelpers.swift
// Shared text parsing helpers for message rendering.
//

import Foundation
import SwiftUI

enum SonarMessageTextFormatter {
    private enum MatchKind {
        case link(URL?)
        case mention
    }

    private struct TextMatch {
        let range: Range<String.Index>
        let kind: MatchKind
        let priority: Int
    }

    static func attributedBubbleText(
        _ text: String,
        baseColor: Color,
        linkColor: Color? = nil,
        mentionFont: Font? = nil,
        detectBareDomains: Bool = false,
        includeLinkAttributes: Bool = true
    ) -> AttributedString {
        let matches = textMatches(in: text, mentionFont: mentionFont, detectBareDomains: detectBareDomains)
        var result = AttributedString()
        var cursor = text.startIndex

        for match in matches {
            guard match.range.lowerBound >= cursor else { continue }
            append(text[cursor..<match.range.lowerBound], to: &result, color: baseColor)
            append(text[match.range], to: &result, color: baseColor) { segment in
                switch match.kind {
                case .link(let url):
                    segment.underlineStyle = .single
                    segment.foregroundColor = linkColor ?? baseColor
                    if includeLinkAttributes {
                        segment.link = url
                    }
                case .mention:
                    if let mentionFont {
                        segment.font = mentionFont
                    }
                }
            }
            cursor = match.range.upperBound
        }

        append(text[cursor..<text.endIndex], to: &result, color: baseColor)
        return result
    }

    private static func textMatches(in text: String, mentionFont: Font?, detectBareDomains: Bool) -> [TextMatch] {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        guard nsText.length > 0 else { return [] }

        var matches: [TextMatch] = []
        if (detectBareDomains || text.contains("://") || text.localizedCaseInsensitiveContains("www.")),
           let detector = MessageFormattingEngine.Patterns.linkDetector {
            for match in detector.matches(in: text, options: [], range: fullRange) {
                appendMatch(match.range, kind: .link(match.url), priority: 0, in: text, to: &matches)
            }
        }

        if mentionFont != nil, text.contains("@") {
            for match in MessageFormattingEngine.Patterns.mention.matches(in: text, options: [], range: fullRange) {
                appendMatch(match.range(at: 0), kind: .mention, priority: 1, in: text, to: &matches)
            }
        }

        return matches.sorted {
            if $0.range.lowerBound == $1.range.lowerBound {
                return $0.priority < $1.priority
            }
            return $0.range.lowerBound < $1.range.lowerBound
        }
    }

    private static func appendMatch(
        _ nsRange: NSRange,
        kind: MatchKind,
        priority: Int,
        in text: String,
        to matches: inout [TextMatch]
    ) {
        let nsText = text as NSString
        guard nsRange.location != NSNotFound,
              nsRange.length > 0,
              NSMaxRange(nsRange) <= nsText.length,
              let range = Range(nsRange, in: text),
              !matches.contains(where: { rangesOverlap($0.range, range) }) else {
            return
        }
        matches.append(TextMatch(range: range, kind: kind, priority: priority))
    }

    private static func rangesOverlap(_ lhs: Range<String.Index>, _ rhs: Range<String.Index>) -> Bool {
        lhs.lowerBound < rhs.upperBound && rhs.lowerBound < lhs.upperBound
    }

    private static func append(
        _ text: Substring,
        to result: inout AttributedString,
        color: Color,
        configure: ((inout AttributedString) -> Void)? = nil
    ) {
        guard !text.isEmpty else { return }
        var segment = AttributedString(String(text))
        segment.foregroundColor = color
        configure?(&segment)
        result.append(segment)
    }
}

extension String {
    // Detect if there is an extremely long token (no whitespace/newlines) that could break layout
    func hasVeryLongToken(threshold: Int) -> Bool {
        var current = 0
        for ch in self {
            if ch.isWhitespace || ch.isNewline {
                if current >= threshold { return true }
                current = 0
            } else {
                current += 1
                if current >= threshold { return true }
            }
        }
        return current >= threshold
    }

    // Extract up to `max` Cashu tokens (cashuA/cashuB). Allow dot '.' and shorter lengths.
    func extractCashuLinks(max: Int = 3) -> [String] {
        let regex = MessageFormattingEngine.Patterns.cashu
        let ns = self as NSString
        let range = NSRange(location: 0, length: ns.length)
        var found: [String] = []
        for m in regex.matches(in: self, range: range) {
            if m.numberOfRanges > 0 {
                let token = ns.substring(with: m.range(at: 0))
                let enc = token.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? token
                found.append("cashu:\(enc)")
                if found.count >= max { break }
            }
        }
        return found
    }

    // Extract Lightning payloads (scheme, BOLT11, LNURL). Returned as lightning:<payload>
    func extractLightningLinks(max: Int = 3) -> [String] {
        var results: [String] = []
        let ns = self as NSString
        let full = NSRange(location: 0, length: ns.length)
        // lightning: scheme
        for m in MessageFormattingEngine.Patterns.lightningScheme.matches(in: self, range: full) {
            let s = ns.substring(with: m.range(at: 0))
            results.append(s)
            if results.count >= max { return results }
        }
        // BOLT11
        for m in MessageFormattingEngine.Patterns.bolt11.matches(in: self, range: full) {
            let s = ns.substring(with: m.range(at: 0))
            results.append("lightning:\(s)")
            if results.count >= max { return results }
        }
        // LNURL bech32
        for m in MessageFormattingEngine.Patterns.lnurl.matches(in: self, range: full) {
            let s = ns.substring(with: m.range(at: 0))
            results.append("lightning:\(s)")
            if results.count >= max { return results }
        }
        return results
    }
}
