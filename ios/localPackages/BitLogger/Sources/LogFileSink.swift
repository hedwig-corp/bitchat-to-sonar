//
// LogFileSink.swift
// BitLogger
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Bounded rotating file tee for `SecureLogger` — the platform half of the
/// diagnostics log export feature (Settings → Diagnostics → "Share debug
/// bundle").
///
/// Design:
/// - All writes hop to a dedicated serial utility queue, so logging call
///   sites (including chat open/send/scroll paths) never block on disk I/O.
/// - The file family is `sonar-ios.log` (+ `.1`, `.2` rotations), capped at
///   `maxFileBytes` per file — total disk use stays bounded.
/// - Debug-level lines are only written when `verbose` is enabled (the
///   explicit user opt-in from the Diagnostics screen). Everything written is
///   already sanitized by `SecureLogger`; as a hard backstop, any `nsec1…`
///   bech32 material is scrubbed before hitting disk.
public final class LogFileSink {
    public static let shared = LogFileSink()

    private let queue = DispatchQueue(label: "chat.bitchat.logfilesink", qos: .utility)
    private let timestampPrefix: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    private var directory: URL?
    private var verbose = false
    private var handle: FileHandle?
    private var bytesWritten: UInt64 = 0

    private let fileName = "sonar-ios.log"
    private let maxFileBytes: UInt64 = 2 * 1024 * 1024
    private let maxRotations = 2

    private init() {}

    // MARK: - Configuration

    /// Point the sink at `directory` (created if missing) and set the verbose
    /// flag. Call once at app start; the sink is inert until configured.
    public func configure(directory: URL, verbose: Bool) {
        queue.async {
            self.directory = directory
            self.verbose = verbose
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.openHandleLocked()
        }
    }

    /// Toggle debug-line capture at runtime (Diagnostics screen switch).
    public func setVerbose(_ verbose: Bool) {
        queue.async { self.verbose = verbose }
    }

    /// Close the file and delete this process's log directory, **serialized on
    /// the writer queue** so an in-flight `write` can't reopen the file after
    /// the delete and strand pre-wipe content. Used by the emergency-wipe path
    /// (verbose logs can contain peer npubs, so a wipe must leave nothing).
    /// The sink stays configured: a later write lazily recreates the file, so
    /// post-wipe logging keeps working (with post-wipe content only).
    public func purge() {
        queue.sync {
            try? self.handle?.close()
            self.handle = nil
            self.bytesWritten = 0
            if let dir = self.directory {
                try? FileManager.default.removeItem(at: dir)
            }
        }
    }

    // MARK: - Writing (called by SecureLogger)

    /// Append one already-sanitized log line. `isDebug` lines are dropped
    /// unless verbose capture is on. Never blocks the caller.
    func write(level: String, category: String, message: String, isDebug: Bool) {
        queue.async {
            guard self.directory != nil else { return }
            if isDebug && !self.verbose { return }
            let scrubbed = Self.scrubSecrets(message)
            let now = Date()
            let epoch = now.timeIntervalSince1970
            let micros = Int((epoch - floor(epoch)) * 1_000_000)
            let stamp = "\(self.timestampPrefix.string(from: now)).\(String(format: "%06d", micros))Z"
            let line = "\(stamp) [\(category)] [\(level)] \(scrubbed)\n"
            self.appendLocked(line)
        }
    }

    // MARK: - Export

    /// URLs of the current log file family (newest first), for the debug
    /// bundle. Synchronizes with the writer queue so rotation can't race.
    ///
    /// - Warning: uses `queue.sync`; must NOT be called from within `queue`
    ///   (i.e. never from `write`/`configure`/`setVerbose`) or it deadlocks.
    ///   Callers are on the export path (a detached task), which is off-queue.
    public func logFileURLs() -> [URL] {
        queue.sync {
            guard let dir = directory else { return [] }
            var urls = [dir.appendingPathComponent(fileName)]
            for i in 1...maxRotations {
                urls.append(dir.appendingPathComponent("\(fileName).\(i)"))
            }
            return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    // MARK: - Private (all on `queue`)

    private func openHandleLocked() {
        guard let dir = directory else { return }
        let url = dir.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        if let handle {
            bytesWritten = (try? handle.seekToEnd()) ?? 0
        }
    }

    private func appendLocked(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        if handle == nil { openHandleLocked() }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            bytesWritten += UInt64(data.count)
            if bytesWritten >= maxFileBytes {
                rotateLocked()
            }
        } catch {
            // Disk full or file vanished: drop the handle; next write retries.
            self.handle = nil
        }
    }

    private func rotateLocked() {
        guard let dir = directory else { return }
        try? handle?.close()
        handle = nil
        bytesWritten = 0
        let fm = FileManager.default
        let base = dir.appendingPathComponent(fileName)
        // Shift sonar-ios.log.(n-1) → .n, oldest falls off.
        for i in stride(from: maxRotations, through: 1, by: -1) {
            let src = i == 1 ? base : dir.appendingPathComponent("\(fileName).\(i - 1)")
            let dst = dir.appendingPathComponent("\(fileName).\(i)")
            try? fm.removeItem(at: dst)
            if fm.fileExists(atPath: src.path) {
                try? fm.moveItem(at: src, to: dst)
            }
        }
        openHandleLocked()
    }

    /// Belt-and-braces: no `nsec1…` (or raw `marmot-nsec` values) may ever be
    /// persisted, even with verbose capture on.
    static func scrubSecrets(_ message: String) -> String {
        guard message.contains("nsec1") else { return message }
        return message.replacingOccurrences(
            of: #"nsec1[a-z0-9]+"#,
            with: "nsec1[REDACTED]",
            options: .regularExpression
        )
    }
}
