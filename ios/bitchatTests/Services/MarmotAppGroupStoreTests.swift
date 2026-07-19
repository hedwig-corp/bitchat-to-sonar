//
// MarmotAppGroupStoreTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
@testable import Sonar

struct MarmotAppGroupStoreTests {

    @Test func migrateMovesLegacyWhenSharedDbMissing() throws {
        #if os(iOS)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try "legacy-db".write(
            to: legacy.appendingPathComponent(MarmotAppGroupStore.dbFileName),
            atomically: true,
            encoding: .utf8
        )
        try "sidecar".write(
            to: legacy.appendingPathComponent("marmot.sqlite.sonar-sync.json"),
            atomically: true,
            encoding: .utf8
        )

        try MarmotAppGroupStore.migrateLegacyStoreIfNeeded(
            from: legacy,
            into: shared,
            fileManager: fm
        )

        let sharedDb = shared.appendingPathComponent(MarmotAppGroupStore.dbFileName)
        let sharedSidecar = shared.appendingPathComponent("marmot.sqlite.sonar-sync.json")
        #expect(fm.fileExists(atPath: sharedDb.path))
        #expect(try String(contentsOf: sharedDb, encoding: .utf8) == "legacy-db")
        #expect(fm.fileExists(atPath: sharedSidecar.path))
        #expect(!fm.fileExists(atPath: legacy.path))
        #endif
    }

    @Test func migrateLeavesSharedDbAloneWhenPresent() throws {
        #if os(iOS)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        try "shared-db".write(
            to: shared.appendingPathComponent(MarmotAppGroupStore.dbFileName),
            atomically: true,
            encoding: .utf8
        )
        try "legacy-db".write(
            to: legacy.appendingPathComponent(MarmotAppGroupStore.dbFileName),
            atomically: true,
            encoding: .utf8
        )

        try MarmotAppGroupStore.migrateLegacyStoreIfNeeded(
            from: legacy,
            into: shared,
            fileManager: fm
        )

        let sharedDb = shared.appendingPathComponent(MarmotAppGroupStore.dbFileName)
        #expect(try String(contentsOf: sharedDb, encoding: .utf8) == "shared-db")
        #expect(fm.fileExists(atPath: legacy.appendingPathComponent(MarmotAppGroupStore.dbFileName).path))
        #endif
    }

    @Test func migrateReplacesEmptySharedPlaceholderWithLegacy() throws {
        #if os(iOS)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        // Zero-byte placeholder must not block migration.
        fm.createFile(
            atPath: shared.appendingPathComponent(MarmotAppGroupStore.dbFileName).path,
            contents: Data(),
            attributes: nil
        )
        try "legacy-db".write(
            to: legacy.appendingPathComponent(MarmotAppGroupStore.dbFileName),
            atomically: true,
            encoding: .utf8
        )

        try MarmotAppGroupStore.migrateLegacyStoreIfNeeded(
            from: legacy,
            into: shared,
            fileManager: fm
        )

        let sharedDb = shared.appendingPathComponent(MarmotAppGroupStore.dbFileName)
        #expect(try String(contentsOf: sharedDb, encoding: .utf8) == "legacy-db")
        #expect(!fm.fileExists(atPath: legacy.path))
        #endif
    }

    @Test func removeStoreRootsDeletesOnlyExistingPaths() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        let missing = root.appendingPathComponent("missing", isDirectory: true)
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try "x".write(
            to: shared.appendingPathComponent(MarmotAppGroupStore.dbFileName),
            atomically: true,
            encoding: .utf8
        )

        try MarmotAppGroupStore.removeStoreRoots([shared, legacy, missing], fileManager: fm)

        #expect(!fm.fileExists(atPath: shared.path))
        #expect(!fm.fileExists(atPath: legacy.path))
        #expect(!fm.fileExists(atPath: missing.path))
    }
}
