//
// SonarDiagnostics.swift
// bitchat
//
// Diagnostics log capture + debug bundle export (Settings → Diagnostics).
// Owns the two on-device log sinks:
//  - Rust core: `setupLogging(dir:verbose:)` (sonar-ffi) → rotating
//    `sonar-core.*.log` under logs/core
//  - Swift app: `LogFileSink` (BitLogger tee of SecureLogger) → rotating
//    `sonar-ios.log` under logs/ios
// and assembles the shareable zip (log files + relay/sync snapshot JSON).
//
// Privacy: both sinks are redacted by default (no message content, no key
// material, core stays at info level). The verbose toggle is an explicit
// user opt-in and still never captures `nsec` material.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Foundation
import SonarCore

enum SonarDiagnostics {
    static let verboseDefaultsKey = "sonar.diagnostics.verbose"

    private static let installLock = NSLock()
    private static var coreLoggingInstalled = false

    // MARK: - Directories

    /// `<Application Support>/sonar-marmot/logs`. App extensions get their own
    /// subtree (`logs-nse`) so two processes never write the same file family.
    private static func logsRootDirectory() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        let isExtension = Bundle.main.bundleURL.pathExtension == "appex"
        return base
            .appendingPathComponent("sonar-marmot", isDirectory: true)
            .appendingPathComponent(isExtension ? "logs-nse" : "logs", isDirectory: true)
    }

    static func coreLogDirectory() -> URL? {
        logsRootDirectory()?.appendingPathComponent("core", isDirectory: true)
    }

    static func appLogDirectory() -> URL? {
        logsRootDirectory()?.appendingPathComponent("ios", isDirectory: true)
    }

    // MARK: - Verbose flag

    static var verboseEnabled: Bool {
        UserDefaults.standard.bool(forKey: verboseDefaultsKey)
    }

    /// Flip verbose capture on both sinks and persist the choice.
    static func setVerbose(_ verbose: Bool) {
        UserDefaults.standard.set(verbose, forKey: verboseDefaultsKey)
        LogFileSink.shared.setVerbose(verbose)
        if let dir = coreLogDirectory() {
            // Re-invoking setupLogging only swaps the core's level filter.
            try? setupLogging(dir: dir.path, verbose: verbose)
        }
    }

    // MARK: - Sink installation

    /// Configure the SecureLogger file tee. Call once at app start.
    static func configureAppSink() {
        guard let dir = appLogDirectory() else { return }
        LogFileSink.shared.configure(directory: dir, verbose: verboseEnabled)
    }

    /// The OTHER process's log root — the NSE writes to `logs-nse` (a separate
    /// process the main app's sink never opened), and vice-versa. Wipe must take
    /// it too since verbose logs there can hold peer npubs.
    private static func siblingLogsRootDirectory() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ) else { return nil }
        let isExtension = Bundle.main.bundleURL.pathExtension == "appex"
        return base
            .appendingPathComponent("sonar-marmot", isDirectory: true)
            .appendingPathComponent(isExtension ? "logs" : "logs-nse", isDirectory: true)
    }

    /// Delete every on-device diagnostics log directory. Called from the
    /// emergency-wipe path: verbose logs can contain peer npubs, so a wipe must
    /// leave nothing behind (Account Key Durability / privacy rule).
    static func clearLogs() {
        // App (SecureLogger) sink: purge on its own writer queue so an in-flight
        // write can't reopen the file mid-delete and strand a pre-wipe npub.
        LogFileSink.shared.purge()
        // The Rust core logs sit beside the app sink dir and are held open by
        // tracing-appender, not LogFileSink — removing the dir unlinks their
        // on-disk content (gone from the FS) with no queue race.
        if let root = logsRootDirectory() {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("core", isDirectory: true))
        }
        // The other process's whole log tree (NSE ↔ main app), never opened by
        // this process's sink, so a plain remove is race-free.
        if let sibling = siblingLogsRootDirectory() {
            try? FileManager.default.removeItem(at: sibling)
        }
        // Exported bundles staged for the share sheet live in the temp dir and
        // can contain verbose peer npubs — drop any that haven't been evicted.
        let tmp = FileManager.default.temporaryDirectory
        if let staged = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: nil
        ) {
            for url in staged where url.lastPathComponent.hasPrefix("sonar-diagnostics") {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Install the Rust core file sink. Idempotent and cheap after the first
    /// call; invoked before every `SonarNode.connect` so the sink exists no
    /// matter which connect path runs first. Failure is non-fatal — chat must
    /// work even if diagnostics logging cannot.
    static func installCoreLoggingIfNeeded() {
        installLock.lock()
        defer { installLock.unlock() }
        guard !coreLoggingInstalled else { return }
        guard let dir = coreLogDirectory() else { return }
        do {
            try setupLogging(dir: dir.path, verbose: verboseEnabled)
            coreLoggingInstalled = true
        } catch {
            SecureLogger.warning("core diagnostics logging unavailable: \(error)", category: .session)
        }
    }

    // MARK: - Debug bundle export

    /// Assemble the shareable diagnostics zip: core + app log files plus the
    /// relay/sync snapshot. Runs file I/O off the main thread; returns the
    /// zip's URL in the temporary directory, or nil if nothing could be
    /// bundled. The staging folder is always cleaned up.
    static func buildDebugBundle(snapshotJson: String?) async -> URL? {
        await Task.detached(priority: .userInitiated) {
            buildDebugBundleSync(snapshotJson: snapshotJson)
        }.value
    }

    private static func buildDebugBundleSync(snapshotJson: String?) -> URL? {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("sonar-diagnostics", isDirectory: true)
        // Fresh staging area per export.
        try? fm.removeItem(at: staging)
        guard (try? fm.createDirectory(at: staging, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        defer { try? fm.removeItem(at: staging) }

        var copiedAnything = false
        // Core log files (rotating daily family).
        if let coreDir = coreLogDirectory(),
           let files = try? fm.contentsOfDirectory(at: coreDir, includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent.hasPrefix("sonar-core") {
                try? fm.copyItem(at: file, to: staging.appendingPathComponent(file.lastPathComponent))
                copiedAnything = true
            }
        }
        // App (SecureLogger tee) log files.
        for file in LogFileSink.shared.logFileURLs() {
            try? fm.copyItem(at: file, to: staging.appendingPathComponent(file.lastPathComponent))
            copiedAnything = true
        }
        // Relay/sync snapshot.
        if let snapshotJson, let data = snapshotJson.data(using: .utf8) {
            try? data.write(to: staging.appendingPathComponent("snapshot.json"))
            copiedAnything = true
        }
        guard copiedAnything else { return nil }

        // Zip without a dependency: a coordinated read with .forUploading
        // materializes the folder as a zip; copy it out before the accessor
        // returns (the provided URL is only valid inside the block).
        var zipURL: URL?
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        coordinator.coordinate(
            readingItemAt: staging, options: .forUploading, error: &coordinationError
        ) { tempZip in
            let stamp = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
            let dest = fm.temporaryDirectory
                .appendingPathComponent("sonar-diagnostics-\(stamp).zip")
            try? fm.removeItem(at: dest)
            if (try? fm.copyItem(at: tempZip, to: dest)) != nil {
                zipURL = dest
            }
        }
        if let coordinationError {
            SecureLogger.warning("diagnostics zip failed: \(coordinationError)", category: .session)
        }
        return zipURL
    }
}
