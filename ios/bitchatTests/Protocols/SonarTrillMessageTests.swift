//
// SonarTrillMessageTests.swift
// bitchatTests
//
// Tests for the ⚡TRILL nudge convention (codec), the receiver alert
// throttle + silence-semantics decision table, and the per-chat mute
// store's expiry logic, see docs/SONAR-TRILL.md.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
@testable import Sonar

final class SonarTrillMessageTests: XCTestCase {

    private let hexId = "a3f92c41770e5b2d"

    // MARK: - Codec round trips

    func testTrillRoundTrip() {
        let line = SonarTrillMessage(id: hexId)
        XCTAssertEqual(line.encoded(), "\u{26A1}TRILL|1|\(hexId)")
        XCTAssertEqual(SonarTrillMessage.decode(line.encoded()), line)
        XCTAssertTrue(SonarTrillMessage.isTrillLine(line.encoded()))
    }

    func testUuidShapedIdRoundTrips() {
        let uuid = "5f0c2c6a-9d57-4f1e-8a3b-2c41770e5b2d"
        let line = SonarTrillMessage(id: uuid)
        XCTAssertEqual(SonarTrillMessage.decode(line.encoded())?.id, uuid)
    }

    func testMakeIDIsSixteenHexAndDecodes() {
        let id = SonarTrillMessage.makeID()
        XCTAssertEqual(id.count, 16)
        XCTAssertTrue(id.allSatisfy(\.isHexDigit))
        XCTAssertNotNil(SonarTrillMessage.decode(SonarTrillMessage(id: id).encoded()))
    }

    // MARK: - Rejections (version locked to 1, no trailing fields)

    func testRejectsWrongVersion() {
        XCTAssertNil(SonarTrillMessage.decode("\u{26A1}TRILL|2|\(hexId)"))
        XCTAssertNil(SonarTrillMessage.decode("\u{26A1}TRILL|0|\(hexId)"))
        XCTAssertNil(SonarTrillMessage.decode("\u{26A1}TRILL|11|\(hexId)"))
        XCTAssertNil(SonarTrillMessage.decode("\u{26A1}TRILL||\(hexId)"))
    }

    func testRejectsTrailingFields() {
        XCTAssertNil(SonarTrillMessage.decode("\u{26A1}TRILL|1|\(hexId)|extra"))
        XCTAssertNil(SonarTrillMessage.decode("\u{26A1}TRILL|1|\(hexId)|"))
    }

    func testRejectsBadIds() {
        XCTAssertNil(SonarTrillMessage.decode("\u{26A1}TRILL|1|"))                 // empty id
        XCTAssertNil(SonarTrillMessage.decode("\u{26A1}TRILL|1"))                  // no id field
        XCTAssertNil(SonarTrillMessage.decode("\u{26A1}TRILL|1|not an id!"))       // bad chars
        XCTAssertNil(SonarTrillMessage.decode("\u{26A1}TRILL|1|zzzz"))             // non-hex
        XCTAssertNil(SonarTrillMessage.decode("\u{26A1}TRILL|1|\(String(repeating: "a", count: 65))")) // > 64
        XCTAssertNotNil(SonarTrillMessage.decode("\u{26A1}TRILL|1|\(String(repeating: "a", count: 64))")) // == 64 ok
    }

    func testRejectsForeignPrefixes() {
        XCTAssertNil(SonarTrillMessage.decode("hello"))
        XCTAssertNil(SonarTrillMessage.decode("TRILL|1|\(hexId)"))                 // no ⚡
        XCTAssertNil(SonarTrillMessage.decode("\u{26A1}TRILLX|1|\(hexId)"))
        XCTAssertNil(SonarTrillMessage.decode("\u{26A1}PAY|1|\(hexId)|21000"))
        XCTAssertNil(SonarTrillMessage.decode(" \u{26A1}TRILL|1|\(hexId)"))        // leading space
    }

    func testTrillLineIsNotAPayLine() {
        XCTAssertNil(SonarPayMessage.decode(SonarTrillMessage(id: hexId).encoded()))
    }

    // MARK: - Receiver throttle (one alert per chat per 8 s window)

    func testThrottleAdmitsOncePerWindowPerChat() {
        let throttle = SonarTrillThrottle(windowSeconds: 8)
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertTrue(throttle.admit(chatKey: "a", at: t0))
        XCTAssertFalse(throttle.admit(chatKey: "a", at: t0.addingTimeInterval(0.5)))
        XCTAssertFalse(throttle.admit(chatKey: "a", at: t0.addingTimeInterval(7.9)))
        XCTAssertTrue(throttle.admit(chatKey: "a", at: t0.addingTimeInterval(8.0)))
        // A denied attempt must not extend the window.
        XCTAssertFalse(throttle.admit(chatKey: "a", at: t0.addingTimeInterval(9.0)))
        XCTAssertTrue(throttle.admit(chatKey: "a", at: t0.addingTimeInterval(16.0)))
    }

    func testThrottleWindowsAreIndependentPerChat() {
        let throttle = SonarTrillThrottle(windowSeconds: 8)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(throttle.admit(chatKey: "a", at: t0))
        XCTAssertTrue(throttle.admit(chatKey: "b", at: t0.addingTimeInterval(1)))
        XCTAssertFalse(throttle.admit(chatKey: "a", at: t0.addingTimeInterval(2)))
    }

    // MARK: - Alert decision table (silence semantics)

    func testBlockedPeerTrillIsFullySuppressed() {
        var throttleAsked = false
        let decision = SonarTrillPolicy.alertDecision(
            arrivedBeforeLaunch: false,
            isBlocked: true,
            isMuted: false,
            isForeground: true,
            admitThrottle: { throttleAsked = true; return true }
        )
        XCTAssertEqual(decision, .suppress)
        // A blocked trill must not consume the chat's alert window either.
        XCTAssertFalse(throttleAsked)
    }

    func testMutedChatTrillIsRowOnly() {
        var throttleAsked = false
        let decision = SonarTrillPolicy.alertDecision(
            arrivedBeforeLaunch: false,
            isBlocked: false,
            isMuted: true,
            isForeground: false,
            admitThrottle: { throttleAsked = true; return true }
        )
        XCTAssertEqual(decision, .suppress)
        XCTAssertFalse(throttleAsked)
    }

    func testPreLaunchReplayNeverAlerts() {
        let decision = SonarTrillPolicy.alertDecision(
            arrivedBeforeLaunch: true,
            isBlocked: false,
            isMuted: false,
            isForeground: true,
            admitThrottle: { true }
        )
        XCTAssertEqual(decision, .suppress)
    }

    func testForegroundAdmittedTrillBuzzes() {
        let decision = SonarTrillPolicy.alertDecision(
            arrivedBeforeLaunch: false,
            isBlocked: false,
            isMuted: false,
            isForeground: true,
            admitThrottle: { true }
        )
        XCTAssertEqual(decision, .buzz)
    }

    func testBackgroundAdmittedTrillNotifiesWithSound() {
        let decision = SonarTrillPolicy.alertDecision(
            arrivedBeforeLaunch: false,
            isBlocked: false,
            isMuted: false,
            isForeground: false,
            admitThrottle: { true }
        )
        XCTAssertEqual(decision, .notify)
    }

    func testThrottledBackgroundTrillAlertsSilently() {
        let decision = SonarTrillPolicy.alertDecision(
            arrivedBeforeLaunch: false,
            isBlocked: false,
            isMuted: false,
            isForeground: false,
            admitThrottle: { false }
        )
        XCTAssertEqual(decision, .notifySilently)
    }

    func testThrottledForegroundTrillIsRowOnly() {
        let decision = SonarTrillPolicy.alertDecision(
            arrivedBeforeLaunch: false,
            isBlocked: false,
            isMuted: false,
            isForeground: true,
            admitThrottle: { false }
        )
        XCTAssertEqual(decision, .suppress)
    }

    // MARK: - Sender cooldown

    func testCooldownRemaining() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertNil(SonarTrillPolicy.cooldownRemaining(until: nil, now: now))
        XCTAssertNil(SonarTrillPolicy.cooldownRemaining(until: now.addingTimeInterval(-1), now: now))
        XCTAssertNil(SonarTrillPolicy.cooldownRemaining(until: now, now: now))
        XCTAssertEqual(
            SonarTrillPolicy.cooldownRemaining(until: now.addingTimeInterval(5), now: now) ?? -1,
            5,
            accuracy: 0.001
        )
    }

    // MARK: - Per-chat mute store (lazy expiry)

    private func freshMuteStore(_ name: String = #function) -> SonarChatMuteStore {
        let defaults = UserDefaults(suiteName: "sonar-trill-tests-\(name)")!
        defaults.removePersistentDomain(forName: "sonar-trill-tests-\(name)")
        return SonarChatMuteStore(defaults: defaults, key: "test.mutes")
    }

    func testMuteUntilFutureIsMuted() {
        let store = freshMuteStore()
        let now = Date(timeIntervalSince1970: 1_000_000)
        store.mute(keys: ["chat-a"], until: now.addingTimeInterval(3600))
        XCTAssertTrue(store.isMuted("chat-a", now: now))
        XCTAssertTrue(store.isMuted("chat-a", now: now.addingTimeInterval(3599)))
        XCTAssertFalse(store.isMuted("chat-b", now: now))
    }

    func testMuteExpiresLazily() {
        let store = freshMuteStore()
        let now = Date(timeIntervalSince1970: 1_000_000)
        store.mute(keys: ["chat-a"], until: now.addingTimeInterval(3600))
        // Past the end: reads unmuted and the stale entry is dropped.
        XCTAssertFalse(store.isMuted("chat-a", now: now.addingTimeInterval(3600)))
        XCTAssertNil(store.mutedUntil["chat-a"])
    }

    func testMuteUntilTurnedBackOnPersistsAndUnmutes() {
        let store = freshMuteStore()
        let now = Date(timeIntervalSince1970: 1_000_000)
        store.mute(keys: ["chat-a"], until: .distantFuture)
        XCTAssertTrue(store.isMuted("chat-a", now: now.addingTimeInterval(400 * 24 * 3600)))
        XCTAssertEqual(store.muteEnd(anyOf: ["chat-a"], now: now), .distantFuture)
        store.unmute(keys: ["chat-a"])
        XCTAssertFalse(store.isMuted("chat-a", now: now))
    }

    func testMutePersistsAcrossStoreReload() {
        let suite = "sonar-trill-tests-reload"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let now = Date(timeIntervalSince1970: 1_000_000)
        SonarChatMuteStore(defaults: defaults, key: "test.mutes")
            .mute(keys: ["chat-a"], until: now.addingTimeInterval(3600))
        let reloaded = SonarChatMuteStore(defaults: defaults, key: "test.mutes")
        XCTAssertTrue(reloaded.isMuted("chat-a", now: now))
    }

    func testMuteKeyNormalizationBridgesIdShapes() {
        let store = freshMuteStore()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let groupId = String(repeating: "ab", count: 32) // 64-hex

        // Muted under the marmot: route id, checked by bare group id (the
        // push summary path) and vice versa.
        store.mute(keys: ["marmot:\(groupId)"], until: now.addingTimeInterval(60))
        XCTAssertTrue(store.isMuted(groupId, now: now))
        XCTAssertTrue(store.isMuted("marmot:\(groupId)", now: now))

        // A 64-hex fingerprint also answers for its canonical 16-hex form.
        let fingerprint = String(repeating: "cd", count: 32)
        store.mute(keys: [fingerprint], until: now.addingTimeInterval(60))
        XCTAssertTrue(store.isMuted(String(fingerprint.prefix(16)), now: now))
    }

    func testWipeForgetsEveryMute() {
        let store = freshMuteStore()
        store.mute(keys: ["chat-a", "chat-b"], until: .distantFuture)
        store.wipe()
        XCTAssertFalse(store.isMuted("chat-a"))
        XCTAssertFalse(store.isMuted("chat-b"))
        XCTAssertTrue(store.mutedUntil.isEmpty)
    }
}
