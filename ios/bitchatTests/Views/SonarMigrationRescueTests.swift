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
}
