//
// SonarConversationRegressionSmokeTests.swift
// bitchatTests
//

import Foundation
import Testing
import SonarCore
@testable import Sonar

/// Cross-platform parity fixture for the conversation regressions seen on real
/// devices: duplicate direct groups, a newer Sara message appearing on the
/// wrong Vincenzo row, and unstable ordering after restart.
@MainActor
struct SonarConversationRegressionSmokeTests {
    private func npub(_ byte: UInt8) -> String {
        try! Bech32.encode(hrp: "npub", data: Data(repeating: byte, count: 32))
    }

    @Test
    func newSaraMessageMovesOnlySaraRowAndKeepsSaraTitle() {
        let old = Date(timeIntervalSince1970: 100)
        let new = Date(timeIntervalSince1970: 300)
        let rows = [
            SNDMRow(
                id: "vincenzo-mac", title: "Vincenzo-Mac", preview: "Yesterday",
                time: "", unread: false, presence: false, verified: false,
                isMarmot: false, lastDate: old
            ),
            SNDMRow(
                id: "sara", title: "Sara D", preview: "Good morning", time: "", unread: true,
                presence: false, verified: false, isMarmot: false, lastDate: new
            ),
        ]

        let ordered = snSortDMRowsByRecency(rows)

        #expect(ordered.map(\.id) == ["sara", "vincenzo-mac"])
        #expect(ordered.first?.title == "Sara D")
        #expect(ordered.first?.preview == "Good morning")
    }

    @Test
    func restartTieOrderIsDeterministic() {
        let same = Date(timeIntervalSince1970: 200)
        let rows = [
            SNDMRow(
                id: "vincenzo", title: "Vincenzo", preview: "", time: "",
                unread: false, presence: false, verified: false,
                isMarmot: false, lastDate: same
            ),
            SNDMRow(
                id: "sara", title: "Sara D", preview: "", time: "",
                unread: false, presence: false, verified: false,
                isMarmot: false, lastDate: same
            ),
        ]

        #expect(snSortDMRowsByRecency(rows).map(\.id) == ["sara", "vincenzo"])
        #expect(snSortDMRowsByRecency(Array(rows.reversed())).map(\.id) == ["sara", "vincenzo"])
    }

    @Test
    func retryDeliveryStateReturnsToSending() {
        let pending = MarmotService.MarmotMessage(
            id: "core-message",
            senderNpub: npub(1),
            content: "hello",
            createdAt: Date(timeIntervalSince1970: 400),
            isMine: true,
            deliveryState: "pending",
            media: []
        )
        let failed = MarmotService.MarmotMessage(
            id: "core-message",
            senderNpub: npub(1),
            content: "hello",
            createdAt: pending.createdAt,
            isMine: true,
            deliveryState: "failed",
            media: []
        )

        #expect(MarmotChatModel.stateText(for: failed) == "Couldn't send")
        #expect(MarmotChatModel.stateText(for: pending) == "Sending")
    }

    @Test
    func retryIsOnlyOfferedForFailedOutgoingInternetMessages() {
        let failedInternet = SNMessage(
            mine: true,
            text: "hello",
            time: "",
            via: .internet,
            state: "Couldn't send"
        )

        #expect(snCanRetryFailedMessage(failedInternet))
        #expect(!snCanRetryFailedMessage(SNMessage(
            mine: true,
            text: "hello",
            time: "",
            via: .mesh,
            state: "Couldn't send"
        )))
        #expect(!snCanRetryFailedMessage(SNMessage(
            mine: false,
            text: "hello",
            time: "",
            via: .internet,
            state: "Couldn't send"
        )))
    }

    @Test
    func retryReconstructsStickerTransportContentFromTheRetainedReference() {
        let message = SNMessage(
            mine: true,
            text: "",
            time: "",
            via: .internet,
            state: "Couldn't send",
            stickerRef: MarmotService.MarmotStickerRef(
                packCoordinate: "30031:author:pack",
                shortcode: "wave",
                plaintextSha256: "aabbcc"
            )
        )

        let encoded = snRetryContent(message)
        let decoded = encoded.flatMap { SonarCore.meshParseStickerContent(content: $0) }

        #expect(decoded?.packCoordinate == message.stickerRef?.packCoordinate)
        #expect(decoded?.shortcode == message.stickerRef?.shortcode)
        #expect(decoded?.plaintextSha256 == message.stickerRef?.plaintextSha256)
    }

    @Test
    func establishedFailedStickerUsesTheOptimisticRetryPipeline() {
        let message = SNMessage(
            id: "failed-optimistic-sticker",
            mine: true,
            text: "",
            time: "",
            via: .internet,
            state: "Couldn't send",
            stickerRef: MarmotService.MarmotStickerRef(
                packCoordinate: "30031:author:pack",
                shortcode: "wave",
                plaintextSha256: "aabbcc"
            )
        )

        #expect(snIsFailedOptimisticStickerMessage(message))
        #expect(!snIsFailedOptimisticStickerMessage(SNMessage(
            id: "core-message",
            mine: true,
            text: "",
            time: "",
            via: .internet,
            state: "Couldn't send",
            stickerRef: message.stickerRef
        )))
    }
}
