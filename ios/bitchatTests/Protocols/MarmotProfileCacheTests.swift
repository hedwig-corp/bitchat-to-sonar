//
// MarmotProfileCacheTests.swift
// bitchatTests
//

import Foundation
import Testing
@testable import Sonar

struct MarmotProfileCacheTests {
    @Test
    func onboardedHomeWaitsForFirstCoherentLocalHydration() {
        #expect(!snShouldRevealLocalHome(onboarded: true, initialLocalHomeReady: false))
        #expect(snShouldRevealLocalHome(onboarded: true, initialLocalHomeReady: true))
        #expect(snShouldRevealLocalHome(onboarded: false, initialLocalHomeReady: false))
    }

    @Test
    func cacheRoundTripsProfileDisplayName() {
        let suiteName = "MarmotProfileCacheTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let npub = "npub1vincent"
        let profile = MarmotService.Profile(
            name: "vincent",
            displayName: "Vincent",
            about: "hello",
            picture: nil,
            nip05: nil
        )

        SNMarmotProfileCache.save([npub: profile], to: defaults)

        let loaded = SNMarmotProfileCache.load(from: defaults)
        #expect(loaded[npub]?.bestName == "Vincent")
        #expect(loaded[npub]?.about == "hello")
    }

    /// `save` is now `encoded` (off-actor, expensive) + `commit` (on-actor,
    /// cheap), so the deferred write path can skip the main actor for the JSON
    /// encode. Pin that the split still produces what the one-shot `save` did.
    ///
    /// The App Group name mirror (`syncSharedProfileNames`, which the NSE uses
    /// to resolve kill-state banner senders) also moved from `save` into
    /// `commit`. It is NOT asserted here: `SonarSharedProfileNames` is a
    /// process-global store keyed on a fixed app group, and sibling tests wipe
    /// it via `SNMarmotProfileCache.clear`, so reading it back races with
    /// whatever else Swift Testing is running in parallel. It is covered
    /// structurally instead — `save` reaches the mirror only by calling
    /// `commit`, so the split cannot skip it without skipping it for both.
    @Test
    func encodeThenCommitMatchesSave() throws {
        let suiteName = "MarmotProfileCacheTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let npub = "npub1vincent"
        let profile = MarmotService.Profile(
            name: "vincent",
            displayName: "Vincent",
            about: "hello",
            picture: nil,
            nip05: nil
        )

        let payload = try #require(SNMarmotProfileCache.encoded([npub: profile]))
        SNMarmotProfileCache.commit(payload, to: defaults)

        let viaSplit = SNMarmotProfileCache.load(from: defaults)
        #expect(viaSplit[npub]?.bestName == "Vincent")
        #expect(viaSplit[npub]?.about == "hello")

        // The synchronous convenience wrapper must stay equivalent. Compared by
        // decoded value, not raw bytes: JSONEncoder does not promise a stable
        // key order for a Dictionary, so two encodes of the same map can differ
        // byte-for-byte while meaning the same thing.
        let otherSuite = "MarmotProfileCacheTests-\(UUID().uuidString)"
        let otherDefaults = UserDefaults(suiteName: otherSuite)!
        defer { otherDefaults.removePersistentDomain(forName: otherSuite) }
        SNMarmotProfileCache.save([npub: profile], to: otherDefaults)

        #expect(SNMarmotProfileCache.load(from: otherDefaults) == viaSplit)
    }

    @Test
    func clearRemovesCachedProfiles() {
        let suiteName = "MarmotProfileCacheTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        SNMarmotProfileCache.save([
            "npub1vincent": MarmotService.Profile(
                name: nil,
                displayName: "Vincent",
                about: nil,
                picture: nil,
                nip05: nil
            )
        ], to: defaults)

        SNMarmotProfileCache.clear(from: defaults)

        #expect(SNMarmotProfileCache.load(from: defaults).isEmpty)
    }

    @Test
    func cacheCanonicalizesHexPubkeyToNpub() throws {
        let suiteName = "MarmotProfileCacheTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let raw = Data((0..<32).map(UInt8.init))
        let hex = raw.map { String(format: "%02x", $0) }.joined()
        let npub = try Bech32.encode(hrp: "npub", data: raw)
        let profile = MarmotService.Profile(
            name: nil,
            displayName: "Sara D",
            about: nil,
            picture: nil,
            nip05: nil
        )

        SNMarmotProfileCache.save([hex: profile], to: defaults)

        let loaded = SNMarmotProfileCache.load(from: defaults)
        #expect(loaded[npub]?.bestName == "Sara D")
        #expect(loaded[hex] == nil)
        #expect(SNMarmotProfileCache.canonicalKey(hex) == npub)
    }

    @Test
    func authorNameResolvesCachedProfileWithoutFetch() {
        let senderNpub = "npub1vincent"
        let profile = MarmotService.Profile(
            name: "vincent",
            displayName: "Vincent P",
            about: nil,
            picture: nil,
            nip05: nil
        )
        let message = MarmotService.MarmotMessage(
            id: "msg-1",
            senderNpub: senderNpub,
            content: "hello",
            createdAt: Date(timeIntervalSince1970: 42),
            isMine: false,
            media: []
        )
        var fetched: [String] = []

        let resolved = snResolvedMarmotAuthorName(
            message,
            profilesByNpub: [senderNpub: profile],
            fetchMissingProfile: { fetched.append($0) },
            shortNpub: snShortNpubLabel
        )

        #expect(resolved == "Vincent P")
        #expect(fetched.isEmpty)
    }

    @Test
    func authorNameCacheMissFetchesProfileAndFallsBack() {
        let senderNpub = "npub1sender1234567890"
        let message = MarmotService.MarmotMessage(
            id: "msg-1",
            senderNpub: senderNpub,
            content: "hello",
            createdAt: Date(timeIntervalSince1970: 42),
            isMine: false,
            media: []
        )
        var fetched: [String] = []

        let resolved = snResolvedMarmotAuthorName(
            message,
            profilesByNpub: [:],
            fetchMissingProfile: { fetched.append($0) },
            shortNpub: snShortNpubLabel
        )

        #expect(resolved == snShortNpubLabel(senderNpub))
        #expect(fetched == [senderNpub])
    }

    @Test
    func directMarmotPeerKeyCanonicalizesHexAndGroupsDuplicates() throws {
        let ownRaw = Data(repeating: 1, count: 32)
        let peerRaw = Data(repeating: 2, count: 32)
        let ownNpub = try Bech32.encode(hrp: "npub", data: ownRaw)
        let peerNpub = try Bech32.encode(hrp: "npub", data: peerRaw)
        let peerHex = peerRaw.map { String(format: "%02x", $0) }.joined()
        let first = MarmotService.MarmotGroup(id: "group-a", name: "", memberNpubs: [ownNpub, peerHex])
        let second = MarmotService.MarmotGroup(id: "group-b", name: "", memberNpubs: [ownNpub, peerNpub])
        let room = MarmotService.MarmotGroup(id: "room", name: "", memberNpubs: [ownNpub, peerNpub, "npub1third"])

        let grouped = snCanonicalDirectMarmotGroups([first, second, room], ownNpub: ownNpub)

        #expect(snDirectMarmotPeerKey(for: first, ownNpub: ownNpub) == peerNpub)
        #expect(grouped[peerNpub]?.map(\.id) == ["group-a", "group-b"])
    }

    @Test
    func chatSnapshotKeepsRowsWithoutPersistingMessages() {
        let suiteName = "MarmotProfileCacheTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let group = MarmotService.MarmotGroup(
            id: "group-1",
            name: "",
            memberNpubs: ["npub1sara", "npub1me"]
        )
        let message = MarmotService.MarmotMessage(
            id: "msg-1",
            senderNpub: "npub1sara",
            content: "hello",
            createdAt: Date(timeIntervalSince1970: 42),
            isMine: false,
            media: [
                MarmotService.MarmotMedia(
                    url: "pending-url",
                    mimeType: "image/png",
                    filename: "photo.png",
                    width: 640,
                    height: 480,
                    durationMs: nil
                )
            ]
        )

        SNMarmotChatSnapshotCache.save(
            groups: [group],
            messagesByGroup: [group.id: [message]],
            to: defaults
        )

        let loaded = SNMarmotChatSnapshotCache.load(from: defaults)
        #expect(loaded.0 == [group])
        #expect(loaded.1.isEmpty)
    }

    @Test
    func clearRemovesChatSnapshot() {
        let suiteName = "MarmotProfileCacheTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let group = MarmotService.MarmotGroup(id: "group-1", name: "", memberNpubs: [])
        SNMarmotChatSnapshotCache.save(groups: [group], messagesByGroup: [:], to: defaults)

        SNMarmotChatSnapshotCache.clear(from: defaults)

        let loaded = SNMarmotChatSnapshotCache.load(from: defaults)
        #expect(loaded.0.isEmpty)
        #expect(loaded.1.isEmpty)
    }

    // MARK: - Stale profile key computation

    @Test
    func staleKeysReturnsEmptyWhenAllFresh() {
        let now = Date()
        let fetchedAt: [String: Date] = [
            "npub1alice": now,
            "npub1bob": now.addingTimeInterval(-60),
        ]
        let cutoff = now.addingTimeInterval(-30 * 60)
        let stale = MarmotChatModel.staleKeys(from: fetchedAt, cutoff: cutoff)
        #expect(stale.isEmpty)
    }

    @Test
    func staleKeysReturnsEntriesOlderThanCutoff() {
        let now = Date()
        let fetchedAt: [String: Date] = [
            "npub1alice": now,
            "npub1bob": now.addingTimeInterval(-31 * 60),
            "npub1carol": now.addingTimeInterval(-45 * 60),
        ]
        let cutoff = now.addingTimeInterval(-30 * 60)
        let stale = Set(MarmotChatModel.staleKeys(from: fetchedAt, cutoff: cutoff))
        #expect(stale == ["npub1bob", "npub1carol"])
    }

    @Test
    func staleKeysReturnsEmptyForEmptyMap() {
        let stale = MarmotChatModel.staleKeys(from: [:], cutoff: Date())
        #expect(stale.isEmpty)
    }

    @Test
    func staleKeysBoundaryExactlyAtCutoffIsNotStale() {
        let cutoff = Date()
        let fetchedAt: [String: Date] = ["npub1alice": cutoff]
        // Entry exactly at cutoff is NOT stale (filter uses strict <).
        let stale = MarmotChatModel.staleKeys(from: fetchedAt, cutoff: cutoff)
        #expect(stale.isEmpty)
    }
}
