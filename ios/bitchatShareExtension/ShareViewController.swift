//
// ShareViewController.swift
// bitchatShareExtension
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import UIKit
import UniformTypeIdentifiers

/// Share extension using UIKit + UTTypes.
/// Avoids deprecated Social framework and SLComposeServiceViewController.
///
/// The extension **stages only**. It collects the shared text/links/files into
/// the App Group container and then opens the app, which shows the recipient
/// picker and does the actual send. Sending from here would mean mutating
/// Marmot/MLS state from a second process while the app may hold the store
/// (`MarmotStoreLock`) — see `SonarSharePayload` for the full reasoning.
final class ShareViewController: UIViewController {
    // Bundle.main.bundleIdentifier would get the extension's bundleID.
    // The app group is injected at build time (APP_GROUP_ID → Info.plist) so
    // local dev builds can use a team-registrable group id.
    private static let groupID =
        Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String ?? "group.chat.bitchat"

    private enum Strings {
        static let nothingToShare = String(localized: "share.status.nothing_to_share", comment: "Shown when the share extension receives no content")
        static let noShareableContent = String(localized: "share.status.no_shareable_content", comment: "Shown when provided content cannot be shared")
        static let preparing = String(localized: "share.status.preparing", comment: "Shown while the share extension stages the shared content")
        static let openingSonar = String(localized: "share.status.opening_sonar", comment: "Shown when the extension is handing off to the Sonar app")
        static let openSonarToSend = String(localized: "share.status.open_sonar_to_send", comment: "Shown when the app could not be opened automatically and the user must open Sonar")
        static let tooLarge = String(localized: "share.status.too_large", comment: "Shown when the shared files exceed the size limit")
        static let failedToStage = String(localized: "share.status.failed_to_stage", comment: "Shown when the shared content cannot be written to the shared container")
    }

    /// Type identifiers we ask an attachment for, most specific first. A
    /// provider usually conforms to several; the first match wins.
    ///
    /// `public.file-url` is deliberately absent: asking for it returns a temp
    /// file containing the `file://` path, not the document. See
    /// `snStagingTypeIdentifier`, which handles everything not listed here.
    private static let fileTypeIdentifiers = [
        UTType.image.identifier,
        UTType.movie.identifier,
        UTType.audio.identifier,
        UTType.pdf.identifier,
    ]

    private let statusLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 15, weight: .semibold)
        l.textAlignment = .center
        l.numberOfLines = 0
        l.textColor = .label
        return l
    }()

    private let spinner: UIActivityIndicatorView = {
        let s = UIActivityIndicatorView(style: .medium)
        s.translatesAutoresizingMaskIntoConstraints = false
        s.hidesWhenStopped = true
        return s
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.addSubview(statusLabel)
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -16),
        ])
        statusLabel.text = Strings.preparing
        spinner.startAnimating()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.processShare()
        }
    }

    // MARK: - Processing

    private func processShare() {
        guard let ctx = self.extensionContext else {
            finish(message: Strings.nothingToShare, handedOff: false)
            return
        }
        let items = ctx.inputItems.compactMap { $0 as? NSExtensionItem }
        guard !items.isEmpty else {
            finish(message: Strings.nothingToShare, handedOff: false)
            return
        }

        // Text/link body: attributed content text first (Safari puts the page
        // URL there), then the title as a last resort.
        var text: String? = items
            .compactMap { $0.attributedContentText?.string }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        let providers = items.flatMap { $0.attachments ?? [] }
        let payloadID = UUID().uuidString

        loadURLOrText(from: providers) { [weak self] loadedText in
            guard let self else { return }
            if let loadedText, !loadedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = loadedText
            }
            self.loadFiles(from: providers, payloadID: payloadID) { staged in
                if text == nil, staged.items.isEmpty {
                    // Nothing usable in the attachments — fall back to a title.
                    let title = items
                        .compactMap { $0.attributedTitle?.string }
                        .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    if let title {
                        text = title
                    }
                }
                self.commitAndHandOff(
                    id: payloadID,
                    text: text,
                    staged: staged
                )
            }
        }
    }

    /// Result of copying attachments into the payload directory.
    private struct StagedFiles {
        var items: [SonarSharedItem] = []
        /// Attachments rejected for exceeding the shared byte budget.
        var oversizedCount = 0
        /// Attachments dropped for any other reason (unreadable, past the item
        /// cap). Kept apart from `oversizedCount` so the status message does
        /// not blame the file's size for an I/O failure.
        var unreadableCount = 0
        /// The App Group container could not be written to at all.
        var containerUnavailable = false

        var droppedCount: Int { oversizedCount + unreadableCount }
    }

    // MARK: - Text / URL

    private func loadURLOrText(
        from providers: [NSItemProvider],
        completion: @escaping (String?) -> Void
    ) {
        // A file URL is content to stage, not a link to send — leave it to the
        // file path so shared documents keep their bytes.
        let urlProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
                && !$0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        if let provider = urlProviders.first {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                if let url = item as? URL, !url.isFileURL {
                    completion(url.absoluteString)
                    return
                }
                if let string = item as? String {
                    completion(string)
                    return
                }
                self.loadPlainText(from: providers, completion: completion)
            }
            return
        }
        loadPlainText(from: providers, completion: completion)
    }

    private func loadPlainText(
        from providers: [NSItemProvider],
        completion: @escaping (String?) -> Void
    ) {
        let id = UTType.plainText.identifier
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(id) }) else {
            completion(nil)
            return
        }
        provider.loadItem(forTypeIdentifier: id, options: nil) { item, _ in
            if let string = item as? String {
                completion(string)
            } else if let data = item as? Data, let string = String(data: data, encoding: .utf8) {
                completion(string)
            } else if let url = item as? URL, !url.isFileURL {
                completion(url.absoluteString)
            } else {
                completion(nil)
            }
        }
    }

    // MARK: - Files

    private func loadFiles(
        from providers: [NSItemProvider],
        payloadID: String,
        completion: @escaping (StagedFiles) -> Void
    ) {
        let concreteTypes = [
            UTType.image.identifier,
            UTType.movie.identifier,
            UTType.audio.identifier,
            UTType.pdf.identifier,
            UTType.fileURL.identifier,
        ]
        // The decision itself lives in `snShouldStageAsFile` so it is testable
        // without an NSItemProvider — see SonarSharePayloadTests.
        let fileProviders = providers.filter { provider in
            let isFileURL = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            return snShouldStageAsFile(
                isConcreteFileType: concreteTypes.contains {
                    provider.hasItemConformingToTypeIdentifier($0)
                },
                isText: provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
                    || provider.hasItemConformingToTypeIdentifier(UTType.text.identifier),
                isNonFileURL: provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
                    && !isFileURL,
                isData: provider.hasItemConformingToTypeIdentifier(UTType.data.identifier),
                hasSuggestedName: provider.suggestedName?.isEmpty == false
            )
        }
        guard !fileProviders.isEmpty else {
            completion(StagedFiles())
            return
        }

        let directory: URL
        do {
            directory = try SonarShareInbox.makePayloadDirectory(
                id: payloadID,
                appGroupID: Self.groupID
            )
        } catch {
            var staged = StagedFiles()
            staged.containerUnavailable = true
            completion(staged)
            return
        }

        // Serialize the copies: the byte budget is shared across items, so
        // "does this still fit?" has to be answered one attachment at a time.
        var staged = StagedFiles()
        var remainingBytes = SonarShareInbox.maxStagedBytes
        let queue = DispatchQueue(label: "chat.bitchat.share.staging")
        let group = DispatchGroup()

        for provider in fileProviders.prefix(SonarShareInbox.maxStagedItems) {
            // A concrete media type first (it is also what names the fallback
            // file), then whatever byte-bearing type the provider registered.
            let typeID = Self.fileTypeIdentifiers.first {
                provider.hasItemConformingToTypeIdentifier($0)
            } ?? snStagingTypeIdentifier(
                registeredTypeIdentifiers: provider.registeredTypeIdentifiers
            )

            group.enter()
            let record: (URL?) -> Void = { url in
                defer { group.leave() }
                guard let url else {
                    // No representation vended. Count it, or a multi-file
                    // share silently omits this attachment and still reports
                    // complete success.
                    queue.sync { staged.unreadableCount += 1 }
                    return
                }
                // The vended URL is valid only inside this callback, so copy
                // synchronously before returning.
                queue.sync {
                    switch self.copyIntoPayload(
                        source: url,
                        directory: directory,
                        index: staged.items.count,
                        typeID: typeID,
                        suggestedName: provider.suggestedName,
                        maxBytes: remainingBytes
                    ) {
                    case .staged(let item):
                        remainingBytes -= item.byteCount
                        staged.items.append(item)
                    case .tooLarge:
                        staged.oversizedCount += 1
                    case .unreadable:
                        staged.unreadableCount += 1
                    }
                }
            }

            if let typeID {
                provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, _ in
                    record(url)
                }
            } else {
                // Nothing but URL identifiers registered. Resolve the file URL
                // and copy the real file — asking `loadFileRepresentation` for
                // `public.file-url` would stage the path string instead.
                Self.loadFileURL(from: provider, completion: record)
            }
        }

        group.notify(queue: .global(qos: .userInitiated)) {
            staged.unreadableCount += max(0, fileProviders.count - SonarShareInbox.maxStagedItems)
            completion(staged)
        }
    }

    /// Resolve a provider that registered only URL identifiers to its file URL.
    /// The URL is handed to the completion still inside the load callback, so
    /// the caller's copy happens while the coordinated read is alive.
    private static func loadFileURL(
        from provider: NSItemProvider,
        completion: @escaping (URL?) -> Void
    ) {
        let id = UTType.fileURL.identifier
        guard provider.hasItemConformingToTypeIdentifier(id) else {
            completion(nil)
            return
        }
        provider.loadItem(forTypeIdentifier: id, options: nil) { item, _ in
            if let url = item as? URL, url.isFileURL {
                completion(url)
            } else if let data = item as? Data,
                      let string = String(data: data, encoding: .utf8),
                      let url = URL(string: string), url.isFileURL {
                completion(url)
            } else {
                completion(nil)
            }
        }
    }

    private enum CopyOutcome {
        case staged(SonarSharedItem)
        case tooLarge
        case unreadable
    }

    /// Copy one attachment into the payload directory, rejecting anything that
    /// does not fit the remaining budget.
    private func copyIntoPayload(
        source: URL,
        directory: URL,
        index: Int,
        typeID: String?,
        suggestedName: String?,
        maxBytes: Int
    ) -> CopyOutcome {
        let fileManager = FileManager.default
        // A provider that vended a URL outside our sandbox needs the scope held
        // for the copy; a temp file we were handed does not, and simply reports
        // false here.
        let scoped = source.startAccessingSecurityScopedResource()
        defer {
            if scoped { source.stopAccessingSecurityScopedResource() }
        }

        guard let size = (try? fileManager.attributesOfItem(atPath: source.path))?[.size] as? Int,
              size > 0
        else {
            return .unreadable
        }
        guard size <= maxBytes else { return .tooLarge }

        // The provider's own name wins: the temp file is named after the TYPE
        // ("Zip archive.zip") whenever the bytes came from a data
        // representation, which is most non-media documents.
        let name = snStagedFilename(
            suggestedName: suggestedName,
            temporaryName: source.lastPathComponent,
            fallback: Self.defaultFilename(for: typeID, index: index)
        )
        // One directory per index so two attachments named "IMG_0001.jpg"
        // cannot overwrite each other — without an `index-` prefix leaking into
        // the filename the recipient sees.
        let relativePath = snStagedRelativePath(index: index, filename: name)
        let destination = directory.appendingPathComponent(relativePath)

        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: source, to: destination)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path
            )
        } catch {
            return .unreadable
        }

        return .staged(
            SonarSharedItem(
                relativePath: relativePath,
                filename: name,
                mime: Self.mime(forFilename: name, typeID: typeID),
                byteCount: size
            )
        )
    }

    private static func defaultFilename(for typeID: String?, index: Int) -> String {
        let ext = typeID.flatMap { UTType($0)?.preferredFilenameExtension }
        let stem: String
        switch typeID {
        case .some(UTType.image.identifier): stem = "photo"
        case .some(UTType.movie.identifier): stem = "video"
        case .some(UTType.audio.identifier): stem = "audio"
        default: stem = "attachment"
        }
        let suffix = ext.map { ".\($0)" } ?? ""
        return index == 0 ? "\(stem)\(suffix)" : "\(stem)-\(index + 1)\(suffix)"
    }

    private static func mime(forFilename filename: String, typeID: String?) -> String {
        // The file extension is more specific than the requested conformance
        // (a provider asked for `public.image` may hand back a HEIC or a PNG).
        let ext = (filename as NSString).pathExtension
        if let fromExtension = UTType(filenameExtension: ext)?.preferredMIMEType {
            return fromExtension
        }
        if let typeID, let fromType = UTType(typeID)?.preferredMIMEType {
            return fromType
        }
        return "application/octet-stream"
    }

    // MARK: - Commit + hand-off

    private func commitAndHandOff(id: String, text: String?, staged: StagedFiles) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (trimmed?.isEmpty ?? true) ? nil : trimmed

        if staged.containerUnavailable {
            finish(message: Strings.failedToStage, handedOff: false)
            return
        }
        guard body != nil || !staged.items.isEmpty else {
            SonarShareInbox.discard(id, appGroupID: Self.groupID)
            finish(
                message: staged.oversizedCount > 0 ? Strings.tooLarge : Strings.noShareableContent,
                handedOff: false
            )
            return
        }

        let payload = SonarSharePayload(
            id: id,
            text: body,
            items: staged.items,
            droppedCount: staged.droppedCount
        )
        do {
            // Files land in the directory first; the manifest is what publishes
            // the payload to the app.
            _ = try SonarShareInbox.makePayloadDirectory(id: id, appGroupID: Self.groupID)
            try SonarShareInbox.commit(payload, appGroupID: Self.groupID)
        } catch {
            SonarShareInbox.discard(id, appGroupID: Self.groupID)
            finish(message: Strings.failedToStage, handedOff: false)
            return
        }

        handOffToApp(payloadID: id)
    }

    /// Jump straight into Sonar so the user picks a chat without leaving the
    /// flow. If the open is refused we still succeeded — the app scans the
    /// inbox on foreground, so the share is only delayed, never lost.
    private func handOffToApp(payloadID: String) {
        guard let url = URL(string: "sonar://share?id=\(payloadID)") else {
            finish(message: Strings.openSonarToSend, handedOff: false)
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let context = self.extensionContext else { return }
            self.statusLabel.text = Strings.openingSonar
            context.open(url) { opened in
                DispatchQueue.main.async {
                    self.finish(
                        message: opened ? Strings.openingSonar : Strings.openSonarToSend,
                        handedOff: opened
                    )
                }
            }
        }
    }

    /// Show a final status and dismiss. A successful hand-off dismisses
    /// immediately — the app is already coming to the front, so lingering just
    /// puts a dead sheet on top of it.
    private func finish(message: String, handedOff: Bool) {
        DispatchQueue.main.async {
            self.spinner.stopAnimating()
            self.statusLabel.text = message
            let delay = handedOff ? 0 : TransportConfig.uiShareExtensionDismissDelaySeconds
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            }
        }
    }
}
