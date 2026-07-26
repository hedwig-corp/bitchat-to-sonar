//
// SonarNSEDecoratePolicyTests.swift
// bitchatTests
//
// Pins NSE decorate privacy + expire invariants (production readiness for #381).
//

import Foundation
import Testing
@testable import Sonar

struct SonarNSEDecoratePolicyTests {

    @Test("showNames=false never surfaces sender or group on the title")
    func namesOffHidesGroupAndSender() {
        let out = SonarNSEDecoratePolicy.render(
            input: .init(
                senderRaw: "npub1aliceexamplexxxxxxxx",
                groupName: "Secret Ops",
                contentPreview: "classified"
            ),
            prefs: .init(showNames: false, showPreview: true)
        )
        #expect(out.title == "New Sonar message")
        #expect(out.body == "classified")
    }

    @Test("showPreview=false uses private body fallback")
    func previewOffHidesBody() {
        let out = SonarNSEDecoratePolicy.render(
            input: .init(
                senderRaw: "Alice",
                groupName: "Friends",
                contentPreview: "hello"
            ),
            prefs: .init(showNames: true, showPreview: false)
        )
        #expect(out.title == "Alice in Friends")
        #expect(out.body == "Open Sonar to read it.")
    }

    @Test("hex sender without profile uses short fingerprint (not New message)")
    func hexSenderLabel() {
        let hex = String(repeating: "ab", count: 32)
        #expect(SonarNSEDecoratePolicy.senderLabel(for: hex) == "abababab…")
        let out = SonarNSEDecoratePolicy.render(
            input: .init(senderRaw: hex, groupName: "Sonar agent DM", contentPreview: "hi"),
            prefs: .init(showNames: true, showPreview: true)
        )
        #expect(out.title == "abababab…")
        #expect(out.body == "hi")
    }

    @Test("cached kind-0 bestName wins over hex fingerprint")
    func cachedAliasWins() {
        let hex = String(repeating: "cd", count: 32)
        #expect(
            SonarNSEDecoratePolicy.senderLabel(for: hex, cachedBestName: "Alice") == "Alice"
        )
        let out = SonarNSEDecoratePolicy.render(
            input: .init(
                senderRaw: hex,
                groupName: "Sonar agent DM",
                contentPreview: "hi",
                cachedBestName: "Alice"
            ),
            prefs: .init(showNames: true, showPreview: true)
        )
        #expect(out.title == "Alice")
    }

    @Test("long kind-0 aliases are not truncated when passed via cachedBestName")
    func longAliasNotTruncated() {
        let hex = String(repeating: "ab", count: 32)
        let alias = "Vincenzo Palazzo Extended Name"
        #expect(alias.count > 16)
        let out = SonarNSEDecoratePolicy.render(
            input: .init(
                senderRaw: hex,
                groupName: "Sonar agent DM",
                contentPreview: "hi",
                cachedBestName: alias
            ),
            prefs: .init(showNames: true, showPreview: true)
        )
        #expect(out.title == alias)
        // Regression: stuffing alias into senderRaw used to truncate at 16.
        let truncated = SonarNSEDecoratePolicy.render(
            input: .init(senderRaw: alias, groupName: "", contentPreview: "hi"),
            prefs: .init(showNames: true, showPreview: true)
        )
        #expect(truncated.title != alias)
        #expect(truncated.title.hasSuffix("…"))
    }

    @Test("App Group profile name map resolves hex sender")
    func sharedProfileNamesResolveHex() {
        let hex = String(repeating: "ef", count: 32)
        let names = [hex: "Bob", hex.uppercased(): "Bob"]
        #expect(SonarSharedProfileNames.bestName(for: hex, in: names) == "Bob")
        #expect(SonarSharedProfileNames.bestName(for: hex.uppercased(), in: names) == "Bob")
        #expect(SonarSharedProfileNames.bestName(for: "unknown", in: names) == nil)
    }

    @Test("placeholder group names are dropped for 1:1 titles")
    func placeholderGroupDropped() {
        #expect(SonarNSEDecoratePolicy.meaningfulGroupName("Sonar agent DM") == nil)
        #expect(SonarNSEDecoratePolicy.meaningfulGroupName("Team Chat") == "Team Chat")
    }

    @Test("expire keeps decorated content when placeholder marker cleared")
    func expireKeepsDecorated() {
        #expect(
            SonarNSEDecoratePolicy.shouldReapplyPlaceholderOnExpire(isPlaceholder: false) == false
        )
        #expect(
            SonarNSEDecoratePolicy.shouldReapplyPlaceholderOnExpire(isPlaceholder: true) == true
        )
    }

    @Test("diagnostics never embed title/body plaintext")
    func diagnosticsAreOpaque() {
        let decorated = SonarNSEDecoratePolicy.diagnosticDecorated(
            showNames: true,
            showPreview: true,
            extras: 0,
            title: "SECRET TITLE",
            body: "SECRET BODY"
        )
        #expect(!decorated.contains("SECRET"))
        #expect(decorated.contains("titleLen=12"))
        #expect(decorated.contains("bodyLen=11"))

        let expire = SonarNSEDecoratePolicy.diagnosticExpireKeepingDecorated(
            title: "SECRET TITLE",
            body: "SECRET BODY"
        )
        #expect(!expire.contains("SECRET"))
    }

    @Test("unread fallback prefers push-hinted group when present")
    func unreadHintFilters() {
        let ids = ["aaa", "bbb", "ccc"]
        #expect(
            SonarNSEDecoratePolicy.filterUnreadTips(groupIdHexes: ids, hintGroupIdHex: "BBB")
                == ["bbb"]
        )
        #expect(
            SonarNSEDecoratePolicy.filterUnreadTips(groupIdHexes: ids, hintGroupIdHex: nil)
                == ids
        )
        #expect(
            SonarNSEDecoratePolicy.filterUnreadTips(groupIdHexes: ids, hintGroupIdHex: "zzz")
                == ids
        )
    }

    @Test("hintGroupIdHex reads common push payload keys")
    func hintFromUserInfo() {
        #expect(
            SonarNSEDecoratePolicy.hintGroupIdHex(from: ["group_id": "deadbeef"]) == "deadbeef"
        )
        #expect(
            SonarNSEDecoratePolicy.hintGroupIdHex(from: ["conversation_id": "marmot:abc"]) == "abc"
        )
    }

    @Test("storeBusy hydrate retries until the attempt budget is spent")
    func storeBusyRetryBudget() {
        #expect(SonarNSEDecoratePolicy.storeLockRetryAttempts >= 80)
        #expect(SonarNSEDecoratePolicy.storeBusyHydrateRetries <= 3)
        #expect(
            SonarNSEDecoratePolicy.storeLockRetryAttempts(forHydrateAttempt: 1)
                == SonarNSEDecoratePolicy.storeLockRetryAttempts
        )
        #expect(
            SonarNSEDecoratePolicy.storeLockRetryAttempts(forHydrateAttempt: 2)
                == SonarNSEDecoratePolicy.storeLockRetryAttemptsOnHydrateRetry
        )
        #expect(SonarNSEDecoratePolicy.shouldRetryHydrateAfterStoreBusy(attempt: 1))
        #expect(SonarNSEDecoratePolicy.shouldRetryHydrateAfterStoreBusy(attempt: 2))
        #expect(
            SonarNSEDecoratePolicy.shouldRetryHydrateAfterStoreBusy(
                attempt: SonarNSEDecoratePolicy.storeBusyHydrateRetries
            ) == false
        )
    }

    @Test("unread fallback prefers tips that still have preview text")
    func preferTipsWithPreview() {
        let ids = ["aaa", "bbb", "ccc"]
        let previews = ["aaa": "", "bbb": "hello", "ccc": "  "]
        #expect(
            SonarNSEDecoratePolicy.preferTipsWithPreview(
                groupIdHexes: ids,
                previewByGroupIdHex: previews
            ) == ["bbb"]
        )
        #expect(
            SonarNSEDecoratePolicy.preferTipsWithPreview(
                groupIdHexes: ids,
                previewByGroupIdHex: ["aaa": "", "bbb": "", "ccc": ""]
            ) == ids
        )
    }

    @Test("trill banner never exposes the raw TRILL line")
    func trillBannerHidesRawLine() {
        let out = SonarNSEDecoratePolicy.render(
            input: .init(senderRaw: "Alice", groupName: "", contentPreview: "\u{26A1}TRILL|1|deadbeef"),
            prefs: .init(showNames: true, showPreview: true)
        )
        #expect(out.title == "Alice nudged you")
        #expect(out.body == "\u{1F44B} They want your attention.")
        #expect(!out.body.contains("TRILL|"))
    }

    @Test("trill with group renders nudged-group title even with preview off")
    func trillGroupTitle() {
        let out = SonarNSEDecoratePolicy.render(
            input: .init(senderRaw: "Alice", groupName: "Lake Days", contentPreview: "\u{26A1}TRILL|1|abc-123"),
            prefs: .init(showNames: true, showPreview: false)
        )
        #expect(out.title == "Alice nudged Lake Days")
    }

    @Test("trill with names off never surfaces sender or group")
    func trillNamesOff() {
        let out = SonarNSEDecoratePolicy.render(
            input: .init(senderRaw: "Alice", groupName: "Secret Ops", contentPreview: "\u{26A1}TRILL|1|deadbeef"),
            prefs: .init(showNames: false, showPreview: true)
        )
        #expect(out.title == "Someone nudged you")
    }

    @Test("trill render marks isTrill so the NSE attaches the trill sound")
    func trillRenderMarksIsTrill() {
        let trill = SonarNSEDecoratePolicy.render(
            input: .init(senderRaw: "Alice", groupName: "", contentPreview: "\u{26A1}TRILL|1|deadbeef"),
            prefs: .init(showNames: true, showPreview: true)
        )
        #expect(trill.isTrill)
        // Names-off still classifies — the sound is not a privacy leak.
        let namesOff = SonarNSEDecoratePolicy.render(
            input: .init(senderRaw: "Alice", groupName: "", contentPreview: "\u{26A1}TRILL|1|deadbeef"),
            prefs: .init(showNames: false, showPreview: false)
        )
        #expect(namesOff.isTrill)
        let plain = SonarNSEDecoratePolicy.render(
            input: .init(senderRaw: "Alice", groupName: "", contentPreview: "hello"),
            prefs: .init(showNames: true, showPreview: true)
        )
        #expect(!plain.isTrill)
    }

    @Test("NSE mute check reads the App Group mirror shapes and honors expiry")
    func nseMuteCheck() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let gid = String(repeating: "ab", count: 32) // 64-hex group id
        let active = now.addingTimeInterval(3600)
        // marmot:-prefixed store key matches a bare 64-hex group id.
        let byGroup = try JSONEncoder().encode(["marmot:" + gid: active])
        #expect(SonarNSEDecoratePolicy.isMuted(
            groupIdHex: gid, senderNpub: "npub1x", mutesJSON: byGroup, now: now
        ))
        // 16-hex short-form store key matches too.
        let byShortForm = try JSONEncoder().encode([String(gid.prefix(16)): active])
        #expect(SonarNSEDecoratePolicy.isMuted(
            groupIdHex: gid, senderNpub: "", mutesJSON: byShortForm, now: now
        ))
        // Sender-keyed mutes (DM drain rows carry no group) match by npub.
        let bySender = try JSONEncoder().encode(["npub1x": active])
        #expect(SonarNSEDecoratePolicy.isMuted(
            groupIdHex: "", senderNpub: "npub1x", mutesJSON: bySender, now: now
        ))
        // Expired reads as unmuted.
        let expired = try JSONEncoder().encode(["marmot:" + gid: now.addingTimeInterval(-1)])
        #expect(!SonarNSEDecoratePolicy.isMuted(
            groupIdHex: gid, senderNpub: "", mutesJSON: expired, now: now
        ))
        // Missing or undecodable mirror fails open (unmuted).
        #expect(!SonarNSEDecoratePolicy.isMuted(
            groupIdHex: gid, senderNpub: "", mutesJSON: nil, now: now
        ))
        #expect(!SonarNSEDecoratePolicy.isMuted(
            groupIdHex: gid, senderNpub: "", mutesJSON: Data("junk".utf8), now: now
        ))
    }

    @Test("malformed trill lines are not treated as trills")
    func malformedTrillNotClassified() {
        #expect(SonarNSEDecoratePolicy.isTrillLine("\u{26A1}TRILL|1|abc-123"))
        #expect(!SonarNSEDecoratePolicy.isTrillLine("\u{26A1}TRILL|2|abc"))
        #expect(!SonarNSEDecoratePolicy.isTrillLine("\u{26A1}TRILL|1"))
        #expect(!SonarNSEDecoratePolicy.isTrillLine("\u{26A1}TRILL|1|abc|extra"))
        #expect(!SonarNSEDecoratePolicy.isTrillLine("just a message"))
        // Unicode full-width hex must not classify (core rejects it too).
        #expect(!SonarNSEDecoratePolicy.isTrillLine("\u{26A1}TRILL|1|\u{FF41}\u{FF42}c"))
    }
}
