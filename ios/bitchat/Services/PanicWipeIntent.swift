import Darwin
import Foundation

/// Crash-durable, app-wide account-removal journal. Cold-start identity, radio,
/// and core entry points fail closed while this file exists. It is removed only
/// after the owner of every Apple account store has crossed its wipe barrier.
final class DurablePanicWipeIntent {
    private let markerURL: URL
    private let directorySyncFault: DirectoryDurability.FaultInjector?
    private let lock = NSLock()

    init(
        rootURL: URL,
        directorySyncFault: DirectoryDurability.FaultInjector? = nil
    ) {
        markerURL = rootURL.appendingPathComponent(".panic-wipe.intent", isDirectory: false)
        self.directorySyncFault = directorySyncFault
    }

    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: markerURL.path) {
            do {
                let handle = try FileHandle(forWritingTo: markerURL)
                try handle.synchronize()
                try handle.close()
                try synchronizeParentDirectory()
                return true
            } catch {
                return false
            }
        }
        do {
            try FileManager.default.createDirectory(
                at: markerURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let temporaryURL = markerURL.deletingLastPathComponent()
                .appendingPathComponent(".panic-wipe.intent.\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            guard FileManager.default.createFile(
                atPath: temporaryURL.path,
                contents: Data("sonar-panic-wipe-v1\n".utf8)
            ) else { return false }
            let handle = try FileHandle(forWritingTo: temporaryURL)
            try handle.synchronize()
            try handle.close()
            guard rename(temporaryURL.path, markerURL.path) == 0 else {
                return false
            }
            try synchronizeParentDirectory()
            return true
        } catch {
            return false
        }
    }

    func isPending() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return FileManager.default.fileExists(atPath: markerURL.path)
    }

    func clear() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: markerURL.path) else { return true }
        guard unlink(markerURL.path) == 0 else { return false }
        do {
            try synchronizeParentDirectory()
            return true
        } catch {
            return false
        }
    }

    private func synchronizeParentDirectory() throws {
        try DirectoryDurability.synchronize(
            markerURL.deletingLastPathComponent(),
            faultInjector: directorySyncFault
        )
    }
}

enum PanicWipeIntent {
    private static let journal: DurablePanicWipeIntent = {
        // Never fall back to tmp: the operating system may purge it between
        // launches, which would silently reopen identity bootstrap.
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return DurablePanicWipeIntent(rootURL: root.appendingPathComponent("Sonar", isDirectory: true))
    }()

    static func begin() -> Bool { journal.begin() }
    static var isPending: Bool { journal.isPending() }
    static func clear() -> Bool { journal.clear() }
}

/// Commits the crash-durable wipe marker before any UI redaction or transport
/// teardown. Cold-start recovery may redact immediately because its marker was
/// already committed by the interrupted process.
@discardableResult
func beginPanicWipeBeforeRedaction(
    alreadyPending: Bool,
    commitIntent: () -> Bool,
    redact: () -> Void
) -> Bool {
    guard alreadyPending || commitIntent() else { return false }
    redact()
    return true
}
