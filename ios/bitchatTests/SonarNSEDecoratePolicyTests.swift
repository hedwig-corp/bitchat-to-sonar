//
// SonarNSEDecoratePolicyTests.swift
// bitchatTests
//
// Pins NSE decorate privacy + expire invariants (production readiness for #381).
//

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

    @Test("hex sender without profile becomes New message")
    func hexSenderLabel() {
        let hex = String(repeating: "ab", count: 32)
        #expect(SonarNSEDecoratePolicy.senderLabel(for: hex) == "New message")
        let out = SonarNSEDecoratePolicy.render(
            input: .init(senderRaw: hex, groupName: "Sonar agent DM", contentPreview: "hi"),
            prefs: .init(showNames: true, showPreview: true)
        )
        #expect(out.title == "New message")
        #expect(out.body == "hi")
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
}
