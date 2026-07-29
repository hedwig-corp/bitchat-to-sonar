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
            groupIdHex: gid, senderNpub: "npub1x", groupName: "friends", mutesJSON: byGroup, now: now
        ))
        // 16-hex short-form store key matches too.
        let byShortForm = try JSONEncoder().encode([String(gid.prefix(16)): active])
        #expect(SonarNSEDecoratePolicy.isMuted(
            groupIdHex: gid, senderNpub: "", groupName: "", mutesJSON: byShortForm, now: now
        ))
        // Sender-keyed mutes match FOR A DIRECT CHAT. Use the production
        // shape: core emits the drain sender as 64-hex (`sender.to_string()`),
        // NOT bech32 — an npub sender here would test a case the real path
        // never produces, which is how the store-npub/look-up-hex mismatch
        // stayed green for six rounds.
        let senderHex = String(repeating: "cd", count: 32)
        let bySender = try JSONEncoder().encode([senderHex: active])
        #expect(SonarNSEDecoratePolicy.isMuted(
            groupIdHex: "", senderNpub: senderHex, groupName: "", mutesJSON: bySender, now: now
        ))
        // Mixed-case hex from any side still matches (every other hex
        // comparison in the NSE lowercases; muting must not be the exception).
        #expect(SonarNSEDecoratePolicy.isMuted(
            groupIdHex: gid.uppercased(), senderNpub: "", groupName: "",
            mutesJSON: byGroup, now: now
        ))
        // A store that only ever saw the bech32 form cannot match a hex sender —
        // pinning why muteKeys has to persist both encodings, not just one.
        let bech32Only = try JSONEncoder().encode(["npub1exampleexample": active])
        #expect(!SonarNSEDecoratePolicy.isMuted(
            groupIdHex: "", senderNpub: senderHex, groupName: "", mutesJSON: bech32Only, now: now
        ))
        // Expired reads as unmuted.
        let expired = try JSONEncoder().encode(["marmot:" + gid: now.addingTimeInterval(-1)])
        #expect(!SonarNSEDecoratePolicy.isMuted(
            groupIdHex: gid, senderNpub: "", groupName: "", mutesJSON: expired, now: now
        ))
        // Missing or undecodable mirror fails open (unmuted).
        #expect(!SonarNSEDecoratePolicy.isMuted(
            groupIdHex: gid, senderNpub: "", groupName: "", mutesJSON: nil, now: now
        ))
        #expect(!SonarNSEDecoratePolicy.isMuted(
            groupIdHex: gid, senderNpub: "", groupName: "", mutesJSON: Data("junk".utf8), now: now
        ))
    }

    @Test("a muted DM must not silence that peer inside an unmuted group")
    func mutedDMSenderDoesNotSilenceGroups() throws {
        // The host refuses this asymmetry in SonarPushProcessor (sender-keyed
        // check gated on no group name); the NSE must match. muteKeys for a DM
        // stores the peer's pubkey, so an unconditional sender match would
        // silence every group message from that peer on the killed-app path.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let senderHex = String(repeating: "cd", count: 32)
        let gid = String(repeating: "ab", count: 32)
        let dmMuted = try JSONEncoder().encode([senderHex: now.addingTimeInterval(3600)])

        // Group message from the muted-DM peer: NOT muted.
        #expect(!SonarNSEDecoratePolicy.isMuted(
            groupIdHex: gid, senderNpub: senderHex, groupName: "friends",
            mutesJSON: dmMuted, now: now
        ))
        // The DM itself: muted.
        #expect(SonarNSEDecoratePolicy.isMuted(
            groupIdHex: gid, senderNpub: senderHex, groupName: "",
            mutesJSON: dmMuted, now: now
        ))
        // The locally-generated placeholder counts as a DM
        // (enrichEmptyContentPreviews can backfill it before the mute check).
        #expect(SonarNSEDecoratePolicy.isMuted(
            groupIdHex: gid, senderNpub: senderHex, groupName: "Sonar agent DM",
            mutesJSON: dmMuted, now: now
        ))
        // But a REMOTE group name must not buy the DM branch: groupName comes
        // from the group, so an attacker could otherwise name a group "New
        // chat" to suppress its banner for anyone who muted a DM with them.
        for spoofed in ["New chat", "dm", "Direct message"] {
            #expect(!SonarNSEDecoratePolicy.isMuted(
                groupIdHex: gid, senderNpub: senderHex, groupName: spoofed,
                mutesJSON: dmMuted, now: now
            ), "a remote group name must not route through the DM mute branch: \(spoofed)")
        }
    }

    @Test("NSE mute lookup covers every key shape the store persists")
    func nseMuteCandidatesMatchStoreNormalization() throws {
        // The store now delegates its normalization to
        // SonarNSEDecoratePolicy.normalizedMuteCandidates, so drift between
        // the writer and the appex reader is impossible by construction. This
        // test keeps the end-to-end guarantee pinned anyway: every key the
        // store persists is found by the NSE lookup, through the store's OWN
        // serialized blob (pinning the JSONEncoder/Decoder date agreement).
        let suiteName = "test.nse.mute.drift"
        let defaults = UserDefaults(suiteName: suiteName)!
        // Clear before AND after: a crashed prior run would otherwise leave
        // mutes behind and decide this test's verdict (matches freshMuteStore).
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storeKey = "test.mutes.drift"
        let store = SonarChatMuteStore(defaults: defaults, key: storeKey)

        let gid = String(repeating: "ab", count: 32) // 64-hex group id
        // A REAL npub, not a syntactic lookalike. "npub1exampleexample" does
        // not decode, so it round-trips unchanged and the test stayed green
        // even with the bech32 -> hex conversion deleted — i.e. it proved
        // nothing about the representation mismatch it exists to guard.
        let npub = "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6"
        let npubHex = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"
        let until = Date().addingTimeInterval(3600)
        for raw in [gid, "marmot:" + gid, npub] {
            store.mute(keys: [raw], until: until)
        }

        // Drift guard: no shape the store writes may be unreachable from the
        // push path. Measured against the union of the lookups that path really
        // performs — by group id, and by the sender as 64-hex — NOT against a
        // single bech32-sender lookup. The store intentionally persists extra
        // hex-derived encodings precisely so the hex sender can match, and those
        // are not candidates of a bech32 lookup by design.
        let reachable = Set(
            SonarNSEDecoratePolicy.mutedLookupCandidates(
                groupIdHex: gid, senderNpub: npub, groupName: ""
            )
        ).union(
            SonarNSEDecoratePolicy.mutedLookupCandidates(
                groupIdHex: gid, senderNpub: npubHex, groupName: ""
            )
        )
        for stored in store.mutedUntil.keys {
            #expect(reachable.contains(stored), "no push-path lookup reaches stored mute key \(stored)")
        }
        // The real point: production drains carry `sender.to_string()` = 64-hex
        // (client.rs:6478), so a mute stored under a bech32 npub has to be
        // reachable by hex. That bridge belongs to the STORE, not to this
        // lookup: `mutedLookupCandidates` is compiled into the appex, which does
        // not include `Bech32`, and an npub-shaped sender is not a shape the
        // drain path ever produces. So assert what actually protects the user —
        // the store persisted the hex twin — and that a hex sender then matches.
        #expect(
            store.mutedUntil[npubHex] != nil,
            "muting by npub must also persist the 64-hex twin push drains look up"
        )
        let byHexSender = Set(
            SonarNSEDecoratePolicy.mutedLookupCandidates(
                groupIdHex: "", senderNpub: npubHex, groupName: ""
            )
        )
        #expect(
            byHexSender.contains(where: { store.mutedUntil[$0] != nil }),
            "a hex sender must reach the mute stored from its npub"
        )

        // Round-trip the store's OWN persisted blob, so the implicit
        // JSONEncoder/JSONDecoder date-strategy agreement is pinned too.
        let blob = defaults.data(forKey: storeKey)
        #expect(blob != nil)
        #expect(SonarNSEDecoratePolicy.isMuted(
            groupIdHex: gid, senderNpub: npub, groupName: "", mutesJSON: blob, now: Date()
        ))
    }

    @Test("a legacy npub-only mute gains its hex twin on store init")
    func legacyNpubMuteMigratesOnLoad() throws {
        // Pins the MIGRATION, not the helper: the user never mutes again, so
        // only the init path can make a pre-upgrade npub-only entry reachable
        // from the 64-hex sender a killed-app drain carries.
        let suiteName = "test.nse.mute.migrate"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storeKey = "test.mutes.migrate"

        let npub = "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6"
        let npubHex = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"
        let until = Date().addingTimeInterval(3600)
        // Exactly what muteKeys wrote before it stored both encodings.
        defaults.set(try JSONEncoder().encode([npub: until]), forKey: storeKey)

        let store = SonarChatMuteStore(defaults: defaults, key: storeKey)
        #expect(
            store.mutedUntil[npubHex] != nil,
            "init must backfill the 64-hex twin the push path looks up"
        )
        #expect(
            store.isMuted(npubHex),
            "a hex sender must match a legacy npub-only mute after load"
        )

        // And the migration is written back, so it happens once rather than on
        // every launch.
        let blob = defaults.data(forKey: storeKey)
        #expect(blob != nil)
        let reloaded = try JSONDecoder().decode([String: Date].self, from: blob ?? Data())
        #expect(reloaded[npubHex] != nil, "the migrated map must be persisted")
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
