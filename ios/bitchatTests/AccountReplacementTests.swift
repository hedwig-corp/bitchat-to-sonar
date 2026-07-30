import XCTest
@testable import Sonar

/// Importing an `nsec` wipes wallet storage, host caches and the Marmot store
/// before restoring from Blossom. These pin the one input where that is
/// catastrophic — the key you are already signed in with — and the one where
/// refusing would break restore entirely.
///
/// Mirror of Compose `AccountReplacementTest`; keep the two in step.
final class AccountReplacementTests: XCTestCase {

    private let mine = "npub1vincenzo000000000000000000000000000000000000000000000000"
    private let theirs = "npub1someoneelse00000000000000000000000000000000000000000000"

    /// The whole reason this exists. Without it the import path wipes a live
    /// database and then restores whatever Blossom last held — or, for an
    /// account that never backed up, nothing at all.
    func testRePastingYourOwnKeyIsNotAReplacement() {
        XCTAssertFalse(shouldReplaceAccount(currentNpub: mine, incomingNpub: mine))
    }

    /// Whitespace from a paste must not turn a no-op into a wipe.
    func testSurroundingWhitespaceDoesNotDefeatTheGuard() {
        XCTAssertFalse(shouldReplaceAccount(currentNpub: mine, incomingNpub: "  \(mine)\n"))
        XCTAssertFalse(shouldReplaceAccount(currentNpub: " \(mine) ", incomingNpub: mine))
    }

    /// A genuine account switch must still replace, or the feature is dead.
    func testADifferentKeyReplacesTheAccount() {
        XCTAssertTrue(shouldReplaceAccount(currentNpub: mine, incomingNpub: theirs))
    }

    /// Onboarding and restore-on-a-new-phone have no current account. Refusing
    /// here would block the case backups exist for, so "unknown ⇒ replace" is
    /// correct — there is nothing on the device to lose.
    func testNoCurrentAccountReplaces() {
        XCTAssertTrue(shouldReplaceAccount(currentNpub: nil, incomingNpub: theirs))
        XCTAssertTrue(shouldReplaceAccount(currentNpub: "", incomingNpub: theirs))
        XCTAssertTrue(shouldReplaceAccount(currentNpub: "   ", incomingNpub: theirs))
    }

    /// Near-misses must replace. A guard that matched loosely would silently
    /// refuse a real account switch, which looks like the app ignoring you.
    func testAPrefixOrTruncationIsNotTheSameAccount() {
        XCTAssertTrue(shouldReplaceAccount(currentNpub: mine, incomingNpub: String(mine.dropLast())))
        XCTAssertTrue(shouldReplaceAccount(currentNpub: String(mine.dropLast()), incomingNpub: mine))
        XCTAssertTrue(shouldReplaceAccount(currentNpub: mine, incomingNpub: mine + "x"))
    }

    /// An unusable incoming key must never authorise a wipe. Callers validate
    /// the `nsec` first so this should be unreachable, but "replace the account
    /// based on nothing" is the one answer that can never be right.
    ///
    /// Found by mutation testing on the Compose mirror: an earlier draft
    /// returned `true` here, which would have wiped a live account.
    func testAnEmptyIncomingKeyNeverReplaces() {
        XCTAssertFalse(shouldReplaceAccount(currentNpub: mine, incomingNpub: ""))
        XCTAssertFalse(shouldReplaceAccount(currentNpub: mine, incomingNpub: "   "))
        XCTAssertFalse(shouldReplaceAccount(currentNpub: nil, incomingNpub: ""))
    }
}
