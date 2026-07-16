//
// SonarPushRegistrationTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(iOS) || os(macOS)

import XCTest
@testable import Sonar

final class SonarPushRegistrationTests: XCTestCase {

    func testInstallationDeviceIdPersistsAcrossTokenRotation() throws {
        let keychain = MockKeychain()
        let expected = "550e8400-e29b-41d4-a716-446655440000"

        let first = SonarPushRegistration.loadOrCreateInstallationDeviceId(
            keychain: keychain,
            makeId: { expected }
        )
        let second = SonarPushRegistration.loadOrCreateInstallationDeviceId(
            keychain: keychain,
            makeId: {
                XCTFail("persisted installation id should be reused")
                return "00000000-0000-0000-0000-000000000000"
            }
        )

        XCTAssertEqual(first, expected)
        XCTAssertEqual(second, expected)
    }

    func testInstallationDeviceIdDefersOnKeychainReadFailure() {
        let keychain = MockKeychain()
        keychain.simulatedReadError = .deviceLocked

        XCTAssertNil(SonarPushRegistration.loadOrCreateInstallationDeviceId(
            keychain: keychain,
            makeId: {
                XCTFail("must not mint an unstable id while Keychain is unavailable")
                return UUID().uuidString
            }
        ))
    }

    func testInstallationDeviceIdReplacesCorruptStoredValue() {
        let keychain = MockKeychain()
        XCTAssertTrue(
            keychain.saveIdentityKey(
                Data("not-a-uuid".utf8),
                forKey: "sonar-push-installation-id"
            )
        )
        let expected = "550e8400-e29b-41d4-a716-446655440000"

        XCTAssertEqual(
            SonarPushRegistration.loadOrCreateInstallationDeviceId(
                keychain: keychain,
                makeId: { expected }
            ),
            expected
        )
    }

    func testNormalizedNdsUrlFallsBackForMissingOrTruncatedValues() {
        XCTAssertEqual(
            SonarPushRegistration.normalizedNdsUrl(nil),
            "https://nds.sonar.hedwig.sh"
        )
        XCTAssertEqual(
            SonarPushRegistration.normalizedNdsUrl("https:"),
            "https://nds.sonar.hedwig.sh"
        )
        XCTAssertEqual(
            SonarPushRegistration.normalizedNdsUrl("http:"),
            "https://nds.sonar.hedwig.sh"
        )
    }

    func testNormalizedNdsUrlUpgradesHttpToHttps() {
        XCTAssertEqual(
            SonarPushRegistration.normalizedNdsUrl("http://nds.sonar.hedwig.sh"),
            "https://nds.sonar.hedwig.sh"
        )
        XCTAssertEqual(
            SonarPushRegistration.normalizedNdsUrl("http://nds.sonar.hedwig.sh/custom"),
            "https://nds.sonar.hedwig.sh/custom"
        )
    }

    func testNormalizedNdsUrlPrependsHttpsForBareHost() {
        XCTAssertEqual(
            SonarPushRegistration.normalizedNdsUrl("nds.sonar.hedwig.sh"),
            "https://nds.sonar.hedwig.sh"
        )
    }

    func testWebhookUrlBuildsHttpsNotifyEndpoint() throws {
        let url = try XCTUnwrap(SonarPushRegistration.webhookUrl(
            ndsUrl: "https://nds.sonar.hedwig.sh",
            platform: "ios",
            fcmToken: "token/value"
        ))
        let components = try XCTUnwrap(URLComponents(string: url))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "nds.sonar.hedwig.sh")
        XCTAssertEqual(components.path, "/api/v1/notify")
        XCTAssertTrue(components.queryItems?.contains(URLQueryItem(name: "platform", value: "ios")) == true)
        XCTAssertTrue(components.queryItems?.contains(URLQueryItem(name: "token", value: "token/value")) == true)
    }

    func testWebhookUrlRejectsHttp() {
        XCTAssertNil(SonarPushRegistration.webhookUrl(
            ndsUrl: "http://nds.sonar.hedwig.sh",
            platform: "ios",
            fcmToken: "token"
        ))
    }
}

#endif
