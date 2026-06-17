//
// SonarPayTests.swift
// bitchatTests
//
// Tests for the ⚡PAY chat-payment convention (codec) and the local
// payment ledger state machine, see docs/SONAR-PAYMENTS.md.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
@testable import Sonar

final class SonarPayTests: XCTestCase {

    private let uuid = "5f0c2c6a-9d57-4f1e-8a3b-2c41770e5b2d"
    private let offer = "lno1qsgqmqvgm96frzdg8m0gc6nzeqffvzsqzrxqy32afmr3jn9ggl9g2s8sugfvxn4xqzqxqsq"

    // MARK: - Codec round trips

    func testPayRoundTrip() {
        let line = SonarPayMessage.pay(id: uuid, sats: 21000)
        XCTAssertEqual(line.encoded(), "\u{26A1}PAY|1|\(uuid)|21000")
        XCTAssertEqual(SonarPayMessage.decode(line.encoded()), line)
    }

    func testClaimRoundTrip() {
        let line = SonarPayMessage.claim(id: uuid, offer: offer)
        XCTAssertEqual(line.encoded(), "\u{26A1}PAYCLAIM|1|\(uuid)|\(offer)")
        XCTAssertEqual(SonarPayMessage.decode(line.encoded()), line)
    }

    func testDoneRoundTrip() {
        let line = SonarPayMessage.done(id: uuid)
        XCTAssertEqual(line.encoded(), "\u{26A1}PAYDONE|1|\(uuid)")
        XCTAssertEqual(SonarPayMessage.decode(line.encoded()), line)
    }

    // MARK: - Codec rejections (unknown versions fall back to plain text)

    func testDecodeRejectsUnknownVersion() {
        XCTAssertNil(SonarPayMessage.decode("\u{26A1}PAY|2|\(uuid)|21000"))
        XCTAssertNil(SonarPayMessage.decode("\u{26A1}PAYCLAIM|2|\(uuid)|\(offer)"))
        XCTAssertNil(SonarPayMessage.decode("\u{26A1}PAYDONE|0|\(uuid)"))
    }

    func testDecodeRejectsMalformedLines() {
        XCTAssertNil(SonarPayMessage.decode("hello"))
        XCTAssertNil(SonarPayMessage.decode("\u{26A1}PAY"))
        XCTAssertNil(SonarPayMessage.decode("\u{26A1}PAY|1|\(uuid)"))          // missing sats
        XCTAssertNil(SonarPayMessage.decode("\u{26A1}PAY|1|\(uuid)|0"))        // zero sats
        XCTAssertNil(SonarPayMessage.decode("\u{26A1}PAY|1|\(uuid)|-5"))       // negative
        XCTAssertNil(SonarPayMessage.decode("\u{26A1}PAY|1|\(uuid)|12.5"))     // non-integer
        XCTAssertNil(SonarPayMessage.decode("\u{26A1}PAY|1||21000"))           // empty id
        XCTAssertNil(SonarPayMessage.decode("\u{26A1}PAY|1|not a uuid!|21000")) // bad id chars
        XCTAssertNil(SonarPayMessage.decode("\u{26A1}PAYCLAIM|1|\(uuid)|"))    // empty offer
        XCTAssertNil(SonarPayMessage.decode("\u{26A1}PAYDONE|1|\(uuid)|extra"))
        XCTAssertNil(SonarPayMessage.decode("PAY|1|\(uuid)|21000"))            // no ⚡ prefix
    }

    func testDecodeDisambiguatesPrefixes() {
        // ⚡PAYCLAIM / ⚡PAYDONE also start with "⚡PAY".
        guard case .claim = SonarPayMessage.decode("\u{26A1}PAYCLAIM|1|\(uuid)|\(offer)") else {
            return XCTFail("Expected .claim")
        }
        guard case .done = SonarPayMessage.decode("\u{26A1}PAYDONE|1|\(uuid)") else {
            return XCTFail("Expected .done")
        }
        guard case .pay = SonarPayMessage.decode("\u{26A1}PAY|1|\(uuid)|100") else {
            return XCTFail("Expected .pay")
        }
    }

    // MARK: - Ledger

    private func freshLedger() -> (SonarPayLedger, UserDefaults) {
        let suite = "sonar.pay.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (SonarPayLedger(defaults: defaults), defaults)
    }

    private func entry(state: SonarPayEntry.State = .sealed, direction: SonarPayEntry.Direction = .outgoing) -> SonarPayEntry {
        SonarPayEntry(id: uuid, peerKey: "peer1", sats: 21000, direction: direction, state: state, via: "mesh")
    }

    private func freshActivityLedger() -> (SonarPaymentActivityLedger, UserDefaults, String) {
        let suite = "sonar.payment.activity.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (SonarPaymentActivityLedger(defaults: defaults), defaults, suite)
    }

    func testRecordIsIdempotent() {
        let (ledger, _) = freshLedger()
        XCTAssertTrue(ledger.record(entry()))
        // Second record with the same id must not overwrite anything.
        var dupe = entry()
        dupe.state = .claimed
        XCTAssertFalse(ledger.record(dupe))
        XCTAssertEqual(ledger.entry(for: uuid)?.state, .sealed)
    }

    func testSenderTransitions() {
        let (ledger, _) = freshLedger()
        ledger.record(entry(direction: .outgoing))
        // sealed → settling (⚡PAYCLAIM received) → claimed (paid)
        XCTAssertTrue(ledger.transition(uuid, to: .settling))
        XCTAssertTrue(ledger.transition(uuid, to: .claimed))
        XCTAssertEqual(ledger.entry(for: uuid)?.state, .claimed)
        // claimed is terminal
        XCTAssertFalse(ledger.transition(uuid, to: .sealed))
        XCTAssertFalse(ledger.transition(uuid, to: .settling))
        XCTAssertFalse(ledger.transition(uuid, to: .claimed))
    }

    func testReceiverTransitions() {
        let (ledger, _) = freshLedger()
        ledger.record(entry(direction: .incoming))
        // sealed → claiming (offer sent) → claimed (⚡PAYDONE)
        XCTAssertTrue(ledger.transition(uuid, to: .claiming))
        XCTAssertTrue(ledger.transition(uuid, to: .claimed))
        XCTAssertEqual(ledger.entry(for: uuid)?.state, .claimed)
    }

    func testFailureRevertsToSealed() {
        let (ledger, _) = freshLedger()
        ledger.record(entry())
        XCTAssertTrue(ledger.transition(uuid, to: .settling))
        // Lightning payment failed: back to sealed, claim can retry.
        XCTAssertTrue(ledger.transition(uuid, to: .sealed))
        XCTAssertEqual(ledger.entry(for: uuid)?.state, .sealed)
        XCTAssertTrue(ledger.transition(uuid, to: .claiming))
        XCTAssertTrue(ledger.transition(uuid, to: .sealed))
    }

    func testInvalidTransitions() {
        let (ledger, _) = freshLedger()
        ledger.record(entry())
        XCTAssertFalse(ledger.transition(uuid, to: .sealed))      // no self-loop
        XCTAssertTrue(ledger.transition(uuid, to: .claiming))
        XCTAssertFalse(ledger.transition(uuid, to: .settling))    // claiming ↛ settling
        XCTAssertFalse(ledger.transition("missing-id", to: .claimed))
    }

    func testDoneCanRaceAheadOfClaiming() {
        let (ledger, _) = freshLedger()
        ledger.record(entry(direction: .incoming))
        // ⚡PAYDONE processed while still sealed locally.
        XCTAssertTrue(ledger.transition(uuid, to: .claimed))
    }

    func testPersistenceRoundTrip() {
        let suite = "sonar.pay.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let ledger = SonarPayLedger(defaults: defaults)
        ledger.record(entry(direction: .incoming))
        ledger.transition(uuid, to: .claiming)

        let reloaded = SonarPayLedger(defaults: defaults)
        XCTAssertEqual(reloaded.entry(for: uuid)?.state, .claiming)
        XCTAssertEqual(reloaded.entry(for: uuid)?.sats, 21000)
        XCTAssertEqual(reloaded.entry(for: uuid)?.via, "mesh")
        XCTAssertEqual(reloaded.entry(for: uuid)?.direction, .incoming)

        defaults.removePersistentDomain(forName: suite)
    }

    func testWipeClearsEverything() {
        let suite = "sonar.pay.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let ledger = SonarPayLedger(defaults: defaults)
        ledger.record(entry())
        ledger.wipe()
        XCTAssertNil(ledger.entry(for: uuid))
        XCTAssertNil(defaults.data(forKey: SonarPayLedger.defaultsKey))

        let reloaded = SonarPayLedger(defaults: defaults)
        XCTAssertNil(reloaded.entry(for: uuid))

        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: - Direct payment activity

    func testDirectPaymentActivityPersistsPaidWalletMetadata() {
        let (ledger, defaults, suite) = freshActivityLedger()
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let settled = created.addingTimeInterval(5)
        let activity = SonarPaymentActivity(
            id: uuid,
            kind: .sonarDirect,
            peerKey: "peer1",
            peerName: "Alice",
            direction: .outgoing,
            sats: 21000,
            via: "internet",
            createdAt: created,
            destinationHash: "abc123",
            status: .pending
        )
        XCTAssertTrue(ledger.recordPending(activity))
        XCTAssertFalse(ledger.recordPending(activity))

        let payment = SonarWalletPayment(
            id: "wallet-payment-1",
            amountSats: 21000,
            isIncoming: false,
            timestamp: settled,
            note: "Sonar payment \(uuid)",
            feesSats: 7
        )
        XCTAssertTrue(ledger.markPaid(uuid, payment: payment))

        let reloaded = SonarPaymentActivityLedger(defaults: defaults)
        let saved = reloaded.activities(peerKey: "peer1").first
        XCTAssertEqual(saved?.status, .paid)
        XCTAssertEqual(saved?.walletPaymentId, "wallet-payment-1")
        XCTAssertEqual(saved?.feesSats, 7)
        XCTAssertEqual(saved?.settledAt, settled)
        XCTAssertEqual(saved?.destinationHash, "abc123")
        XCTAssertEqual(saved?.kind, .sonarDirect)

        defaults.removePersistentDomain(forName: suite)
    }

    func testDirectPaymentActivityRecordsFailure() {
        let (ledger, defaults, suite) = freshActivityLedger()
        let activity = SonarPaymentActivity(
            id: uuid,
            kind: .unifyNearby,
            peerKey: "unify:peer1",
            peerName: "Unify user",
            direction: .outgoing,
            sats: 1000,
            via: "internet",
            createdAt: Date(),
            destinationHash: nil,
            status: .pending
        )
        ledger.recordPending(activity)
        XCTAssertTrue(ledger.markFailed(uuid, message: "route not found"))
        XCTAssertEqual(ledger.activities(peerKey: "unify:peer1").first?.status, .failed)
        XCTAssertEqual(ledger.activities(peerKey: "unify:peer1").first?.failure, "route not found")
        XCTAssertNotNil(ledger.activities(peerKey: "unify:peer1").first?.settledAt)

        defaults.removePersistentDomain(forName: suite)
    }

    func testWalletIncomingPaymentActivityPersists() {
        let (ledger, defaults, suite) = freshActivityLedger()
        let settled = Date(timeIntervalSince1970: 1_800_000_100)
        let activity = SonarPaymentActivity(
            id: "wallet-payment-2",
            kind: .walletIncoming,
            peerKey: "wallet",
            peerName: "External wallet",
            direction: .incoming,
            sats: 5000,
            via: "internet",
            createdAt: settled,
            destinationHash: nil,
            status: .paid,
            walletPaymentId: "payment-2",
            feesSats: 0,
            settledAt: settled
        )

        XCTAssertTrue(ledger.recordPending(activity))

        let reloaded = SonarPaymentActivityLedger(defaults: defaults)
        let saved = reloaded.activities(peerKey: "wallet").first
        XCTAssertEqual(saved?.kind, .walletIncoming)
        XCTAssertEqual(saved?.direction, .incoming)
        XCTAssertEqual(saved?.walletPaymentId, "payment-2")
        XCTAssertEqual(saved?.status, .paid)

        defaults.removePersistentDomain(forName: suite)
    }
}
