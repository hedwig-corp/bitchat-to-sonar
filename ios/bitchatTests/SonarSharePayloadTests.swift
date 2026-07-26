//
// SonarSharePayloadTests.swift
// bitchatTests
//
// Share-extension → app hand-off format.
//

import Testing
import Foundation
@testable import Sonar

/// Pins the staging contract between the share extension and the app.
///
/// The bugs behind these: a share used to cross the process boundary as a
/// single `UserDefaults` string (so files could not travel at all), and the app
/// blind-sent whatever arrived into the currently selected chat — which with no
/// selection is the public mesh broadcast.
struct SonarSharePayloadTests {
    /// A throwaway App Group stand-in. `containerURL(forSecurityApplicationGroupIdentifier:)`
    /// needs a provisioned group, so exercise the pure logic that does not.
    private func item(_ name: String, bytes: Int = 10) -> SonarSharedItem {
        SonarSharedItem(relativePath: "0-\(name)", filename: name, mime: "image/jpeg", byteCount: bytes)
    }

    @Test
    func payloadWithOnlyBlankTextIsEmpty() {
        #expect(SonarSharePayload(text: nil, items: []).isEmpty)
        #expect(SonarSharePayload(text: "   \n ", items: []).isEmpty)
    }

    @Test
    func payloadWithFilesIsNotEmptyEvenWithoutText() {
        // A shared photo carries no caption; treating that as empty is exactly
        // how image sharing used to fail with "no shareable content".
        #expect(!SonarSharePayload(text: nil, items: [item("photo.jpg")]).isEmpty)
    }

    @Test
    func payloadRoundTripsThroughJSON() throws {
        let payload = SonarSharePayload(
            text: "https://example.com",
            items: [item("photo.jpg", bytes: 4096), item("doc.pdf")]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(
            SonarSharePayload.self,
            from: try encoder.encode(payload)
        )
        #expect(decoded.id == payload.id)
        #expect(decoded.text == "https://example.com")
        #expect(decoded.items.count == 2)
        #expect(decoded.items[0].byteCount == 4096)
        #expect(decoded.version == SonarSharePayload.currentVersion)
    }

    @Test
    func staleWindowOutlivesTheOldThirtySecondDrop() {
        // The previous accept window was 30 s: open the app later than that and
        // the share was silently discarded.
        #expect(SonarShareInbox.staleAfterSeconds > 30)
    }

    @Test
    func stagingCapsMatchTheSendRoutes() {
        // The extension must not stage more than the largest route accepts, nor
        // more items than the app's importer will read.
        #expect(SonarShareInbox.maxStagedBytes == 25 * 1024 * 1024)
        #expect(SonarShareInbox.maxStagedItems == snMaxImportedAttachments)
    }

    // MARK: - Filenames

    @Test
    func sharedFilenameKeepsOnlyASafeComponent() {
        // Filenames come from other apps, so a staged item must never be able
        // to escape its payload directory.
        #expect(snSafeSharedFilename("../../etc/passwd") == "passwd")
        #expect(snSafeSharedFilename("C:\\Users\\x\\photo.jpg") == "photo.jpg")
        #expect(snSafeSharedFilename("plain.pdf") == "plain.pdf")
    }

    @Test
    func sharedFilenameFallsBackWhenUnusable() {
        #expect(snSafeSharedFilename("") == "attachment")
        #expect(snSafeSharedFilename("..") == "attachment")
        #expect(snSafeSharedFilename(".") == "attachment")
        #expect(snSafeSharedFilename("/") == "attachment")
        #expect(snSafeSharedFilename("", fallback: "photo.jpg") == "photo.jpg")
    }

    @Test
    func sharedFilenameIsBounded() {
        let long = String(repeating: "a", count: 500) + ".jpg"
        #expect(snSafeSharedFilename(long).count <= 120)
    }
}
