//
// SonarGifDiscovery.swift
// bitchat
//
// Provider-neutral GIF catalog models. Public Nostr catalogs publish this shape
// as kind-30078 with d=sonar.gif.catalog.v1; selected media is still re-encrypted
// through Sonar's private media path before sending to a chat.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import CryptoKit
import Foundation

enum SonarGifDiscovery {
    static let nostrKind = 30078
    static let catalogDTag = "sonar.gif.catalog.v1"
    static let schema = 1
    static let maxItems = 64
    static let maxItemBytes: Int64 = 25 * 1024 * 1024

    private static let appName = "sonar"
    private static let catalogType = "gif_catalog"
    private static let maxCatalogName = 80
    private static let maxItemTitle = 80
    private static let maxToken = 64
    private static let maxDimension = 8192
    private static let allowedMimes: Set<String> = ["image/gif", "video/mp4", "image/webp"]

    static func catalogEventTags(catalogId: String = catalogDTag) -> [[String]] {
        let cleanId = cleanProtocolToken(catalogId)
        return [
            ["d", cleanId.isEmpty ? catalogDTag : cleanId],
            ["t", appName],
            ["t", "gif"],
        ]
    }

    static func normalize(_ catalog: SonarGifCatalog) -> SonarGifCatalog? {
        guard let cleanName = cleanLabel(catalog.name, max: maxCatalogName) else { return nil }
        let cleanId = cleanProtocolToken(catalog.id).isEmpty ? catalogDTag : cleanProtocolToken(catalog.id)
        let cleanItems = Array(
            catalog.items
                .compactMap(normalize(_:))
                .uniquedBy(\.id)
                .prefix(maxItems)
        )
        guard !cleanItems.isEmpty else { return nil }
        return SonarGifCatalog(
            id: cleanId,
            name: cleanName,
            authorNpub: catalog.authorNpub?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            items: cleanItems,
            updatedAtSecs: (catalog.updatedAtSecs ?? 0) > 0 ? catalog.updatedAtSecs : nil
        )
    }

    static func normalize(_ item: SonarGifItem) -> SonarGifItem? {
        guard let mediaUrl = normalizeHttpsUrl(item.mediaUrl) else { return nil }
        let inferredMime = item.mimeType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? inferGifMime(from: mediaUrl)
            : nil
        guard let mime = normalizeGifMime(item.mimeType) ?? inferredMime else { return nil }
        guard item.byteSize == nil || (1...maxItemBytes).contains(item.byteSize!) else { return nil }
        let id = cleanProtocolToken(item.id).isEmpty ? stableItemId(mediaUrl) : cleanProtocolToken(item.id)
        return SonarGifItem(
            id: id,
            title: cleanLabel(item.title, max: maxItemTitle) ?? "GIF",
            mimeType: mime,
            mediaUrl: mediaUrl,
            previewUrl: item.previewUrl.flatMap(normalizeHttpsUrl(_:)),
            stillUrl: item.stillUrl.flatMap(normalizeHttpsUrl(_:)),
            width: item.width.flatMap { (1...maxDimension).contains($0) ? $0 : nil },
            height: item.height.flatMap { (1...maxDimension).contains($0) ? $0 : nil },
            byteSize: item.byteSize,
            source: cleanProtocolToken(item.source).isEmpty ? "nostr" : cleanProtocolToken(item.source)
        )
    }

    static func normalizeGifMime(_ mime: String) -> String? {
        let clean = mime
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return allowedMimes.contains(clean) ? clean : nil
    }

    static func inferGifMime(from url: String) -> String? {
        let path = url
            .split(separator: "?", maxSplits: 1).first.map(String.init)?
            .split(separator: "#", maxSplits: 1).first.map(String.init)?
            .lowercased() ?? ""
        if path.hasSuffix(".gif") { return "image/gif" }
        if path.hasSuffix(".mp4") { return "video/mp4" }
        if path.hasSuffix(".webp") { return "image/webp" }
        return nil
    }

    static func normalizeHttpsUrl(_ value: String) -> String? {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (9...2048).contains(raw.count) else { return nil }
        guard raw.lowercased().hasPrefix("https://") else { return nil }
        guard raw.unicodeScalars.allSatisfy({ !$0.properties.isWhitespace }) else { return nil }
        guard var components = URLComponents(string: raw), components.scheme?.lowercased() == "https" else {
            return nil
        }
        guard components.user == nil, components.password == nil else { return nil }
        guard let host = components.host?.lowercased(), host.contains(".") else { return nil }
        components.scheme = "https"
        components.host = host
        return components.string
    }

    static func stableItemId(_ mediaUrl: String) -> String {
        let digest = SHA256.hash(data: Data(mediaUrl.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func fileExtension(for mime: String) -> String {
        switch normalizeGifMime(mime) {
        case "video/mp4": return "mp4"
        case "image/webp": return "webp"
        default: return "gif"
        }
    }

    static func nostrContentData(for catalog: SonarGifCatalog) -> Data? {
        guard let catalog = normalize(catalog) else { return nil }
        let content = SonarGifCatalogContent(
            schema: schema,
            app: appName,
            type: catalogType,
            name: catalog.name,
            items: catalog.items.map(SonarGifCatalogContent.Item.init)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(content)
    }

    private static func cleanLabel(_ value: String, max: Int) -> String? {
        let parts = value.split(whereSeparator: \.isWhitespace)
        let clean = parts.joined(separator: " ").prefix(max)
        return clean.isEmpty ? nil : String(clean)
    }

    private static func cleanProtocolToken(_ value: String) -> String {
        String(
            value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
                .prefix(maxToken)
        )
    }
}

struct SonarGifCatalog: Codable, Equatable {
    var id: String = SonarGifDiscovery.catalogDTag
    var name: String
    var authorNpub: String?
    var items: [SonarGifItem]
    var updatedAtSecs: Int64?
}

struct SonarGifItem: Codable, Equatable {
    var id: String = ""
    var title: String
    var mimeType: String
    var mediaUrl: String
    var previewUrl: String?
    var stillUrl: String?
    var width: Int?
    var height: Int?
    var byteSize: Int64?
    var source: String = "nostr"

    var isVideoGif: Bool {
        mimeType.caseInsensitiveCompare("video/mp4") == .orderedSame
    }

    var sendFilename: String {
        let itemId = id.isEmpty ? SonarGifDiscovery.stableItemId(mediaUrl) : id
        return "\(itemId).\(SonarGifDiscovery.fileExtension(for: mimeType))"
    }
}

private struct SonarGifCatalogContent: Codable {
    struct Item: Codable {
        let id: String
        let title: String
        let mime: String
        let url: String
        let previewURL: String?
        let stillURL: String?
        let width: Int?
        let height: Int?
        let bytes: Int64?
        let source: String

        enum CodingKeys: String, CodingKey {
            case id, title, mime, url, width, height, bytes, source
            case previewURL = "preview_url"
            case stillURL = "still_url"
        }

        init(_ item: SonarGifItem) {
            id = item.id
            title = item.title
            mime = item.mimeType
            url = item.mediaUrl
            previewURL = item.previewUrl
            stillURL = item.stillUrl
            width = item.width
            height = item.height
            bytes = item.byteSize
            source = item.source
        }
    }

    let schema: Int
    let app: String
    let type: String
    let name: String
    let items: [Item]
}

private extension Sequence {
    func uniquedBy<T: Hashable>(_ keyPath: KeyPath<Element, T>) -> [Element] {
        var seen = Set<T>()
        var out: [Element] = []
        for item in self {
            if seen.insert(item[keyPath: keyPath]).inserted {
                out.append(item)
            }
        }
        return out
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
