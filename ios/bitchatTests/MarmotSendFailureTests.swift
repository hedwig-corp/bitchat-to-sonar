//
// MarmotSendFailureTests.swift
// bitchatTests
//
// Regression tests for the blank-chat-after-send failure: when the Marmot
// local store cannot be opened (missing account key, wrong DB encryption key),
// a direct text send used to time out and silently discard its optimistic
// echo — the message vanished and the chat looked blank with no error. The
// send must instead keep a retryable "Couldn't send" row and the model must
// surface the blocking failure for the restore/error UI.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
@testable import Sonar
import SonarCore

@MainActor
final class MarmotSendFailureTests: XCTestCase {
    private static let groupId = "send-failure-group"

    /// A model whose connect can never succeed: the mock keychain holds no
    /// account key and post-onboarding connects refuse to create a fresh one,
    /// so `ensureConnected` fails without touching any real database.
    private func makeUnconnectableModel(suite: String) -> MarmotChatModel {
        let defaults = UserDefaults(suiteName: suite)!
        return MarmotChatModel(
            service: MarmotService(relayUrls: []),
            keychain: MockKeychain(),
            defaults: defaults
        )
    }

    private func waitForFailedRow(
        in model: MarmotChatModel,
        groupId: String,
        timeout: TimeInterval = 20
    ) async throws -> [MarmotService.MarmotMessage] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let rows = model.messagesByGroup[groupId] ?? []
            if rows.contains(where: { $0.id.hasPrefix(MarmotChatModel.failedOptimisticIDPrefix) }) {
                return rows
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return model.messagesByGroup[groupId] ?? []
    }

    func testFailedDirectTextSendKeepsRetryableFailedRow() async throws {
        let suite = "MarmotSendFailureTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let model = makeUnconnectableModel(suite: suite)

        model.send("hello there", to: Self.groupId)

        // The optimistic echo paints immediately.
        let echoes = model.messagesByGroup[Self.groupId] ?? []
        XCTAssertEqual(echoes.count, 1)
        XCTAssertTrue(echoes[0].id.hasPrefix(MarmotChatModel.optimisticIDPrefix))

        // Once the connect times out, the echo must convert into a retryable
        // failed row — never vanish from the transcript.
        let rows = try await waitForFailedRow(in: model, groupId: Self.groupId)
        XCTAssertEqual(rows.count, 1)
        let failed = try XCTUnwrap(rows.first)
        XCTAssertTrue(failed.id.hasPrefix(MarmotChatModel.failedOptimisticIDPrefix))
        XCTAssertEqual(failed.content, "hello there")
        XCTAssertTrue(failed.isMine)
        XCTAssertEqual(MarmotChatModel.stateText(for: failed), "Couldn't send")
        XCTAssertFalse(rows.contains { $0.id.hasPrefix(MarmotChatModel.optimisticIDPrefix) })

        // The blocking account/store failure is surfaced for the UI banner.
        XCTAssertNotNil(model.localStoreFailure)
    }

    func testFailedReceiptLineBatchSendLeavesNoFailedRow() async throws {
        let suite = "MarmotSendFailureTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let model = makeUnconnectableModel(suite: suite)

        // Payment receipt control lines own their redelivery: a failed batch
        // send must report failure and leave no lingering failed row.
        let delivered = await model.send(["\u{26A1}PAY|1|payment-id|21"], to: Self.groupId)

        XCTAssertFalse(delivered)
        let rows = model.messagesByGroup[Self.groupId] ?? []
        XCTAssertTrue(rows.isEmpty, "receipt lines must not leave transcript rows, got \(rows.map(\.id))")
    }
}
