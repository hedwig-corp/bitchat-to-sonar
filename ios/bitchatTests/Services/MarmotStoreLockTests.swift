//
// MarmotStoreLockTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
import notify
@testable import Sonar

struct MarmotStoreLockTests {

    @Test func tryAcquireFailsWhileExclusiveHeld() throws {
        #if os(iOS)
        let group = IsolatedAppGroup()
        defer { group.remove() }
        let first = try MarmotStoreLock.acquireExclusive(fileManager: group)
        defer { first.release() }
        #expect(MarmotStoreLock.tryAcquireExclusive(fileManager: group) == nil)
        // Same-process second blocking acquire would hang — callers must reuse.
        first.release()
        let second = MarmotStoreLock.tryAcquireExclusive(fileManager: group)
        #expect(second != nil)
        second?.release()
        #endif
    }

    @Test func sameProcessSecondFdConflicts() throws {
        #if os(iOS)
        // Pins the Darwin flock semantics that make connectLocal→connect
        // re-acquire unsafe without reuse.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("probe.lock")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let first = try FileHandle(forWritingTo: url)
        defer { try? first.close() }
        #expect(flock(first.fileDescriptor, LOCK_EX) == 0)
        let second = try FileHandle(forWritingTo: url)
        defer { try? second.close() }
        #expect(flock(second.fileDescriptor, LOCK_EX | LOCK_NB) != 0)
        #expect(errno == EWOULDBLOCK || errno == EAGAIN)
        _ = flock(first.fileDescriptor, LOCK_UN)
        #endif
    }

    @Test func lockFileURLRespectsCreateDirectoryFlag() {
        #if os(iOS)
        let withoutCreate = MarmotStoreLock.lockFileURL(createDirectory: false)
        // May be nil if App Group missing or dir absent — either is fine.
        if let url = withoutCreate {
            #expect(url.lastPathComponent == MarmotStoreLock.lockFileName)
        }
        if let created = MarmotStoreLock.lockFileURL(createDirectory: true) {
            #expect(created.lastPathComponent == MarmotStoreLock.lockFileName)
            #expect(FileManager.default.fileExists(atPath: created.deletingLastPathComponent().path))
        }
        #endif
    }

    @Test("release lets NSE tryAcquire succeed — background suspend contract")
    func releaseUnblocksNseTryAcquire() throws {
        #if os(iOS)
        let group = IsolatedAppGroup()
        defer { group.remove() }
        let held = try MarmotStoreLock.acquireExclusive(fileManager: group)
        #expect(MarmotStoreLock.tryAcquireExclusive(fileManager: group) == nil)
        if case .busy = MarmotStoreLock.tryAcquireExclusiveResult(fileManager: group) {
            // expected
        } else {
            Issue.record("expected .busy while exclusive held")
        }
        // App background path: closeNode → release. NSE must then hydrate.
        held.release()
        let nse = MarmotStoreLock.tryAcquireExclusive(fileManager: group)
        #expect(nse != nil)
        nse?.release()
        #endif
    }

    /// QA-164 (#665): the app's blocking acquire must ask whoever holds the
    /// store to yield BEFORE it parks on `flock`. The holder here is a hold in
    /// this process that lets go only when that Darwin notification arrives,
    /// which is exactly what the NSE's observer does with its latch. Without
    /// the signal the acquire waits until the holder finishes on its own; for
    /// a push wake on cellular that was the 5 s relay quorum plus the 8 s
    /// drain, with the app stuck on its launch surface the whole time.
    /// Other tests' acquires post the same notification and may release this
    /// hold early; that cannot make this test pass without the fix, because
    /// without it nothing posts at all.
    @Test("acquireExclusive asks the store holder to yield (QA-164)")
    func acquireExclusiveAsksHolderToYield() throws {
        #if os(iOS)
        let group = IsolatedAppGroup()
        defer { group.remove() }
        _ = MarmotStoreLock.lockFileURL(fileManager: group, createDirectory: true)
        let held = try #require(MarmotStoreLock.tryAcquireExclusive(fileManager: group))

        var token: Int32 = NOTIFY_TOKEN_INVALID
        let status = notify_register_dispatch(
            MarmotStoreLock.hostWantsStoreNotification,
            &token,
            DispatchQueue.global(qos: .userInitiated)
        ) { _ in held.release() }
        #expect(status == 0) // NOTIFY_STATUS_OK
        defer { notify_cancel(token) }

        let acquired = AcquiredLockBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            acquired.lock = try? MarmotStoreLock.acquireExclusive(fileManager: group)
            done.signal()
        }
        let yielded = done.wait(timeout: .now() + 3) == .success
        if !yielded {
            // Unpark the blocked acquire so the suite ends instead of hanging.
            held.release()
            done.wait()
        }
        #expect(yielded, "acquireExclusive parked on flock without asking the holder to yield")
        #expect(acquired.lock != nil)
        acquired.lock?.release()
        #endif
    }
}

/// Carries the lock out of the background acquire in
/// `acquireExclusiveAsksHolderToYield`; the semaphore orders the access.
private final class AcquiredLockBox: @unchecked Sendable {
    var lock: MarmotStoreLock?
}

/// An App Group container of the test's own. These tests take the exclusive
/// lock, and the suite runs in parallel: on the one real App Group lock file,
/// one test's hold made the other's "released, so NSE can acquire" check fail
/// (`releaseUnblocksNseTryAcquire` and `tryAcquireFailsWhileExclusiveHeld`
/// each failed this way on main). Only `containerURL` is redirected; the lock
/// file keeps its real name and directory layout under it.
private final class IsolatedAppGroup: FileManager {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MarmotStoreLockTests-\(UUID().uuidString)", isDirectory: true)

    override func containerURL(forSecurityApplicationGroupIdentifier groupIdentifier: String) -> URL? {
        root
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
