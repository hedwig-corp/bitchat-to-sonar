//
// SonarMoneyDisplayTests.swift
// bitchatTests
//
// Covers the effective money-display logic that hides the bitcoin/Lightning
// concept behind a fiat-by-default surface: amounts render as fiat ONLY when
// the user prefers fiat AND a live exchange rate exists; otherwise they fall
// back to honest grouped sats — never a bundled/fake fiat conversion. See
// bitchat/Views/Sonar/SonarWalletStore.swift.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Combine
import XCTest
@testable import Sonar

final class SonarMoneyDisplayTests: XCTestCase {

    /// Test double for `SonarWalletProviding` with toggleable mode/rate, so we
    /// can assert the effective-display matrix without the Breez SDK. The fiat
    /// formatter here is a stand-in for the SDK's converter — the test asserts
    /// *which* path is taken (fiat vs sats), not the SDK's exact formatting.
    private final class FakeWallet: SonarWalletProviding {
        var displayMode: String
        var hasLiveRate: Bool
        var displayCurrency: String = "EUR"
        /// Pretend "live" rate: 1000 sats == 1 unit of fiat.
        private let satsPerFiatUnit: Int64 = 1000

        init(displayMode: String, hasLiveRate: Bool) {
            self.displayMode = displayMode
            self.hasLiveRate = hasLiveRate
        }

        let state: SonarWalletState = .ready(balanceSats: 0)
        var statePublisher: AnyPublisher<SonarWalletState, Never> {
            Just(state).eraseToAnyPublisher()
        }
        func send(destination: String, amountSats: Int64, note: String?) async throws -> SonarWalletPayment {
            SonarWalletPayment(id: "fake", amountSats: amountSats, isIncoming: false, timestamp: Date(), note: note)
        }
        func createOffer() async throws -> String { "lno1fake" }

        func setDisplayMode(_ mode: String) async { displayMode = mode }
        func setDisplayCurrency(_ code: String) async { displayCurrency = code }
        func supportedCurrencies() -> [SonarCurrency] {
            [SonarCurrency(code: "EUR", symbol: "\u{20AC}", decimals: 2)]
        }

        func format(sats: Int64) -> String {
            // Mirror the production rule: fiat only when fiat-mode AND live.
            guard displayMode == "fiat", hasLiveRate else { return sonarFormatSats(sats) }
            let units = Double(sats) / Double(satsPerFiatUnit)
            return "\u{20AC}\(String(format: "%.2f", units))"
        }

        func parseFiatInput(_ text: String, currencyCode: String) -> Int64 {
            let units = Double(text.filter { $0.isNumber || $0 == "." }) ?? 0
            return Int64(units * Double(satsPerFiatUnit))
        }

        var moneyDisplayChanged: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }
    }

    // MARK: effectiveShowsFiat matrix

    func testFiatShownOnlyWhenFiatModeAndLiveRate() {
        XCTAssertTrue(FakeWallet(displayMode: "fiat", hasLiveRate: true).effectiveShowsFiat)
    }

    func testSatsWhenFiatModeButNoLiveRate() {
        // Offline / no rate: must NOT show a fabricated fiat figure.
        XCTAssertFalse(FakeWallet(displayMode: "fiat", hasLiveRate: false).effectiveShowsFiat)
    }

    func testSatsWhenBitcoinModeEvenWithLiveRate() {
        XCTAssertFalse(FakeWallet(displayMode: "bitcoin", hasLiveRate: true).effectiveShowsFiat)
    }

    func testSatsWhenBitcoinModeAndNoRate() {
        XCTAssertFalse(FakeWallet(displayMode: "bitcoin", hasLiveRate: false).effectiveShowsFiat)
    }

    // MARK: format(sats:) follows the effective mode

    func testFormatRendersFiatWhenLiveFiat() {
        let w = FakeWallet(displayMode: "fiat", hasLiveRate: true)
        XCTAssertEqual(w.format(sats: 21_000), "\u{20AC}21.00")
    }

    func testFormatRendersSatsWhenOfflineDespiteFiatMode() {
        let w = FakeWallet(displayMode: "fiat", hasLiveRate: false)
        XCTAssertEqual(w.format(sats: 21_000), sonarFormatSats(21_000))
        XCTAssertTrue(w.format(sats: 21_000).hasSuffix("sats"))
    }

    func testFormatRendersSatsInBitcoinMode() {
        let w = FakeWallet(displayMode: "bitcoin", hasLiveRate: true)
        XCTAssertEqual(w.format(sats: 21_000), sonarFormatSats(21_000))
    }

    // MARK: sonarFormatSats — the only Swift-side money formatting

    func testSonarFormatSatsGroupsAndLabels() {
        // 1,234,567 sats — grouped with the locale separator, labelled "sats".
        let s = sonarFormatSats(1_234_567)
        XCTAssertTrue(s.hasSuffix(" sats"))
        XCTAssertTrue(s.contains("1") && s.contains("234") && s.contains("567"))
        // No bitcoin/Lightning jargon leaks into the formatted amount.
        XCTAssertFalse(s.localizedCaseInsensitiveContains("BTC"))
        XCTAssertFalse(s.localizedCaseInsensitiveContains("lightning"))
    }

    func testSonarFormatSatsZero() {
        XCTAssertEqual(sonarFormatSats(0), "0 sats")
    }

    // MARK: UnconfiguredWallet is honest — always sats, never fiat

    func testUnconfiguredWalletNeverShowsFiat() {
        let w = UnconfiguredWallet()
        XCTAssertFalse(w.effectiveShowsFiat)
        XCTAssertFalse(w.hasLiveRate)
        XCTAssertEqual(w.format(sats: 5_000), sonarFormatSats(5_000))
        XCTAssertTrue(w.supportedCurrencies().isEmpty)
    }
}
