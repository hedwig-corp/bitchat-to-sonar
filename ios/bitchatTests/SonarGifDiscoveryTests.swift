//
// SonarGifDiscoveryTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
@testable import Sonar

struct SonarGifDiscoveryTests {
    @Test func normalizesCatalogAndDerivesStableIds() throws {
        let catalog = SonarGifCatalog(
            name: "  Reactions  ",
            items: [
                SonarGifItem(
                    title: "  Thumbs up  ",
                    mimeType: "video/mp4; charset=utf-8",
                    mediaUrl: "HTTPS://Blossom.Example/files/thumbs-up.mp4",
                    previewUrl: "https://blossom.example/files/thumbs-up-preview.mp4",
                    stillUrl: "https://blossom.example/files/thumbs-up.jpg",
                    width: 480,
                    height: 270,
                    byteSize: 734_201,
                    source: "Nostr"
                )
            ]
        )

        let normalized = try #require(SonarGifDiscovery.normalize(catalog))
        #expect(normalized.name == "Reactions")
        #expect(normalized.items.count == 1)
        let item = normalized.items[0]
        #expect(item.title == "Thumbs up")
        #expect(item.mimeType == "video/mp4")
        #expect(item.mediaUrl == "https://blossom.example/files/thumbs-up.mp4")
        #expect(item.id == SonarGifDiscovery.stableItemId(item.mediaUrl))
        #expect(item.source == "nostr")
        #expect(SonarGifDiscovery.fileExtension(for: item.mimeType) == "mp4")
    }

    @Test func rejectsUnsafeCatalogItems() {
        #expect(SonarGifDiscovery.normalize(SonarGifItem(
            title: "bad",
            mimeType: "image/gif",
            mediaUrl: "http://example.com/bad.gif"
        )) == nil)

        #expect(SonarGifDiscovery.normalize(SonarGifItem(
            title: "too big",
            mimeType: "image/gif",
            mediaUrl: "https://example.com/big.gif",
            byteSize: SonarGifDiscovery.maxItemBytes + 1
        )) == nil)

        #expect(SonarGifDiscovery.normalize(SonarGifItem(
            title: "unsupported",
            mimeType: "image/png",
            mediaUrl: "https://example.com/not-gif.gif"
        )) == nil)

        #expect(SonarGifDiscovery.normalize(SonarGifItem(
            title: "userinfo",
            mimeType: "image/gif",
            mediaUrl: "https://example.com@evil.example/bad.gif"
        )) == nil)

        let inferred = SonarGifDiscovery.normalize(SonarGifItem(
            title: "inferred",
            mimeType: "",
            mediaUrl: "https://example.com/ok.gif"
        ))
        #expect(inferred?.mimeType == "image/gif")
    }

    @Test func writesNostrCatalogJsonAndTags() throws {
        let catalog = SonarGifCatalog(
            name: "Reactions",
            items: [
                SonarGifItem(
                    id: "thumbs-up",
                    title: "Thumbs \"up\"",
                    mimeType: "image/gif",
                    mediaUrl: "https://blossom.example/thumbs-up.gif",
                    width: 320,
                    height: 240,
                    source: "nostr"
                )
            ]
        )

        let data = try #require(SonarGifDiscovery.nostrContentData(for: catalog))
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"app\":\"sonar\""))
        #expect(json.contains("\"schema\":1"))
        #expect(json.contains("\"type\":\"gif_catalog\""))
        #expect(json.contains("\"title\":\"Thumbs \\\"up\\\"\""))
        #expect(json.contains("\"url\":\"https://blossom.example/thumbs-up.gif\""))

        #expect(SonarGifDiscovery.catalogEventTags() == [
            ["d", SonarGifDiscovery.catalogDTag],
            ["t", "sonar"],
            ["t", "gif"],
        ])
    }
}
