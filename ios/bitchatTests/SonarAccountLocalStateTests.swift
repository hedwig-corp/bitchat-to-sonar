import XCTest
@testable import Sonar

/// An account switch sets the leaving account's own values aside and brings
/// them back on return, instead of deleting them (codex review of #667: a
/// switch used to run the restore clear and lost them for good).
///
/// Mirror of Compose `AccountLocalStateParkingTest`; keep the two in step.
final class SonarAccountLocalStateTests: XCTestCase {
    private let a = String(repeating: "a", count: 64)
    private let b = String(repeating: "b", count: 64)
    private let keys = ["sonar.bip353", "sonar.payment.activity.v1", "sonar.callLogs.v1"]

    private func defaults() -> UserDefaults {
        let name = "sonar-parking-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    func testSwitchAwayAndBackRestoresTheLeavingAccountsValues() {
        let d = defaults()
        d.set("alice@sonar", forKey: "sonar.bip353")
        d.set(Data([1, 2, 3]), forKey: "sonar.payment.activity.v1")

        // Switch A → B: park A, then the clear resets the live values.
        var record = SonarAccountLocalState.capture(keys: keys, from: d)
        record["nickname"] = "Alice"
        SonarAccountLocalState.park(record, for: a, defaults: d)
        keys.forEach { d.removeObject(forKey: $0) }
        // B is new: nothing to restore.
        XCTAssertNil(SonarAccountLocalState.record(for: b, defaults: d))

        // Switch B → A.
        let back = SonarAccountLocalState.record(for: a, defaults: d)
        XCTAssertNotNil(back)
        SonarAccountLocalState.apply(back!, keys: keys, to: d)
        SonarAccountLocalState.clearRecord(for: a, defaults: d)
        XCTAssertEqual(d.string(forKey: "sonar.bip353"), "alice@sonar")
        XCTAssertEqual(d.data(forKey: "sonar.payment.activity.v1"), Data([1, 2, 3]))
        XCTAssertEqual(back?["nickname"] as? String, "Alice")
        XCTAssertNil(SonarAccountLocalState.record(for: a, defaults: d), "the record is consumed")
    }

    /// A key the record does not name must not keep the previous account's
    /// value in the live slot.
    func testAKeyMissingFromTheRecordIsRemoved() {
        let d = defaults()
        SonarAccountLocalState.park([:], for: a, defaults: d)
        d.set("bob@sonar", forKey: "sonar.bip353")
        SonarAccountLocalState.apply(SonarAccountLocalState.record(for: a, defaults: d)!, keys: keys, to: d)
        XCTAssertNil(d.string(forKey: "sonar.bip353"))
    }

    func testDiscardAllDropsEveryAccountsRecordAndNothingElse() {
        let d = defaults()
        SonarAccountLocalState.park(["x": 1], for: a, defaults: d)
        SonarAccountLocalState.park(["x": 2], for: b, defaults: d)
        d.set("keep", forKey: "sonar.bip353")
        SonarAccountLocalState.discardAll(defaults: d)
        XCTAssertNil(SonarAccountLocalState.record(for: a, defaults: d))
        XCTAssertNil(SonarAccountLocalState.record(for: b, defaults: d))
        XCTAssertEqual(d.string(forKey: "sonar.bip353"), "keep")
    }
}
