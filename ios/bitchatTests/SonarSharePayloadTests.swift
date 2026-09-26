//
// SonarSharePayloadTests.swift
// bitchatTests
//
// Share-extension → app hand-off format.
//

import Testing
import Foundation
import UniformTypeIdentifiers
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

    // MARK: - What counts as a file to stage

    /// The regression this pins: `public.plain-text` and `public.url` both
    /// conform to `public.data` (verified: `UTType.url.conforms(to: .data)` is
    /// true). A plain "does it conform to public.data?" check therefore matched
    /// a Safari link share, and the link was staged as a file on top of the
    /// text already extracted from the same provider — a duplicate attachment,
    /// or a spurious "1 file couldn't be attached" on the commonest flow.
    @Test
    func linkShareIsNotAlsoStagedAsAFile() {
        // A Safari link provider: URL + data, not a file URL.
        #expect(!snShouldStageAsFile(
            isConcreteFileType: false,
            isText: false,
            isNonFileURL: true,
            isData: true,
            hasSuggestedName: false
        ))
    }

    @Test
    func plainTextShareIsNotAlsoStagedAsAFile() {
        // A plain text share has no filename — it is the message body, not a
        // document, so it must not also be staged as a file.
        #expect(!snShouldStageAsFile(
            isConcreteFileType: false,
            isText: true,
            isNonFileURL: false,
            isData: true,
            hasSuggestedName: false
        ))
    }

    @Test
    func textDocumentWithFilenameIsStaged() {
        // A CSV/JSON/.swift/.ics document conforms to UTType.text, so without
        // the suggested-name rescue the isText guard would drop it and only the
        // message body would survive — losing the file and its filename. A
        // provider that carries a filename is a document, so it is staged to
        // match Android's wildcard file handling.
        #expect(snShouldStageAsFile(
            isConcreteFileType: false,
            isText: true,
            isNonFileURL: false,
            isData: true,
            hasSuggestedName: true
        ))
    }

    @Test
    func linkShareIsNotStagedEvenWithASuggestedName() {
        // A non-file URL keeps being rejected even when it carries a suggested
        // name — a shared web link is not a document.
        #expect(!snShouldStageAsFile(
            isConcreteFileType: false,
            isText: false,
            isNonFileURL: true,
            isData: true,
            hasSuggestedName: true
        ))
    }

    @Test
    func concreteFileTypesAlwaysStage() {
        // A photo conforms to public.data as well; the concrete match must win
        // so tightening the fallback never stops real attachments shipping.
        #expect(snShouldStageAsFile(
            isConcreteFileType: true,
            isText: false,
            isNonFileURL: false,
            isData: true,
            hasSuggestedName: false
        ))
        // A file URL is content even though it is also a URL.
        #expect(snShouldStageAsFile(
            isConcreteFileType: true,
            isText: false,
            isNonFileURL: false,
            isData: false,
            hasSuggestedName: false
        ))
    }

    @Test
    func opaqueDataStillStagesThroughTheFallback() {
        // An arbitrary document with no more specific conformance — the reason
        // the public.data fallback exists at all.
        #expect(snShouldStageAsFile(
            isConcreteFileType: false,
            isText: false,
            isNonFileURL: false,
            isData: true,
            hasSuggestedName: false
        ))
    }

    @Test
    func providerMatchingNothingIsNotStaged() {
        #expect(!snShouldStageAsFile(
            isConcreteFileType: false,
            isText: false,
            isNonFileURL: false,
            isData: false,
            hasSuggestedName: false
        ))
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

    // MARK: - Which type identifier carries the bytes

    /// THE regression: sharing any non-media document into Sonar delivered the
    /// file's PATH instead of the file.
    ///
    /// `loadFileRepresentation(forTypeIdentifier: "public.file-url")` does not
    /// vend the document — it vends a temp file named `file URL` whose contents
    /// are the `file://` path string (measured: 111 bytes for a 11-byte
    /// `notes.txt`). `public.file-url` sat ahead of `public.data` in the probe
    /// order, so every csv/txt/json/zip/docx share hit it. Photos and PDFs
    /// dodged it by matching a concrete type first, which is why the bug read as
    /// "some files work".
    @Test
    func stagingNeverAsksAURLIdentifierForBytes() {
        // Exactly what NSItemProvider(contentsOf:) registers for a document.
        #expect(snStagingTypeIdentifier(registeredTypeIdentifiers: [
            "public.comma-separated-values-text", "public.file-url", "public.url",
        ]) == "public.comma-separated-values-text")

        #expect(snStagingTypeIdentifier(registeredTypeIdentifiers: [
            "public.zip-archive", "public.file-url", "public.url",
        ]) == "public.zip-archive")

        // Order must not rescue us: a provider that lists the URL type first is
        // still asked for its content type.
        #expect(snStagingTypeIdentifier(registeredTypeIdentifiers: [
            "public.file-url", "public.url", "public.plain-text",
        ]) == "public.plain-text")

        // Generic data is the floor, not a miss: a provider whose only
        // byte-carrying type IS `public.data` must stage from it — every case
        // above would also pass an implementation that only ranked CONCRETE
        // types over `public.file-url` and skipped the generic one.
        #expect(snStagingTypeIdentifier(registeredTypeIdentifiers: [
            "public.file-url", "public.data", "public.url",
        ]) == "public.data")
    }

    @Test
    func urlOnlyProviderHasNoStagingTypeAndFallsBackToTheFileURL() {
        // nil is the signal for "resolve the file URL and copy the real file"
        // — never "ask public.file-url for bytes".
        #expect(snStagingTypeIdentifier(
            registeredTypeIdentifiers: ["public.file-url", "public.url"]
        ) == nil)
        #expect(snStagingTypeIdentifier(registeredTypeIdentifiers: []) == nil)
    }

    @Test
    func dynamicUTIStillStages() {
        // An unknown extension yields a `dyn.…` identifier. Dropping it would
        // lose the file, so the non-URL fallback keeps it.
        let dynamic = UTType(filenameExtension: "sonartestext")?.identifier ?? "dyn.test"
        #expect(snStagingTypeIdentifier(
            registeredTypeIdentifiers: [dynamic, "public.file-url"]
        ) == dynamic)
    }

    @Test
    func urlIdentifiersAreRecognised() {
        #expect(snIsURLTypeIdentifier("public.file-url"))
        #expect(snIsURLTypeIdentifier("public.url"))
        #expect(!snIsURLTypeIdentifier("public.plain-text"))
        #expect(!snIsURLTypeIdentifier("public.jpeg"))
    }

    // MARK: - Staged names

    @Test
    func stagedFilenamePrefersTheProviderName() {
        // The temp file is named after the TYPE whenever the bytes came from a
        // data representation, so `report.csv` would otherwise be delivered as
        // "comma-separated values.csv".
        #expect(snStagedFilename(
            suggestedName: "report.csv",
            temporaryName: "comma-separated values.csv",
            fallback: "attachment"
        ) == "report.csv")
    }

    @Test
    func stagedFilenameBorrowsTheExtensionWhenTheProviderNameHasNone() {
        #expect(snStagedFilename(
            suggestedName: "report",
            temporaryName: "comma-separated values.csv",
            fallback: "attachment"
        ) == "report.csv")
    }

    @Test
    func stagedFilenameFallsBackWhenThereIsNoProviderName() {
        #expect(snStagedFilename(
            suggestedName: nil,
            temporaryName: "IMG_0001.HEIC",
            fallback: "photo.jpg"
        ) == "IMG_0001.HEIC")
        #expect(snStagedFilename(
            suggestedName: "   ",
            temporaryName: "",
            fallback: "photo.jpg"
        ) == "photo.jpg")
    }

    @Test
    func stagedFilenameCannotEscapeThePayloadDirectory() {
        // The suggested name comes from another app and is attacker-influenced,
        // so it goes through the same single-component sanitiser as before.
        // (`.bin` is then borrowed from the temp name, which has no extension of
        // its own after sanitising — the point here is that no separator and no
        // `..` survives.)
        let name = snStagedFilename(
            suggestedName: "../../../etc/passwd",
            temporaryName: "data.bin",
            fallback: "attachment"
        )
        #expect(name == "passwd.bin")
        #expect(!name.contains("/"))
        #expect(!name.contains(".."))

        // And the relative path it feeds is still one directory + one name.
        let path = snStagedRelativePath(index: 0, filename: name)
        #expect(path == "0/passwd.bin")
        #expect((path as NSString).pathComponents.count == 2)
    }

    // MARK: - Which staged share the picker offers

    private func payload(_ id: String, at secs: TimeInterval) -> SonarSharePayload {
        SonarSharePayload(
            id: id, createdAt: Date(timeIntervalSince1970: secs), text: nil, items: [item("\(id).csv")]
        )
    }

    /// QA finding on #559: a share abandoned earlier (the app was killed with
    /// its picker up) stays staged for 24 h. The picker took the OLDEST staged
    /// payload, so the user who had just shared `fresh.csv` saw last time's
    /// `old-draft.csv`, and a tap on a chat sent it. The extension cannot open
    /// the app (`extensionContext.open` is refused for share extensions), so
    /// most scans carry no hand-off id: newest must win on its own.
    @Test
    func theShareJustMadeIsOfferedBeforeAnOlderStagedOne() {
        let old = payload("old", at: 100)
        let new = payload("new", at: 200)
        #expect(snNextSharePayload([old, new], preferring: nil)?.id == "new")
        #expect(snNextSharePayload([new, old], preferring: nil)?.id == "new")
        // A hand-off id is the most precise signal when there is one…
        #expect(snNextSharePayload([old, new], preferring: "old")?.id == "old")
        // …and one that is no longer staged falls back to the newest.
        #expect(snNextSharePayload([old, new], preferring: "gone")?.id == "new")
        #expect(snNextSharePayload([], preferring: "new") == nil)
    }

    /// The foreground that follows a share also fires `didBecomeActive`, and a
    /// picker for an older payload may already be up (restored after a
    /// relaunch). The newer share takes it over; an older one never does, so
    /// repeated foreground scans cannot flap between payloads.
    @Test
    func aNewerShareTakesOverAPickerShowingAnOlderOne() {
        let old = payload("old", at: 100)
        let new = payload("new", at: 200)
        #expect(snShouldReplaceOfferedShare(current: old, with: new, preferring: nil))
        #expect(!snShouldReplaceOfferedShare(current: new, with: old, preferring: nil))
        #expect(!snShouldReplaceOfferedShare(current: new, with: new, preferring: nil))
        // The payload a hand-off names wins even if it is not the newest.
        #expect(snShouldReplaceOfferedShare(current: new, with: old, preferring: "old"))
    }

    @Test
    func theHandOffURLNamesItsPayload() throws {
        let id = UUID().uuidString
        #expect(snSharePayloadID(from: try #require(URL(string: "sonar://share?id=\(id)"))) == id)
        #expect(snSharePayloadID(from: try #require(URL(string: "sonar://share"))) == nil)
        #expect(snSharePayloadID(from: try #require(URL(string: "sonar://share?id="))) == nil)
    }

    // MARK: - File or body, never both

    /// QA finding on #559 (QA-084): an app exporting a text document from
    /// memory — the bytes registered as `public.plain-text`, plus a
    /// `suggestedName` — was delivered as the file AND as a text message
    /// holding the whole document. `loadItem(forTypeIdentifier:
    /// "public.plain-text")` on that provider returns the bytes, and the body
    /// reader looked at every provider. Exactly the provider the QA host built.
    @Test
    func anInAppTextExportIsStagedAndNeverReadAsTheMessageBody() {
        let document = Data("Sonar share QA notes.\nThis is a document, not a message.\n".utf8)
        let export = NSItemProvider(item: document as NSData, typeIdentifier: UTType.plainText.identifier)
        export.suggestedName = "export.txt"
        let split = snPartitionShareProviders([export])
        #expect(split.files == [export])
        #expect(split.body.isEmpty)
    }

    /// The same invariant for file-backed providers, which answer a
    /// plain-text load with the file's bytes in-process.
    @Test
    func aSharedDocumentIsStagedAndNeverReadAsTheMessageBody() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-partition-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for name in ["notes.txt", "report.csv", "script.py", "data.json", "archive.zip", "README"] {
            let url = dir.appendingPathComponent(name)
            try Data("a,b\n1,2\n".utf8).write(to: url)
            let provider = try #require(NSItemProvider(contentsOf: url))
            let split = snPartitionShareProviders([provider])
            #expect(split.files.count == 1, "\(name) must be staged as a file")
            #expect(split.body.isEmpty, "\(name) must not also be read as the message body")
        }
    }

    @Test
    func plainTextAndWebLinksStayTheBody() throws {
        let text = NSItemProvider(object: "hello from Notes" as NSString)
        let link = NSItemProvider(object: try #require(URL(string: "https://example.com/a")) as NSURL)
        let split = snPartitionShareProviders([text, link])
        #expect(split.files.isEmpty)
        #expect(split.body.count == 2)
    }

    @Test
    func aCaptionedFileSplitsIntoOneFileAndOneBody() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-partition-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("report.csv")
        try Data("a,b\n".utf8).write(to: url)

        let file = try #require(NSItemProvider(contentsOf: url))
        let caption = NSItemProvider(object: "Q3 numbers" as NSString)
        let split = snPartitionShareProviders([caption, file])
        #expect(split.files == [file])
        #expect(split.body == [caption])
    }

    /// The second half of "the path is broken": the app sends each staged file
    /// under `url.lastPathComponent`, so the old `"\(index)-\(name)"` layout put
    /// the index INTO the delivered filename — the recipient saw `0-report.csv`.
    @Test
    func stagedPathKeepsTheIndexOutOfTheFilename() {
        let path = snStagedRelativePath(index: 0, filename: "report.csv")
        #expect(path == "0/report.csv")
        #expect((path as NSString).lastPathComponent == "report.csv")

        // Still collision-proof: two identically named attachments stay apart.
        #expect(snStagedRelativePath(index: 1, filename: "IMG_0001.jpg")
            != snStagedRelativePath(index: 2, filename: "IMG_0001.jpg"))
    }
}
