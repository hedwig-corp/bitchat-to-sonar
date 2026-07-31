//
// SonarConversationFoldTests.swift
// bitchatTests
//

import Foundation
import Testing
@testable import Sonar

struct SonarConversationFoldTests {
    @Test
    func foldedDirectHomeTitleUsesMarmotProfile() {
        let title = snFoldedDirectMarmotHomeTitle(
            isDirectGroup: true,
            marmotProfileTitle: "Sara D",
            peerDerivedTitle: "Wrong BLE Name"
        )

        #expect(title == "Sara D")
    }

    @Test
    func nonDirectHomeTitleKeepsPeerDerivedName() {
        let title = snFoldedDirectMarmotHomeTitle(
            isDirectGroup: false,
            marmotProfileTitle: "Room Profile",
            peerDerivedTitle: "Builders Room"
        )

        #expect(title == "Builders Room")
    }

    @Test
    func sameNpubMeshFingerprintsShareIdentityKey() {
        let npub = String(repeating: "ab", count: 32)
        #expect(
            snMeshConversationIdentityKey(peerId: "abef0238b73563e6", linkedNpubHex: npub)
                == snMeshConversationIdentityKey(peerId: "dfb13e10b8069122", linkedNpubHex: npub.uppercased())
        )
        #expect(
            snMeshConversationIdentityKey(peerId: "abef0238b73563e6", linkedNpubHex: npub)
                != snMeshConversationIdentityKey(peerId: "sara-fp", linkedNpubHex: String(repeating: "cd", count: 32))
        )
        #expect(
            snMeshConversationIdentityKey(peerId: "unlinked-a", linkedNpubHex: nil)
                != snMeshConversationIdentityKey(peerId: "unlinked-b", linkedNpubHex: nil)
        )
    }

    @Test
    func rotatingVincenzoAliasesCollapseWithoutAbsorbingSara() {
        let vincenzoNpub = String(repeating: "ab", count: 32)
        let saraNpub = String(repeating: "cd", count: 32)
        let links = [
            "fp-vincenzo": vincenzoNpub,
            "fp-vincenzo-mac": vincenzoNpub.uppercased(),
            "fp-sara": saraNpub,
        ]
        let groups = snGroupMeshPeerIdsByIdentity(
            peerIds: Array(links.keys),
            linkedNpubByPeer: links
        )
        .map { Set($0) }

        #expect(groups.count == 2)
        #expect(groups.contains(Set(["fp-vincenzo", "fp-vincenzo-mac"])))
        #expect(groups.contains(Set(["fp-sara"])))
    }

    @Test
    func sameNpubMeshFingerprintsCollapseToOneHomeRow() {
        let npub = String(repeating: "ab", count: 32)
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        let rows: [String: SNDMRow] = [
            "abef0238b73563e6": SNDMRow(
                id: "abef0238b73563e6",
                title: "Vincenzo Palazzo",
                preview: "👀",
                time: "00:58",
                unread: false,
                presence: false,
                verified: false,
                isMarmot: false,
                lastDate: older
            ),
            "dfb13e10b8069122": SNDMRow(
                id: "dfb13e10b8069122",
                title: "Vincenzo Palazzo",
                preview: "Ok it is receiving notifica",
                time: "00:58",
                unread: true,
                presence: false,
                verified: false,
                isMarmot: false,
                lastDate: newer
            ),
            "sara-fp": SNDMRow(
                id: "sara-fp",
                title: "Sara D",
                preview: "hi",
                time: "00:01",
                unread: false,
                presence: false,
                verified: false,
                isMarmot: false,
                lastDate: older
            ),
        ]
        let linked = [
            "abef0238b73563e6": npub,
            "dfb13e10b8069122": npub,
            "sara-fp": String(repeating: "cd", count: 32),
        ]

        let collapsed = snCollapseMeshDMRowsByIdentity(
            rowsByPeer: rows,
            linkedNpubByPeer: linked,
            persistedFoldPeerIds: ["abef0238b73563e6"]
        )

        #expect(collapsed.count == 2)
        #expect(collapsed["abef0238b73563e6"] != nil)
        #expect(collapsed["dfb13e10b8069122"] == nil)
        #expect(collapsed["abef0238b73563e6"]?.preview == "Ok it is receiving notifica")
        #expect(collapsed["abef0238b73563e6"]?.unread == true)
        #expect(collapsed["abef0238b73563e6"]?.id == "abef0238b73563e6")
        #expect(collapsed["sara-fp"]?.title == "Sara D")
    }

    @Test
    func selectCanonicalMeshPeerPrefersPersistedFoldTarget() {
        #expect(
            snSelectCanonicalMeshPeerId(
                aliases: ["dfb13e10b8069122", "abef0238b73563e6"],
                persistedFoldPeerIds: ["dfb13e10b8069122"]
            ) == "dfb13e10b8069122"
        )
        #expect(
            snSelectCanonicalMeshPeerId(
                aliases: ["dfb13e10b8069122", "abef0238b73563e6"],
                persistedFoldPeerIds: []
            ) == "abef0238b73563e6"
        )
    }

    @Test
    func filterPeerKeysDropsConflictingFavoriteClaim() {
        // Reverse index may still list sara under vincenzo's npub if a stale
        // favorite claimed it; current linked map must drop her (Compose parity).
        let vincenzo = String(repeating: "ab", count: 32)
        let sara = String(repeating: "cd", count: 32)
        let filtered = snFilterPeerKeysMatchingNpubHex(
            candidates: ["fp-vincenzo", "fp-vincenzo-mac", "fp-sara"],
            linkedNpubHexByPeer: [
                "fp-vincenzo": vincenzo,
                "fp-vincenzo-mac": vincenzo,
                "fp-sara": sara,
            ],
            targetNpubHex: vincenzo
        )
        #expect(filtered == ["fp-vincenzo", "fp-vincenzo-mac"])
        #expect(!filtered.contains("fp-sara"))
    }

    @Test
    func liveMeshRoutePrefersConnectedAliasOverCanonical() {
        let connected = "dfb13e10b8069122"
        let canonical = "abef0238b73563e6"
        #expect(
            snSelectLiveMeshRoutePeerId(
                aliases: [canonical, connected],
                isConnected: { $0 == connected },
                isReachable: { _ in false },
                requireDirectConnection: true
            ) == connected
        )
        #expect(
            snSelectLiveMeshRoutePeerId(
                aliases: [canonical, connected],
                isConnected: { _ in false },
                isReachable: { $0 == connected },
                requireDirectConnection: true
            ) == nil
        )
        #expect(
            snSelectLiveMeshRoutePeerId(
                aliases: [canonical, connected],
                isConnected: { _ in false },
                isReachable: { $0 == connected },
                requireDirectConnection: false
            ) == connected
        )
    }

    @Test
    func rekeyAlignsLiveMeshRowWithFullPeerKeysCanonical() {
        // Live row is only under fingerprint B; full peerKeys universe prefers
        // inactive A (lexicographically smaller). Without rekey, Marmot fold
        // targets A while the mesh row stays at B → duplicate home rows.
        let live = "dfb13e10b8069122"
        let staleCanonical = "abef0238b73563e6"
        let rows: [String: SNDMRow] = [
            live: SNDMRow(
                id: live,
                title: "Vincenzo Palazzo",
                preview: "Ok it is receiving notifica",
                time: "00:58",
                unread: true,
                presence: false,
                verified: false,
                isMarmot: false,
                lastDate: Date(timeIntervalSince1970: 200)
            ),
        ]
        let aligned = snRekeyMeshRowsToCanonicalIds(rowsByPeer: rows) { key in
            key == live ? staleCanonical : nil
        }
        #expect(aligned.count == 1)
        #expect(aligned[staleCanonical] != nil)
        #expect(aligned[live] == nil)
        #expect(aligned[staleCanonical]?.id == staleCanonical)
        #expect(aligned[staleCanonical]?.preview == "Ok it is receiving notifica")
        #expect(aligned[staleCanonical]?.unread == true)
    }

    // MARK: Internet DM buckets (docs/CHAT-TYPES.md — id shape 6)

    /// Sara's real shape: the alias set is the canonical 16-hex short id, but
    /// her internet reply is stored under her 64-hex Noise public key because
    /// she was out of BLE range when it arrived.
    private static let saraShortId = "f3237e63eb468722"
    private static let saraNoiseKeyHex =
        "83091c3ca8de95eb6d944787c1a845a2c5216250149360841604482e50016675"

    private func meshRow(_ id: String, _ text: String, at secs: TimeInterval) -> BitchatMessage {
        BitchatMessage(
            id: id,
            sender: "Sara D",
            content: text,
            timestamp: Date(timeIntervalSince1970: secs),
            isRelay: false,
            isPrivate: true
        )
    }

    @Test
    func outOfRangeInternetDmBucketIsPartOfTheTranscript() {
        let keys = snMeshPrivateChatKeys(
            aliases: [Self.saraShortId],
            noiseKeyHexByPeerKey: [Self.saraShortId: [Self.saraNoiseKeyHex]]
        )
        #expect(keys == [Self.saraShortId, Self.saraNoiseKeyHex])

        // Only the Noise-key bucket holds the newest row — exactly what the
        // chat-list preview showed while the transcript stayed a message behind.
        let buckets: [String: [BitchatMessage]] = [
            Self.saraNoiseKeyHex: [meshRow("m1", "Yoooo 🐍", at: 200)],
        ]
        let merged = snMergeMeshPrivateChats(keys: keys) { buckets[$0] }
        #expect(merged.map(\.id) == ["m1"])
        #expect(snMeshPrivateChatCount(keys: keys) { buckets[$0] } == 1)
    }

    @Test
    func mirroredRowIsNotRenderedTwice() {
        // `mirrorToEphemeralIfNeeded` copies the row onto the short id once the
        // peer is live again, so both buckets can hold the same message id.
        let keys = snMeshPrivateChatKeys(
            aliases: [Self.saraShortId],
            noiseKeyHexByPeerKey: [Self.saraShortId: [Self.saraNoiseKeyHex]]
        )
        let buckets: [String: [BitchatMessage]] = [
            Self.saraShortId: [
                meshRow("m0", "Y", at: 100),
                meshRow("m1", "Yoooo 🐍", at: 200),
            ],
            Self.saraNoiseKeyHex: [meshRow("m1", "Yoooo 🐍", at: 200)],
        ]
        let merged = snMergeMeshPrivateChats(keys: keys) { buckets[$0] }
        #expect(merged.map(\.id) == ["m0", "m1"])
        #expect(snMeshPrivateChatCount(keys: keys) { buckets[$0] } == 2)
    }

    @Test
    func unlinkedConversationKeepsSingleBucketReturn() {
        // No favorite ⇒ no Noise-key form; the single-bucket path must stay
        // identity-preserving (no re-sort, no dedup pass).
        let keys = snMeshPrivateChatKeys(
            aliases: [Self.saraShortId],
            noiseKeyHexByPeerKey: [:]
        )
        #expect(keys == [Self.saraShortId])
        let rows = [meshRow("m0", "Y", at: 100), meshRow("m1", "Yoooo 🐍", at: 200)]
        let merged = snMergeMeshPrivateChats(keys: keys) { $0 == Self.saraShortId ? rows : nil }
        #expect(merged.map(\.id) == ["m0", "m1"])
    }

    @Test
    func anotherPeersNoiseKeyNeverJoinsTheTranscript() {
        let vincenzoShortId = "abef0238b73563e6"
        let keys = snMeshPrivateChatKeys(
            aliases: [Self.saraShortId],
            noiseKeyHexByPeerKey: [
                Self.saraShortId: [Self.saraNoiseKeyHex],
                vincenzoShortId: [String(repeating: "ab", count: 32)],
            ]
        )
        #expect(keys == [Self.saraShortId, Self.saraNoiseKeyHex])
        #expect(!keys.contains(String(repeating: "ab", count: 32)))
    }

    /// Reading the chat must clear the dot the chat list took from that same
    /// bucket. `SonarAppStore.markMeshConversationRead` feeds
    /// `markPrivateMessagesAsRead(fromKeys:)` the `snMeshPrivateChatKeys` set;
    /// this pins the ChatViewModel half of that contract against a real view
    /// model with no live `unifiedPeerService` entry (peer out of BLE range).
    @Test @MainActor
    func openingTheChatClearsUnreadFromTheOutOfRangeInternetDmBucket() {
        let viewModel = Self.makeFoldTestViewModel()
        let shortPeer = PeerID(str: Self.saraShortId)
        let noiseKeyPeer = PeerID(str: Self.saraNoiseKeyHex)
        defer {
            viewModel.privateChats[shortPeer] = nil
            viewModel.privateChats[noiseKeyPeer] = nil
            viewModel.unreadPrivateMessages.remove(shortPeer)
            viewModel.unreadPrivateMessages.remove(noiseKeyPeer)
        }

        // Sara replied over the internet while out of range: the row lands in
        // her 64-hex Noise-key bucket and is marked unread under that key.
        viewModel.privateChats[noiseKeyPeer] = [meshRow("m1", "Yoooo 🐍", at: 200)]
        viewModel.unreadPrivateMessages.insert(noiseKeyPeer)

        // What opening used to do: mark only the conversation's row id. Out of
        // range nothing resolves the peer's Noise-key form, so the dot stayed.
        // This line documents WHY the key set exists — if the single-key path
        // ever grows a durable (favorites-backed) Noise-key resolution, delete
        // it rather than working around it.
        viewModel.markPrivateMessagesAsRead(from: shortPeer)
        #expect(viewModel.unreadPrivateMessages.contains(noiseKeyPeer))

        viewModel.markPrivateMessagesAsRead(
            fromKeys: snMeshPrivateChatKeys(
                aliases: [Self.saraShortId],
                noiseKeyHexByPeerKey: [Self.saraShortId: [Self.saraNoiseKeyHex]]
            ).map { PeerID(str: $0) }
        )
        #expect(!viewModel.unreadPrivateMessages.contains(noiseKeyPeer))
        #expect(!viewModel.unreadPrivateMessages.contains(shortPeer))
    }

    /// Marking one conversation read must not reach into another person's
    /// bucket — the key set is per-conversation, not a global sweep.
    @Test @MainActor
    func markingOneConversationReadLeavesAnotherPeersBucketUnread() {
        let viewModel = Self.makeFoldTestViewModel()
        let vincenzoNoiseKeyHex = String(repeating: "ab", count: 32)
        let vincenzoPeer = PeerID(str: vincenzoNoiseKeyHex)
        let noiseKeyPeer = PeerID(str: Self.saraNoiseKeyHex)
        defer {
            viewModel.privateChats[vincenzoPeer] = nil
            viewModel.privateChats[noiseKeyPeer] = nil
            viewModel.unreadPrivateMessages.remove(vincenzoPeer)
            viewModel.unreadPrivateMessages.remove(noiseKeyPeer)
        }

        viewModel.privateChats[noiseKeyPeer] = [meshRow("m1", "Yoooo 🐍", at: 200)]
        viewModel.privateChats[vincenzoPeer] = [meshRow("m2", "👀", at: 300)]
        viewModel.unreadPrivateMessages.insert(noiseKeyPeer)
        viewModel.unreadPrivateMessages.insert(vincenzoPeer)

        viewModel.markPrivateMessagesAsRead(
            fromKeys: snMeshPrivateChatKeys(
                aliases: [Self.saraShortId],
                noiseKeyHexByPeerKey: [
                    Self.saraShortId: [Self.saraNoiseKeyHex],
                    "abef0238b73563e6": [vincenzoNoiseKeyHex],
                ]
            ).map { PeerID(str: $0) }
        )

        #expect(!viewModel.unreadPrivateMessages.contains(noiseKeyPeer))
        #expect(viewModel.unreadPrivateMessages.contains(vincenzoPeer))
    }

    @MainActor
    private static func makeFoldTestViewModel() -> ChatViewModel {
        let keychain = MockKeychain()
        return ChatViewModel(
            keychain: keychain,
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: MockIdentityManager(keychain),
            transport: MockTransport()
        )
    }
}
