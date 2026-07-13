//
// MarmotStickerOptimisticTests.swift
// bitchatTests
//

import XCTest
@testable import Sonar

@MainActor
final class MarmotStickerOptimisticTests: XCTestCase {
    func testFailedInstalledRefreshPreservesCachedPacks() {
        XCTAssertTrue(snShouldPreserveCachedStickerPacks(
            hadCachedPacks: true,
            installedCoordinates: nil
        ))
        XCTAssertFalse(snShouldPreserveCachedStickerPacks(
            hadCachedPacks: false,
            installedCoordinates: nil
        ))
        XCTAssertFalse(snShouldPreserveCachedStickerPacks(
            hadCachedPacks: true,
            installedCoordinates: []
        ))
    }

    func testCachedStickerPacksFollowInstalledAuthority() {
        let coordinate = "30031:author:pack"

        XCTAssertTrue(MarmotChatModel.shouldExposeCachedStickerPack(
            coordinate: coordinate,
            installedCoordinates: [],
            installedCoordinatesLoaded: false
        ))
        XCTAssertTrue(MarmotChatModel.shouldExposeCachedStickerPack(
            coordinate: coordinate,
            installedCoordinates: [coordinate],
            installedCoordinatesLoaded: true
        ))
        XCTAssertFalse(MarmotChatModel.shouldExposeCachedStickerPack(
            coordinate: coordinate,
            installedCoordinates: [],
            installedCoordinatesLoaded: true
        ))
        XCTAssertFalse(MarmotChatModel.shouldExposeCachedStickerPack(
            coordinate: coordinate,
            installedCoordinates: ["30031:author:other"],
            installedCoordinatesLoaded: true
        ))
    }

    func testStickerEchoMatchesOnlyTheSameSticker() {
        let createdAt = Date()
        let expectedRef = MarmotService.MarmotStickerRef(
            packCoordinate: "30031:author:pack",
            shortcode: "wave",
            plaintextSha256: "aabbcc"
        )
        let echo = message(
            id: "optimistic-sticker",
            createdAt: createdAt,
            stickerRef: expectedRef
        )

        XCTAssertTrue(MarmotChatModel.serverMessage(
            message(id: "canonical", createdAt: createdAt.addingTimeInterval(1), stickerRef: expectedRef),
            matchesOptimistic: echo
        ))

        let differentRef = MarmotService.MarmotStickerRef(
            packCoordinate: expectedRef.packCoordinate,
            shortcode: "other",
            plaintextSha256: "ddeeff"
        )
        XCTAssertFalse(MarmotChatModel.serverMessage(
            message(id: "other-sticker", createdAt: createdAt.addingTimeInterval(1), stickerRef: differentRef),
            matchesOptimistic: echo
        ))
        XCTAssertFalse(MarmotChatModel.serverMessage(
            message(id: "empty-text", createdAt: createdAt.addingTimeInterval(1), stickerRef: nil),
            matchesOptimistic: echo
        ))
    }

    private func message(
        id: String,
        createdAt: Date,
        stickerRef: MarmotService.MarmotStickerRef?
    ) -> MarmotService.MarmotMessage {
        MarmotService.MarmotMessage(
            id: id,
            senderNpub: "npub1test",
            content: "",
            createdAt: createdAt,
            isMine: true,
            media: [],
            stickerRef: stickerRef
        )
    }
}
