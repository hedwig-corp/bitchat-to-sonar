//
// MarmotStickerOptimisticTests.swift
// bitchatTests
//

import XCTest
@testable import Sonar
import SonarCore

@MainActor
final class MarmotStickerOptimisticTests: XCTestCase {
    func testInvalidatedStickerLookupNeverFallsThroughAsCacheMiss() {
        XCTAssertEqual(MarmotChatModel.stickerCacheLookupState(
            hasData: false,
            startedGeneration: 1,
            currentGeneration: 2
        ), .invalidated)
        XCTAssertEqual(MarmotChatModel.stickerCacheLookupState(
            hasData: true,
            startedGeneration: 1,
            currentGeneration: 2
        ), .invalidated)
        XCTAssertEqual(MarmotChatModel.stickerCacheLookupState(
            hasData: false,
            startedGeneration: 2,
            currentGeneration: 2
        ), .miss)
        XCTAssertEqual(MarmotChatModel.stickerCacheLookupState(
            hasData: true,
            startedGeneration: 2,
            currentGeneration: 2
        ), .hit)
    }

    func testIdentityReplacementClearsPickerAuthorityBeforeDatabaseWipe() async {
        let suiteName = "MarmotStickerOptimisticTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = MarmotChatModel(
            service: MarmotService(relayUrls: []),
            keychain: MockKeychain(),
            defaults: defaults
        )
        let coordinate = "30031:author:old-account-pack"
        let pack = StickerPackInfo(
            packCoordinate: coordinate,
            title: "Old account",
            description: nil,
            coverUrl: nil,
            stickers: []
        )
        model.rememberStickerPack(pack, cacheKey: coordinate)
        model.replaceInstalledPackCoordinates([coordinate])
        XCTAssertEqual(model.cachedStickerPacksSnapshot(), [pack])

        var wipeObservedClearedMemory = false
        await model.prepareForIdentityReplacement {
            wipeObservedClearedMemory = model.cachedStickerPacksSnapshot().isEmpty
                && !model.isStickerPackInstalled(coordinate)
        }

        XCTAssertTrue(wipeObservedClearedMemory)
        XCTAssertTrue(model.cachedStickerPacksSnapshot().isEmpty)
        XCTAssertFalse(model.isStickerPackInstalled(coordinate))
    }

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

        // Preview/transcript metadata is not installed authority. Before the
        // local installed set is known, the composer must expose nothing.
        XCTAssertFalse(MarmotChatModel.shouldExposeCachedStickerPack(
            coordinate: coordinate,
            installedCoordinates: []
        ))
        XCTAssertTrue(MarmotChatModel.shouldExposeCachedStickerPack(
            coordinate: coordinate,
            installedCoordinates: [coordinate]
        ))
        XCTAssertFalse(MarmotChatModel.shouldExposeCachedStickerPack(
            coordinate: coordinate,
            installedCoordinates: []
        ))
        XCTAssertFalse(MarmotChatModel.shouldExposeCachedStickerPack(
            coordinate: coordinate,
            installedCoordinates: ["30031:author:other"]
        ))
    }

    func testStickerPreviewPreservesCachedInstallStateOnlyOnRefreshFailure() {
        let coordinate = "30031:author:pack"

        XCTAssertTrue(snStickerPackInstalledState(
            coordinate: coordinate,
            refreshedCoordinates: nil,
            cachedInstalled: true
        ))
        XCTAssertFalse(snStickerPackInstalledState(
            coordinate: coordinate,
            refreshedCoordinates: nil,
            cachedInstalled: false
        ))
        XCTAssertFalse(snStickerPackInstalledState(
            coordinate: coordinate,
            refreshedCoordinates: [],
            cachedInstalled: true
        ))
        XCTAssertTrue(snStickerPackInstalledState(
            coordinate: coordinate,
            refreshedCoordinates: ["30031:AUTHOR:PACK"],
            cachedInstalled: false
        ))
    }

    func testSuccessfulInstalledRefreshFiltersCachedPickerPacks() {
        let removed = StickerPackInfo(
            packCoordinate: "30031:author:removed",
            title: "Removed",
            description: nil,
            coverUrl: nil,
            stickers: []
        )
        let installed = StickerPackInfo(
            packCoordinate: "30031:author:installed",
            title: "Installed",
            description: nil,
            coverUrl: nil,
            stickers: []
        )

        XCTAssertEqual(
            snFilterCachedStickerPacks(
                [removed, installed],
                installedCoordinates: ["30031:AUTHOR:INSTALLED"]
            ),
            [installed]
        )
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
