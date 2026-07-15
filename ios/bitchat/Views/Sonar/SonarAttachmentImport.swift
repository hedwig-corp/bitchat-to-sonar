//
// SonarAttachmentImport.swift
// bitchat
//
// Bounded, security-scoped document import shared by the Apple chat surfaces.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import UniformTypeIdentifiers

let snMaxImportedAttachments = 10

private let snGenericEncryptedAttachmentMime = "application/octet-stream"
private let snMaxEncryptedAttachmentFilenameBytes = 210
private let snEncryptedAttachmentMimes: Set<String> = [
    "image/png", "image/jpeg", "image/gif", "image/webp", "image/bmp",
    "image/x-icon", "image/tiff", "image/x-farbfeld", "image/avif", "image/qoi",
    "video/mp4", "video/quicktime", "video/x-matroska", "video/webm",
    "video/x-msvideo", "video/ogg", "audio/ogg", "audio/flac", "audio/x-flac",
    "audio/aac", "audio/mp4", "audio/webm", "audio/mpeg", "audio/wav",
    "audio/x-matroska", "application/pdf", "text/plain",
    snGenericEncryptedAttachmentMime,
]

/// MDK deliberately accepts a media allowlist plus this generic escape hatch.
/// Preserve the filename/extension while normalizing every other file type.
func snEncryptedAttachmentMime(_ mime: String) -> String {
    let normalized = mime
        .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        .first
        .map(String.init)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? ""
    return snEncryptedAttachmentMimes.contains(normalized)
        ? normalized
        : snGenericEncryptedAttachmentMime
}

/// Match MDK filename validation without losing a useful short extension.
func snEncryptedAttachmentFilename(_ filename: String) -> String {
    // MDK rejects both path-separator styles. NSString only treats `/` as a
    // separator on Apple platforms, so normalize Windows-style paths first.
    let normalizedPath = filename.replacingOccurrences(of: "\\", with: "/")
    let candidate = snSafeAttachmentFilename(normalizedPath)
    guard candidate.utf8.count > snMaxEncryptedAttachmentFilenameBytes else { return candidate }

    let nsCandidate = candidate as NSString
    let rawExtension = nsCandidate.pathExtension
    let rawSuffix = rawExtension.isEmpty ? "" : ".\(rawExtension)"
    let suffix = rawSuffix.utf8.count < snMaxEncryptedAttachmentFilenameBytes / 2
        ? rawSuffix
        : ""
    let base = suffix.isEmpty ? candidate : nsCandidate.deletingPathExtension
    let baseBudget = snMaxEncryptedAttachmentFilenameBytes - suffix.utf8.count
    let bounded = snUTF8Prefix(base, maxBytes: baseBudget) + suffix
    return bounded.isEmpty ? "attachment" : bounded
}

private func snUTF8Prefix(_ value: String, maxBytes: Int) -> String {
    guard maxBytes > 0 else { return "" }
    var result = ""
    var usedBytes = 0
    for scalar in value.unicodeScalars {
        let text = String(scalar)
        let count = text.utf8.count
        guard usedBytes + count <= maxBytes else { break }
        result.append(contentsOf: text)
        usedBytes += count
    }
    return result
}

struct SNImportedAttachment: Sendable {
    let data: Data
    let filename: String
    let mime: String
}

struct SNAttachmentImportResult: Sendable {
    let attachments: [SNImportedAttachment]
    let rejectedCount: Int
    let oversizedCount: Int
}

private enum SNAttachmentReadResult: Sendable {
    case attachment(SNImportedAttachment)
    case tooLarge
    case unreadable
}

private func snReadAttachment(_ url: URL, maxBytes: Int) -> SNAttachmentReadResult {
    guard url.isFileURL, maxBytes > 0 else { return .unreadable }
    let scoped = url.startAccessingSecurityScopedResource()
    defer {
        if scoped { url.stopAccessingSecurityScopedResource() }
    }

    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey])
    guard values?.isRegularFile == true else { return .unreadable }
    if let size = values?.fileSize, size > maxBytes { return .tooLarge }

    do {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let readLimit = min(maxBytes, Int.max - 1) + 1
        var data = Data()
        data.reserveCapacity(min(max(values?.fileSize ?? 0, 0), maxBytes))
        var remainingRead = readLimit
        while remainingRead > 0 {
            guard let chunk = try handle.read(upToCount: min(64 * 1024, remainingRead)),
                  !chunk.isEmpty else { break }
            data.append(chunk)
            remainingRead -= chunk.count
        }
        guard data.count <= maxBytes else { return .tooLarge }
        let filename = url.lastPathComponent.isEmpty ? "attachment" : url.lastPathComponent
        let detectedMime = values?.contentType?.preferredMIMEType
            ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        let mime = snEffectiveAttachmentMime(
            declaredMime: detectedMime,
            filename: filename,
            plaintext: data
        )
        return .attachment(SNImportedAttachment(data: data, filename: filename, mime: mime))
    } catch {
        return .unreadable
    }
}

func snReadAttachments(_ urls: [URL], maxTotalBytes: Int) -> SNAttachmentImportResult {
    let fileURLs = urls.filter(\.isFileURL)
    var rejectedCount = urls.count - fileURLs.count
    rejectedCount += max(0, fileURLs.count - snMaxImportedAttachments)
    guard maxTotalBytes > 0 else {
        return SNAttachmentImportResult(
            attachments: [],
            rejectedCount: rejectedCount + min(fileURLs.count, snMaxImportedAttachments),
            oversizedCount: min(fileURLs.count, snMaxImportedAttachments)
        )
    }

    var attachments: [SNImportedAttachment] = []
    var oversizedCount = 0
    var remainingBytes = maxTotalBytes
    for url in fileURLs.prefix(snMaxImportedAttachments) {
        switch snReadAttachment(url, maxBytes: remainingBytes) {
        case .attachment(let attachment):
            attachments.append(attachment)
            remainingBytes -= attachment.data.count
        case .tooLarge:
            rejectedCount += 1
            oversizedCount += 1
        case .unreadable:
            rejectedCount += 1
        }
    }
    return SNAttachmentImportResult(
        attachments: attachments,
        rejectedCount: rejectedCount,
        oversizedCount: oversizedCount
    )
}

/// Route setup can replace a pending conversation while its first attachment
/// is still importing. Preserve only that import across the replacement.
func snPreservesAttachmentImport(
    conversationID: String,
    routeReplacement: SNMarmotRouteReplacement?
) -> Bool {
    routeReplacement?.pendingId == conversationID
}
