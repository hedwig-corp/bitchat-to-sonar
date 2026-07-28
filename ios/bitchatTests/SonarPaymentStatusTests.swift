//
// SonarPaymentStatusTests.swift
// bitchatTests
//
// Mirror of the Compose `PaymentStatusTest`
// (apps/sonar/composeApp/src/commonTest/kotlin/chat/bitchat/sonar/wallet/PaymentStatusTest.kt).
// Both pin the same state machine and the same money-truth copy, because a
// payment status that says different things on the two platforms is exactly
// the failure the Cross-Platform Feature Rule exists to catch.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
@testable import Sonar

final class SonarPaymentStatusTests: XCTestCase {

    private func status(
        _ phase: SNPayPhase,
        sats: Int64 = 2_100,
        elapsed: Int = 6,
        preimage: String? = nil,
        canRetry: Bool = true
    ) -> SNPaymentStatus {
        SNPaymentStatus(
            id: "a1",
            payeeName: "Café Lumen",
            sats: sats,
            phase: phase,
            elapsedSeconds: elapsed,
            preimage: preimage,
            canRetry: canRetry
        )
    }

    private func activity(_ status: SonarPaymentActivity.Status) -> SonarPaymentActivity {
        SonarPaymentActivity(
            id: "a1",
            kind: .sonarDirect,
            peerKey: "wallet",
            peerName: "Café Lumen",
            direction: .outgoing,
            sats: 2_100,
            via: "internet",
            createdAt: Date(),
            destinationHash: "hash",
            status: status
        )
    }

    private func liveSend() -> SNLivePayment {
        SNLivePayment(
            id: "a1", payeeName: "Café Lumen", sats: 2_100,
            startedAt: Date(), handedToWallet: true
        )
    }

    // MARK: Live phase derivation

    func testResolvingUntilTheWalletIsCalled() {
        let started = Date()
        let live = SNLivePayment(
            id: "a1", payeeName: "Café Lumen", sats: 2_100,
            startedAt: started, handedToWallet: false
        )
        XCTAssertEqual(live.phase(now: started.addingTimeInterval(120)), .resolving)
    }

    func testInFlightIsPayingUntilItIsUnusuallySlow() {
        let started = Date()
        let live = SNLivePayment(
            id: "a1", payeeName: "Café Lumen", sats: 2_100,
            startedAt: started, handedToWallet: true
        )
        XCTAssertEqual(live.phase(now: started.addingTimeInterval(6)), .paying)
        XCTAssertEqual(live.elapsedSeconds(now: started.addingTimeInterval(6)), 6)
        XCTAssertEqual(
            live.phase(now: started.addingTimeInterval(SNLivePayment.slowAfter)), .slow
        )
    }

    // MARK: Money-truth copy — must match the Compose table verbatim
    //
    // Amounts are interpolated through `SNPayStatusCopy.amount`, which groups
    // with the device locale's separator ("2,100" in en-US, "2.100" in it-IT).
    // The Compose mirror hard-codes en-US grouping in `payFmt`, so asserting a
    // literal "2,100" here would fail on any non-en-US simulator and pin the
    // wrong thing: what must match across platforms is the wording.

    func testEveryPhaseNamesWhereTheMoneyIs() {
        let n = SNPayStatusCopy.amount(2_100)
        let expected: [SNPayPhase: String] = [
            .resolving: "Nothing sent yet — your sats are still yours",
            .paying: "\(n) sats in flight — not yet settled",
            .slow: "Still in flight — held, not lost",
            .sent: "\(n) sats delivered · proof received",
            .failedSafe: "Nothing left your wallet — balance unchanged",
            .refunded: "\(n) sats returned to your balance",
            .unknown: "Sats reserved — we’ll confirm or refund automatically"
        ]
        for (phase, text) in expected {
            XCTAssertEqual(
                SNPayStatusCopy.money(phase, sats: 2_100).text, text,
                "money line for \(phase.rawValue)"
            )
        }
        // Every phase must have one — this is the design's core promise.
        XCTAssertEqual(expected.count, SNPayPhase.allCases.count)
    }

    func testHeadlinesMatchTheDesign() {
        XCTAssertEqual(
            SNPayStatusCopy.headline(.resolving, payee: "Café Lumen", sats: 2_100),
            "Finding Café Lumen"
        )
        XCTAssertEqual(
            SNPayStatusCopy.headline(.paying, payee: "Café Lumen", sats: 2_100),
            "Sending \(SNPayStatusCopy.amount(2_100)) sats"
        )
        XCTAssertEqual(
            SNPayStatusCopy.headline(.sent, payee: "Café Lumen", sats: 2_100),
            "Paid Café Lumen"
        )
        XCTAssertEqual(
            SNPayStatusCopy.headline(.failedSafe, payee: "Café Lumen", sats: 2_100),
            "Couldn’t send"
        )
    }

    func testWalletRowAndElapsed() {
        XCTAssertEqual(SNPayStatusCopy.elapsed(-5), "0s")
        XCTAssertEqual(SNPayStatusCopy.elapsed(48), "48s")
        XCTAssertEqual(SNPayStatusCopy.elapsed(60), "1m")
        XCTAssertEqual(SNPayStatusCopy.walletRow(.paying, elapsedSeconds: 6), "Sending · 6s")
        XCTAssertEqual(SNPayStatusCopy.walletRow(.unknown, elapsedSeconds: 120), "Confirming · 2m")
        XCTAssertEqual(SNPayStatusCopy.walletRow(.failedSafe, elapsedSeconds: 9), "Not sent · not charged")
    }

    // MARK: Actions

    func testCancelIsOfferedOnlyBeforeTheWalletIsCalled() {
        XCTAssertEqual(SNPayStatusCopy.actions(status(.resolving)).map(\.label), ["Cancel"])
        // Once in flight, Lightning cannot recall it — so no button may claim
        // to. This is the one deliberate deviation from the design.
        for phase in [SNPayPhase.paying, .slow] {
            let labels = SNPayStatusCopy.actions(status(phase)).map(\.label)
            XCTAssertFalse(
                labels.contains(where: { $0.contains("Cancel") }),
                "\(phase.rawValue) must not offer Cancel"
            )
        }
    }

    func testCopyProofNeedsAProof() {
        XCTAssertEqual(
            SNPayStatusCopy.actions(status(.sent, preimage: "beef")).map(\.label),
            ["Copy proof", "Done"]
        )
        XCTAssertEqual(SNPayStatusCopy.actions(status(.sent)).map(\.label), ["Done"])
    }

    func testRetryIsHiddenWhenTheDestinationIsGone() {
        XCTAssertEqual(
            SNPayStatusCopy.actions(status(.failedSafe, canRetry: false)).map(\.label),
            ["Done"]
        )
        XCTAssertEqual(
            SNPayStatusCopy.actions(status(.failedSafe, canRetry: true)).map(\.label),
            ["Try again", "Not now"]
        )
    }

    // MARK: Home strip

    func testOnlyLivePhasesEverReachTheHomeStrip() {
        for phase in [SNPayPhase.resolving, .paying, .slow] {
            XCTAssertTrue(phase.isLive, "\(phase.rawValue) should be live")
            XCTAssertFalse(phase.isGood || phase.isBad, "\(phase.rawValue) must not read as terminal")
        }
        let strip = SNPayStatusCopy.homeStrip(.paying, payee: "Café Lumen", sats: 2_100)
        XCTAssertEqual(strip.title, "Sending \(SNPayStatusCopy.amount(2_100)) sats")
        XCTAssertEqual(strip.sub, "Café Lumen · tap for details")
    }

    // MARK: The scan sheet's amount label (regression: "2,100 sats sats")

    func testFormattedSatsCarryTheUnitExactlyOnce() {
        // The grouping separator is the device locale's; the unit is not, and
        // must appear exactly once. Composing an amount into a phrase goes
        // through the unit-less `sonarGroupedSats`.
        let grouped = sonarGroupedSats(2_100)
        XCTAssertFalse(grouped.contains("sats"))
        XCTAssertEqual(sonarFormatSats(2_100), "\(grouped) sats")
        // Regression: the scan sheet used to append its own " sats" on top of
        // sonarFormatSats, rendering "2,100 sats sats".
        let label = "Continue · \(sonarFormatSats(2_100))"
        XCTAssertEqual(label.components(separatedBy: "sats").count - 1, 1)
    }

    // MARK: Home-strip visibility

    func testStripShowsOnlyWhileTheSendIsLiveAndPending() {
        XCTAssertTrue(
            snShowsOnHomeStrip(live: liveSend(), activity: activity(.pending)),
            "a live, still-pending send is exactly what the strip is for"
        )
    }

    func testStripClearsOnSettleOrFailure() {
        // The owner's explicit requirement: gone the moment it concludes.
        for status in [SonarPaymentActivity.Status.paid, .failed] {
            XCTAssertFalse(
                snShowsOnHomeStrip(live: liveSend(), activity: activity(status)),
                "\(status.rawValue) must not stay pinned over the chat list"
            )
        }
    }

    func testStripIgnoresAPendingRowLeftByAKilledProcess() {
        // No live send means nothing will ever resolve this row, so a banner
        // would sit there forever.
        XCTAssertFalse(snShowsOnHomeStrip(live: nil, activity: activity(.pending)))
        XCTAssertFalse(snShowsOnHomeStrip(live: liveSend(), activity: nil))
    }

    // MARK: The call site's decision, not just the helper

    func testHomeStripShowsTheLiveInFlightPayment() {
        let started = Date()
        let live = SNLivePayment(
            id: "a1", payeeName: "Café Lumen", sats: 2_100,
            startedAt: started, handedToWallet: true
        )
        let status = snHomeStripStatus(
            livePayments: ["a1": live],
            activityOf: { _ in self.activity(.pending) },
            now: started.addingTimeInterval(6)
        )
        XCTAssertEqual(status?.phase, .paying)
        XCTAssertEqual(status?.payeeName, "Café Lumen")
    }

    func testHomeStripClearsTheMomentThePaymentConcludes() {
        // The owner's explicit requirement. This is the test that fails if the
        // gate is dropped from the call site.
        for concluded in [SonarPaymentActivity.Status.paid, .failed] {
            XCTAssertNil(
                snHomeStripStatus(
                    livePayments: ["a1": liveSend()],
                    activityOf: { _ in self.activity(concluded) },
                    now: Date()
                ),
                "\(concluded.rawValue) must not stay pinned over the chat list"
            )
        }
    }

    func testHomeStripStaysEmptyWithoutALiveSend() {
        XCTAssertNil(
            snHomeStripStatus(
                livePayments: [:],
                activityOf: { _ in self.activity(.pending) },
                now: Date()
            )
        )
        // A pending row whose activity is gone (wiped) shows nothing either.
        XCTAssertNil(
            snHomeStripStatus(
                livePayments: ["a1": liveSend()],
                activityOf: { _ in nil },
                now: Date()
            )
        )
    }
}
