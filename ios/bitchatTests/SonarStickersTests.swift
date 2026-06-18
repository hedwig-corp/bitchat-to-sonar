//
// SonarStickersTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
@testable import Sonar

struct SonarStickersTests {
    private let pubkey = "6a04ab98d9e4774ad806e302dddeb63bea16b5cb5f223ee77478e861bb583eb3"
    private let hashA = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    private let hashB = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

    @Test func featureGateDefaultsOff() {
        let defaults = UserDefaults(suiteName: "SonarStickersTests.featureGateDefaultsOff")!
        defaults.removeObject(forKey: SonarStickers.featureFlagKey)

        #expect(SonarStickers.isEnabled(defaults: defaults) == false)
    }

    @Test func validatesInstallsAndResolvesFixturePack() throws {
        let store = SonarStickerStore()
        let pack = try #require(fixturePack())
        let stickerRef = try #require(SonarStickerRef(
            pack: pack.address,
            shortcode: "cat_wave",
            plaintextSha256: hashA
        ))

        store.install(pack)

        let expectedSticker = try #require(pack.sticker(shortcode: "cat_wave"))
        #expect(store.installedPacks.map(\.address.coordinate) == [pack.address.coordinate])
        #expect(store.resolve(stickerRef) == .resolved(expectedSticker))
    }

    @Test func chatMessageContractMatchesRustFixture() throws {
        let address = try #require(fixtureAddress())
        let stickerRef = try #require(SonarStickerRef(
            pack: address,
            shortcode: "cat_wave",
            plaintextSha256: hashA
        ))
        let message = SonarStickers.buildChatMessage(stickerRef)

        #expect(message == "[sticker] [sonar-sticker-v1] pack=30030:\(pubkey):signal-0123456789abcdef0123456789abcdef shortcode=cat_wave sha256=\(hashA)")
        #expect(SonarStickers.parseChatMessage(message) == stickerRef)
        #expect(SonarStickers.parseChatMessage("plain text") == nil)
    }

    @Test func rejectsUnsafeAndAmbiguousFixtureCases() throws {
        let address = try #require(fixtureAddress())
        let stickerA = try #require(fixtureSticker("cat_wave", hash: hashA))
        let stickerB = try #require(fixtureSticker("cat_cry", hash: hashB))
        let duplicateHashSticker = try #require(SonarSticker(
            shortcode: "cat_other",
            url: "https://blossom.example/stickers/\(hashA)/cat-other.webp",
            sha256: hashA,
            mime: "image/webp",
            width: 512,
            height: 512
        ))

        #expect(SonarSticker(
            shortcode: "bad_url",
            url: "http://blossom.example/stickers/\(hashA)/cat-wave.webp",
            sha256: hashA,
            mime: "image/webp",
            width: 512,
            height: 512
        ) == nil)
        #expect(SonarSticker(
            shortcode: "upper_https",
            url: "HTTPS://blossom.example/stickers/\(hashA)/upper.webp",
            sha256: hashA,
            mime: "image/webp",
            width: 512,
            height: 512
        ) != nil)
        #expect(SonarStickerPack(
            address: address,
            title: "Duplicate shortcode",
            stickers: [stickerA, stickerA]
        ) == nil)
        #expect(SonarStickerPack(
            address: address,
            title: "Duplicate hash",
            stickers: [stickerA, duplicateHashSticker]
        ) == nil)
        #expect(SonarStickerPack(
            address: address,
            title: "Good",
            stickers: [stickerA, stickerB]
        ) != nil)
    }

    @Test func mismatchStatesNeverSubstituteAnotherSticker() throws {
        let store = SonarStickerStore()
        let pack = try #require(fixturePack())
        store.install(pack)

        let missingSticker = try #require(SonarStickerRef(
            pack: pack.address,
            shortcode: "cat_missing",
            plaintextSha256: hashA
        ))
        let mismatchedHash = try #require(SonarStickerRef(
            pack: pack.address,
            shortcode: "cat_wave",
            plaintextSha256: "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
        ))

        #expect(store.resolve(missingSticker) == .missingSticker)
        #expect(store.resolve(mismatchedHash) == .hashMismatch)
    }

    @Test func sendableRefsMustComeFromInstalledPacks() throws {
        let store = SonarStickerStore()
        let pack = try #require(fixturePack())
        let sticker = try #require(pack.sticker(shortcode: "cat_wave"))

        #expect(store.ref(for: sticker, in: pack) == nil)

        store.install(pack)
        let stickerRef = try #require(store.ref(for: sticker, in: pack))

        #expect(stickerRef == SonarStickerRef(
            pack: pack.address,
            shortcode: sticker.shortcode,
            plaintextSha256: sticker.sha256
        ))
        let editedSticker = try #require(SonarSticker(
            shortcode: sticker.shortcode,
            url: "https://blossom.example/stickers/\(hashB)/cat-edited.webp",
            sha256: hashB,
            mime: sticker.mime,
            width: sticker.width,
            height: sticker.height,
            alt: sticker.alt,
            emoji: sticker.emoji
        ))
        #expect(store.ref(for: editedSticker, in: pack) == nil)
    }

    @Test func assetCacheStoresOnlyHashVerifiedBoundedStickerBytes() throws {
        let abcHash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let sticker = try #require(fixtureSticker("abc", hash: abcHash))
        let cache = SonarStickerAssetCache(maxStickerBytes: 3)
        let data = Data("abc".utf8)

        #expect(cache.storeVerified(data, for: sticker))
        #expect(cache.data(for: sticker) == data)
        #expect(cache.storeVerified(Data("abcd".utf8), for: sticker) == false)
        let wrongHashSticker = try #require(fixtureSticker("abc_wrong", hash: hashA))
        #expect(cache.storeVerified(data, for: wrongHashSticker) == false)
    }

    private func fixtureAddress() -> SonarStickerPackAddress? {
        SonarStickerPackAddress(authorPubkeyHex: pubkey, identifier: "signal-0123456789abcdef0123456789abcdef")
    }

    private func fixtureSticker(_ shortcode: String, hash: String) -> SonarSticker? {
        SonarSticker(
            shortcode: shortcode,
            url: "https://blossom.example/stickers/\(hash)/\(shortcode).webp",
            sha256: hash,
            mime: "image/webp",
            width: 512,
            height: 512,
            alt: "\(shortcode) sticker",
            emoji: ":)"
        )
    }

    private func fixturePack() -> SonarStickerPack? {
        guard let address = fixtureAddress(),
              let stickerA = fixtureSticker("cat_wave", hash: hashA),
              let stickerB = fixtureSticker("cat_cry", hash: hashB)
        else { return nil }
        return SonarStickerPack(
            address: address,
            title: "Sonar Signal Cats",
            description: "Native sticker contract fixture for Signal-style pack import.",
            cover: stickerA,
            stickers: [stickerA, stickerB],
            license: "CC-BY-4.0"
        )
    }
}
