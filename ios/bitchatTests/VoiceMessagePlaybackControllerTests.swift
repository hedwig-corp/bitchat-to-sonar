import XCTest
@testable import Sonar

@MainActor
final class VoiceMessagePlaybackControllerTests: XCTestCase {
    private final class FakeEngine: VoicePlaybackEngine {
        var onFinish: (@MainActor (Bool) -> Void)?
        var onDecodeError: (@MainActor (Error?) -> Void)?
        var currentTime: TimeInterval = 0
        var duration: TimeInterval = 5
        var playing = false
        var lastSeek: TimeInterval = 0
        var rate: Float = 1
        var loadedURL: URL?

        func load(url: URL) throws -> TimeInterval {
            loadedURL = url
            return duration
        }

        @discardableResult
        func play() -> Bool {
            playing = true
            return true
        }

        func pause() { playing = false }
        func stop() { playing = false }
        func seek(to time: TimeInterval) {
            lastSeek = time
            currentTime = time
        }
        func setRate(_ rate: Float) { self.rate = rate }
    }

    private final class ManualTicker: VoicePlaybackTicker {
        private var tick: (() -> Void)?
        func start(interval: TimeInterval, _ tick: @escaping () -> Void) { self.tick = tick }
        func stop() { tick = nil }
        func fire() { tick?() }
    }

    private final class MemoryRates: VoicePlaybackRateStore {
        var values: [String: Double] = [:]
        func rate(forLogicalConversationId id: String) -> Double { values[id] ?? 1.0 }
        func setRate(_ rate: Double, forLogicalConversationId id: String) { values[id] = rate }
    }

    private final class MemoryListened: VoicePlaybackListenedStore {
        var keys = Set<String>()
        func hasListened(messageId: String) -> Bool { keys.contains(messageId) }
        func markListened(messageId: String) { keys.insert(messageId) }
        func clearAll() { keys.removeAll() }
    }

    private final class ListQueue: VoicePlaybackQueue {
        let items: [VoicePlaybackItem]
        init(_ items: [VoicePlaybackItem]) { self.items = items }
        func next(after item: VoicePlaybackItem) -> VoicePlaybackItem? {
            guard let idx = items.firstIndex(where: { $0.key == item.key }) else { return nil }
            return items.indices.contains(idx + 1) ? items[idx + 1] : nil
        }
        func previous(before item: VoicePlaybackItem) -> VoicePlaybackItem? {
            guard let idx = items.firstIndex(where: { $0.key == item.key }) else { return nil }
            return items.indices.contains(idx - 1) ? items[idx - 1] : nil
        }
    }

    private func item(_ id: String, file: String = "/tmp/a.m4a") -> VoicePlaybackItem {
        VoicePlaybackItem(
            logicalConversationId: "chat-a",
            sourceConversationId: "group-a",
            messageId: id,
            attachmentId: "att-\(id)",
            localFile: URL(fileURLWithPath: file),
            durationHint: 5
        )
    }

    private func makeController(
        engine: FakeEngine,
        rates: MemoryRates = MemoryRates(),
        listened: MemoryListened = MemoryListened(),
        queue: VoicePlaybackQueue = ListQueue([])
    ) -> VoiceNotePlaybackController {
        let ticker = ManualTicker()
        return VoiceNotePlaybackController(
            engineFactory: { engine },
            ticker: ticker,
            rateStore: rates,
            listenedStore: listened,
            queueProvider: queue
        )
    }

    func testPauseResumePreservesPlayhead() {
        let engine = FakeEngine()
        let controller = makeController(engine: engine)
        controller.play(item("m1"))
        engine.currentTime = 1.2
        controller.pause()
        XCTAssertEqual(controller.state.phase, .paused)
        XCTAssertEqual(controller.state.position, 1.2, accuracy: 0.001)
        controller.resume()
        XCTAssertEqual(controller.state.phase, .playing)
    }

    func testUserPauseDoesNotAutoResume() {
        let engine = FakeEngine()
        let controller = makeController(engine: engine)
        controller.play(item("m1"))
        controller.pause()
        XCTAssertEqual(controller.state.phase, .paused)
        XCTAssertFalse(engine.playing)
    }

    func testSwitchingItemsSupersedesPrevious() {
        let engine = FakeEngine()
        let controller = makeController(engine: engine)
        controller.play(item("m1", file: "/tmp/1.m4a"))
        controller.play(item("m2", file: "/tmp/2.m4a"))
        XCTAssertEqual(controller.state.item?.messageId, "m2")
        XCTAssertEqual(controller.state.phase, .playing)
    }

    func testNextAdvancesQueue() {
        let a = item("m1", file: "/tmp/1.m4a")
        let b = item("m2", file: "/tmp/2.m4a")
        let engine = FakeEngine()
        let controller = makeController(engine: engine, queue: ListQueue([a, b]))
        controller.configure(queue: ListQueue([a, b]))
        controller.play(a)
        controller.next()
        XCTAssertEqual(controller.state.item?.messageId, "m2")
    }

    func testCycleRatePersistsPerLogicalConversation() {
        let rates = MemoryRates()
        let engine = FakeEngine()
        let controller = makeController(engine: engine, rates: rates)
        controller.play(item("m1"))
        controller.cycleRate()
        XCTAssertEqual(controller.state.rate, 1.5, accuracy: 0.01)
        XCTAssertEqual(rates.rate(forLogicalConversationId: "chat-a"), 1.5, accuracy: 0.01)
        XCTAssertEqual(rates.rate(forLogicalConversationId: "chat-b"), 1.0, accuracy: 0.01)
    }

    func testCallStopDoesNotAutoResume() {
        let engine = FakeEngine()
        let controller = makeController(engine: engine)
        controller.play(item("m1"))
        controller.stop(reason: .call)
        XCTAssertTrue(controller.state.phase == .idle || controller.state.item == nil)
        controller.resume()
        XCTAssertNotEqual(controller.state.phase, .playing)
    }

    func testMarksListenedOnFirstPlay() {
        let listened = MemoryListened()
        var starts = 0
        let engine = FakeEngine()
        let a = item("m1")
        let controller = makeController(engine: engine, listened: listened)
        controller.configure(queue: ListQueue([])) { _ in starts += 1 }
        controller.play(a)
        XCTAssertTrue(listened.hasListened(messageId: a.messageId))
        XCTAssertEqual(starts, 1)
        controller.pause()
        controller.resume()
        XCTAssertEqual(starts, 1)
    }
}
