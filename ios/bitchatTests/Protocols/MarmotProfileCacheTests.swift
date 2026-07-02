//
// MarmotProfileCacheTests.swift
// bitchatTests
//

import Foundation
import Testing
@testable import Sonar

struct MarmotProfileCacheTests {
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
}
