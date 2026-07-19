//
// MarmotStoreLockTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
@testable import Sonar

struct MarmotStoreLockTests {

    @Test func tryAcquireFailsWhileExclusiveHeld() throws {
        #if os(iOS)
        // Uses the real App Group when available (simulator/device entitlements).
        // If the group container is missing in this test host, skip.
        guard MarmotStoreLock.lockFileURL(createDirectory: true) != nil else {
            return
        }
        let first = try MarmotStoreLock.acquireExclusive()
        defer { first.release() }
        #expect(MarmotStoreLock.tryAcquireExclusive() == nil)
        // Same-process second blocking acquire would hang — callers must reuse.
        first.release()
        let second = MarmotStoreLock.tryAcquireExclusive()
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
}
