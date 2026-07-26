//
// SonarSharePayload.swift
// bitchat
//
// Hand-off format between the iOS share extension and the app.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// One item shared into Sonar from the system share sheet.
///
/// Files are staged as real files in the App Group container rather than
/// carried inline: a `UserDefaults` string cannot hold a photo, and the app
/// send path (`snReadAttachments`) already speaks file URLs.
struct SonarSharedItem: Codable, Equatable, Identifiable {
    /// Path relative to the payload directory. Also the identity — the
    /// extension writes one file per name.
    let relativePath: String
    let filename: String
    let mime: String
    let byteCount: Int

    var id: String { relativePath }
}

/// A single "share into Sonar" gesture: optional text/link plus staged files.
///
/// The extension deliberately does **not** send. Sending means mutating
/// Marmot/MLS state, and a second process touching that store races the app
/// (see `MarmotStoreLock`) — the class of damage the Account Key Durability
/// Rule exists to prevent. So the extension stages, and the app picks a
/// recipient and sends.
struct SonarSharePayload: Codable, Equatable, Identifiable {
    /// Bump when the on-disk shape changes so an old staged payload written by
    /// a previous build is discarded instead of misread.
    static let currentVersion = 1

    let version: Int
    let id: String
    let createdAt: Date
    /// Message body: the shared link, the shared text, or nil for files only.
    let text: String?
    let items: [SonarSharedItem]
    /// Attachments the extension could not stage (too large, unreadable, or
    /// past the item cap). Carried so the app can say so instead of dropping
    /// part of a multi-file share in silence.
    let droppedCount: Int

    init(
        version: Int = SonarSharePayload.currentVersion,
        id: String = UUID().uuidString,
        createdAt: Date = Date(),
        text: String?,
        items: [SonarSharedItem],
        droppedCount: Int = 0
    ) {
        self.version = version
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.items = items
        self.droppedCount = droppedCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        id = try container.decode(String.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        items = try container.decode([SonarSharedItem].self, forKey: .items)
        // Tolerated as absent so a payload staged by the previous build is
        // still delivered rather than discarded mid-upgrade.
        droppedCount = try container.decodeIfPresent(Int.self, forKey: .droppedCount) ?? 0
    }

    var isEmpty: Bool {
        items.isEmpty && (text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

/// App Group staging area for share-extension payloads.
///
/// Both processes talk to this type: the extension writes, the app reads and
/// deletes. Everything is directory-scoped by payload id so a partially
/// written payload can never be half-consumed, and so cleanup is one
/// `removeItem`.
enum SonarShareInbox {
    /// Total staged bytes accepted from one share gesture. The largest cap any
    /// send route accepts is the 25 MiB internet attachment budget; the app
    /// still enforces the real per-transport cap at send time (mesh is 1 MiB).
    static let maxStagedBytes = 25 * 1024 * 1024
    /// Matches `snMaxImportedAttachments` — the app rejects beyond this anyway.
    static let maxStagedItems = 10
    /// Staged payloads older than this are treated as abandoned and pruned.
    /// Generous on purpose: the old 30 s accept window silently discarded a
    /// share whenever the user did not open the app straight away.
    static let staleAfterSeconds: TimeInterval = 24 * 60 * 60

    private static let inboxDirName = "SharedInbox"
    private static let manifestName = "payload.json"

    /// Root of the staging area, created on demand.
    ///
    /// Returns nil when the App Group is unavailable — in the extension that
    /// means a provisioning problem, and the caller must surface it rather
    /// than silently dropping the user's content.
    static func inboxDirectory(
        appGroupID: String,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            return nil
        }
        let dir = container.appendingPathComponent(inboxDirName, isDirectory: true)
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return dir
    }

    static func payloadDirectory(
        id: String,
        appGroupID: String,
        fileManager: FileManager = .default
    ) -> URL? {
        inboxDirectory(appGroupID: appGroupID, fileManager: fileManager)?
            .appendingPathComponent(id, isDirectory: true)
    }

    // MARK: - Extension side

    /// Create the per-payload directory. The caller writes files into it and
    /// then calls `commit` — an uncommitted directory has no manifest and is
    /// therefore invisible to `pendingPayloads`.
    static func makePayloadDirectory(
        id: String,
        appGroupID: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let dir = payloadDirectory(id: id, appGroupID: appGroupID, fileManager: fileManager) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write the manifest, which is what makes the payload visible to the app.
    /// Written last, so a crash mid-copy leaves an inert directory that the
    /// next prune sweeps up rather than a payload with missing files.
    static func commit(
        _ payload: SonarSharePayload,
        appGroupID: String,
        fileManager: FileManager = .default
    ) throws {
        guard let dir = payloadDirectory(
            id: payload.id,
            appGroupID: appGroupID,
            fileManager: fileManager
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        try data.write(
            to: dir.appendingPathComponent(manifestName),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    // MARK: - App side

    /// Every committed payload, oldest first, after pruning stale and
    /// unreadable directories.
    static func pendingPayloads(
        appGroupID: String,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> [SonarSharePayload] {
        guard let inbox = inboxDirectory(appGroupID: appGroupID, fileManager: fileManager),
              let entries = try? fileManager.contentsOfDirectory(
                  at: inbox,
                  includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]
              )
        else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var payloads: [SonarSharePayload] = []

        for entry in entries {
            let manifest = entry.appendingPathComponent(manifestName)
            guard let data = try? Data(contentsOf: manifest),
                  let payload = try? decoder.decode(SonarSharePayload.self, from: data),
                  payload.version == SonarSharePayload.currentVersion,
                  !payload.isEmpty
            else {
                // No manifest yet means a share is mid-copy; only sweep it once
                // it is old enough to be certainly abandoned.
                if let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate,
                   now.timeIntervalSince(modified) > staleAfterSeconds {
                    try? fileManager.removeItem(at: entry)
                }
                continue
            }
            guard now.timeIntervalSince(payload.createdAt) <= staleAfterSeconds else {
                try? fileManager.removeItem(at: entry)
                continue
            }
            payloads.append(payload)
        }

        return payloads.sorted { $0.createdAt < $1.createdAt }
    }

    /// Absolute URLs of a payload's staged files, in manifest order, skipping
    /// any that went missing.
    static func fileURLs(
        for payload: SonarSharePayload,
        appGroupID: String,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard let dir = payloadDirectory(
            id: payload.id,
            appGroupID: appGroupID,
            fileManager: fileManager
        ) else {
            return []
        }
        return payload.items.compactMap { item in
            let url = dir.appendingPathComponent(item.relativePath)
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }
    }

    /// Delete a payload and its staged files. Called once the app has taken
    /// the bytes into memory for send, and on explicit cancel.
    static func discard(
        _ payloadID: String,
        appGroupID: String,
        fileManager: FileManager = .default
    ) {
        guard let dir = payloadDirectory(
            id: payloadID,
            appGroupID: appGroupID,
            fileManager: fileManager
        ) else {
            return
        }
        try? fileManager.removeItem(at: dir)
    }
}

/// Decide whether a share-sheet attachment is a *file* to stage, given what its
/// provider conforms to.
///
/// Pure and boolean-only so it is testable without an `NSItemProvider`.
///
/// The subtlety this exists for: `public.plain-text` and `public.url` both
/// conform to `public.data`. A naive "does it conform to public.data?" check
/// therefore matches a plain Safari link share, and the link gets staged as a
/// file *on top of* the text already extracted from the same provider —
/// producing a duplicate attachment, or a spurious "couldn't be attached"
/// when the coercion fails. So the generic `public.data` fallback is only
/// honoured for providers that are neither text nor a non-file URL.
func snShouldStageAsFile(
    isConcreteFileType: Bool,
    isText: Bool,
    isNonFileURL: Bool,
    isData: Bool
) -> Bool {
    // Images, movies, audio, PDFs and file URLs are always content to stage,
    // even though they conform to public.data too.
    if isConcreteFileType { return true }
    if isText || isNonFileURL { return false }
    return isData
}

/// Filenames arrive from other apps and are attacker-influenced. Keep only a
/// single safe path component so a staged item can never escape its payload
/// directory.
func snSafeSharedFilename(_ raw: String, fallback: String = "attachment") -> String {
    let lastComponent = raw
        .replacingOccurrences(of: "\\", with: "/")
        .split(separator: "/")
        .last
        .map(String.init) ?? ""
    let cleaned = lastComponent
        .replacingOccurrences(of: "\0", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return fallback }
    return String(cleaned.prefix(120))
}
