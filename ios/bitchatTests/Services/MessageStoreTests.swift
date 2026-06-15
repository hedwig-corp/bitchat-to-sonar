//
// MessageStoreTests.swift
// bitchatTests
//
// Round-trip + panic-wipe tests for the on-disk MessageStore that persists
// mesh private chats and public/geohash channel transcripts across restart.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
@testable import bitchat

final class MessageStoreTests: XCTestCase {

    private var store: MessageStore!
    private var dirName: String!

    override func setUp() {
        super.setUp()
        // Unique directory per test so we never touch the real store.
        dirName = "MessagesTest-\(UUID().uuidString)"
        store = MessageStore(directoryName: dirName)
    }

    override func tearDown() {
        store.wipeAll()
        store = nil
        dirName = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Monotonically increasing so stored order is deterministic (the store
    /// sorts by timestamp via cleanedAndDeduped()).
    private var clock = 1_000_000.0

    private func message(
        id: String = UUID().uuidString,
        sender: String = "alice",
        content: String,
        senderPeerID: PeerID? = nil,
        status: DeliveryStatus? = nil
    ) -> BitchatMessage {
        clock += 1
        return BitchatMessage(
            id: id,
            sender: sender,
            content: content,
            timestamp: Date(timeIntervalSince1970: clock),
            isRelay: false,
            isPrivate: senderPeerID != nil,
            senderPeerID: senderPeerID,
            mentions: ["bob"],
            deliveryStatus: status
        )
    }

    /// Wait for the async serial-queue writes to drain before asserting.
    private func flush() {
        // A read (load*) is a sync barrier on the same serial queue, so any
        // queued writes have completed once it returns.
        _ = store.loadAllPrivate()
    }

    // MARK: - Private chat round trip

    func testPrivateAppendAndLoadRoundTrip() {
        let peer = PeerID(str: "a1b2c3d4e5f60718")
        let m1 = message(content: "hi", senderPeerID: peer)
        let m2 = message(content: "there", senderPeerID: peer, status: .sent)
        store.appendPrivate(peerID: peer, message: m1)
        store.appendPrivate(peerID: peer, message: m2)

        let loaded = store.load(peerID: peer)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.map(\.content), ["hi", "there"])
        // All rehydratable fields survive the round trip.
        XCTAssertEqual(loaded[0].id, m1.id)
        XCTAssertEqual(loaded[0].sender, "alice")
        XCTAssertEqual(loaded[0].senderPeerID, peer)
        XCTAssertEqual(loaded[0].mentions, ["bob"])
        XCTAssertEqual(loaded[1].deliveryStatus, .sent)
    }

    func testPrivateAppendDedupesByID() {
        let peer = PeerID(str: "a1b2c3d4e5f60718")
        let m = message(id: "dup", content: "once", senderPeerID: peer)
        store.appendPrivate(peerID: peer, message: m)
        store.appendPrivate(peerID: peer, message: m)
        XCTAssertEqual(store.load(peerID: peer).count, 1)
    }

    func testSavePrivateReplacesTranscript() {
        let peer = PeerID(str: "a1b2c3d4e5f60718")
        store.appendPrivate(peerID: peer, message: message(content: "old", senderPeerID: peer))
        let replacement = [message(content: "new", senderPeerID: peer)]
        store.savePrivate(peerID: peer, messages: replacement)
        XCTAssertEqual(store.load(peerID: peer).map(\.content), ["new"])
    }

    func testLoadAllPrivateReKeysByPeer() {
        let peerA = PeerID(str: "a1b2c3d4e5f60718")
        let peerB = PeerID(str: "f0e1d2c3b4a59687")
        store.appendPrivate(peerID: peerA, message: message(content: "to a", senderPeerID: peerA))
        store.appendPrivate(peerID: peerB, message: message(content: "to b", senderPeerID: peerB))

        let all = store.loadAllPrivate()
        XCTAssertEqual(Set(all.keys), [peerA, peerB])
        XCTAssertEqual(all[peerA]?.first?.content, "to a")
        XCTAssertEqual(all[peerB]?.first?.content, "to b")
    }

    /// A fresh store pointed at the same directory sees the persisted data —
    /// i.e. the transcript survives an "app restart".
    func testPrivateSurvivesNewStoreInstance() {
        let peer = PeerID(str: "a1b2c3d4e5f60718")
        store.appendPrivate(peerID: peer, message: message(content: "persisted", senderPeerID: peer))
        flush()

        let reopened = MessageStore(directoryName: dirName)
        XCTAssertEqual(reopened.load(peerID: peer).map(\.content), ["persisted"])
    }

    // MARK: - Channel round trip

    func testChannelAppendAndLoadRoundTrip() {
        store.appendChannel("mesh", message: message(sender: "carol", content: "mesh hello"))
        store.appendChannel("geo:9q8yy", message: message(sender: "dave", content: "geo hello"))

        XCTAssertEqual(store.loadChannel("mesh").map(\.content), ["mesh hello"])
        XCTAssertEqual(store.loadChannel("geo:9q8yy").map(\.content), ["geo hello"])
        // Different channel ids never collide.
        XCTAssertTrue(store.loadChannel("geo:zzzzz").isEmpty)
    }

    func testSaveChannelReplacesTranscript() {
        store.appendChannel("mesh", message: message(content: "one"))
        store.saveChannel("mesh", messages: [
            message(content: "a"), message(content: "b")
        ])
        XCTAssertEqual(store.loadChannel("mesh").map(\.content), ["a", "b"])
    }

    func testChannelSurvivesNewStoreInstance() {
        store.appendChannel("mesh", message: message(content: "still here"))
        flush()
        let reopened = MessageStore(directoryName: dirName)
        XCTAssertEqual(reopened.loadChannel("mesh").map(\.content), ["still here"])
    }

    // MARK: - Pay-ledger blob (generic Codable passthrough)

    func testPayLedgerBlobRoundTrip() {
        let entry = SonarPayEntry(
            id: "abc", peerKey: "peer1", sats: 21,
            direction: .outgoing, state: .sealed, via: "mesh"
        )
        store.savePayLedger(["abc": entry])
        flush()
        let loaded = store.loadPayLedger([String: SonarPayEntry].self)
        XCTAssertEqual(loaded?["abc"], entry)
    }

    // MARK: - Panic wipe

    func testWipeAllErasesEverything() {
        let peer = PeerID(str: "a1b2c3d4e5f60718")
        store.appendPrivate(peerID: peer, message: message(content: "secret", senderPeerID: peer))
        store.appendChannel("mesh", message: message(content: "public secret"))
        store.appendChannel("geo:9q8yy", message: message(content: "geo secret"))
        flush()

        store.wipeAll()

        XCTAssertTrue(store.load(peerID: peer).isEmpty)
        XCTAssertTrue(store.loadChannel("mesh").isEmpty)
        XCTAssertTrue(store.loadChannel("geo:9q8yy").isEmpty)
        XCTAssertTrue(store.loadAllPrivate().isEmpty)

        // And the data is gone from disk for a freshly opened store too.
        let reopened = MessageStore(directoryName: dirName)
        XCTAssertTrue(reopened.load(peerID: peer).isEmpty)
        XCTAssertTrue(reopened.loadChannel("mesh").isEmpty)
    }

    /// The store keeps working after a wipe (directories are recreated).
    func testStoreUsableAfterWipe() {
        let peer = PeerID(str: "a1b2c3d4e5f60718")
        store.appendPrivate(peerID: peer, message: message(content: "before", senderPeerID: peer))
        store.wipeAll()
        store.appendPrivate(peerID: peer, message: message(content: "after", senderPeerID: peer))
        XCTAssertEqual(store.load(peerID: peer).map(\.content), ["after"])
    }
}
