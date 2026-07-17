//
// MarmotSendFailureTests.swift
// bitchatTests
//
// Regression tests for R-007 (docs/REGRESSIONS.md): a failed send stays
// visible, exactly once. When the Marmot local store cannot be opened (missing
// account key, wrong DB encryption key), a direct text send used to time out
// and silently discard its optimistic echo — the message vanished and the chat
// looked blank with no error. The send must instead keep a retryable
// "Couldn't send" row, and the model must surface the blocking failure for the
// restore/error UI.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
@testable import Sonar

@MainActor
struct MarmotSendFailureTests {
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

    @Test
    func testFailedDirectTextSendKeepsRetryableFailedRow() async throws {
        let suite = "MarmotSendFailureTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let model = makeUnconnectableModel(suite: suite)

        model.send("hello there", to: Self.groupId)

        // The optimistic echo paints immediately.
        let echoes = model.messagesByGroup[Self.groupId] ?? []
        #expect(echoes.count == 1)
        #expect(echoes.first?.id.hasPrefix(MarmotChatModel.optimisticIDPrefix) == true)

        // Once the connect times out, the echo must convert into a retryable
        // failed row — never vanish from the transcript.
        let rows = try await waitForFailedRow(in: model, groupId: Self.groupId)
        #expect(rows.count == 1)
        let failed = try #require(rows.first)
        #expect(failed.id.hasPrefix(MarmotChatModel.failedOptimisticIDPrefix))
        #expect(failed.content == "hello there")
        #expect(failed.isMine)
        #expect(MarmotChatModel.stateText(for: failed) == "Couldn't send")
        #expect(!rows.contains { $0.id.hasPrefix(MarmotChatModel.optimisticIDPrefix) })

        // The blocking account/store failure is surfaced for the UI banner.
        #expect(model.localStoreFailure != nil)
    }

    @Test
    func testFailedReceiptLineBatchSendLeavesNoFailedRow() async throws {
        let suite = "MarmotSendFailureTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let model = makeUnconnectableModel(suite: suite)

        // Payment receipt control lines own their redelivery: a failed batch
        // send must report failure and leave no lingering failed row.
        let delivered = await model.send(["\u{26A1}PAY|1|payment-id|21"], to: Self.groupId)

        #expect(delivered == false)
        let rows = model.messagesByGroup[Self.groupId] ?? []
        #expect(rows.isEmpty, "receipt lines must not leave transcript rows, got \(rows.map(\.id))")
    }
}
