import XCTest
import SonarCore
@testable import Sonar

@MainActor
final class SonarMigrationRescueTests: XCTestCase {

    func testExecuteErrorAfterSourceAcceptedIsPendingNotANewQuote() {
        let dest: UInt64 = 500
        let failed = "payment failed"
        let pendingStates: [MigrationAttemptState] = [
            .sending, .paymentUnknown, .sourcePending, .sourcePaid, .mintPaid,
        ]
        for state in pendingStates {
            XCTAssertTrue(
                SonarMigrationModel.attemptBlocksNewQuote(state),
                "\(state) must not mint a second invoice"
            )
            XCTAssertEqual(
                SonarMigrationModel.phaseAfterExecuteError(
                    state: state,
                    destConfirmedSats: dest,
                    failedMessage: failed
                ),
                .pendingSettlement(cashuSats: dest)
            )
        }
        XCTAssertEqual(
            SonarMigrationModel.phaseAfterExecuteError(
                state: .settled,
                destConfirmedSats: dest,
                failedMessage: failed
            ),
            .settled(cashuSats: dest)
        )
        for state in [MigrationAttemptState.awaitingConsent, .expiredUnsent, .sourceFailed] {
            XCTAssertFalse(SonarMigrationModel.attemptBlocksNewQuote(state))
            XCTAssertEqual(
                SonarMigrationModel.phaseAfterExecuteError(
                    state: state,
                    destConfirmedSats: dest,
                    failedMessage: failed
                ),
                .failed(failed)
            )
        }
        XCTAssertEqual(
            SonarMigrationModel.phaseAfterExecuteError(
                state: nil,
                destConfirmedSats: dest,
                failedMessage: failed
            ),
            .failed(failed)
        )
    }

    func testRelaunchAfterPaidJournalIsPendingNotANewQuote() {
        let dest: UInt64 = 500
        let failed = "Lightning payment failed"
        let pendingStates: [MigrationAttemptState] = [
            .sending, .paymentUnknown, .sourcePending, .sourcePaid, .mintPaid,
        ]
        for state in pendingStates {
            XCTAssertTrue(
                SonarMigrationModel.needsRescue(state),
                "\(state) must resume, not re-quote"
            )
            XCTAssertEqual(
                SonarMigrationModel.phaseAfterOpenStatus(
                    state: state,
                    attemptAmountSats: 2_000,
                    destConfirmedSats: dest,
                    lightningFailedMessage: failed
                ),
                .pendingSettlement(cashuSats: dest)
            )
        }
        XCTAssertEqual(
            SonarMigrationModel.phaseAfterOpenStatus(
                state: nil,
                attemptAmountSats: 0,
                destConfirmedSats: dest,
                lightningFailedMessage: failed
            ),
            .idle
        )
        XCTAssertEqual(
            SonarMigrationModel.phaseAfterOpenStatus(
                state: .awaitingConsent,
                attemptAmountSats: 2_000,
                destConfirmedSats: dest,
                lightningFailedMessage: failed
            ),
            .idle
        )
        XCTAssertEqual(
            SonarMigrationModel.phaseAfterOpenStatus(
                state: .settled,
                attemptAmountSats: 2_000,
                destConfirmedSats: dest,
                lightningFailedMessage: failed
            ),
            .settled(cashuSats: dest)
        )
        XCTAssertEqual(
            SonarMigrationModel.phaseAfterOpenStatus(
                state: .sourceFailed,
                attemptAmountSats: 2_000,
                destConfirmedSats: dest,
                lightningFailedMessage: failed
            ),
            .failed(failed)
        )
        XCTAssertFalse(SonarMigrationModel.needsRescue(.settled))
    }

    func testSettledPhaseCarriesDestConfirmedSatsNotInvoice() {
        let invoice: UInt64 = 2_000
        let dest: UInt64 = 500
        XCTAssertEqual(
            SonarMigrationModel.phaseAfterOpenStatus(
                state: .settled,
                attemptAmountSats: invoice,
                destConfirmedSats: dest,
                lightningFailedMessage: "failed"
            ),
            .settled(cashuSats: dest)
        )
    }

    func testJournalBytesNeedRescueWithoutOpeningTheMint() {
        func journal(_ state: String) -> String {
            """
            {
              "version": 1,
              "account_fingerprint": "aa",
              "mint_fingerprint": "bb",
              "attempt": {
                "settlement_id": "qid",
                "invoice": "lnbc1",
                "payment_hash": "hh",
                "amount_sats": 2000,
                "source_fee_sats": 20,
                "expires_at_secs": null,
                "source_payment_id": null,
                "state": "\(state)"
              }
            }
            """
        }
        XCTAssertEqual(CashuMigrationStorage.journalAttemptStateName(journal("SourcePaid")), "SourcePaid")
        XCTAssertTrue(CashuMigrationStorage.journalNeedsRescue(journal("Sending")))
        XCTAssertTrue(CashuMigrationStorage.journalNeedsRescue(journal("PaymentUnknown")))
        XCTAssertTrue(CashuMigrationStorage.journalNeedsRescue(journal("SourcePaid")))
        XCTAssertFalse(CashuMigrationStorage.journalNeedsRescue(journal("AwaitingConsent")))
        XCTAssertFalse(CashuMigrationStorage.journalNeedsRescue(journal("Settled")))
        XCTAssertFalse(CashuMigrationStorage.journalNeedsRescue(journal("SourceFailed")))
        XCTAssertFalse(CashuMigrationStorage.journalNeedsRescue(nil))
        XCTAssertFalse(CashuMigrationStorage.journalNeedsRescue("{}"))
        XCTAssertFalse(CashuMigrationStorage.journalNeedsRescue(journal("NotAState")))
    }

    func testPaidJournalShowsOnHomeStripAfterRelaunch() {
        // Opposite of the live-payment H1 rule: a killed process with a
        // paid journal is exactly when the chat list has to offer rescue.
        XCTAssertTrue(CashuMigrationStorage.showsOnHomeStrip(walletReady: true, journalNeedsRescue: true))
        XCTAssertFalse(CashuMigrationStorage.showsOnHomeStrip(walletReady: false, journalNeedsRescue: true))
        XCTAssertFalse(CashuMigrationStorage.showsOnHomeStrip(walletReady: true, journalNeedsRescue: false))
        XCTAssertFalse(CashuMigrationStorage.showsOnHomeStrip(walletReady: false, journalNeedsRescue: false))
    }

    func testBackgroundRescueSkipsWhenStoreAlreadyOwned() async {
        let gate = CashuMigrationStoreGate()
        let acquired = await gate.tryAcquire()
        XCTAssertTrue(acquired)
        let second = await gate.tryAcquire()
        XCTAssertFalse(second, "a launch-time rescue must not open the store the screen owns")
        await gate.release()
        XCTAssertTrue(await gate.tryAcquire())
        await gate.release()
    }

    func testCancelledAcquireDoesNotKeepTheLock() async {
        let gate = CashuMigrationStoreGate()
        XCTAssertTrue(await gate.tryAcquire())
        let waiter = Task { await gate.acquire() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        waiter.cancel()
        await gate.release()
        let got = await waiter.value
        XCTAssertFalse(got, "a cancelled migration screen must not keep cashu.redb")
        XCTAssertTrue(await gate.tryAcquire(), "rescue must be able to take the lock after a cancelled waiter")
        await gate.release()
    }
}

@MainActor
final class BreezMigrationSourceTests: XCTestCase {
    func testBreezProseInsufficientFundsIsTheDrainSignal() {
        XCTAssertTrue(BreezMigrationSource.looksInsufficient("Cannot pay: not enough funds"))
        XCTAssertTrue(BreezMigrationSource.looksInsufficient("InsufficientFunds"))
        XCTAssertTrue(BreezMigrationSource.looksInsufficient("balance too low for this swap"))
        XCTAssertFalse(BreezMigrationSource.looksInsufficient("Boltz is unavailable"))
        XCTAssertFalse(BreezMigrationSource.looksInsufficient("timeout"))
    }

    func testAcceptedBreezSendWithoutPreimageIsPending() {
        XCTAssertFalse(BreezMigrationSource.hostSendReportsComplete(preimage: nil))
        XCTAssertFalse(BreezMigrationSource.hostSendReportsComplete(preimage: ""))
        XCTAssertTrue(BreezMigrationSource.hostSendReportsComplete(preimage: "00"))
    }

    func testHostWalletErrorInsufficientFundsLiftsAcrossUniffi() {
        XCTAssertThrowsError(
            try probeHostMigrationPrepare(
                source: InsufficientHost(),
                invoice: "lnbc1test",
                amountSats: 1_000
            )
        ) { error in
            XCTAssertEqual(error as? HostWalletError, .InsufficientFunds)
        }
    }

    func testHostWalletErrorFailedLiftsAcrossUniffi() {
        XCTAssertThrowsError(
            try probeHostMigrationPrepare(
                source: FailedHost(),
                invoice: "lnbc1test",
                amountSats: 1_000
            )
        ) { error in
            XCTAssertEqual(error as? HostWalletError, .Failed(reason: "bolt timeout"))
        }
    }
}

private final class InsufficientHost: HostMigrationSource, @unchecked Sendable {
    func balanceSats() throws -> UInt64 { 10_000 }
    func prepare(invoice: String, amountSats: UInt64) throws -> HostSendQuote {
        throw HostWalletError.InsufficientFunds
    }
    func send(token: String, note: String) throws -> HostPayment {
        throw HostWalletError.Failed(reason: "send must not run")
    }
    func lookupPayment(paymentHash: String) throws -> HostPaymentLookup {
        throw HostWalletError.Failed(reason: "lookup must not run")
    }
}

private final class FailedHost: HostMigrationSource, @unchecked Sendable {
    func balanceSats() throws -> UInt64 { 10_000 }
    func prepare(invoice: String, amountSats: UInt64) throws -> HostSendQuote {
        throw HostWalletError.Failed(reason: "bolt timeout")
    }
    func send(token: String, note: String) throws -> HostPayment {
        throw HostWalletError.Failed(reason: "send must not run")
    }
    func lookupPayment(paymentHash: String) throws -> HostPaymentLookup {
        throw HostWalletError.Failed(reason: "lookup must not run")
    }
}
