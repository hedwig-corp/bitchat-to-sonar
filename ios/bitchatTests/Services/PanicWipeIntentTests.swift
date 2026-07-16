import XCTest
@testable import Sonar

final class PanicWipeIntentTests: XCTestCase {
    private enum SimulatedFailure: Error { case directory(DirectoryDurabilityStage) }

    func testMarkerSurvivesReopenAndClearsIdempotently() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("panic-wipe-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertTrue(DurablePanicWipeIntent(rootURL: root).begin())
        XCTAssertTrue(DurablePanicWipeIntent(rootURL: root).isPending())
        XCTAssertTrue(DurablePanicWipeIntent(rootURL: root).begin())
        XCTAssertTrue(DurablePanicWipeIntent(rootURL: root).clear())
        XCTAssertFalse(DurablePanicWipeIntent(rootURL: root).isPending())
        XCTAssertTrue(DurablePanicWipeIntent(rootURL: root).clear())
    }

    func testStaleLegacyTemporaryFileCannotBlockMarkerCommitAfterRestart() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("panic-wipe-stale-temp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stale = root.appendingPathComponent(".panic-wipe.intent.(UUID().uuidString).tmp")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: stale.path,
            contents: Data("interrupted-old-process".utf8)
        ))

        let reopened = DurablePanicWipeIntent(rootURL: root)
        XCTAssertTrue(reopened.begin())
        XCTAssertTrue(reopened.isPending())
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path))
    }

    func testFreshWipeCommitsMarkerBeforeRedaction() {
        var events: [String] = []

        XCTAssertTrue(beginPanicWipeBeforeRedaction(
            alreadyPending: false,
            commitIntent: { events.append("commit"); return true },
            redact: { events.append("redact") }
        ))

        XCTAssertEqual(events, ["commit", "redact"])
    }

    func testFailedMarkerCommitLeavesLiveStateUntouched() {
        var events: [String] = []

        XCTAssertFalse(beginPanicWipeBeforeRedaction(
            alreadyPending: false,
            commitIntent: { events.append("commit"); return false },
            redact: { events.append("redact") }
        ))

        XCTAssertEqual(events, ["commit"])
    }

    func testPendingRecoveryCanRedactWithoutRecommittingMarker() {
        var events: [String] = []

        XCTAssertTrue(beginPanicWipeBeforeRedaction(
            alreadyPending: true,
            commitIntent: { events.append("commit"); return false },
            redact: { events.append("redact") }
        ))

        XCTAssertEqual(events, ["redact"])
    }

    func testBeginPropagatesEveryParentDirectoryDurabilityFailure() throws {
        for stage in [DirectoryDurabilityStage.open, .fsync, .close] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("panic-wipe-begin-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            var observed: [DirectoryDurabilityStage] = []
            let journal = DurablePanicWipeIntent(
                rootURL: root,
                directorySyncFault: { _, current in
                    observed.append(current)
                    if current == stage { throw SimulatedFailure.directory(stage) }
                }
            )

            XCTAssertFalse(journal.begin(), "stage \(stage) must fail closed")
            XCTAssertTrue(observed.contains(stage))
        }
    }

    func testClearPropagatesEveryParentDirectoryDurabilityFailure() throws {
        for stage in [DirectoryDurabilityStage.open, .fsync, .close] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("panic-wipe-clear-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            XCTAssertTrue(DurablePanicWipeIntent(rootURL: root).begin())
            var observed: [DirectoryDurabilityStage] = []
            let journal = DurablePanicWipeIntent(
                rootURL: root,
                directorySyncFault: { _, current in
                    observed.append(current)
                    if current == stage { throw SimulatedFailure.directory(stage) }
                }
            )

            XCTAssertFalse(journal.clear(), "stage \(stage) must propagate")
            XCTAssertTrue(observed.contains(stage))
        }
    }
}
