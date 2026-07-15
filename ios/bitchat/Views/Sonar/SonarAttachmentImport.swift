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
