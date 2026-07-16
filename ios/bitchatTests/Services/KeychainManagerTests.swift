import Security
import XCTest
@testable import Sonar

final class KeychainManagerTests: XCTestCase {
    func testDeletionRequiresExplicitAbsenceVerification() {
        XCTAssertTrue(KeychainManager.deletionProvedAbsent(
            deleteStatus: errSecSuccess,
            verificationStatus: errSecItemNotFound
        ))
        XCTAssertTrue(KeychainManager.deletionProvedAbsent(
            deleteStatus: errSecItemNotFound,
            verificationStatus: errSecItemNotFound
        ))

        XCTAssertFalse(KeychainManager.deletionProvedAbsent(
            deleteStatus: errSecSuccess,
            verificationStatus: errSecSuccess
        ))
    }

    func testDeletionFailsClosedOnMissingEntitlement() {
        let missingEntitlement = OSStatus(-34018)

        XCTAssertFalse(KeychainManager.deletionProvedAbsent(
            deleteStatus: missingEntitlement,
            verificationStatus: errSecItemNotFound
        ))
        XCTAssertFalse(KeychainManager.deletionProvedAbsent(
            deleteStatus: errSecSuccess,
            verificationStatus: missingEntitlement
        ))
    }

    func testDeletionFailsClosedOnAccessAndAvailabilityErrors() {
        XCTAssertFalse(KeychainManager.deletionProvedAbsent(
            deleteStatus: errSecNotAvailable,
            verificationStatus: errSecItemNotFound
        ))
        XCTAssertFalse(KeychainManager.deletionProvedAbsent(
            deleteStatus: errSecSuccess,
            verificationStatus: errSecInteractionNotAllowed
        ))
    }

    func testUnconfiguredOptionalAccessGroupIsNotARequiredDeletionScope() {
        // The app declares an application group, but no
        // keychain-access-groups entitlement. That unrelated group must not be
        // queried and produce errSecMissingEntitlement during a valid wipe.
        XCTAssertEqual(
            KeychainManager.deletionScopeAccessGroups(configuredAccessGroups: []),
            [nil]
        )
        XCTAssertEqual(
            KeychainManager.deletionScopeAccessGroups(configuredAccessGroups: ["configured.group"]),
            [nil, "configured.group"]
        )
    }
}
