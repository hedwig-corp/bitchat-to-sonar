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

        var errorDescription: String? {
            switch self {
            case .appGroupUnavailable:
                return "App Group \(appGroupId) unavailable — Marmot store cannot open safely"
            case .migrationFailed(let reason):
                return "Marmot App Group migration failed: \(reason)"
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
        try migrateLegacyApplicationSupportStoreIfNeeded(
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
        let sharedDb = sharedDir.appendingPathComponent(dbFileName)
        if fileManager.fileExists(atPath: sharedDb.path) {
            return
        }
        guard let legacyDir = legacyApplicationSupportDirectory(fileManager: fileManager),
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

    /// Wipe shared root and any leftover legacy Application Support directory.
    static func removeAllStoreFiles(fileManager: FileManager = .default) {
        if let shared = try? databaseDirectory(fileManager: fileManager) {
            try? fileManager.removeItem(at: shared)
        }
        #if os(iOS)
        if let legacy = legacyApplicationSupportDirectory(fileManager: fileManager) {
            try? fileManager.removeItem(at: legacy)
        }
        #endif
    }
}
