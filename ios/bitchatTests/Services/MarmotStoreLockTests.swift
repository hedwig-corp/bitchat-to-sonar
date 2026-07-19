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
        first.release()
        let second = MarmotStoreLock.tryAcquireExclusive()
        #expect(second != nil)
        second?.release()
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
