//
// SonarMoneyDisplayTests.swift
// bitchatTests
//
// Covers the effective money-display logic that hides the bitcoin/Lightning
// concept behind a fiat-by-default surface: amounts render as fiat ONLY when
// the user prefers fiat AND a live exchange rate exists; otherwise they fall
// back to honest grouped sats — never a bundled/fake fiat conversion. Plus
// the one-time move of the display prefs out of the (legacy) Breez Keychain
// service, so deleting that wallet never resets the user's currency. See
// bitchat/Services/SonarMoneyDisplay.swift.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Combine
import XCTest
@testable import Sonar

@MainActor
final class SonarMoneyDisplayTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "SonarMoneyDisplayTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func display(
        _ legacy: SonarLegacyMoneyPrefsRead = .absent,
        locale: Locale = Locale(identifier: "de_DE")
    ) -> SonarMoneyDisplay {
        SonarMoneyDisplay(
            defaults: defaults,
            legacyPrefs: { legacy },
            fetchRates: { [] },
            locale: locale
        )
    }

    // MARK: Prefs migration (Breez Keychain → UserDefaults)

    /// The user's choice in the old Breez Keychain items is copied once and
    /// then read from UserDefaults — deleting the legacy wallet (its Keychain
    /// service gone ⇒ `.absent`) no longer changes it.
    func testCurrencyPrefsSurviveThePrefsMigration() {
        let migrated = display(.found(mode: "bitcoin", currency: "chf"))
        XCTAssertEqual(migrated.displayMode, "bitcoin")
        XCTAssertEqual(migrated.displayCurrency, "CHF")
        XCTAssertTrue(defaults.bool(forKey: SonarMoneyDisplay.Keys.migrated))

        // Legacy wallet deleted: its Keychain items are gone.
        var legacyRead = false
        let afterDelete = SonarMoneyDisplay(
            defaults: defaults,
            legacyPrefs: { legacyRead = true; return .absent },
            fetchRates: { [] },
            locale: Locale(identifier: "de_DE")
        )
        XCTAssertFalse(legacyRead, "the migration runs once")
        XCTAssertEqual(afterDelete.displayMode, "bitcoin")
        XCTAssertEqual(afterDelete.displayCurrency, "CHF")
    }

    /// A locked / unreadable Keychain must not be mistaken for "no prefs":
    /// nothing is persisted and the copy is retried on the next launch.
    func testUnreadableKeychainDefersTheMigrationWithoutPersistingDefaults() {
        let locked = display(.unavailable)
        XCTAssertEqual(locked.displayMode, "fiat", "session-only default")
        XCTAssertFalse(defaults.bool(forKey: SonarMoneyDisplay.Keys.migrated))
        XCTAssertNil(defaults.string(forKey: SonarMoneyDisplay.Keys.mode))
        XCTAssertNil(defaults.string(forKey: SonarMoneyDisplay.Keys.currency))

        let unlocked = display(.found(mode: "bitcoin", currency: "GBP"))
        XCTAssertEqual(unlocked.displayMode, "bitcoin")
        XCTAssertEqual(unlocked.displayCurrency, "GBP")
    }

    /// Values already in UserDefaults win over the old Keychain copy.
    func testExistingPrefsWinOverTheLegacyCopy() {
        defaults.set("fiat", forKey: SonarMoneyDisplay.Keys.mode)
        defaults.set("JPY", forKey: SonarMoneyDisplay.Keys.currency)
        let d = display(.found(mode: "bitcoin", currency: "CHF"))
        XCTAssertEqual(d.displayMode, "fiat")
        XCTAssertEqual(d.displayCurrency, "JPY")
    }

    /// Fresh install: fiat in the device-locale currency, persisted once.
    func testFirstRunDefaultsToFiatInTheLocaleCurrency() {
        let d = display(.absent, locale: Locale(identifier: "de_DE"))
        XCTAssertEqual(d.displayMode, "fiat")
        XCTAssertEqual(d.displayCurrency, "EUR")
        XCTAssertTrue(defaults.bool(forKey: SonarMoneyDisplay.Keys.defaulted))
        d.setDisplayCurrency("usd")
        XCTAssertEqual(display(.absent).displayCurrency, "USD")
    }

    // MARK: Effective display (fiat only with a live rate)

    func testFiatShownOnlyWhenFiatModeAndLiveRate() {
        let d = display(.found(mode: "fiat", currency: "EUR"))
        XCTAssertFalse(d.effectiveShowsFiat, "no live rate yet")
        XCTAssertEqual(d.format(sats: 21_000), sonarFormatSats(21_000))

        d.applyRates([SonarFiatRate(currency: "EUR", perBtc: 100_000)])
        XCTAssertTrue(d.hasLiveRate)
        XCTAssertTrue(d.effectiveShowsFiat)
        XCTAssertFalse(d.format(sats: 21_000).hasSuffix("sats"))
        XCTAssertTrue(d.format(sats: 21_000).contains("21"), d.format(sats: 21_000))
    }

    func testSatsWhenBitcoinModeEvenWithLiveRate() {
        let d = display(.found(mode: "bitcoin", currency: "EUR"))
        d.applyRates([SonarFiatRate(currency: "EUR", perBtc: 100_000)])
        XCTAssertFalse(d.effectiveShowsFiat)
        XCTAssertEqual(d.format(sats: 21_000), sonarFormatSats(21_000))
    }

    func testRatesForOtherCurrenciesAreNotALiveRate() {
        let d = display(.found(mode: "fiat", currency: "CHF"))
        d.applyRates([SonarFiatRate(currency: "EUR", perBtc: 100_000)])
        XCTAssertFalse(d.hasLiveRate)
        XCTAssertEqual(d.format(sats: 5_000), sonarFormatSats(5_000))
        // An empty or failed fetch never invents a rate.
        d.applyRates([])
        XCTAssertFalse(d.hasLiveRate)
    }

    func testParseFiatInputUsesTheLiveRate() {
        let d = display(.found(mode: "fiat", currency: "EUR"))
        d.applyRates([SonarFiatRate(currency: "EUR", perBtc: 100_000)])
        // 1 EUR at 100k EUR/BTC = 1,000 sats.
        XCTAssertEqual(d.parseFiatInput("1", currencyCode: "EUR"), 1_000)
        XCTAssertEqual(d.parseFiatInput("0,5", currencyCode: "EUR"), 500)
    }

    // MARK: sonarFormatSats

    func testSonarFormatSatsGroupsAndLabels() {
        let s = sonarFormatSats(1_234_567)
        XCTAssertTrue(s.hasSuffix(" sats"))
        XCTAssertTrue(s.contains("1") && s.contains("234") && s.contains("567"))
        XCTAssertFalse(s.localizedCaseInsensitiveContains("BTC"))
        XCTAssertFalse(s.localizedCaseInsensitiveContains("lightning"))
    }

    func testSonarFormatSatsZero() {
        XCTAssertEqual(sonarFormatSats(0), "0 sats")
    }

    // MARK: UnconfiguredWallet is honest

    func testUnconfiguredWalletHasNoOfferAndRefusesToSend() async {
        let w = UnconfiguredWallet()
        XCTAssertEqual(w.state, .notConfigured)
        XCTAssertNil(w.cachedReceiveOffer)
        do {
            _ = try await w.send(destination: "lno1x", amountSats: 1, note: nil)
            XCTFail("an unconfigured wallet must not pretend to send")
        } catch {}
    }
}
