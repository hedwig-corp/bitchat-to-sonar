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

    func testStickerRefMemoryKeyNormalizesAuthorCaseAndHashCase() {
        let key = MarmotChatModel.stickerRefMemoryKey(
            packCoordinate: "30031:ABCDEF1234:MyPack",
            shortcode: "wave",
            plaintextSha256: String(repeating: "AA", count: 32)
        )
        XCTAssertEqual(key, "30031:abcdef1234:MyPack|wave|\(String(repeating: "aa", count: 32))")
        // Identifier and shortcode stay case-sensitive: they are distinct
        // stickers per the pack model, so they must not collapse to one key.
        XCTAssertNotEqual(key, MarmotChatModel.stickerRefMemoryKey(
            packCoordinate: "30031:abcdef1234:mypack",
            shortcode: "wave",
            plaintextSha256: String(repeating: "aa", count: 32)
        ))
        XCTAssertNotEqual(key, MarmotChatModel.stickerRefMemoryKey(
            packCoordinate: "30031:abcdef1234:MyPack",
            shortcode: "Wave",
            plaintextSha256: String(repeating: "aa", count: 32)
        ))
    }

    func testStickerLoadRetryScheduleIsShortAndBounded() {
        XCTAssertEqual(MarmotChatModel.stickerLoadRetryDelaySeconds(attempt: 0), 2)
        XCTAssertEqual(MarmotChatModel.stickerLoadRetryDelaySeconds(attempt: 1), 8)
        XCTAssertNil(MarmotChatModel.stickerLoadRetryDelaySeconds(attempt: 2))
        XCTAssertNil(MarmotChatModel.stickerLoadRetryDelaySeconds(attempt: 100))
    }

    func testIdentityReplacementClearsPickerAuthorityBeforeDatabaseWipe() async throws {
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
        try await model.prepareForIdentityReplacement {
            wipeObservedClearedMemory = model.cachedStickerPacksSnapshot().isEmpty
                && !model.isStickerPackInstalled(coordinate)
        }

        XCTAssertTrue(wipeObservedClearedMemory)
        XCTAssertTrue(model.cachedStickerPacksSnapshot().isEmpty)
        XCTAssertFalse(model.isStickerPackInstalled(coordinate))
    }

    func testIdentityReplacementStaysRedactedWhenDatabaseWipeFails() async {
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

        do {
            try await model.prepareForIdentityReplacement {
                throw MarmotService.ServiceError.core("injected wipe failure")
            }
            XCTFail("expected injected wipe failure")
        } catch {}

        XCTAssertTrue(model.cachedStickerPacksSnapshot().isEmpty)
        XCTAssertFalse(model.isStickerPackInstalled(coordinate))
    }

    func testStickerPackCacheUsesDeterministicLRUEviction() async {
        let suiteName = "MarmotStickerOptimisticTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = MarmotChatModel(
            service: MarmotService(relayUrls: []),
            keychain: MockKeychain(),
            defaults: defaults
        )
        let author = "author"
        var coordinates: [String] = []
        for index in 0..<20 {
            let coordinate = "30031:\(author):pack-\(index)"
            coordinates.append(coordinate)
            model.rememberStickerPack(
                StickerPackInfo(
                    packCoordinate: coordinate,
                    title: "Pack \(index)",
                    description: nil,
                    coverUrl: nil,
                    stickers: []
                ),
                cacheKey: coordinate
            )
        }
        model.replaceInstalledPackCoordinates(coordinates)
        _ = await model.fetchStickerPack(
            authorPubkeyHex: author,
            identifier: "pack-0",
            relayUrls: []
        )

        let newest = "30031:\(author):pack-20"
        model.rememberStickerPack(
            StickerPackInfo(
                packCoordinate: newest,
                title: "Pack 20",
                description: nil,
                coverUrl: nil,
                stickers: []
            ),
            cacheKey: newest
        )
        model.replaceInstalledPackCoordinates(coordinates + [newest])
        let visible = model.cachedStickerPacksSnapshot().map(\.packCoordinate)

        XCTAssertTrue(visible.contains(coordinates[0]))
        XCTAssertFalse(visible.contains(coordinates[1]))
        XCTAssertEqual(visible.last, newest)
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
        let coordinate = "30031:abcdef:Pack"

        // Preview/transcript metadata is not installed authority. Before the
        // local installed set is known, the composer must expose nothing.
        XCTAssertFalse(MarmotChatModel.shouldExposeCachedStickerPack(
            coordinate: coordinate,
            installedCoordinates: []
        ))
        XCTAssertTrue(MarmotChatModel.shouldExposeCachedStickerPack(
            coordinate: coordinate,
            installedCoordinates: [snNormalizeStickerPackCoordinate("30031:ABCDEF:Pack")]
        ))
        XCTAssertFalse(MarmotChatModel.shouldExposeCachedStickerPack(
            coordinate: coordinate,
            installedCoordinates: []
        ))
        XCTAssertFalse(MarmotChatModel.shouldExposeCachedStickerPack(
            coordinate: coordinate,
            installedCoordinates: [snNormalizeStickerPackCoordinate("30031:abcdef:pack")]
        ))
    }

    func testStickerPackCoordinateNormalizesOnlyTheAuthor() {
        XCTAssertEqual(
            snNormalizeStickerPackCoordinate("30031:ABCDEF:Pack"),
            "30031:abcdef:Pack"
        )
        XCTAssertEqual(snNormalizeStickerPackCoordinate("invalid"), "invalid")
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
            refreshedCoordinates: ["30031:AUTHOR:pack"],
            cachedInstalled: false
        ))
        XCTAssertFalse(snStickerPackInstalledState(
            coordinate: coordinate,
            refreshedCoordinates: ["30031:AUTHOR:PACK"],
            cachedInstalled: true
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
        let caseCollision = StickerPackInfo(
            packCoordinate: "30031:author:Installed",
            title: "Wrong case",
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
                [removed, caseCollision, installed],
                installedCoordinates: ["30031:AUTHOR:installed"]
            ),
            [installed]
        )
    }

    func testPartialMetadataRefreshPreservesEachUnrefreshedInstalledPack() {
        let cachedFirst = StickerPackInfo(
            packCoordinate: "30031:author:first",
            title: "Cached first",
            description: nil,
            coverUrl: nil,
            stickers: []
        )
        let cachedSecond = StickerPackInfo(
            packCoordinate: "30031:author:second",
            title: "Cached second",
            description: nil,
            coverUrl: nil,
            stickers: []
        )
        let refreshedFirst = StickerPackInfo(
            packCoordinate: cachedFirst.packCoordinate,
            title: "Fresh first",
            description: nil,
            coverUrl: nil,
            stickers: []
        )

        XCTAssertEqual(
            snMergeRefreshedStickerPacks(
                cachedPacks: [cachedFirst, cachedSecond],
                refreshedPacks: [refreshedFirst],
                installedCoordinates: [
                    "30031:AUTHOR:first",
                    "30031:author:second",
                ]
            ),
            [refreshedFirst, cachedSecond]
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
