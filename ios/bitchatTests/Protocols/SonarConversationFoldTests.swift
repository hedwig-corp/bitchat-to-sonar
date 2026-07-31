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

    /// The real shape from the bug report: the alias set is the canonical
    /// 16-hex short id, but the peer's internet reply is stored under their
    /// 64-hex Noise public key because they were out of BLE range.
    private static let peerShortId = "630dcd2966c43366"
    private static let peerNoiseKeyHex =
        "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

    /// Synthetic key material, not a real contact's: the test only needs
    /// `sha256(noiseKeyHex)[0..<16] == shortId` to hold, which any 32 bytes
    /// give. `PeerID(publicKey:)` does that derivation for real.
    private static let shortIdForNoiseKeyHex: (String) -> String? = { hex in
        Data(hexString: hex).map { PeerID(publicKey: $0).bare }
    }

    private func meshRow(
        _ id: String,
        _ text: String,
        at secs: TimeInterval,
        status: DeliveryStatus? = nil
    ) -> BitchatMessage {
        BitchatMessage(
            id: id,
            sender: "Peer",
            content: text,
            timestamp: Date(timeIntervalSince1970: secs),
            isRelay: false,
            isPrivate: true,
            deliveryStatus: status
        )
    }

    private func peerKeys(bucketKeys: [String]) -> [String] {
        snMeshPrivateChatKeys(
            aliases: [Self.peerShortId],
            noiseKeyBuckets: snMeshNoiseKeyBuckets(
                bucketKeys: bucketKeys,
                aliases: [Self.peerShortId],
                shortIdForNoiseKeyHex: Self.shortIdForNoiseKeyHex
            )
        )
    }

    @Test
    func outOfRangeInternetDmBucketIsPartOfTheTranscript() {
        // Derived from the live bucket keys, not from favorites: unfavouriting
        // the peer must not hide her transcript again.
        let keys = peerKeys(bucketKeys: [Self.peerShortId, Self.peerNoiseKeyHex])
        #expect(keys == [Self.peerShortId, Self.peerNoiseKeyHex])

        // Only the Noise-key bucket holds the newest row — exactly what the
        // chat-list preview showed while the transcript stayed a message behind.
        let buckets: [String: [BitchatMessage]] = [
            Self.peerNoiseKeyHex: [meshRow("m1", "reply over the internet", at: 200)],
        ]
        let merged = snMergeMeshPrivateChats(keys: keys) { buckets[$0] }
        #expect(merged.map(\.id) == ["m1"])
        #expect(snMeshPrivateChatCount(keys: keys) { buckets[$0] } == 1)
    }

    @Test
    func fingerprintShapedBucketAlsoResolves() {
        // The other 64-hex shape: the fingerprint, whose first 16 hex ARE the
        // short id. `MessageStore` holds real buckets in both shapes.
        let fingerprint = Self.peerShortId + String(repeating: "0", count: 48)
        let keys = peerKeys(bucketKeys: [Self.peerShortId, fingerprint])
        #expect(keys == [Self.peerShortId, fingerprint])
        // Key presence is not readability: assert the merge actually reaches
        // that bucket in the exact string form the key list carries.
        let buckets: [String: [BitchatMessage]] = [
            fingerprint: [meshRow("m1", "reply over the internet", at: 200)],
        ]
        #expect(snMergeMeshPrivateChats(keys: keys) { buckets[$0] }.map(\.id) == ["m1"])
    }

    @Test
    func receivedInternetRowOverridesTheConversationTransport() {
        // The rows this fix surfaces arrived over the internet while the peer
        // was out of BLE range; rendering them as Bluetooth bubbles would
        // contradict the chat's own header.
        #expect(snMeshRowVia(receivedViaInternet: true, default: .mesh) == .internet)
        #expect(snMeshRowVia(receivedViaInternet: true, default: .internet) == .internet)
        // Additive: nothing else changes. Our own sends carry nil.
        #expect(snMeshRowVia(receivedViaInternet: nil, default: .mesh) == .mesh)
        #expect(snMeshRowVia(receivedViaInternet: false, default: .mesh) == .mesh)
        #expect(snMeshRowVia(receivedViaInternet: nil, default: .internet) == .internet)
    }

    @Test
    func mirroredRowIsNotRenderedTwice() {
        // `mirrorToEphemeralIfNeeded` copies the row onto the short id once the
        // peer is live again, so both buckets can hold the same message id.
        let keys = peerKeys(bucketKeys: [Self.peerShortId, Self.peerNoiseKeyHex])
        let buckets: [String: [BitchatMessage]] = [
            Self.peerShortId: [
                meshRow("m0", "Y", at: 100),
                meshRow("m1", "reply over the internet", at: 200),
            ],
            Self.peerNoiseKeyHex: [meshRow("m1", "reply over the internet", at: 200)],
        ]
        let merged = snMergeMeshPrivateChats(keys: keys) { buckets[$0] }
        #expect(merged.map(\.id) == ["m0", "m1"])
        #expect(snMeshPrivateChatCount(keys: keys) { buckets[$0] } == 2)
    }

    @Test
    func aliasBucketWinsOverAStalerMirroredCopy() {
        // Several send paths update delivery status on ONE bucket only, so the
        // two copies of a mirrored row can diverge. The alias bucket — the one
        // `sendPrivateMessage` appends to and marks `.sent` — must win.
        let keys = peerKeys(bucketKeys: [Self.peerShortId, Self.peerNoiseKeyHex])
        let buckets: [String: [BitchatMessage]] = [
            Self.peerShortId: [
                meshRow("m0", "Y", at: 100),
                meshRow("m1", "reply", at: 200, status: .sent),
            ],
            Self.peerNoiseKeyHex: [meshRow("m1", "reply", at: 200, status: .sending)],
        ]
        let merged = snMergeMeshPrivateChats(keys: keys) { buckets[$0] }
        // The losing copy must be dropped, not merely ordered behind: exactly
        // one m1 survives, and it is the alias bucket's.
        #expect(merged.map(\.id) == ["m0", "m1"])
        #expect(merged.filter { $0.id == "m1" }.count == 1)
        #expect(merged.first { $0.id == "m1" }?.deliveryStatus == .sent)
    }

    @Test
    func unlinkedConversationKeepsSingleBucketReturn() {
        // No Noise-key bucket ⇒ single key; the single-bucket path must stay
        // identity-preserving (no re-sort, no dedup pass).
        let keys = peerKeys(bucketKeys: [Self.peerShortId])
        #expect(keys == [Self.peerShortId])
        let rows = [meshRow("m0", "Y", at: 100), meshRow("m1", "reply over the internet", at: 200)]
        let merged = snMergeMeshPrivateChats(keys: keys) { $0 == Self.peerShortId ? rows : nil }
        #expect(merged.map(\.id) == ["m0", "m1"])
    }

    @Test
    func anotherPeersNoiseKeyNeverJoinsTheTranscript() {
        let vincenzoNoiseKeyHex = String(repeating: "ab", count: 32)
        let keys = peerKeys(bucketKeys: [
            Self.peerShortId,
            Self.peerNoiseKeyHex,
            vincenzoNoiseKeyHex,
            "abef0238b73563e6",
        ])
        #expect(keys == [Self.peerShortId, Self.peerNoiseKeyHex])
        #expect(!keys.contains(vincenzoNoiseKeyHex))
    }

    @Test
    func nonHexAndAliasShapedBucketsAreNotDuplicated() {
        // A geohash/name-shaped 64-char key is not a Noise key, and an alias
        // already in the key list must not be appended a second time.
        let buckets = [
            Self.peerShortId,
            Self.peerNoiseKeyHex.uppercased(),
            String(repeating: "z", count: 64),
        ]
        let keys = peerKeys(bucketKeys: buckets)
        #expect(keys == [Self.peerShortId, Self.peerNoiseKeyHex])
    }
}
