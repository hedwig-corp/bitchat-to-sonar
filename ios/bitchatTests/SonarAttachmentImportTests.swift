//
// SonarAttachmentImportTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
@testable import Sonar

struct SonarAttachmentImportTests {
    @Test func readsFilesWithinAggregateLimitAndRejectsOverflow() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonar-attachment-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = directory.appendingPathComponent("first.txt")
        let second = directory.appendingPathComponent("second.bin")
        try Data("1234".utf8).write(to: first)
        try Data("5678".utf8).write(to: second)

        let result = snReadAttachments([first, second], maxTotalBytes: 5)

        #expect(result.attachments.count == 1)
        #expect(result.attachments.first?.filename == "first.txt")
        #expect(result.attachments.first?.data == Data("1234".utf8))
        #expect(result.rejectedCount == 1)
        #expect(result.oversizedCount == 1)
    }

    @Test func capsOneSelectionAtTenFiles() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonar-attachment-count-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let result = snReadAttachments(
            Array(repeating: file, count: snMaxImportedAttachments + 1),
            maxTotalBytes: snMaxImportedAttachments + 1
        )

        #expect(result.attachments.count == snMaxImportedAttachments)
        #expect(result.rejectedCount == 1)
    }

    @Test func preservesOnlyTheImportWhosePendingRouteWasReplaced() {
        let replacement = SNMarmotRouteReplacement(
            pendingId: "pending:npub1peer",
            realId: "marmot:group"
        )

        #expect(snPreservesAttachmentImport(
            conversationID: "pending:npub1peer",
            routeReplacement: replacement
        ))
        #expect(!snPreservesAttachmentImport(
            conversationID: "another-chat",
            routeReplacement: replacement
        ))
    }

    @Test func normalizesUnsupportedEncryptedMediaMetadata() {
        #expect(snEncryptedAttachmentMime("application/zip") == "application/octet-stream")
        #expect(snEncryptedAttachmentMime("application/json; charset=utf-8") == "application/octet-stream")
        #expect(snEncryptedAttachmentMime("application/pdf") == "application/pdf")
        #expect(snEncryptedAttachmentMime("IMAGE/WEBP") == "image/webp")

        #expect(snEncryptedAttachmentFilename("../../diagnostic.zip") == "diagnostic.zip")
        #expect(snEncryptedAttachmentFilename("..\\..\\diagnostic.zip") == "diagnostic.zip")
        #expect(snEncryptedAttachmentFilename("..") == "attachment")
        #expect(snEncryptedAttachmentFilename("report\u{0000}.txt") == "report.txt")

        let bounded = snEncryptedAttachmentFilename(String(repeating: "a", count: 240) + ".zip")
        #expect(bounded.hasSuffix(".zip"))
        #expect(bounded.utf8.count <= 210)
    }
}
