//
// SonarMentionsTests.swift
// bitchatTests
//
// Mirrors apps/sonar/.../MentionsTest.kt. Keep the two in step — the Kotlin
// side is the one that runs in CI (iOS tests do not; see docs/REGRESSIONS.md),
// so a rule that only holds here is effectively unguarded.
//

import Foundation
import Testing
@testable import Sonar

struct SonarMentionsTests {

    private let vincenzo = SNMentionCandidate(npub: "npub1aaa", name: "vincenzo", suffixHex4: "0011")
    private let vincenzoTwin = SNMentionCandidate(npub: "npub1bbb", name: "Vincenzo", suffixHex4: "beef")
    private let giulia = SNMentionCandidate(npub: "npub1ccc", name: "giulia", suffixHex4: "c0de")

    private var uniqueRoster: [SNMentionCandidate] { [vincenzo, giulia] }
    private var ambiguousRoster: [SNMentionCandidate] { [vincenzo, vincenzoTwin, giulia] }

    @Test("no @ means the picker stays closed")
    func noActiveQuery() {
        #expect(SNMentions.activeQuery("hello there") == nil)
        #expect(SNMentions.activeQuery("") == nil)
    }

    @Test("a trailing @ opens the picker with the whole roster")
    func trailingAtOpensPicker() {
        #expect(SNMentions.activeQuery("hey @") == "")
        #expect(SNMentions.matches(draft: "hey @", roster: uniqueRoster).count == 2)
    }

    @Test("an email never opens the picker")
    func emailDoesNotOpenPicker() {
        #expect(SNMentions.activeQuery("write to alice@example") == nil)
        #expect(SNMentions.matches(draft: "write to alice@example", roster: uniqueRoster).isEmpty)
    }

    @Test("the query ends when the mention does")
    func queryStopsAtNonNameCharacter() {
        #expect(SNMentions.activeQuery("hey @vincenzo how are you") == nil)
    }

    @Test("matching is prefixed and case-insensitive")
    func matchesArePrefixedAndCaseInsensitive() {
        let hits = SNMentions.matches(draft: "hey @VIN", roster: uniqueRoster)
        #expect(hits.map(\.name) == ["vincenzo"])
    }

    @Test("suggestions are capped")
    func matchesAreCapped() {
        let roster = (1...10).map { SNMentionCandidate(npub: "npub\($0)", name: "user\($0)", suffixHex4: "000\($0)") }
        #expect(SNMentions.matches(draft: "@user", roster: roster).count == SNMentions.maxSuggestions)
    }

    @Test("a unique name inserts a bare mention")
    func uniqueNameInsertsBare() {
        #expect(!SNMentions.needsSuffix(vincenzo, roster: uniqueRoster))
        #expect(SNMentions.token(vincenzo, roster: uniqueRoster) == "@vincenzo")
        #expect(SNMentions.applyPick(draft: "hey @vin", pick: vincenzo, roster: uniqueRoster) == "hey @vincenzo ")
    }

    @Test("a duplicated name inserts the disambiguating suffix")
    func duplicateNameInsertsSuffix() {
        #expect(SNMentions.needsSuffix(vincenzo, roster: ambiguousRoster))
        #expect(SNMentions.token(vincenzo, roster: ambiguousRoster) == "@vincenzo#0011")
        #expect(SNMentions.token(vincenzoTwin, roster: ambiguousRoster) == "@Vincenzo#beef")
    }

    @Test("duplicate detection ignores case")
    func duplicateDetectionIgnoresCase() {
        #expect(SNMentions.needsSuffix(vincenzoTwin, roster: ambiguousRoster))
    }

    @Test("a pick outside a mention leaves the draft alone")
    func staleePickDoesNotCorruptDraft() {
        let draft = "already sent @vincenzo ok"
        #expect(SNMentions.applyPick(draft: draft, pick: vincenzo, roster: uniqueRoster) == draft)
    }

    @Test("a name with a space is forced to carry its key")
    func nameWithSpaceCarriesKey() {
        // Display names are free text. Emitting "@John Doe" would put "@John" on
        // the wire — the scanner stops at the space — and resolve to nobody, so
        // the token is truncated to the wire-legal run AND carries the suffix,
        // which resolves by key regardless of the name.
        let john = SNMentionCandidate(npub: "npub1ddd", name: "John Doe", suffixHex4: "d0e5")
        let roster = [john, giulia]
        #expect(SNMentions.token(john, roster: roster) == "@John#d0e5")
        #expect(SNMentions.applyPick(draft: "hey @Jo", pick: john, roster: roster) == "hey @John#d0e5 ")
    }

    @Test("a name with no wire-legal run is not offered")
    func nameWithoutWireLegalRunIsNotOffered() {
        let emoji = SNMentionCandidate(npub: "npub1fff", name: "🎉 party", suffixHex4: "beef")
        #expect(SNMentions.matches(draft: "@", roster: [emoji]).isEmpty)
    }

    @Test("an unambiguous plain name still inserts bare")
    func unambiguousPlainNameStaysBare() {
        // The truncation rule must not drag every mention into the suffix form.
        #expect(SNMentions.token(vincenzo, roster: uniqueRoster) == "@vincenzo")
    }

    @Test("the suffix form resolves regardless of the name")
    func suffixFormResolves() {
        let span = SNMentionSpan(start: 0, end: 14, name: "whoever", suffixHex4: "0011")
        #expect(SNMentions.target(for: span, roster: ambiguousRoster)?.npub == vincenzo.npub)
    }

    @Test("an ambiguous bare name resolves to nobody")
    func ambiguousBareNameResolvesToNobody() {
        let span = SNMentionSpan(start: 0, end: 9, name: "vincenzo", suffixHex4: nil)
        #expect(SNMentions.target(for: span, roster: ambiguousRoster) == nil)
        #expect(SNMentions.target(for: span, roster: uniqueRoster)?.npub == vincenzo.npub)
    }

    @Test("mention links round-trip through the custom scheme")
    func mentionURLRoundTrips() {
        let url = SNMentions.url(forNpub: "npub1aaa")
        #expect(url != nil)
        #expect(SNMentions.npub(fromURL: url!) == "npub1aaa")
        // A real link must fall through to the system opener untouched.
        #expect(SNMentions.npub(fromURL: URL(string: "https://example.com")!) == nil)
    }

    // MARK: - Parity with the core scanner

    @Test("the core scanner agrees with the shipped mesh regex on ordinary mentions")
    func coreScannerMatchesLegacyRegexOnOrdinaryInput() {
        // The two decoders must agree everywhere except the documented
        // left-boundary fix, which the corpus below deliberately excludes.
        let corpus = [
            "hey @alice",
            "@alice and @bob are chatting with @charlie",
            "Hey @alice#a1b2 check this out",
            "Thanks @user_name_123",
            "Hello @日本語 and @émile",
            "no mentions here at all",
        ]
        for content in corpus {
            let core = MessageFormattingEngine.extractMentions(from: content)
            let legacy = Self.legacyRegexMentions(content)
            #expect(core == legacy, "disagreement on: \(content)")
        }
    }

    /// The pre-core extraction, kept here so the parity test has something to
    /// compare against after the production path moved to Rust.
    private static func legacyRegexMentions(_ content: String) -> [String] {
        let ns = content as NSString
        let range = NSRange(location: 0, length: ns.length)
        return MessageFormattingEngine.Patterns.mention
            .matches(in: content, options: [], range: range)
            .compactMap { match in
                guard match.numberOfRanges > 1,
                      let r = Range(match.range(at: 1), in: content) else { return nil }
                return String(content[r])
            }
    }
}
