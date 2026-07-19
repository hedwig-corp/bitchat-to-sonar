//
// MarmotStoreLock.swift
// bitchat + SonarNotificationService
//
// Cross-process exclusive lock for the shared App Group Marmot SQLCipher store.
// Main app holds while SonarNode is open and releases on background (see
// `MarmotChatModel.suspendStoreForBackground`) so the NSE can hydrate. NSE
// tries non-blocking and skips hydrate if the lock is still busy.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Darwin
import Foundation

/// Advisory `flock` on `sonar-marmot/marmot.store.lock` in the App Group.
///
/// Darwin note: a second `LOCK_EX` on a **different fd** in the **same process**
/// conflicts (EWOULDBLOCK). Callers must reuse an existing hold (see
/// `MarmotService.prepareStoreLockForConnect`) instead of acquiring twice.
final class MarmotStoreLock: @unchecked Sendable {
    static let appGroupId = "group.sh.hedwig.sonar"
    static let dbDirName = "sonar-marmot"
    static let lockFileName = "marmot.store.lock"

    private let fileHandle: FileHandle
    private let stateLock = NSLock()
    private var released = false

    private init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }

    deinit {
        release()
    }

    /// Lock file URL next to the shared DB. Creates the store directory when
    /// `createDirectory` is true (main app). NSE should pass false and only
    /// lock when the shared store already exists.
    static func lockFileURL(
        fileManager: FileManager = .default,
        createDirectory: Bool
    ) -> URL? {
        #if os(iOS)
        guard let group = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId
        ) else {
            return nil
        }
        let dir = group.appendingPathComponent(dbDirName, isDirectory: true)
        if createDirectory {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        } else if !fileManager.fileExists(atPath: dir.path) {
            return nil
        }
        return dir.appendingPathComponent(lockFileName)
        #else
        return nil
        #endif
    }

    /// Blocking exclusive lock — used by the main app around `SonarNode.connect`.
    /// Waits if the NSE currently holds the wake lock (bounded by NSE lifetime).
    static func acquireExclusive(fileManager: FileManager = .default) throws -> MarmotStoreLock {
        #if os(iOS)
        guard let url = lockFileURL(fileManager: fileManager, createDirectory: true) else {
            throw StoreLockError.appGroupUnavailable
        }
        do {
            return try openAndLock(url: url, nonBlocking: false)
        } catch StoreLockError.busy {
            // Blocking path should not surface busy; treat as system failure.
            throw StoreLockError.system(EAGAIN)
        }
        #else
        throw StoreLockError.appGroupUnavailable
        #endif
    }

    /// Non-blocking exclusive lock — used by the NSE. Returns `nil` if the main
    /// app (or another wake) already holds the store.
    static func tryAcquireExclusive(fileManager: FileManager = .default) -> MarmotStoreLock? {
        #if os(iOS)
        guard let url = lockFileURL(fileManager: fileManager, createDirectory: false) else {
            return nil
        }
        do {
            return try openAndLock(url: url, nonBlocking: true)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    func release() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !released else { return }
        released = true
        let fd = fileHandle.fileDescriptor
        _ = flock(fd, LOCK_UN)
        try? fileHandle.close()
    }

    #if os(iOS)
    private static func openAndLock(url: URL, nonBlocking: Bool) throws -> MarmotStoreLock {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        let flags = nonBlocking ? (LOCK_EX | LOCK_NB) : LOCK_EX
        let status = flock(handle.fileDescriptor, flags)
        if status != 0 {
            let err = errno
            try? handle.close()
            if nonBlocking, err == EWOULDBLOCK || err == EAGAIN {
                throw StoreLockError.busy
            }
            throw StoreLockError.system(err)
        }
        return MarmotStoreLock(fileHandle: handle)
    }
    #endif
}

enum StoreLockError: Error {
    case busy
    case appGroupUnavailable
    case system(Int32)
}
