//
// SonarStickers.swift
// bitchat
//
// Native sticker models mirror core/sonar-stickers. UI remains feature-gated
// until install, picker, send, receive, and render parity exists on every app.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import CryptoKit
import Foundation

enum SonarStickers {
    static let featureFlagKey = "sonar.stickers.enabled"
    static let enabledByDefault = false
    static let messageMarker = "[sonar-sticker-v1]"
    static let packFormat = "sonar-sticker-pack-v1"
    static let stickerPackKind = 30030
    static let userStickerPacksKind = 10030
    static let maxRecentStickers = 24

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: featureFlagKey) != nil else { return enabledByDefault }
        return defaults.bool(forKey: featureFlagKey)
    }

    static func buildChatMessage(_ stickerRef: SonarStickerRef) -> String {
        "[sticker] \(messageMarker) pack=\(stickerRef.pack.coordinate) shortcode=\(stickerRef.shortcode) sha256=\(stickerRef.plaintextSha256)"
    }

    static func parseChatMessage(_ content: String) -> SonarStickerRef? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("[sticker]") else { return nil }
        var rest = String(trimmed.dropFirst("[sticker]".count)).trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix(messageMarker) else { return nil }
        rest = String(rest.dropFirst(messageMarker.count)).trimmingCharacters(in: .whitespaces)
        let fields = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count == 3,
              let packValue = fields[0].stripPrefix("pack="),
              let shortcode = fields[1].stripPrefix("shortcode="),
              let sha256 = fields[2].stripPrefix("sha256="),
              let pack = SonarStickerPackAddress.parse(packValue)
        else { return nil }
        return SonarStickerRef(pack: pack, shortcode: shortcode, plaintextSha256: sha256)
    }

    static func parsePackEvent(kind: Int, pubkeyHex: String, tags: [[String]]) -> SonarStickerPack? {
        guard kind == stickerPackKind,
              hasTagValue(tags, name: "pack_format", value: packFormat),
              let identifier = tagValue(tags, name: "d"),
              let title = tagValue(tags, name: "title"),
              let address = SonarStickerPackAddress(authorPubkeyHex: pubkeyHex, identifier: identifier)
        else { return nil }
        let imageTag = tags.first { $0.first == "image" }
        let cover: SonarSticker?
        if let imageTag {
            guard let parsedCover = parseCoverTag(imageTag) else { return nil }
            cover = parsedCover
        } else {
            cover = nil
        }
        var stickers: [SonarSticker] = []
        for tag in tags where tag.first == "sticker" {
            guard let sticker = parseStickerTag(tag) else { return nil }
            stickers.append(sticker)
        }
        return SonarStickerPack(
            address: address,
            title: title,
            description: tagValue(tags, name: "description"),
            cover: cover,
            stickers: stickers,
            license: tagValue(tags, name: "license")
        )
    }

    static func parseInstalledPackList(kind: Int, tags: [[String]]) -> [SonarStickerPackAddress] {
        guard kind == userStickerPacksKind else { return [] }
        var seen = Set<String>()
        var packs: [SonarStickerPackAddress] = []
        for tag in tags where tag.first == "a" {
            guard tag.count > 1,
                  let pack = SonarStickerPackAddress.parse(tag[1]),
                  seen.insert(pack.coordinate).inserted
            else { continue }
            packs.append(pack)
        }
        return packs
    }

    private static func tagValue(_ tags: [[String]], name: String) -> String? {
        tags.first { $0.first == name }?.dropFirst().first
    }

    private static func hasTagValue(_ tags: [[String]], name: String, value: String) -> Bool {
        tags.contains { $0.first == name && $0.dropFirst().first == value }
    }

    private static func parseStickerTag(_ tag: [String]) -> SonarSticker? {
        guard tag.count >= 6,
              let dim = parseStickerDim(tag[5])
        else { return nil }
        return SonarSticker(
            shortcode: tag[1],
            url: tag[2],
            sha256: tag[3],
            mime: tag[4],
            width: dim.width,
            height: dim.height,
            alt: tag.count > 6 && !tag[6].isEmpty ? tag[6] : nil,
            emoji: tag.count > 7 && !tag[7].isEmpty ? tag[7] : nil
        )
    }

    private static func parseCoverTag(_ tag: [String]) -> SonarSticker? {
        guard tag.count >= 3,
              let dim = parseStickerDim(tag.count > 3 ? tag[3] : "")
        else { return nil }
        return SonarSticker(
            shortcode: "cover",
            url: tag[1],
            sha256: tag[2],
            mime: "image/webp",
            width: dim.width,
            height: dim.height,
            alt: "Sticker pack cover"
        )
    }

    private static func parseStickerDim(_ value: String) -> (width: Int?, height: Int?)? {
        guard !value.isEmpty else { return (nil, nil) }
        let parts = value.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let width = Int(parts[0]),
              let height = Int(parts[1])
        else { return nil }
        return (width, height)
    }
}

struct SonarStickerPackAddress: Codable, Equatable, Hashable {
    let authorPubkeyHex: String
    let identifier: String

    var coordinate: String {
        "30030:\(authorPubkeyHex):\(identifier)"
    }

    init?(authorPubkeyHex: String, identifier: String) {
        let pubkey = authorPubkeyHex.lowercased()
        guard pubkey.isHex(count: 64), identifier.isStickerIdentifier else { return nil }
        self.authorPubkeyHex = pubkey
        self.identifier = identifier
    }

    static func parse(_ value: String) -> SonarStickerPackAddress? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "30030" else { return nil }
        return SonarStickerPackAddress(authorPubkeyHex: parts[1], identifier: parts[2])
    }
}

struct SonarSticker: Codable, Equatable, Hashable {
    let shortcode: String
    let url: String
    let sha256: String
    let mime: String
    let width: Int?
    let height: Int?
    let alt: String?
    let emoji: String?

    init?(
        shortcode: String,
        url: String,
        sha256: String,
        mime: String,
        width: Int? = nil,
        height: Int? = nil,
        alt: String? = nil,
        emoji: String? = nil
    ) {
        let cleanHash = sha256.lowercased()
        let cleanMime = mime.lowercased()
        guard shortcode.isStickerShortcode,
              cleanHash.isHex(count: 64),
              Self.allowedMimes.contains(cleanMime),
              Self.isBlossomHttpsUrl(url, sha256: cleanHash),
              Self.validDimensions(width: width, height: height),
              (alt?.count ?? 0) <= 160,
              (emoji?.count ?? 0) <= 8
        else { return nil }
        self.shortcode = shortcode
        self.url = url
        self.sha256 = cleanHash
        self.mime = cleanMime
        self.width = width
        self.height = height
        self.alt = alt?.nilIfBlank
        self.emoji = emoji?.nilIfBlank
    }

    private static let allowedMimes: Set<String> = ["image/webp", "image/png", "image/apng", "image/gif"]

    private static func validDimensions(width: Int?, height: Int?) -> Bool {
        switch (width, height) {
        case (nil, nil):
            return true
        case let (w?, h?):
            return (1...4096).contains(w) && (1...4096).contains(h)
        default:
            return false
        }
    }

    private static func isBlossomHttpsUrl(_ value: String, sha256: String) -> Bool {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host != nil
        else { return false }
        return components.path.lowercased().contains(sha256)
    }
}

struct SonarStickerPack: Codable, Equatable {
    let address: SonarStickerPackAddress
    let title: String
    let description: String?
    let cover: SonarSticker?
    let stickers: [SonarSticker]
    let license: String?

    init?(
        address: SonarStickerPackAddress,
        title: String,
        description: String? = nil,
        cover: SonarSticker? = nil,
        stickers: [SonarSticker],
        license: String? = nil
    ) {
        let cleanTitle = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard (1...80).contains(cleanTitle.count),
              stickers.count > 0,
              stickers.count <= 200,
              (description?.count ?? 0) <= 500
        else { return nil }
        var shortcodes = Set<String>()
        var hashes = Set<String>()
        for sticker in stickers {
            guard shortcodes.insert(sticker.shortcode).inserted,
                  hashes.insert(sticker.sha256).inserted
            else { return nil }
        }
        self.address = address
        self.title = cleanTitle
        self.description = description?.nilIfBlank
        self.cover = cover
        self.stickers = stickers
        self.license = license?.nilIfBlank
    }

    func sticker(shortcode: String) -> SonarSticker? {
        stickers.first { $0.shortcode == shortcode }
    }
}

struct SonarStickerRef: Codable, Equatable, Hashable {
    let pack: SonarStickerPackAddress
    let shortcode: String
    let plaintextSha256: String

    init?(pack: SonarStickerPackAddress, shortcode: String, plaintextSha256: String) {
        let cleanHash = plaintextSha256.lowercased()
        guard shortcode.isStickerShortcode, cleanHash.isHex(count: 64) else { return nil }
        self.pack = pack
        self.shortcode = shortcode
        self.plaintextSha256 = cleanHash
    }
}

enum SonarStickerResolution: Equatable {
    case resolved(SonarSticker)
    case missingPack
    case missingSticker
    case hashMismatch
}

struct SonarStickerChoice: Equatable {
    let pack: SonarStickerPack
    let sticker: SonarSticker

    var id: String {
        "\(pack.address.coordinate)|\(sticker.shortcode)|\(sticker.sha256)"
    }
}

final class SonarStickerStore {
    private struct Snapshot: Codable {
        let version: Int
        let packs: [SonarStickerPack]
        let recentRefs: [SonarStickerRef]
    }

    private var packsByCoordinate: [String: SonarStickerPack] = [:]
    private var recentRefs: [SonarStickerRef] = []

    var installedPacks: [SonarStickerPack] {
        packsByCoordinate.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var hasInstalledPacks: Bool {
        !packsByCoordinate.isEmpty
    }

    var recentStickers: [SonarStickerChoice] {
        recentRefs.compactMap { ref in
            guard let pack = packsByCoordinate[ref.pack.coordinate],
                  let sticker = pack.sticker(shortcode: ref.shortcode),
                  sticker.sha256 == ref.plaintextSha256
            else { return nil }
            return SonarStickerChoice(pack: pack, sticker: sticker)
        }
    }

    func install(_ pack: SonarStickerPack) {
        packsByCoordinate[pack.address.coordinate] = pack
    }

    func remove(_ address: SonarStickerPackAddress) {
        packsByCoordinate.removeValue(forKey: address.coordinate)
        recentRefs.removeAll { $0.pack.coordinate == address.coordinate }
    }

    func clear() {
        packsByCoordinate.removeAll()
        recentRefs.removeAll()
    }

    func resolve(_ stickerRef: SonarStickerRef) -> SonarStickerResolution {
        guard let pack = packsByCoordinate[stickerRef.pack.coordinate] else { return .missingPack }
        guard let sticker = pack.sticker(shortcode: stickerRef.shortcode) else { return .missingSticker }
        guard sticker.sha256 == stickerRef.plaintextSha256 else { return .hashMismatch }
        return .resolved(sticker)
    }

    func ref(for sticker: SonarSticker, in pack: SonarStickerPack) -> SonarStickerRef? {
        guard let installed = packsByCoordinate[pack.address.coordinate],
              installed.sticker(shortcode: sticker.shortcode) == sticker
        else { return nil }
        return SonarStickerRef(
            pack: installed.address,
            shortcode: sticker.shortcode,
            plaintextSha256: sticker.sha256
        )
    }

    @discardableResult
    func recordRecent(pack: SonarStickerPack, sticker: SonarSticker) -> Bool {
        guard let ref = ref(for: sticker, in: pack) else { return false }
        recentRefs.removeAll { $0 == ref }
        recentRefs.insert(ref, at: 0)
        if recentRefs.count > SonarStickers.maxRecentStickers {
            recentRefs.removeLast(recentRefs.count - SonarStickers.maxRecentStickers)
        }
        return true
    }

    func snapshotData() -> Data? {
        let refs = recentStickers.compactMap { choice in
            SonarStickerRef(
                pack: choice.pack.address,
                shortcode: choice.sticker.shortcode,
                plaintextSha256: choice.sticker.sha256
            )
        }
        return try? JSONEncoder().encode(Snapshot(version: 1, packs: installedPacks, recentRefs: refs))
    }

    @discardableResult
    func restoreSnapshotData(_ data: Data) -> Bool {
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == 1
        else { return false }

        var cleanPacks: [String: SonarStickerPack] = [:]
        for pack in snapshot.packs {
            guard let clean = Self.validatedPack(pack),
                  cleanPacks[clean.address.coordinate] == nil
            else { return false }
            cleanPacks[clean.address.coordinate] = clean
        }

        var cleanRefs: [SonarStickerRef] = []
        for ref in snapshot.recentRefs {
            guard let cleanPackAddress = SonarStickerPackAddress(
                authorPubkeyHex: ref.pack.authorPubkeyHex,
                identifier: ref.pack.identifier
            ),
                  let cleanRef = SonarStickerRef(
                pack: cleanPackAddress,
                shortcode: ref.shortcode,
                plaintextSha256: ref.plaintextSha256
            ) else { return false }
            guard cleanRefs.count < SonarStickers.maxRecentStickers else { break }
            guard let pack = cleanPacks[cleanRef.pack.coordinate],
                  let sticker = pack.sticker(shortcode: cleanRef.shortcode),
                  sticker.sha256 == cleanRef.plaintextSha256,
                  !cleanRefs.contains(cleanRef)
            else { continue }
            cleanRefs.append(cleanRef)
        }

        packsByCoordinate = cleanPacks
        recentRefs = cleanRefs
        return true
    }

    private static func validatedPack(_ pack: SonarStickerPack) -> SonarStickerPack? {
        guard let address = SonarStickerPackAddress(
            authorPubkeyHex: pack.address.authorPubkeyHex,
            identifier: pack.address.identifier
        ) else { return nil }
        let cover: SonarSticker?
        if let storedCover = pack.cover {
            guard let cleanCover = validatedSticker(storedCover) else { return nil }
            cover = cleanCover
        } else {
            cover = nil
        }
        let stickers = pack.stickers.compactMap(validatedSticker)
        guard stickers.count == pack.stickers.count else { return nil }
        return SonarStickerPack(
            address: address,
            title: pack.title,
            description: pack.description,
            cover: cover,
            stickers: stickers,
            license: pack.license
        )
    }

    private static func validatedSticker(_ sticker: SonarSticker) -> SonarSticker? {
        SonarSticker(
            shortcode: sticker.shortcode,
            url: sticker.url,
            sha256: sticker.sha256,
            mime: sticker.mime,
            width: sticker.width,
            height: sticker.height,
            alt: sticker.alt,
            emoji: sticker.emoji
        )
    }
}

final class SonarStickerAssetCache {
    static let defaultMaxStickerBytes = 1024 * 1024

    private let maxStickerBytes: Int
    private var bytesByHash: [String: Data] = [:]

    init(maxStickerBytes: Int = defaultMaxStickerBytes) {
        self.maxStickerBytes = maxStickerBytes
    }

    func storeVerified(_ data: Data, for sticker: SonarSticker) -> Bool {
        guard data.count <= maxStickerBytes,
              Self.sha256Hex(data) == sticker.sha256
        else { return false }
        bytesByHash[sticker.sha256] = data
        return true
    }

    func data(for sticker: SonarSticker) -> Data? {
        bytesByHash[sticker.sha256]
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    func stripPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }

    var isStickerShortcode: Bool {
        !isEmpty && utf8.count <= 64 && utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 95
        }
    }

    var isStickerIdentifier: Bool {
        !isEmpty && utf8.count <= 80 && utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 45 || byte == 46 || byte == 95
        }
    }

    func isHex(count expectedCount: Int) -> Bool {
        count == expectedCount && utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }

    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
