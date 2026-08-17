//
// MessageTextHelpers.swift
// Shared text parsing helpers for message rendering.
//

import Foundation
import SwiftUI

enum SonarMessageTextFormatter {
    private enum MatchKind {
        case link(URL?)
        /// `npub` is non-nil only when the mention resolves to a real group
        /// member, which is what makes it tappable.
        case mention(npub: String?)
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
        mentionColor: Color? = nil,
        mentions: [SNResolvedMention]? = nil,
        detectBareDomains: Bool = false,
        includeLinkAttributes: Bool = true,
        excludeLinkBeforeTrailingEllipsis: Bool = false
    ) -> AttributedString {
        let matches = textMatches(
            in: text,
            mentionStyled: mentionFont != nil,
            mentions: mentions,
            detectBareDomains: detectBareDomains,
            excludeLinkBeforeTrailingEllipsis: excludeLinkBeforeTrailingEllipsis
        )
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
                case .mention(let npub):
                    if let mentionFont {
                        segment.font = mentionFont
                    }
                    if let mentionColor {
                        segment.foregroundColor = mentionColor
                    }
                    // Only a mention that resolved to a member is tappable; an
                    // unresolved one still stands out, it just goes nowhere.
                    if let npub, let url = SNMentions.url(forNpub: npub) {
                        segment.link = url
                    }
                }
            }
            cursor = match.range.upperBound
        }

        append(text[cursor..<text.endIndex], to: &result, color: baseColor)
        return result
    }

    #if canImport(UIKit)
    /// UIKit sibling of `attributedBubbleText` for the pre-measured transcript
    /// cell. Same match scan, TextKit attributes: `.link` carries both URLs and
    /// `SNMentions` deep links so the cell can hit-test one attribute.
    static func nsAttributedBubbleText(
        _ text: String,
        font: UIFont,
        baseColor: UIColor,
        lineSpacing: CGFloat,
        lineBreakMode: NSLineBreakMode,
        linkColor: UIColor? = nil,
        mentionFont: UIFont? = nil,
        mentionColor: UIColor? = nil,
        mentions: [SNResolvedMention]? = nil,
        detectBareDomains: Bool = false,
        excludeLinkBeforeTrailingEllipsis: Bool = false
    ) -> NSAttributedString {
        let matches = textMatches(
            in: text,
            mentionStyled: mentionFont != nil,
            mentions: mentions,
            detectBareDomains: detectBareDomains,
            excludeLinkBeforeTrailingEllipsis: excludeLinkBeforeTrailingEllipsis
        )
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = lineBreakMode
        let base: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: baseColor,
            .paragraphStyle: paragraph,
        ]
        let result = NSMutableAttributedString()
        var cursor = text.startIndex

        for match in matches {
            guard match.range.lowerBound >= cursor else { continue }
            if cursor < match.range.lowerBound {
                result.append(NSAttributedString(string: String(text[cursor..<match.range.lowerBound]), attributes: base))
            }
            var attributes = base
            switch match.kind {
            case .link(let url):
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.foregroundColor] = linkColor ?? baseColor
                if let url { attributes[.link] = url }
            case .mention(let npub):
                if let mentionFont { attributes[.font] = mentionFont }
                if let mentionColor { attributes[.foregroundColor] = mentionColor }
                if let npub, let url = SNMentions.url(forNpub: npub) { attributes[.link] = url }
            }
            result.append(NSAttributedString(string: String(text[match.range]), attributes: attributes))
            cursor = match.range.upperBound
        }

        if cursor < text.endIndex {
            result.append(NSAttributedString(string: String(text[cursor...]), attributes: base))
        }
        return result
    }
    #endif

    private static func textMatches(
        in text: String,
        mentionStyled: Bool,
        mentions: [SNResolvedMention]?,
        detectBareDomains: Bool,
        excludeLinkBeforeTrailingEllipsis: Bool
    ) -> [TextMatch] {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        guard nsText.length > 0 else { return [] }

        var matches: [TextMatch] = []
        if (detectBareDomains || text.contains("://") || text.localizedCaseInsensitiveContains("www.")),
           let detector = MessageFormattingEngine.Patterns.linkDetector {
            for match in detector.matches(in: text, options: [], range: fullRange) {
                if excludeLinkBeforeTrailingEllipsis,
                   NSMaxRange(match.range) < nsText.length,
                   nsText.substring(from: NSMaxRange(match.range)) == SonarTranscriptDisplayPolicy.ellipsis {
                    continue
                }
                appendMatch(match.range, kind: .link(match.url), priority: 0, in: text, to: &matches)
            }
        }

        // Core-decoded spans win when supplied (Sonar/Marmot transcripts). The
        // regex branch stays for the mesh bubble, which has no group roster to
        // resolve against and only wants the bolder font.
        if let mentions {
            for mention in mentions {
                appendMatch(
                    mention.span.nsRange,
                    kind: .mention(npub: mention.npub),
                    priority: 1,
                    in: text,
                    to: &matches
                )
            }
        } else if mentionStyled, text.contains("@") {
            for match in MessageFormattingEngine.Patterns.mention.matches(in: text, options: [], range: fullRange) {
                appendMatch(match.range(at: 0), kind: .mention(npub: nil), priority: 1, in: text, to: &matches)
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

struct SonarTranscriptTextPreview: Equatable {
    let text: String
    let isTruncated: Bool
}

/// Signal-style cheap first render for long command output. Truncation walks
/// Swift `Character`s, so emoji and combining sequences are never split.
enum SonarTranscriptDisplayPolicy {
    static let ellipsis = "…"

    static func preview(
        _ text: String,
        maxGlyphs: Int = TransportConfig.sonarTranscriptPreviewGlyphCount,
        maxNewlines: Int = TransportConfig.sonarTranscriptPreviewNewlineCount
    ) -> SonarTranscriptTextPreview {
        guard maxGlyphs > 0, maxNewlines >= 0 else {
            return SonarTranscriptTextPreview(text: ellipsis, isTruncated: !text.isEmpty)
        }

        var rendered = String()
        rendered.reserveCapacity(min(text.utf8.count, maxGlyphs * 2))
        var glyphs = 0
        var newlines = 0
        var truncated = false

        for character in text {
            if glyphs >= maxGlyphs {
                truncated = true
                break
            }
            if character.isNewline {
                if newlines >= maxNewlines {
                    truncated = true
                    break
                }
                newlines += 1
            }
            rendered.append(character)
            glyphs += 1
        }

        guard truncated else {
            return SonarTranscriptTextPreview(text: text, isTruncated: false)
        }
        let trimmed = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
        return SonarTranscriptTextPreview(text: trimmed + ellipsis, isTruncated: true)
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
