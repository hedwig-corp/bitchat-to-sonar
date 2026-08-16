//
// MessageFormattingEngineTests.swift
// bitchatTests
//
// Tests for MessageFormattingEngine regex patterns and utility functions.
// This is free and unencumbered software released into the public domain.
//

import Testing
import Foundation
import SwiftUI
@testable import Sonar

struct MessageFormattingEngineTests {

    // MARK: - Mention Extraction Tests

    @Test func extractMentions_singleMention() {
        let content = "Hello @alice how are you?"
        let mentions = MessageFormattingEngine.extractMentions(from: content)
        #expect(mentions == ["alice"])
    }

    @Test func extractMentions_multipleMentions() {
        let content = "@alice and @bob are chatting with @charlie"
        let mentions = MessageFormattingEngine.extractMentions(from: content)
        #expect(mentions.count == 3)
        #expect(mentions.contains("alice"))
        #expect(mentions.contains("bob"))
        #expect(mentions.contains("charlie"))
    }

    @Test func extractMentions_mentionWithSuffix() {
        let content = "Hey @alice#a1b2 check this out"
        let mentions = MessageFormattingEngine.extractMentions(from: content)
        #expect(mentions == ["alice#a1b2"])
    }

    @Test func extractMentions_noMentions() {
        let content = "Just a regular message with no mentions"
        let mentions = MessageFormattingEngine.extractMentions(from: content)
        #expect(mentions.isEmpty)
    }

    @Test func extractMentions_unicodeNickname() {
        let content = "Hello @日本語 and @émile"
        let mentions = MessageFormattingEngine.extractMentions(from: content)
        #expect(mentions.count == 2)
        #expect(mentions.contains("日本語"))
        #expect(mentions.contains("émile"))
    }

    @Test func extractMentions_mentionWithUnderscore() {
        let content = "Thanks @user_name_123"
        let mentions = MessageFormattingEngine.extractMentions(from: content)
        #expect(mentions == ["user_name_123"])
    }

    @Test func extractMentions_emailNotCaptured() {
        // Email addresses are not mentions. This previously asserted the
        // opposite — the shipped regex had no left-boundary rule, so it
        // captured "example" out of an email and the test documented that as
        // "expected behavior". Extraction now runs through the Rust core
        // scanner, which requires start-of-text or whitespace before the `@`,
        // so the long-standing wart is gone.
        let content = "Contact me at test@example.com"
        let mentions = MessageFormattingEngine.extractMentions(from: content)
        #expect(mentions.isEmpty)
    }

    @Test func extractMentions_urlHandleNotCaptured() {
        // Same boundary rule: a profile URL is a link, not a mention.
        let content = "see https://njump.me/@bob"
        #expect(MessageFormattingEngine.extractMentions(from: content).isEmpty)
    }

    @Test func extractMentions_malformedSuffixFallsBackToBareName() {
        // `#abcd` counts only as exactly 4 hex; anything else stays part of a
        // bare mention rather than being half-swallowed.
        #expect(MessageFormattingEngine.extractMentions(from: "@alice#zzzz") == ["alice"])
        #expect(MessageFormattingEngine.extractMentions(from: "@alice#abc") == ["alice"])
        #expect(MessageFormattingEngine.extractMentions(from: "@alice#abcdef") == ["alice"])
    }

    // MARK: - Cashu Token Detection Tests

    @Test func containsCashuToken_validTokenA() {
        let content = "Here's a token: cashuAeyJwcm9vZnMiOiJIZWxsbyBXb3JsZCEgVGhpcyBpcyBhIHRlc3QgdG9rZW4i"
        #expect(MessageFormattingEngine.containsCashuToken(content))
    }

    @Test func containsCashuToken_validTokenB() {
        let content = "Payment: cashuBeyJwcm9vZnMiOiJIZWxsbyBXb3JsZCEgVGhpcyBpcyBhIHRlc3QgdG9rZW4i"
        #expect(MessageFormattingEngine.containsCashuToken(content))
    }

    @Test func containsCashuToken_noToken() {
        let content = "Just a regular message about cashews"
        #expect(!MessageFormattingEngine.containsCashuToken(content))
    }

    @Test func containsCashuToken_tooShort() {
        let content = "Invalid: cashuAshort"
        #expect(!MessageFormattingEngine.containsCashuToken(content))
    }

    // MARK: - Regex Pattern Tests

    @Test func hashtagPattern_standaloneHashtag() {
        let content = "#bitcoin is great"
        let nsContent = content as NSString
        let range = NSRange(location: 0, length: nsContent.length)
        let matches = MessageFormattingEngine.Patterns.hashtag.matches(in: content, options: [], range: range)
        #expect(matches.count == 1)
    }

    @Test func hashtagPattern_multipleHashtags() {
        let content = "#bitcoin #lightning #nostr"
        let nsContent = content as NSString
        let range = NSRange(location: 0, length: nsContent.length)
        let matches = MessageFormattingEngine.Patterns.hashtag.matches(in: content, options: [], range: range)
        #expect(matches.count == 3)
    }

    @Test func hashtagPattern_hashInMiddleOfWord() {
        let content = "test#notahashtag"
        let nsContent = content as NSString
        let range = NSRange(location: 0, length: nsContent.length)
        let matches = MessageFormattingEngine.Patterns.hashtag.matches(in: content, options: [], range: range)
        // This will match because the regex doesn't check for word boundaries
        #expect(matches.count == 1)
    }

    @Test func bolt11Pattern_mainnet() {
        let content = "Pay this: lnbc10u1pjexampleinvoice0000000000000000000000000000000000000000000"
        let nsContent = content as NSString
        let range = NSRange(location: 0, length: nsContent.length)
        let matches = MessageFormattingEngine.Patterns.bolt11.matches(in: content, options: [], range: range)
        #expect(matches.count == 1)
    }

    @Test func bolt11Pattern_testnet() {
        let content = "Test: lntb10u1pjexampleinvoice0000000000000000000000000000000000000000000"
        let nsContent = content as NSString
        let range = NSRange(location: 0, length: nsContent.length)
        let matches = MessageFormattingEngine.Patterns.bolt11.matches(in: content, options: [], range: range)
        #expect(matches.count == 1)
    }

    @Test func lnurlPattern_valid() {
        let content = "LNURL: lnurl1dp68gurn8ghj7um9wfmxjcm99e3k7mf0v9cxj0m385ekvcenxc6r2c35xvukxefcv5mkvv34x5ekzd3ev56nyd3hxqurzepexejxxepnxscrvwfnv9nxzcn9xq6xyefhvgcxxcmyxymnserx"
        let nsContent = content as NSString
        let range = NSRange(location: 0, length: nsContent.length)
        let matches = MessageFormattingEngine.Patterns.lnurl.matches(in: content, options: [], range: range)
        #expect(matches.count == 1)
    }

    @Test func lightningSchemePattern_valid() {
        let content = "Click: lightning:lnbc10u1example"
        let nsContent = content as NSString
        let range = NSRange(location: 0, length: nsContent.length)
        let matches = MessageFormattingEngine.Patterns.lightningScheme.matches(in: content, options: [], range: range)
        #expect(matches.count == 1)
    }

    @Test func cashuPattern_valid() {
        let content = "Token: cashuAeyJwcm9vZnMiOlt7ImlkIjoiMDAwMDAwMDAwMDAwMDAwMCJ9XX0="
        let nsContent = content as NSString
        let range = NSRange(location: 0, length: nsContent.length)
        let matches = MessageFormattingEngine.Patterns.cashu.matches(in: content, options: [], range: range)
        #expect(matches.count == 1)
    }

    // MARK: - URL Detection Tests

    @Test func linkDetector_httpURL() {
        let content = "Check out http://example.com"
        let nsContent = content as NSString
        let range = NSRange(location: 0, length: nsContent.length)
        let matches = MessageFormattingEngine.Patterns.linkDetector?.matches(in: content, options: [], range: range) ?? []
        #expect(matches.count == 1)
    }

    @Test func linkDetector_httpsURL() {
        let content = "Visit https://example.com/path?query=value"
        let nsContent = content as NSString
        let range = NSRange(location: 0, length: nsContent.length)
        let matches = MessageFormattingEngine.Patterns.linkDetector?.matches(in: content, options: [], range: range) ?? []
        #expect(matches.count == 1)
    }

    @Test func linkDetector_multipleURLs() {
        let content = "See https://a.com and http://b.com"
        let nsContent = content as NSString
        let range = NSRange(location: 0, length: nsContent.length)
        let matches = MessageFormattingEngine.Patterns.linkDetector?.matches(in: content, options: [], range: range) ?? []
        #expect(matches.count == 2)
    }

    @Test func attributedBubbleText_preservesUnicodeURLsAndMentions() {
        let content = "👋 @日本語 see https://example.com/path?q=é and ping @émile#a1b2"
        let attributed = SonarMessageTextFormatter.attributedBubbleText(
            content,
            baseColor: .primary,
            linkColor: .blue,
            mentionFont: .system(size: 16, weight: .semibold)
        )

        #expect(String(attributed.characters) == content)
        #expect(attributed.runs.contains { $0.link?.absoluteString.contains("example.com") == true })
    }

    @Test func attributedBubbleText_preservesEveryLinkTarget() {
        let content = "Compare https://first.example/path and www.second.example"
        let attributed = SonarMessageTextFormatter.attributedBubbleText(
            content,
            baseColor: .primary,
            linkColor: .blue,
            detectBareDomains: true
        )

        #expect(String(attributed.characters) == content)
        let links = attributed.runs.compactMap(\.link).map(\.absoluteString)
        #expect(links == ["https://first.example/path", "http://www.second.example"])
    }

    @Test func attributedBubbleText_canDetectBareDomainsWhenRequested() {
        let content = "Open example.org and wave to @alice"
        let attributed = SonarMessageTextFormatter.attributedBubbleText(
            content,
            baseColor: .primary,
            linkColor: .blue,
            detectBareDomains: true
        )

        #expect(String(attributed.characters) == content)
        #expect(attributed.runs.contains { $0.link?.absoluteString.contains("example.org") == true })
    }

    @Test func transcriptPreview_isGraphemeSafeAtSignalBoundary() {
        let family = "👨‍👩‍👧‍👦"
        let exact = String(repeating: family, count: 512)
        #expect(SonarTranscriptDisplayPolicy.preview(exact).isTruncated == false)

        let preview = SonarTranscriptDisplayPolicy.preview(exact + family)
        #expect(preview.isTruncated)
        #expect(preview.text.dropLast().count == 512)
        #expect(preview.text.hasSuffix(SonarTranscriptDisplayPolicy.ellipsis))
    }

    @Test func transcriptPreview_limitsNewlinesWithoutChangingFullText() {
        let full = (0...16).map { "line-\($0)" }.joined(separator: "\n")
        let preview = SonarTranscriptDisplayPolicy.preview(full)

        #expect(preview.isTruncated)
        #expect(preview.text.filter { $0.isNewline }.count == 15)
        #expect(full.contains("line-16"))
        #expect(!preview.text.contains("line-16"))
    }

    @Test func transcriptPreview_doesNotLinkifyCutURL() {
        let full = String(repeating: "x", count: 490) + " https://example.org/a-very-long-path"
        let preview = SonarTranscriptDisplayPolicy.preview(full)
        let attributed = SonarMessageTextFormatter.attributedBubbleText(
            preview.text,
            baseColor: .primary,
            linkColor: .blue,
            detectBareDomains: true,
            excludeLinkBeforeTrailingEllipsis: true
        )

        #expect(preview.isTruncated)
        #expect(!attributed.runs.contains { $0.link != nil })
    }

    // MARK: - String Extension Tests

    @Test func splitSuffix_withSuffix() {
        let name = "alice#a1b2"
        let (base, suffix) = name.splitSuffix()
        #expect(base == "alice")
        #expect(suffix == "#a1b2")
    }

    @Test func splitSuffix_withoutSuffix() {
        let name = "alice"
        let (base, suffix) = name.splitSuffix()
        #expect(base == "alice")
        #expect(suffix == "")
    }

    @Test func splitSuffix_withAtPrefix() {
        let name = "@alice#a1b2"
        let (base, suffix) = name.splitSuffix()
        #expect(base == "alice")
        #expect(suffix == "#a1b2")
    }

    @Test func hasVeryLongToken_noLongToken() {
        let content = "Short words only here"
        #expect(!content.hasVeryLongToken(threshold: 50))
    }

    @Test func hasVeryLongToken_withLongToken() {
        let longToken = String(repeating: "a", count: 100)
        let content = "Here is a \(longToken) token"
        #expect(content.hasVeryLongToken(threshold: 50))
    }

    @Test func hasVeryLongToken_exactThreshold() {
        let exactToken = String(repeating: "a", count: 50)
        let content = "Token: \(exactToken)"
        // Exactly at threshold DOES trigger (uses >= comparison)
        #expect(content.hasVeryLongToken(threshold: 50))
    }
}
