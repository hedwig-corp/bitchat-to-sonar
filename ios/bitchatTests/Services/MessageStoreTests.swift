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
@testable import Sonar

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
        receivedViaInternet: Bool? = nil,
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
            receivedViaInternet: receivedViaInternet,
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

    func testPrivateRoundTripPreservesInternetArrivalTransport() {
        let peer = PeerID(str: "a1b2c3d4e5f60718")
        store.appendPrivate(
            peerID: peer,
            message: message(
                content: "over Nostr",
                senderPeerID: peer,
                receivedViaInternet: true
            )
        )

        XCTAssertEqual(store.load(peerID: peer).first?.receivedViaInternet, true)
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

    func testFirstPaintReadsOnlyBoundedWindowForHugeTranscript() {
        let peer = PeerID(str: "a1b2c3d4e5f60718")
        let huge = (0..<TransportConfig.privateChatCap).map { index in
            message(id: "huge-\(index)", content: "row-\(index)", senderPeerID: peer)
        }
        store.savePrivate(peerID: peer, messages: huge)
        flush()

        var fullTranscriptReads = 0
        let reopened = MessageStore(
            directoryName: dirName,
            fullTranscriptReadObserver: { fullTranscriptReads += 1 }
        )
        let snapshot = reopened.loadPrivateSnapshot(chatLimit: 1)

        XCTAssertEqual(fullTranscriptReads, 0)
        XCTAssertEqual(snapshot.scannedFileCount, 1)
        XCTAssertEqual(snapshot.chats[peer]?.count, 1)
        XCTAssertEqual(snapshot.chats[peer]?.last?.id, huge.last?.id)
    }

    func testPrivateSnapshotChatPageHasStrictDecodeBound() {
        for index in 0..<40 {
            let peer = PeerID(str: String(format: "%016llx", index + 1))
            store.savePrivate(
                peerID: peer,
                messages: [message(content: "chat-\(index)", senderPeerID: peer)]
            )
        }
        flush()

        let snapshot = store.loadPrivateSnapshot(chatLimit: 7)

        XCTAssertEqual(snapshot.scannedFileCount, 7)
        XCTAssertLessThanOrEqual(snapshot.chats.count, 7)
        XCTAssertTrue(snapshot.hasMore)
    }

    func testManyChatStartupReadsFixedIndexPageWithoutListingSidecars() {
        for index in 0..<80 {
            let peer = PeerID(str: String(format: "%016llx", index + 1))
            store.savePrivate(
                peerID: peer,
                messages: [message(id: "chat-\(index)", content: "row-\(index)", senderPeerID: peer)]
            )
        }
        flush()

        var windowDirectoryListings = 0
        var completeIndexReads = 0
        var windowReads = 0
        let reopened = MessageStore(
            directoryName: dirName,
            privateWindowReadObserver: { windowReads += 1 },
            fullConversationIndexReadObserver: { completeIndexReads += 1 },
            directoryLister: { directory in
                if directory.lastPathComponent == "private-windows" {
                    windowDirectoryListings += 1
                }
                return try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil
                )
            }
        )
        let first = reopened.loadPrivateSnapshot(
            chatLimit: PrivateChatManager.startupChatPageSize
        )

        XCTAssertEqual(windowDirectoryListings, 0)
        XCTAssertEqual(completeIndexReads, 0)
        XCTAssertEqual(windowReads, 0)
        XCTAssertEqual(first.scannedFileCount, PrivateChatManager.startupChatPageSize)
        XCTAssertEqual(first.chats.count, PrivateChatManager.startupChatPageSize)
        XCTAssertTrue(first.chats.values.allSatisfy { $0.count == 1 })
        XCTAssertTrue(first.hasMore)
        XCTAssertNotNil(first.nextCursor)
    }

    func testConversationIndexCursorPaginationIsStableWhenNewChatArrives() async {
        var expectedPeers = Set<PeerID>()
        for index in 0..<55 {
            let peer = PeerID(str: String(format: "%016llx", index + 1))
            expectedPeers.insert(peer)
            store.savePrivate(
                peerID: peer,
                messages: [message(id: "stable-\(index)", content: "row-\(index)", senderPeerID: peer)]
            )
        }
        flush()

        let first = store.loadPrivateSnapshot(chatLimit: 24)
        XCTAssertEqual(first.chats.count, 24)
        let inserted = PeerID(str: "ffffffffffffffff")
        store.savePrivate(
            peerID: inserted,
            messages: [message(id: "inserted-after-page-one", content: "new", senderPeerID: inserted)]
        )
        flush()

        var seen = Set(first.chats.keys)
        var cursor = first.nextCursor
        var hasMore = first.hasMore
        while hasMore {
            let page = await store.loadPrivateSnapshotPage(after: cursor, chatLimit: 24)
            XCTAssertTrue(seen.isDisjoint(with: page.chats.keys))
            seen.formUnion(page.chats.keys)
            cursor = page.nextCursor
            hasMore = page.hasMore
        }

        // The newly inserted chat sorts before the exclusive cursor and is
        // intentionally reserved for a fresh pagination session.
        XCTAssertEqual(seen, expectedPeers)
        XCTAssertFalse(seen.contains(inserted))
    }

    func testConversationIndexMutationAndCursorPageTouchBoundedNodesAtScale() {
        let chatCount = 256
        for index in 0..<chatCount {
            let peer = PeerID(str: String(format: "%016llx", index + 1))
            store.savePrivate(
                peerID: peer,
                messages: [message(id: "scaled-\(index)", content: "row", senderPeerID: peer)]
            )
        }
        flush()

        var nodeReads = 0
        var nodeWrites = 0
        let reopened = MessageStore(
            directoryName: dirName,
            indexNodeReadObserver: { nodeReads += 1 },
            indexNodeWriteObserver: { nodeWrites += 1 }
        )
        let target = PeerID(str: String(format: "%016llx", chatCount / 2))
        reopened.savePrivate(
            peerID: target,
            messages: [message(id: "scaled-updated", content: "updated", senderPeerID: target)]
        )
        _ = reopened.load(peerID: target) // serial-queue barrier

        XCTAssertGreaterThan(nodeWrites, 0)
        XCTAssertLessThan(nodeReads, chatCount / 2)
        XCTAssertLessThan(nodeWrites, chatCount / 2)

        nodeReads = 0
        let first = reopened.loadPrivateSnapshot(chatLimit: 24)
        XCTAssertEqual(nodeReads, 0, "first paint must use the inline manifest page")
        XCTAssertEqual(first.chats.count, 24)

        let second = reopened.loadPrivateSnapshot(after: first.nextCursor, chatLimit: 24)
        XCTAssertEqual(second.chats.count, 24)
        XCTAssertLessThan(nodeReads, chatCount / 2)
    }

    func testLegacyIndexAndWindowsRebuildOnlyInBoundedBackgroundPages() async throws {
        for index in 0..<5 {
            let peer = PeerID(str: String(format: "%016llx", index + 1))
            store.savePrivate(
                peerID: peer,
                messages: [message(id: "legacy-\(index)", content: "row", senderPeerID: peer)]
            )
        }
        flush()
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = support.appendingPathComponent(dirName, isDirectory: true)
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("private-conversation-index.json")
        )
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("private-windows", isDirectory: true)
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("private-windows", isDirectory: true),
            withIntermediateDirectories: true
        )

        var fullTranscriptReads = 0
        var privateDirectoryListings = 0
        let legacy = MessageStore(
            directoryName: dirName,
            fullTranscriptReadObserver: { fullTranscriptReads += 1 },
            directoryLister: { directory in
                if directory.lastPathComponent == "private" {
                    privateDirectoryListings += 1
                }
                return try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil
                )
            }
        )
        XCTAssertTrue(legacy.loadPrivateSnapshot(chatLimit: 24).chats.isEmpty)
        XCTAssertEqual(fullTranscriptReads, 0)

        let firstRepair = await legacy.rebuildLegacyPrivateWindowPage(chatLimit: 2)
        XCTAssertEqual(firstRepair.scannedFileCount, 2)
        XCTAssertEqual(fullTranscriptReads, 2)
        XCTAssertTrue(firstRepair.hasMore)
        while (await legacy.rebuildLegacyPrivateWindowPage(chatLimit: 2)).hasMore {}

        let repaired = legacy.loadPrivateSnapshot(chatLimit: 24)
        XCTAssertEqual(repaired.chats.count, 5)
        XCTAssertEqual(fullTranscriptReads, 5)
        XCTAssertEqual(privateDirectoryListings, 1)
    }

    func testLegacyFullScanNeverBlocksBoundedChatOpen() async throws {
        let target = PeerID(str: "0000000000000001")
        for index in 0..<12 {
            let peer = PeerID(str: String(format: "%016llx", index + 1))
            store.savePrivate(
                peerID: peer,
                messages: [message(id: "concurrent-\(index)", content: "row", senderPeerID: peer)]
            )
        }
        flush()

        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = support.appendingPathComponent(dirName, isDirectory: true)
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("private-conversation-index.json")
        )

        let scanStarted = expectation(description: "legacy scan started")
        let allowScan = DispatchSemaphore(value: 0)
        let observerLock = NSLock()
        var blockedFirstRead = false
        let legacy = MessageStore(
            directoryName: dirName,
            fullTranscriptReadObserver: {
                observerLock.lock()
                let shouldBlock = !blockedFirstRead
                blockedFirstRead = true
                observerLock.unlock()
                if shouldBlock {
                    scanStarted.fulfill()
                    _ = allowScan.wait(timeout: .now() + 5)
                }
            }
        )
        let repair = Task {
            await legacy.rebuildLegacyPrivateWindowPage(chatLimit: 12)
        }
        await fulfillment(of: [scanStarted], timeout: 2)

        let openedAt = Date()
        let recent = legacy.loadRecent(peerID: target)
        let openDuration = Date().timeIntervalSince(openedAt)
        XCTAssertEqual(recent.map(\.id), ["concurrent-0"])
        XCTAssertLessThan(openDuration, 0.5)

        allowScan.signal()
        _ = await repair.value
    }

    @MainActor
    func testWindowMutationPreservesRowsOutsideRenderWindow() {
        let peer = PeerID(str: "a1b2c3d4e5f60718")
        let history = (0..<100).map { index in
            message(id: "history-\(index)", content: "row-\(index)", senderPeerID: peer)
        }
        store.savePrivate(peerID: peer, messages: history)
        flush()

        let manager = PrivateChatManager(store: store)
        XCTAssertEqual(manager.privateChats[peer]?.count, 1)
        manager.privateChats[peer]?.append(
            message(id: "new-row", content: "new", senderPeerID: peer)
        )

        let persisted = store.load(peerID: peer)
        XCTAssertEqual(persisted.count, 101)
        XCTAssertEqual(persisted.first?.id, history.first?.id)
        XCTAssertEqual(persisted.last?.id, "new-row")
    }

    @MainActor
    func testOpeningChatOutsideStartupPageReadsOnlyFiftyMessageWindow() {
        let target = PeerID(str: "0000000000000001")
        let history = (0..<100).map { index in
            message(id: "target-\(index)", content: "row-\(index)", senderPeerID: target)
        }
        store.savePrivate(peerID: target, messages: history)
        for index in 0..<PrivateChatManager.startupChatPageSize {
            let peer = PeerID(str: String(format: "%016llx", index + 2))
            store.savePrivate(
                peerID: peer,
                messages: [message(id: "newer-\(index)", content: "newer", senderPeerID: peer)]
            )
        }
        flush()

        var fullTranscriptReads = 0
        let reopened = MessageStore(
            directoryName: dirName,
            fullTranscriptReadObserver: { fullTranscriptReads += 1 }
        )
        let manager = PrivateChatManager(store: reopened)
        XCTAssertNil(manager.privateChats[target])

        manager.startChat(with: target)

        XCTAssertEqual(manager.privateChats[target]?.count, MessageStore.privateMessageWindowSize)
        XCTAssertEqual(manager.privateChats[target]?.first?.id, "target-50")
        XCTAssertEqual(manager.privateChats[target]?.last?.id, "target-99")
        XCTAssertEqual(fullTranscriptReads, 0)
    }

    @MainActor
    func testOpenChatPagesOlderRowsAndCapsLiveWindow() async {
        let peer = PeerID(str: "0000000000000001")
        let history = (0..<TransportConfig.privateChatCap).map { index in
            message(id: "paged-\(index)", content: "row-\(index)", senderPeerID: peer)
        }
        store.savePrivate(peerID: peer, messages: history)
        flush()

        let manager = PrivateChatManager(store: store)
        XCTAssertEqual(manager.privateChats[peer]?.count, 1, "chat list retains only a summary")
        manager.startChat(with: peer)
        XCTAssertEqual(manager.privateChats[peer]?.count, MessageStore.privateMessageWindowSize)
        XCTAssertEqual(manager.privateChats[peer]?.first?.id, "paged-1287")

        while manager.canLoadOlderMessages(for: peer) {
            _ = await manager.loadOlderMessages(for: peer)
        }

        XCTAssertEqual(manager.privateChats[peer]?.count, TransportConfig.privateChatCap)
        XCTAssertEqual(manager.privateChats[peer]?.first?.id, "paged-0")
        manager.privateChats[peer]?.append(
            message(id: "beyond-cap", content: "new", senderPeerID: peer)
        )
        XCTAssertEqual(manager.privateChats[peer]?.count, TransportConfig.privateChatCap)
        XCTAssertEqual(manager.privateChats[peer]?.last?.id, "beyond-cap")

        manager.endChat()
        XCTAssertEqual(manager.privateChats[peer]?.map(\.id), ["beyond-cap"])
    }

    @MainActor
    func testBackgroundHydrationRetainsSummariesOnly() async {
        for index in 0..<60 {
            let peer = PeerID(str: String(format: "%016llx", index + 1))
            store.savePrivate(
                peerID: peer,
                messages: (0..<80).map { row in
                    message(id: "summary-\(index)-\(row)", content: "row", senderPeerID: peer)
                }
            )
        }
        flush()
        var windowReads = 0
        let reopened = MessageStore(
            directoryName: dirName,
            privateWindowReadObserver: { windowReads += 1 }
        )
        let manager = PrivateChatManager(store: reopened)

        await manager.hydrateRemainingChatPages()

        XCTAssertEqual(manager.privateChats.count, 60)
        XCTAssertTrue(manager.privateChats.values.allSatisfy { $0.count == 1 })
        XCTAssertEqual(windowReads, 0)
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

    func testDurableCommitSurvivesNewStoreInstance() async {
        let peer = PeerID(str: "a1b2c3d4e5f60718")
        let committed = message(content: "durable", senderPeerID: peer)

        let didCommit = await store.commitPrivate(peerID: peer, messages: [committed])
        XCTAssertTrue(didCommit)

        let reopened = MessageStore(directoryName: dirName)
        XCTAssertEqual(reopened.load(peerID: peer).map(\.content), ["durable"])
    }

    func testWipeFencesSuspendedOldAccountCommit() async {
        let peer = PeerID(str: "a1b2c3d4e5f60718")
        let oldGeneration = store.currentStorageGeneration()
        store.wipeAll()

        let committed = await store.commitPrivate(
            peerID: peer,
            messages: [message(content: "old account", senderPeerID: peer)],
            expectedGeneration: oldGeneration
        )

        XCTAssertFalse(committed)
        XCTAssertTrue(store.load(peerID: peer).isEmpty)
    }

    func testFailedWipeQuarantineKeepsOldStoreAndFencesStaleCommit() async {
        enum SimulatedFailure: Error { case beforeQuarantine }
        let peer = PeerID(str: "a1b2c3d4e5f60718")
        store.appendPrivate(peerID: peer, message: message(content: "old account", senderPeerID: peer))
        flush()

        let failingStore = MessageStore(
            directoryName: dirName,
            beforeWipeQuarantine: { throw SimulatedFailure.beforeQuarantine }
        )
        let oldGeneration = failingStore.currentStorageGeneration()
        let result = failingStore.wipeAll()
        let staleCommit = await failingStore.commitPrivate(
            peerID: peer,
            messages: [message(content: "stale write", senderPeerID: peer)],
            expectedGeneration: oldGeneration
        )

        XCTAssertFalse(result.quarantined)
        XCTAssertFalse(staleCommit)
        XCTAssertEqual(MessageStore(directoryName: dirName).load(peerID: peer).map(\.content), ["old account"])
    }

    func testDurableCommitOrdersAfterQueuedWrite() async {
        let peer = PeerID(str: "a1b2c3d4e5f60718")
        store.savePrivate(
            peerID: peer,
            messages: [message(content: "queued-old", senderPeerID: peer)]
        )
        let newest = message(content: "committed-new", senderPeerID: peer)

        let didCommit = await store.commitPrivate(peerID: peer, messages: [newest])
        XCTAssertTrue(didCommit)

        let reopened = MessageStore(directoryName: dirName)
        XCTAssertEqual(reopened.load(peerID: peer).map(\.content), ["committed-new"])
    }

    func testFailedAtomicReplaceKeepsPreviousCommitIntact() async {
        enum SimulatedCrash: Error { case beforeRename }

        let peer = PeerID(str: "a1b2c3d4e5f60718")
        let previous = message(content: "previous", senderPeerID: peer)
        let didSeed = await store.commitPrivate(peerID: peer, messages: [previous])
        XCTAssertTrue(didSeed)

        let failingStore = MessageStore(
            directoryName: dirName,
            beforeAtomicReplace: { throw SimulatedCrash.beforeRename }
        )
        let replacement = message(content: "partial", senderPeerID: peer)
        let didReplace = await failingStore.commitPrivate(peerID: peer, messages: [replacement])
        XCTAssertFalse(didReplace)

        let reopened = MessageStore(directoryName: dirName)
        XCTAssertEqual(reopened.load(peerID: peer).map(\.content), ["previous"])
    }

    func testDurableCommitRejectsEveryDirectoryDurabilityFailure() async {
        enum SimulatedFailure: Error { case directory(DirectoryDurabilityStage) }
        let peer = PeerID(str: "a1b2c3d4e5f60718")

        for stage in [DirectoryDurabilityStage.open, .fsync, .close] {
            let failingStore = MessageStore(
                directoryName: dirName,
                directorySyncFault: { _, current in
                    if current == stage { throw SimulatedFailure.directory(current) }
                }
            )
            let committed = await failingStore.commitPrivate(
                peerID: peer,
                messages: [message(content: "must not ACK", senderPeerID: peer)],
                pendingReceiveEffectMessageID: "must-not-ack-\(stage)"
            )
            XCTAssertFalse(committed, "directory \(stage) failure must withhold ACK")
        }
    }

    func testControlReceiptIsDurableAndIdempotent() async {
        let peer = PeerID(str: "a1b2c3d4e5f60718")

        let firstCommit = await store.commitControlReceipt(peerID: peer, messageID: "control-1")
        let duplicateCommit = await store.commitControlReceipt(peerID: peer, messageID: "control-1")
        XCTAssertTrue(firstCommit)
        XCTAssertTrue(duplicateCommit)

        let reopened = MessageStore(directoryName: dirName)
        XCTAssertTrue(reopened.hasControlReceipt(peerID: peer, messageID: "control-1"))
    }

    func testReceiveEffectsObligationSurvivesCrashAndClearsDurably() async {
        let peer = PeerID(str: "a1b2c3d4e5f60718")
        let incoming = message(id: "incoming-1", content: "hello", senderPeerID: peer)
        let generation = store.currentStorageGeneration()

        let committed = await store.commitPrivate(
            peerID: peer,
            messages: [incoming],
            expectedGeneration: generation,
            pendingReceiveEffectMessageID: incoming.id
        )
        XCTAssertTrue(committed)

        let reopened = MessageStore(directoryName: dirName)
        XCTAssertTrue(reopened.hasPendingReceiveEffects(peerID: peer, messageID: incoming.id))
        let reopenedPending = await reopened.loadPendingReceiveEffects()
        XCTAssertEqual(reopenedPending.map { $0.message.id }, [incoming.id])
        let processed = await reopened.commitReceiveEffectsProcessed(
            peerID: peer,
            messageID: incoming.id,
            expectedGeneration: reopened.currentStorageGeneration()
        )
        XCTAssertTrue(processed)

        let verified = MessageStore(directoryName: dirName)
        XCTAssertEqual(verified.load(peerID: peer).map(\.id), [incoming.id])
        XCTAssertFalse(verified.hasPendingReceiveEffects(peerID: peer, messageID: incoming.id))
        let verifiedPending = await verified.loadPendingReceiveEffects()
        XCTAssertTrue(verifiedPending.isEmpty)
    }

    func testIncomingStableIDCollisionKeepsStoredPayloadAndDoesNotRearmEffects() async {
        let peer = PeerID(str: "stable-receive-peer")
        let original = message(id: "stable-receive-id", content: "original", senderPeerID: peer)
        let generation = store.currentStorageGeneration()
        let admitted = await store.commitIncomingPrivate(
            peerID: peer,
            message: original,
            expectedGeneration: generation
        )
        XCTAssertEqual(admitted.disposition, .admitted)
        let processed = await store.commitReceiveEffectsProcessed(
            peerID: peer,
            messageID: original.id,
            expectedGeneration: generation
        )
        XCTAssertTrue(processed)

        let collision = message(id: original.id, content: "replacement", senderPeerID: peer)
        let duplicate = await store.commitIncomingPrivate(
            peerID: peer,
            message: collision,
            expectedGeneration: generation
        )

        XCTAssertEqual(duplicate.disposition, .duplicate)
        XCTAssertEqual(duplicate.message?.content, "original")
        XCTAssertEqual(store.load(peerID: peer).map(\.content), ["original"])
        let pending = await store.loadPendingReceiveEffects()
        XCTAssertTrue(pending.isEmpty)
    }

    @MainActor
    func testStableIDReceiptMutatesClosedNonLatestRowWithoutPromotingIt() async {
        let peer = PeerID(str: "receipt-history-peer")
        let older = message(
            id: "receipt-older",
            content: "older",
            senderPeerID: peer,
            status: .sent
        )
        let newer = message(
            id: "receipt-newer",
            content: "newer",
            senderPeerID: peer,
            status: .sent
        )
        let seeded = await store.commitPrivate(peerID: peer, messages: [older, newer])
        XCTAssertTrue(seeded)

        let manager = PrivateChatManager(store: store)
        XCTAssertEqual(manager.privateChats[peer]?.map(\.id), [newer.id])

        let deliveredAt = Date(timeIntervalSince1970: 2_000_000)
        let delivered = await manager.commitDeliveryStatus(
            messageID: older.id,
            status: .delivered(to: "alice", at: deliveredAt),
            preferredPeerIDs: [peer],
            expectedGeneration: manager.currentStorageGeneration()
        )
        XCTAssertEqual(delivered.disposition, .updated)
        XCTAssertFalse(delivered.isLatest)
        XCTAssertEqual(manager.privateChats[peer]?.map(\.id), [newer.id])
        XCTAssertEqual(manager.privateChats[peer]?.first?.deliveryStatus, .sent)

        let duplicate = await store.commitPrivateDeliveryStatus(
            peerIDs: [peer],
            messageID: older.id,
            status: .delivered(to: "replacement", at: deliveredAt.addingTimeInterval(30)),
            expectedGeneration: store.currentStorageGeneration()
        )
        XCTAssertEqual(duplicate.disposition, .unchanged)
        XCTAssertEqual(
            store.load(peerID: peer).first(where: { $0.id == older.id })?.deliveryStatus,
            .delivered(to: "alice", at: deliveredAt)
        )

        let readAt = deliveredAt.addingTimeInterval(60)
        let read = await store.commitPrivateDeliveryStatus(
            peerIDs: [peer],
            messageID: older.id,
            status: .read(by: "alice", at: readAt),
            expectedGeneration: store.currentStorageGeneration()
        )
        XCTAssertEqual(read.disposition, .updated)
        let lateDelivered = await store.commitPrivateDeliveryStatus(
            peerIDs: [peer],
            messageID: older.id,
            status: .delivered(to: "alice", at: readAt.addingTimeInterval(30)),
            expectedGeneration: store.currentStorageGeneration()
        )
        XCTAssertEqual(lateDelivered.disposition, .unchanged)

        let latest = await manager.commitDeliveryStatus(
            messageID: newer.id,
            status: .delivered(to: "alice", at: deliveredAt),
            preferredPeerIDs: [peer],
            expectedGeneration: manager.currentStorageGeneration()
        )
        XCTAssertEqual(latest.disposition, .updated)
        XCTAssertTrue(latest.isLatest)
        XCTAssertEqual(
            manager.privateChats[peer]?.first?.deliveryStatus,
            .delivered(to: "alice", at: deliveredAt)
        )

        let reopened = MessageStore(directoryName: dirName)
        let reopenedManager = PrivateChatManager(store: reopened)
        XCTAssertEqual(reopenedManager.privateChats[peer]?.map(\.id), [newer.id])
        reopenedManager.startChat(with: peer)
        XCTAssertEqual(
            reopenedManager.privateChats[peer]?.first(where: { $0.id == older.id })?.deliveryStatus,
            .read(by: "alice", at: readAt)
        )
        XCTAssertEqual(
            reopenedManager.privateChats[peer]?.first(where: { $0.id == newer.id })?.deliveryStatus,
            .delivered(to: "alice", at: deliveredAt)
        )
    }

    func testDuplicateReceiptRepairsWindowAfterPartialDurableCommit() async {
        enum SimulatedFailure: Error { case beforeWindowReplace }
        let peer = PeerID(str: "receipt-repair-peer")
        let message = message(
            id: "receipt-repair-id",
            content: "repair",
            senderPeerID: peer,
            status: .sent
        )
        let seeded = await store.commitPrivate(peerID: peer, messages: [message])
        XCTAssertTrue(seeded)

        var replaceCount = 0
        let failing = MessageStore(
            directoryName: dirName,
            beforeAtomicReplace: {
                replaceCount += 1
                if replaceCount == 2 { throw SimulatedFailure.beforeWindowReplace }
            }
        )
        let deliveredAt = Date(timeIntervalSince1970: 3_000_000)
        let partial = await failing.commitPrivateDeliveryStatus(
            peerIDs: [peer],
            messageID: message.id,
            status: .delivered(to: "alice", at: deliveredAt),
            expectedGeneration: failing.currentStorageGeneration()
        )
        XCTAssertEqual(partial.disposition, .failed)
        XCTAssertEqual(
            failing.load(peerID: peer).first?.deliveryStatus,
            .delivered(to: "alice", at: deliveredAt),
            "the full transcript crossed its rename before the sidecar fault"
        )
        XCTAssertEqual(failing.loadRecent(peerID: peer).first?.deliveryStatus, .sent)

        let retrying = MessageStore(directoryName: dirName)
        let repaired = await retrying.commitPrivateDeliveryStatus(
            peerIDs: [peer],
            messageID: message.id,
            status: .delivered(to: "replacement", at: deliveredAt.addingTimeInterval(60)),
            expectedGeneration: retrying.currentStorageGeneration()
        )
        XCTAssertEqual(repaired.disposition, .unchanged)

        let reopened = MessageStore(directoryName: dirName)
        XCTAssertEqual(
            reopened.loadRecent(peerID: peer).first?.deliveryStatus,
            .delivered(to: "alice", at: deliveredAt)
        )
    }

    func testProcessedStableIDReceiptSurvivesTranscriptCapEviction() async {
        let peer = PeerID(str: "stable-receipt-peer")
        let original = message(id: "receipt-id", content: "original", senderPeerID: peer)
        let generation = store.currentStorageGeneration()
        let admitted = await store.commitIncomingPrivate(
            peerID: peer,
            message: original,
            expectedGeneration: generation
        )
        XCTAssertEqual(admitted.disposition, .admitted)
        let processed = await store.commitReceiveEffectsProcessed(
            peerID: peer,
            messageID: original.id,
            expectedGeneration: generation
        )
        XCTAssertTrue(processed)
        let newer = (0..<TransportConfig.privateChatCap).map { index in
            message(id: "newer-\(index)", content: "row", senderPeerID: peer)
        }
        store.savePrivate(peerID: peer, messages: newer)
        flush()
        XCTAssertFalse(store.load(peerID: peer).contains { $0.id == original.id })

        let replay = await store.commitIncomingPrivate(
            peerID: peer,
            message: original,
            expectedGeneration: generation
        )

        XCTAssertEqual(replay.disposition, .duplicate)
        XCTAssertNil(replay.message)
        XCTAssertFalse(store.load(peerID: peer).contains { $0.id == original.id })
    }

    func testPendingEffectReplayReadsOnlyIndexedPeersWithoutDirectoryScan() async {
        let pendingPeer = PeerID(str: "0000000000000001")
        let incoming = message(id: "pending-indexed", content: "hello", senderPeerID: pendingPeer)
        let committed = await store.commitPrivate(
            peerID: pendingPeer,
            messages: [incoming],
            pendingReceiveEffectMessageID: incoming.id
        )
        XCTAssertTrue(committed)
        for index in 2...40 {
            let peer = PeerID(str: String(format: "%016llx", index))
            store.savePrivate(
                peerID: peer,
                messages: [message(id: "unrelated-\(index)", content: "row", senderPeerID: peer)]
            )
        }
        flush()

        var fullTranscriptReads = 0
        var privateDirectoryListings = 0
        let reopened = MessageStore(
            directoryName: dirName,
            fullTranscriptReadObserver: { fullTranscriptReads += 1 },
            directoryLister: { directory in
                if directory.lastPathComponent == "private" {
                    privateDirectoryListings += 1
                }
                return try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil
                )
            }
        )

        let pending = await reopened.loadPendingReceiveEffects()

        XCTAssertEqual(pending.map { $0.message.id }, [incoming.id])
        XCTAssertEqual(fullTranscriptReads, 1)
        XCTAssertEqual(privateDirectoryListings, 0)
    }

    func testBlockedManyPendingEffectReplayNeverBlocksBoundedChatOpen() async {
        let pendingCount = 40
        let target = PeerID(str: "0000000000000001")
        for index in 0..<pendingCount {
            let peer = PeerID(str: String(format: "%016llx", index + 1))
            let incoming = message(
                id: "pending-many-\(index)",
                content: "row-\(index)",
                senderPeerID: peer
            )
            let committed = await store.commitPrivate(
                peerID: peer,
                messages: [incoming],
                pendingReceiveEffectMessageID: incoming.id
            )
            XCTAssertTrue(committed)
        }

        let replayStarted = expectation(description: "pending replay started")
        let allowReplay = DispatchSemaphore(value: 0)
        let observerLock = NSLock()
        var blockedFirstRead = false
        var fullTranscriptReads = 0
        let reopened = MessageStore(
            directoryName: dirName,
            fullTranscriptReadObserver: {
                observerLock.lock()
                fullTranscriptReads += 1
                let shouldBlock = !blockedFirstRead
                blockedFirstRead = true
                observerLock.unlock()
                if shouldBlock {
                    replayStarted.fulfill()
                    _ = allowReplay.wait(timeout: .now() + 5)
                }
            }
        )
        let replay = Task { await reopened.loadPendingReceiveEffects() }
        await fulfillment(of: [replayStarted], timeout: 2)

        let openedAt = Date()
        let recent = reopened.loadRecent(peerID: target)
        let openDuration = Date().timeIntervalSince(openedAt)
        XCTAssertEqual(recent.map(\.id), ["pending-many-0"])
        XCTAssertLessThan(openDuration, 0.5)

        allowReplay.signal()
        let pending = await replay.value
        XCTAssertEqual(pending.count, pendingCount)
        XCTAssertEqual(fullTranscriptReads, pendingCount)
    }

    func testPendingEffectReplayCleanupPreservesConcurrentCommit() async {
        enum SimulatedCrash: Error { case beforeTranscriptRename }

        let stalePeer = PeerID(str: "0000000000000001")
        let stale = message(id: "stale-replay", content: "stale", senderPeerID: stalePeer)
        let faultLock = NSLock()
        var durableWriteCount = 0
        let interruptedStore = MessageStore(
            directoryName: dirName,
            beforeAtomicReplace: {
                faultLock.lock(); defer { faultLock.unlock() }
                durableWriteCount += 1
                if durableWriteCount == 2 {
                    throw SimulatedCrash.beforeTranscriptRename
                }
            }
        )
        let interrupted = await interruptedStore.commitPrivate(
            peerID: stalePeer,
            messages: [stale],
            pendingReceiveEffectMessageID: stale.id
        )
        XCTAssertFalse(interrupted)

        let validationStarted = expectation(description: "stale replay validation started")
        let allowValidation = DispatchSemaphore(value: 0)
        let observerLock = NSLock()
        var blockedFirstRead = false
        let replayingStore = MessageStore(
            directoryName: dirName,
            fullTranscriptReadObserver: {
                observerLock.lock()
                let shouldBlock = !blockedFirstRead
                blockedFirstRead = true
                observerLock.unlock()
                if shouldBlock {
                    validationStarted.fulfill()
                    _ = allowValidation.wait(timeout: .now() + 5)
                }
            }
        )
        let replay = Task { await replayingStore.loadPendingReceiveEffects() }
        await fulfillment(of: [validationStarted], timeout: 2)

        let addedPeer = PeerID(str: "0000000000000002")
        let added = message(id: "added-during-replay", content: "new", senderPeerID: addedPeer)
        let committed = await replayingStore.commitPrivate(
            peerID: addedPeer,
            messages: [added],
            pendingReceiveEffectMessageID: added.id
        )
        XCTAssertTrue(committed)

        allowValidation.signal()
        let replayed = await replay.value
        XCTAssertTrue(replayed.isEmpty)

        let verified = MessageStore(directoryName: dirName)
        let pending = await verified.loadPendingReceiveEffects()
        XCTAssertEqual(pending.map { $0.peerID }, [addedPeer])
        XCTAssertEqual(pending.map { $0.message.id }, [added.id])
    }

    func testPendingEffectIndexCorruptionFailsClosedWithoutOverwriting() async throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let indexURL = support
            .appendingPathComponent(dirName, isDirectory: true)
            .appendingPathComponent("pending-receive-effects.json")
        let corrupt = Data("not-a-pending-index".utf8)
        try corrupt.write(to: indexURL, options: .atomic)
        let peer = PeerID(str: "0000000000000001")
        let incoming = message(id: "must-not-overwrite", content: "hello", senderPeerID: peer)

        let committed = await store.commitPrivate(
            peerID: peer,
            messages: [incoming],
            pendingReceiveEffectMessageID: incoming.id
        )

        XCTAssertFalse(committed)
        XCTAssertEqual(try Data(contentsOf: indexURL), corrupt)
        XCTAssertTrue(store.load(peerID: peer).isEmpty)
    }

    func testQueuedTranscriptWriterPreservesPendingReceiveEffects() async {
        let peer = PeerID(str: "a1b2c3d4e5f60718")
        let incoming = message(id: "incoming-2", content: "hello", senderPeerID: peer)
        let committed = await store.commitPrivate(
            peerID: peer,
            messages: [incoming],
            pendingReceiveEffectMessageID: incoming.id
        )
        XCTAssertTrue(committed)

        store.savePrivate(peerID: peer, messages: [
            incoming,
            message(content: "later", senderPeerID: peer),
        ])
        flush()

        XCTAssertTrue(store.hasPendingReceiveEffects(peerID: peer, messageID: incoming.id))
    }

    // MARK: - Durable mesh outbox

    func testMeshOutboxRestoresAcrossProcessAndRemovesOnlyOnPeerAck() {
        let owner = "owner-a"
        let firstFence = "process-a"
        let peer = PeerID(str: "a1b2c3d4e5f60718")
        store.activateMeshOutbox(ownerID: owner, fence: firstFence)
        let enqueued = store.enqueueMeshObligation(
            ownerID: owner,
            fence: firstFence,
            messageID: "out-1",
            peerID: peer,
            recipientNickname: "alice",
            content: "hello",
            kind: .text
        )
        XCTAssertEqual(enqueued?.obligation.messageID, "out-1")

        let reopened = MessageStore(directoryName: dirName)
        reopened.activateMeshOutbox(ownerID: owner, fence: "process-b")
        XCTAssertEqual(
            reopened.loadMeshObligations(ownerID: owner, fence: "process-b")?.obligations.map(\.messageID),
            ["out-1"]
        )
        XCTAssertEqual(
            reopened.acknowledgeMeshObligation(
                ownerID: owner,
                fence: "process-b",
                messageID: "out-1",
                from: PeerID(str: "wrong-peer")
            ),
            .peerMismatch
        )
        XCTAssertEqual(
            reopened.acknowledgeMeshObligation(
                ownerID: owner,
                fence: "process-b",
                messageID: "out-1",
                from: peer
            ),
            .removed
        )
        XCTAssertTrue(
            reopened.loadMeshObligations(ownerID: owner, fence: "process-b")?.obligations.isEmpty == true
        )
    }

    func testMeshOutboxSameInstantUsesStableTotalOrder() {
        let owner = "owner-order"
        let fence = "process-order"
        let peer = PeerID(str: "a1b2c3d4e5f60718")
        let instant = Date(timeIntervalSince1970: 1_000)
        store.activateMeshOutbox(ownerID: owner, fence: fence)

        let first = store.enqueueMeshObligation(
            ownerID: owner, fence: fence, messageID: "first", peerID: peer,
            recipientNickname: "alice", content: "one", kind: .text, createdAt: instant
        )
        let second = store.enqueueMeshObligation(
            ownerID: owner, fence: fence, messageID: "second", peerID: peer,
            recipientNickname: "alice", content: "two", kind: .text, createdAt: instant
        )

        XCTAssertEqual(first?.obligation.sequence, 0)
        XCTAssertEqual(second?.obligation.sequence, 1)
        XCTAssertEqual(
            (second?.obligation.wireTimestampMillis ?? 0),
            (first?.obligation.wireTimestampMillis ?? 0) + 1
        )
        XCTAssertEqual(
            store.loadMeshObligations(ownerID: owner, fence: fence, now: instant)?.obligations.map(\.messageID),
            ["first", "second"]
        )
    }

    func testMeshOutboxPerPeerCapRejectsNewAdmissionWithoutEvictingAcceptedWork() {
        let owner = "owner-cap"
        let fence = "process-cap"
        let peer = PeerID(str: "a1b2c3d4e5f60718")
        let instant = Date(timeIntervalSince1970: 2_000)
        store.activateMeshOutbox(ownerID: owner, fence: fence)
        for index in 0..<100 {
            XCTAssertNotNil(store.enqueueMeshObligation(
                ownerID: owner,
                fence: fence,
                messageID: "m-\(index)",
                peerID: peer,
                recipientNickname: "alice",
                content: "message \(index)",
                kind: .text,
                createdAt: instant
            ))
        }

        XCTAssertNil(store.enqueueMeshObligation(
            ownerID: owner,
            fence: fence,
            messageID: "m-100",
            peerID: peer,
            recipientNickname: "alice",
            content: "message 100",
            kind: .text,
            createdAt: instant
        ))
        let ids = store.loadMeshObligations(
            ownerID: owner,
            fence: fence,
            now: instant
        )?.obligations.map(\.messageID)
        XCTAssertEqual(ids?.count, 100)
        XCTAssertEqual(ids?.first, "m-0")
        XCTAssertEqual(ids?.last, "m-99")
    }

    func testMeshOutboxStableIDRetryRequiresExactImmutableObligation() {
        let owner = "owner-idempotency"
        let fence = "process-idempotency"
        let peer = PeerID(str: "a1b2c3d4e5f60718")
        let otherPeer = PeerID(str: "f0e1d2c3b4a59687")
        store.activateMeshOutbox(ownerID: owner, fence: fence)
        let original = store.enqueueMeshObligation(
            ownerID: owner, fence: fence, messageID: "stable", peerID: peer,
            recipientNickname: "alice", content: "hello", kind: .text
        )
        XCTAssertNotNil(original)

        let exactRetry = store.enqueueMeshObligation(
            ownerID: owner, fence: fence, messageID: "stable", peerID: peer,
            recipientNickname: "renamed locally", content: "hello", kind: .text
        )
        XCTAssertEqual(exactRetry?.obligation, original?.obligation)
        XCTAssertNil(store.enqueueMeshObligation(
            ownerID: owner, fence: fence, messageID: "stable", peerID: otherPeer,
            recipientNickname: "alice", content: "hello", kind: .text
        ))
        XCTAssertNil(store.enqueueMeshObligation(
            ownerID: owner, fence: fence, messageID: "stable", peerID: peer,
            recipientNickname: "alice", content: "different", kind: .text
        ))
        XCTAssertNil(store.enqueueMeshObligation(
            ownerID: owner, fence: fence, messageID: "stable", peerID: peer,
            recipientNickname: "alice", content: "hello", kind: .paymentControl
        ))
        XCTAssertEqual(
            store.loadMeshObligations(ownerID: owner, fence: fence)?.obligations,
            [original!.obligation]
        )
    }

    func testMeshOutboxGlobalCapRejectsNewAdmissionWithoutEviction() {
        let owner = "owner-global-cap"
        let fence = "process-global-cap"
        let instant = Date(timeIntervalSince1970: 3_000)
        let peers = (0..<5).map {
            PeerID(str: String(format: "%016llx", $0 + 1))
        }
        store.activateMeshOutbox(ownerID: owner, fence: fence)

        for (peerIndex, peer) in peers.enumerated() {
            for itemIndex in 0..<100 {
                XCTAssertNotNil(store.enqueueMeshObligation(
                    ownerID: owner,
                    fence: fence,
                    messageID: "global-\(peerIndex)-\(itemIndex)",
                    peerID: peer,
                    recipientNickname: "peer-\(peerIndex)",
                    content: "message \(itemIndex)",
                    kind: .text,
                    createdAt: instant
                ))
            }
        }
        let overflowPeer = PeerID(str: "ffffffffffffffff")
        XCTAssertNil(store.enqueueMeshObligation(
            ownerID: owner,
            fence: fence,
            messageID: "global-overflow",
            peerID: overflowPeer,
            recipientNickname: "overflow",
            content: "must be rejected",
            kind: .text,
            createdAt: instant
        ))
        let obligations = store.loadMeshObligations(
            ownerID: owner,
            fence: fence,
            now: instant
        )?.obligations
        XCTAssertEqual(obligations?.count, 500)
        XCTAssertEqual(obligations?.first?.messageID, "global-0-0")
        XCTAssertEqual(obligations?.last?.messageID, "global-4-99")
    }

    func testMeshOutboxFenceRejectsPreWipeWork() {
        let owner = "owner-wipe"
        let oldFence = "before-wipe"
        let newFence = "after-wipe"
        let peer = PeerID(str: "a1b2c3d4e5f60718")
        store.activateMeshOutbox(ownerID: owner, fence: oldFence)
        XCTAssertNotNil(store.enqueueMeshObligation(
            ownerID: owner, fence: oldFence, messageID: "secret", peerID: peer,
            recipientNickname: "alice", content: "secret", kind: .text
        ))

        store.invalidateMeshOutbox(ownerID: owner, fence: oldFence)
        store.activateMeshOutbox(ownerID: owner, fence: newFence)

        XCTAssertNil(store.enqueueMeshObligation(
            ownerID: owner, fence: oldFence, messageID: "stale", peerID: peer,
            recipientNickname: "alice", content: "stale", kind: .text
        ))
        XCTAssertTrue(
            store.loadMeshObligations(ownerID: owner, fence: newFence)?.obligations.isEmpty == true
        )
    }

    func testMeshOutboxPrunesExpiredControlWithoutSending() {
        let owner = "owner-expiry"
        let fence = "process-expiry"
        let peer = PeerID(str: "a1b2c3d4e5f60718")
        let created = Date(timeIntervalSince1970: 1_000)
        store.activateMeshOutbox(ownerID: owner, fence: fence)
        XCTAssertNotNil(store.enqueueMeshObligation(
            ownerID: owner, fence: fence, messageID: "call-old", peerID: peer,
            recipientNickname: "alice", content: "☎CALL|offer", kind: .callControl,
            createdAt: created
        ))

        let loaded = store.loadMeshObligations(
            ownerID: owner,
            fence: fence,
            now: created.addingTimeInterval(61)
        )
        XCTAssertEqual(loaded?.expiredMessageIDs, ["call-old"])
        XCTAssertTrue(loaded?.obligations.isEmpty == true)
    }

    func testMeshOutboxAckWriteFailurePreservesObligation() {
        enum SimulatedFailure: Error { case beforeRename }
        let owner = "owner-ack-failure"
        let peer = PeerID(str: "a1b2c3d4e5f60718")
        store.activateMeshOutbox(ownerID: owner, fence: "seed")
        XCTAssertNotNil(store.enqueueMeshObligation(
            ownerID: owner, fence: "seed", messageID: "out-fail", peerID: peer,
            recipientNickname: "alice", content: "hello", kind: .text
        ))

        let failingStore = MessageStore(
            directoryName: dirName,
            beforeAtomicReplace: { throw SimulatedFailure.beforeRename }
        )
        failingStore.activateMeshOutbox(ownerID: owner, fence: "failed-process")
        XCTAssertEqual(
            failingStore.acknowledgeMeshObligation(
                ownerID: owner,
                fence: "failed-process",
                messageID: "out-fail",
                from: peer
            ),
            .failed
        )

        let reopened = MessageStore(directoryName: dirName)
        reopened.activateMeshOutbox(ownerID: owner, fence: "verify")
        XCTAssertEqual(
            reopened.loadMeshObligations(ownerID: owner, fence: "verify")?.obligations.map(\.messageID),
            ["out-fail"]
        )
    }

    func testConversationPruneFailurePreservesOutboxAndTranscriptAcrossRestart() {
        enum SimulatedFailure: Error { case beforeRename }
        let owner = "owner-delete-failure"
        let peer = PeerID(str: "a1b2c3d4e5f60718")
        let transcript = message(content: "unsent", senderPeerID: peer)
        store.savePrivate(peerID: peer, messages: [transcript])
        store.activateMeshOutbox(ownerID: owner, fence: "seed")
        XCTAssertNotNil(store.enqueueMeshObligation(
            ownerID: owner,
            fence: "seed",
            messageID: transcript.id,
            peerID: peer,
            recipientNickname: "alice",
            content: transcript.content,
            kind: .text
        ))

        let failingStore = MessageStore(
            directoryName: dirName,
            beforeAtomicReplace: { throw SimulatedFailure.beforeRename }
        )
        failingStore.activateMeshOutbox(ownerID: owner, fence: "delete")
        XCTAssertFalse(failingStore.pruneMeshObligations(
            ownerID: owner,
            fence: "delete",
            peerIDs: [peer]
        ))

        let reopened = MessageStore(directoryName: dirName)
        reopened.activateMeshOutbox(ownerID: owner, fence: "verify")
        XCTAssertEqual(
            reopened.loadMeshObligations(ownerID: owner, fence: "verify")?.obligations.map(\.messageID),
            [transcript.id]
        )
        XCTAssertEqual(reopened.load(peerID: peer).map(\.id), [transcript.id])
    }

    func testConversationPruneAndTranscriptDeleteSurviveRestart() {
        let owner = "owner-delete-success"
        let peer = PeerID(str: "a1b2c3d4e5f60718")
        let transcript = message(content: "delete me", senderPeerID: peer)
        store.savePrivate(peerID: peer, messages: [transcript])
        store.activateMeshOutbox(ownerID: owner, fence: "seed")
        XCTAssertNotNil(store.enqueueMeshObligation(
            ownerID: owner,
            fence: "seed",
            messageID: transcript.id,
            peerID: peer,
            recipientNickname: "alice",
            content: transcript.content,
            kind: .text
        ))

        XCTAssertTrue(store.pruneMeshObligations(
            ownerID: owner,
            fence: "seed",
            peerIDs: [peer]
        ))
        XCTAssertTrue(store.deletePrivateDurably(peerID: peer))

        let reopened = MessageStore(directoryName: dirName)
        reopened.activateMeshOutbox(ownerID: owner, fence: "verify")
        XCTAssertTrue(
            reopened.loadMeshObligations(ownerID: owner, fence: "verify")?.obligations.isEmpty == true
        )
        XCTAssertTrue(reopened.load(peerID: peer).isEmpty)
    }

    func testBatchConversationDeleteRemovesEveryAliasInOneCommittedResult() async {
        let aliasA = PeerID(str: "alias-delete-a")
        let aliasB = PeerID(str: "alias-delete-b")
        let survivor = PeerID(str: "alias-delete-survivor")
        let messageA = message(id: "alias-a-message", content: "delete a", senderPeerID: aliasA)
        let messageB = message(id: "alias-b-message", content: "delete b", senderPeerID: aliasB)
        let committedA = await store.commitPrivate(
            peerID: aliasA,
            messages: [messageA],
            pendingReceiveEffectMessageID: messageA.id
        )
        let committedB = await store.commitPrivate(
            peerID: aliasB,
            messages: [messageB],
            pendingReceiveEffectMessageID: messageB.id
        )
        let committedSurvivor = await store.commitPrivate(
            peerID: survivor,
            messages: [message(content: "keep", senderPeerID: survivor)]
        )
        XCTAssertTrue(committedA)
        XCTAssertTrue(committedB)
        XCTAssertTrue(committedSurvivor)

        let result = store.deletePrivateDurably(peerIDs: [aliasB, aliasA, aliasA])

        XCTAssertEqual(result, PrivateConversationDeletionResult(fenced: true, complete: true))
        let snapshot = store.loadPrivateSnapshot(chatLimit: 24)
        XCTAssertNil(snapshot.chats[aliasA])
        XCTAssertNil(snapshot.chats[aliasB])
        XCTAssertNotNil(snapshot.chats[survivor])
        XCTAssertTrue(store.load(peerID: aliasA).isEmpty)
        XCTAssertTrue(store.load(peerID: aliasB).isEmpty)
        XCTAssertEqual(store.load(peerID: survivor).map(\.content), ["keep"])
        let pendingEffects = await store.loadPendingReceiveEffects()
        XCTAssertTrue(pendingEffects.isEmpty)
    }

    func testEveryConversationDeletionStageRecoversAfterRestart() async {
        enum SimulatedCrash: Error { case after(PrivateDeletionStage) }

        for stage in PrivateDeletionStage.allCases {
            let name = "PrivateDeletionRecovery-\(stage)-\(UUID().uuidString)"
            let aliasA = PeerID(str: "recovery-alias-a")
            let aliasB = PeerID(str: "recovery-alias-b")
            let survivor = PeerID(str: "recovery-survivor")
            let seeded = MessageStore(directoryName: name)
            let messageA = message(id: "recover-a", content: "delete a", senderPeerID: aliasA)
            let messageB = message(id: "recover-b", content: "delete b", senderPeerID: aliasB)
            let committedA = await seeded.commitPrivate(
                peerID: aliasA,
                messages: [messageA],
                pendingReceiveEffectMessageID: messageA.id
            )
            let committedB = await seeded.commitPrivate(
                peerID: aliasB,
                messages: [messageB],
                pendingReceiveEffectMessageID: messageB.id
            )
            let committedSurvivor = await seeded.commitPrivate(
                peerID: survivor,
                messages: [message(content: "keep", senderPeerID: survivor)]
            )
            XCTAssertTrue(committedA, "stage=\(stage)")
            XCTAssertTrue(committedB, "stage=\(stage)")
            XCTAssertTrue(committedSurvivor, "stage=\(stage)")

            let interrupted = MessageStore(
                directoryName: name,
                beforePrivateDeletionStage: { reached in
                    if reached == stage { throw SimulatedCrash.after(reached) }
                }
            )
            let interruptedResult = interrupted.deletePrivateDurably(peerIDs: [aliasA, aliasB])
            XCTAssertTrue(interruptedResult.fenced, "stage=\(stage)")
            XCTAssertFalse(interruptedResult.complete, "stage=\(stage)")
            // The durable intent is also a render/read fence; a failed cleanup
            // never republishes the embedded manifest summary in this process.
            XCTAssertNil(interrupted.loadPrivateSnapshot(chatLimit: 24).chats[aliasA], "stage=\(stage)")
            XCTAssertNil(interrupted.loadPrivateSnapshot(chatLimit: 24).chats[aliasB], "stage=\(stage)")
            XCTAssertTrue(interrupted.load(peerID: aliasA).isEmpty, "stage=\(stage)")

            let reopened = MessageStore(directoryName: name)
            let snapshot = reopened.loadPrivateSnapshot(chatLimit: 24)
            XCTAssertNil(snapshot.chats[aliasA], "stage=\(stage)")
            XCTAssertNil(snapshot.chats[aliasB], "stage=\(stage)")
            XCTAssertNotNil(snapshot.chats[survivor], "stage=\(stage)")
            XCTAssertTrue(reopened.load(peerID: aliasA).isEmpty, "stage=\(stage)")
            XCTAssertTrue(reopened.load(peerID: aliasB).isEmpty, "stage=\(stage)")
            XCTAssertEqual(reopened.load(peerID: survivor).map(\.content), ["keep"], "stage=\(stage)")
            let pendingEffects = await reopened.loadPendingReceiveEffects()
            XCTAssertTrue(pendingEffects.isEmpty, "stage=\(stage)")
            _ = reopened.wipeAll()
        }
    }

    func testMeshOutboxCorruptionFailsClosedWithoutOverwritingJournal() throws {
        let owner = "owner-corrupt"
        let fence = "process-corrupt"
        let peer = PeerID(str: "a1b2c3d4e5f60718")
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let outboxURL = support
            .appendingPathComponent(dirName, isDirectory: true)
            .appendingPathComponent("mesh-outbox.json")
        let corruptBytes = Data("not-json-outbox".utf8)
        try corruptBytes.write(to: outboxURL, options: .atomic)
        store.activateMeshOutbox(ownerID: owner, fence: fence)

        XCTAssertNil(store.enqueueMeshObligation(
            ownerID: owner,
            fence: fence,
            messageID: "must-not-overwrite",
            peerID: peer,
            recipientNickname: "alice",
            content: "hello",
            kind: .text
        ))
        XCTAssertEqual(try Data(contentsOf: outboxURL), corruptBytes)
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

    func testPanicMediaQuarantineNeverDeletesReplacementTree() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PanicMediaTest-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: support) }
        let oldFile = support.appendingPathComponent("files/images/incoming/old.bin")
        try FileManager.default.createDirectory(
            at: oldFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("old".utf8).write(to: oldFile)
        let replacementFile = support.appendingPathComponent("files/images/incoming/new.bin")

        let result = PanicMediaStore.quarantineAndRecreate(
            supportDirectory: support,
            beforeTombstoneCleanup: { live, _ in
                XCTAssertEqual(live, support.appendingPathComponent("files", isDirectory: true))
                try Data("new".utf8).write(to: replacementFile)
            }
        )

        XCTAssertTrue(result.quarantined)
        XCTAssertTrue(result.cleanupComplete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path))
        XCTAssertEqual(try Data(contentsOf: replacementFile), Data("new".utf8))
    }

    func testPanicMediaFailureLeavesOldTreeReachableAndNoReplacement() throws {
        enum SimulatedFailure: Error { case beforeQuarantine }
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PanicMediaFailureTest-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: support) }
        let oldFile = support.appendingPathComponent("files/old.bin")
        try FileManager.default.createDirectory(at: oldFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: oldFile)

        let result = PanicMediaStore.quarantineAndRecreate(
            supportDirectory: support,
            beforeQuarantine: { throw SimulatedFailure.beforeQuarantine }
        )

        XCTAssertFalse(result.quarantined)
        XCTAssertEqual(try Data(contentsOf: oldFile), Data("old".utf8))
    }

    func testPanicMediaEnumerationFailureKeepsCleanupBarrierPending() throws {
        enum SimulatedFailure: Error { case enumeration }
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PanicMediaEnumerationTest-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: support) }
        try FileManager.default.createDirectory(
            at: support.appendingPathComponent("files", isDirectory: true),
            withIntermediateDirectories: true
        )

        let result = PanicMediaStore.quarantineAndRecreate(
            supportDirectory: support,
            directoryLister: { _ in throw SimulatedFailure.enumeration }
        )

        XCTAssertTrue(result.quarantined)
        XCTAssertFalse(result.cleanupComplete)
    }

    func testMessageStoreEnumerationFailureKeepsCleanupBarrierPending() {
        enum SimulatedFailure: Error { case enumeration }
        let failingName = "MessageEnumerationFailure-\(UUID().uuidString)"
        let failingStore = MessageStore(
            directoryName: failingName,
            directoryLister: { _ in throw SimulatedFailure.enumeration }
        )

        let result = failingStore.wipeAll()

        XCTAssertTrue(result.quarantined)
        XCTAssertFalse(result.cleanupComplete)
        _ = MessageStore(directoryName: failingName).wipeAll()
    }

    func testWipeQuarantineFailsWhenParentDirectoryCannotBeSynchronized() {
        enum SimulatedFailure: Error { case fsync }
        let failingStore = MessageStore(
            directoryName: dirName,
            directorySyncFault: { _, stage in
                if stage == .fsync { throw SimulatedFailure.fsync }
            }
        )

        let result = failingStore.wipeAll()

        XCTAssertFalse(result.quarantined)
        XCTAssertFalse(result.cleanupComplete)
    }

    func testWipeTombstoneCloseFailureKeepsCleanupBarrierPending() {
        enum SimulatedFailure: Error { case close }
        var closeCount = 0
        let failingStore = MessageStore(
            directoryName: dirName,
            directorySyncFault: { _, stage in
                guard stage == .close else { return }
                closeCount += 1
                if closeCount == 2 { throw SimulatedFailure.close }
            }
        )

        let result = failingStore.wipeAll()

        XCTAssertTrue(result.quarantined)
        XCTAssertFalse(result.cleanupComplete)
    }

    func testPanicMediaDirectoryDurabilityFailureDoesNotCommitQuarantine() throws {
        enum SimulatedFailure: Error { case open }
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PanicMediaDirectoryFailure-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: support) }
        let oldFile = support.appendingPathComponent("files/old.bin")
        try FileManager.default.createDirectory(
            at: oldFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("old".utf8).write(to: oldFile)

        let result = PanicMediaStore.quarantineAndRecreate(
            supportDirectory: support,
            directorySyncFault: { _, stage in
                if stage == .open { throw SimulatedFailure.open }
            }
        )

        XCTAssertFalse(result.quarantined)
        XCTAssertEqual(try Data(contentsOf: oldFile), Data("old".utf8))
    }

    func testPanicMediaTombstoneFsyncFailureKeepsCleanupPending() throws {
        enum SimulatedFailure: Error { case fsync }
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PanicMediaCleanupFailure-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: support) }
        let oldFile = support.appendingPathComponent("files/old.bin")
        try FileManager.default.createDirectory(
            at: oldFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("old".utf8).write(to: oldFile)
        var fsyncCount = 0

        let result = PanicMediaStore.quarantineAndRecreate(
            supportDirectory: support,
            directorySyncFault: { _, stage in
                guard stage == .fsync else { return }
                fsyncCount += 1
                if fsyncCount == 2 { throw SimulatedFailure.fsync }
            }
        )

        XCTAssertTrue(result.quarantined)
        XCTAssertFalse(result.cleanupComplete)
    }
}
