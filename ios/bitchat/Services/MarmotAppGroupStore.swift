//
// MarmotAppGroupStore.swift
// bitchat
//
// Resolves the shared Marmot SQLCipher root used by the main app and (on iOS)
// the Notification Service Extension — White Noise / Signal shape: one App
// Group store, never a forked per-process path.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

enum MarmotAppGroupStore {
    static let appGroupId = "group.sh.hedwig.sonar"
    static let dbDirName = "sonar-marmot"
    static let dbFileName = "marmot.sqlite"

    enum StoreError: Error, LocalizedError {
        case appGroupUnavailable
        case migrationFailed(String)
        case wipeFailed(String)

        var errorDescription: String? {
            switch self {
            case .appGroupUnavailable:
                return "App Group \(appGroupId) unavailable — Marmot store cannot open safely"
            case .migrationFailed(let reason):
                return "Marmot App Group migration failed: \(reason)"
            case .wipeFailed(let reason):
                return "Marmot store wipe failed: \(reason)"
            }
        }
    }

    /// Directory that contains `marmot.sqlite` and core sidecars. On iOS this is
    /// always the App Group container after migration. On macOS we keep
    /// Application Support (no NSE).
    static func databaseDirectory(fileManager: FileManager = .default) throws -> URL {
        #if os(iOS)
        guard let group = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId
        ) else {
            throw StoreError.appGroupUnavailable
        }
        let dir = group.appendingPathComponent(dbDirName, isDirectory: true)
        try migrateLegacyStoreIfNeeded(
            from: legacyApplicationSupportDirectory(fileManager: fileManager),
            into: dir,
            fileManager: fileManager
        )
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
        #else
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent(dbDirName, isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
        #endif
    }

    static func databaseURL(fileManager: FileManager = .default) throws -> URL {
        try databaseDirectory(fileManager: fileManager)
            .appendingPathComponent(dbFileName)
    }

    /// Shared App Group DB URL only when the file already exists.
    /// NSE must use this (or equivalent) and never create an empty SQLCipher DB.
    static func existingSharedDatabaseURL(fileManager: FileManager = .default) -> URL? {
        #if os(iOS)
        guard let group = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId
        ) else {
            return nil
        }
        let db = group
            .appendingPathComponent(dbDirName, isDirectory: true)
            .appendingPathComponent(dbFileName)
        guard fileManager.fileExists(atPath: db.path),
              isAuthoritativeDatabaseFile(db, fileManager: fileManager)
        else {
            return nil
        }
        return db
        #else
        return try? databaseURL(fileManager: fileManager)
        #endif
    }

    /// True when `db` looks like a real SQLCipher store (non-empty). Zero-byte
    /// placeholders must not block legacy migration or authorize NSE connect.
    static func isAuthoritativeDatabaseFile(
        _ db: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let attrs = try? fileManager.attributesOfItem(atPath: db.path),
              let size = attrs[.size] as? NSNumber
        else {
            return false
        }
        return size.intValue > 0
    }

    /// Legacy pre-NSE path (`Application Support/sonar-marmot`).
    static func legacyApplicationSupportDirectory(
        fileManager: FileManager = .default
    ) -> URL? {
        guard let base = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else {
            return nil
        }
        return base.appendingPathComponent(dbDirName, isDirectory: true)
    }

    #if os(iOS)
    /// One-time move of an existing sandbox store into the App Group.
    static func migrateLegacyApplicationSupportStoreIfNeeded(
        into sharedDir: URL,
        fileManager: FileManager = .default
    ) throws {
        try migrateLegacyStoreIfNeeded(
            from: legacyApplicationSupportDirectory(fileManager: fileManager),
            into: sharedDir,
            fileManager: fileManager
        )
    }

    /// Testable migration: if shared DB exists, leave it alone; else move legacy.
    static func migrateLegacyStoreIfNeeded(
        from legacyDir: URL?,
        into sharedDir: URL,
        fileManager: FileManager = .default
    ) throws {
        let sharedDb = sharedDir.appendingPathComponent(dbFileName)
        if fileManager.fileExists(atPath: sharedDb.path) {
            if isAuthoritativeDatabaseFile(sharedDb, fileManager: fileManager) {
                return
            }
            // Empty placeholder (e.g. historical NSE mkdir+connect) is not
            // authoritative — drop it so Application Support can migrate.
            try? fileManager.removeItem(at: sharedDb)
        }
        guard let legacyDir,
              fileManager.fileExists(atPath: legacyDir.path)
        else {
            return
        }
        let legacyDb = legacyDir.appendingPathComponent(dbFileName)
        guard fileManager.fileExists(atPath: legacyDb.path) else {
            try? fileManager.removeItem(at: legacyDir)
            return
        }

        try fileManager.createDirectory(at: sharedDir, withIntermediateDirectories: true)
        let contents = try fileManager.contentsOfDirectory(
            at: legacyDir,
            includingPropertiesForKeys: nil
        )
        for item in contents {
            let dest = sharedDir.appendingPathComponent(item.lastPathComponent)
            if fileManager.fileExists(atPath: dest.path) {
                try fileManager.removeItem(at: dest)
            }
            do {
                try fileManager.moveItem(at: item, to: dest)
            } catch {
                do {
                    try fileManager.copyItem(at: item, to: dest)
                    try fileManager.removeItem(at: item)
                } catch {
                    throw StoreError.migrationFailed(error.localizedDescription)
                }
            }
        }
        try? fileManager.removeItem(at: legacyDir)
    }
    #endif

    /// Wipe shared + legacy roots by fixed paths — never call `databaseDirectory()`
    /// (which migrates) from a wipe path. Throws if a present root cannot be removed
    /// so callers do not delete the Keychain DB key against a surviving store.
    static func removeAllStoreFiles(fileManager: FileManager = .default) throws {
        var roots: [URL] = []
        #if os(iOS)
        if let group = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId
        ) {
            roots.append(group.appendingPathComponent(dbDirName, isDirectory: true))
        }
        if let legacy = legacyApplicationSupportDirectory(fileManager: fileManager) {
            roots.append(legacy)
        }
        #else
        if let support = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            roots.append(support.appendingPathComponent(dbDirName, isDirectory: true))
        }
        #endif
        try removeStoreRoots(roots, fileManager: fileManager)
    }

    /// Testable wipe helper: delete only the given roots when present.
    static func removeStoreRoots(_ roots: [URL], fileManager: FileManager = .default) throws {
        for root in roots where fileManager.fileExists(atPath: root.path) {
            do {
                try fileManager.removeItem(at: root)
            } catch {
                throw StoreError.wipeFailed(
                    "failed to remove \(root.lastPathComponent): \(error.localizedDescription)"
                )
            }
            if fileManager.fileExists(atPath: root.path) {
                throw StoreError.wipeFailed("\(root.lastPathComponent) still present after remove")
            }
        }
    }
}
