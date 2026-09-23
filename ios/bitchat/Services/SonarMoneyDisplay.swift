//
// SonarMoneyDisplay.swift
// bitchat
//
// Money display, independent of any wallet: the persisted fiat/bitcoin mode,
// the display currency, and the live Yadio rates behind every fiat figure.
//
// This used to live inside the Breez wallet (`display.mode` / `display.currency`
// in the Breez Keychain service, rates from the Breez SDK). Breez is now a
// legacy wallet the user can delete, and deleting it must never reset their
// currency — so the prefs live in UserDefaults, copied ONCE from the old
// Keychain items, and the rates come from the FFI `fetchFiatRates()` (Yadio,
// ~145 currencies) whether or not any wallet is open.
//
// Honesty rule (unchanged): fiat is shown only when the user picked fiat AND a
// live rate for their currency was fetched in this process. Otherwise amounts
// are grouped sats — never a bundled, cached or fake conversion.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Combine
import Foundation
import Security
import SonarCore

/// One fiat rate: fiat units per whole BTC.
struct SonarFiatRate: Equatable, Sendable {
    let currency: String
    let perBtc: Double
}

/// What the one-time read of the old Breez-owned display prefs found.
enum SonarLegacyMoneyPrefsRead: Equatable {
    /// The Keychain answered; either value may be absent.
    case found(mode: String?, currency: String?)
    /// The Keychain answered and holds neither item.
    case absent
    /// The Keychain could not be read (locked before first unlock, access
    /// error). The migration must NOT be marked done — retry next launch.
    case unavailable
}

@MainActor
final class SonarMoneyDisplay: ObservableObject {
    enum Keys {
        static let mode = "sonar.money.displayMode"
        static let currency = "sonar.money.displayCurrency"
        /// Set once the old Breez Keychain prefs were copied (or proven absent).
        static let migrated = "sonar.money.prefsMigrated.v1"
        /// Pre-existing key: the first-run "fiat in the locale currency"
        /// default has been applied. Kept so an upgrade does not re-default.
        static let defaulted = "sonar.money.defaulted"
    }

    /// The Breez Keychain service and item names the prefs used to live in.
    /// Read-only here; the legacy wallet owns deleting them.
    nonisolated static let legacyKeychainService = "chat.bitchat.sonar.wallet"
    nonisolated static let legacyModeAccount = "display.mode"
    nonisolated static let legacyCurrencyAccount = "display.currency"

    /// Offered in the picker before the first rate fetch lands, so it is
    /// never empty. Rates for them are still required before fiat shows.
    static let fallbackCurrencyCodes = ["USD", "EUR", "GBP", "CHF"]

    typealias RateFetcher = @Sendable () async throws -> [SonarFiatRate]

    @Published private(set) var displayMode: String
    @Published private(set) var displayCurrency: String
    /// True only after a live fetch in THIS process returned the selected
    /// currency.
    @Published private(set) var hasLiveRate = false
    /// Fires when the mode, currency, or live-rate availability changes.
    let changed = PassthroughSubject<Void, Never>()

    private var rates: [String: Double] = [:]
    private let defaults: UserDefaults
    private let fetchRates: RateFetcher
    private let locale: Locale
    private var refreshTask: Task<Void, Never>?
    private static let refreshInterval: UInt64 = 5 * 60 * 1_000_000_000

    init(
        defaults: UserDefaults = .standard,
        legacyPrefs: () -> SonarLegacyMoneyPrefsRead = SonarMoneyDisplay.readLegacyKeychainPrefs,
        fetchRates: @escaping RateFetcher = { try await SonarMoneyDisplay.fetchYadioRates() },
        locale: Locale = .current
    ) {
        self.defaults = defaults
        self.fetchRates = fetchRates
        self.locale = locale
        let resolved = Self.resolvePrefs(defaults: defaults, legacyPrefs: legacyPrefs, locale: locale)
        displayMode = resolved.mode
        displayCurrency = resolved.currency
    }

    // MARK: Prefs migration

    /// Resolve the display prefs, running the one-time copy out of the Breez
    /// Keychain first. Values already in UserDefaults always win; an
    /// unreadable Keychain leaves the migration pending and persists nothing,
    /// so a locked-device launch can never overwrite the user's real choice
    /// with a default.
    private static func resolvePrefs(
        defaults: UserDefaults,
        legacyPrefs: () -> SonarLegacyMoneyPrefsRead,
        locale: Locale
    ) -> (mode: String, currency: String) {
        var migrationSettled = defaults.bool(forKey: Keys.migrated)
        if !migrationSettled {
            switch legacyPrefs() {
            case .found(let mode, let currency):
                if defaults.string(forKey: Keys.mode) == nil, let mode = normalizedMode(mode) {
                    defaults.set(mode, forKey: Keys.mode)
                }
                if defaults.string(forKey: Keys.currency) == nil, let currency = normalizedCurrency(currency) {
                    defaults.set(currency, forKey: Keys.currency)
                }
                defaults.set(true, forKey: Keys.migrated)
                migrationSettled = true
            case .absent:
                defaults.set(true, forKey: Keys.migrated)
                migrationSettled = true
            case .unavailable:
                SecureLogger.warning(
                    "Money display: old wallet prefs unreadable; migration retried next launch",
                    category: .session
                )
            }
        }

        let storedMode = normalizedMode(defaults.string(forKey: Keys.mode))
        let storedCurrency = normalizedCurrency(defaults.string(forKey: Keys.currency))
        if let storedMode, let storedCurrency {
            return (storedMode, storedCurrency)
        }
        let localeCurrency = normalizedCurrency(locale.currency?.identifier) ?? "EUR"
        guard migrationSettled else {
            // Session-only defaults: nothing persisted until the old prefs
            // could be read.
            return (storedMode ?? "fiat", storedCurrency ?? localeCurrency)
        }
        if !defaults.bool(forKey: Keys.defaulted) {
            // First run ever: fiat in the device-locale currency.
            let mode = storedMode ?? "fiat"
            let currency = storedCurrency ?? localeCurrency
            defaults.set(mode, forKey: Keys.mode)
            defaults.set(currency, forKey: Keys.currency)
            defaults.set(true, forKey: Keys.defaulted)
            return (mode, currency)
        }
        // Defaulted before but a value is missing: the old SDK's own defaults.
        return (storedMode ?? "bitcoin", storedCurrency ?? "USD")
    }

    private static func normalizedMode(_ raw: String?) -> String? {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "fiat": return "fiat"
        case "bitcoin": return "bitcoin"
        default: return nil
        }
    }

    private static func normalizedCurrency(_ raw: String?) -> String? {
        guard let code = raw?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              code.count == 3, code.allSatisfy({ $0.isASCII && $0.isLetter })
        else { return nil }
        return code
    }

    /// Read the two old Breez Keychain items. `nonisolated` + no shared state:
    /// safe from init. A status other than success / not-found is
    /// `.unavailable`, never "absent".
    nonisolated static func readLegacyKeychainPrefs() -> SonarLegacyMoneyPrefsRead {
        enum Item { case value(String), missing, failed }
        func read(_ account: String) -> Item {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: legacyKeychainService,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                guard let data = result as? Data, let s = String(data: data, encoding: .utf8) else {
                    return .missing
                }
                return .value(s)
            case errSecItemNotFound:
                return .missing
            default:
                return .failed
            }
        }
        let mode = read(legacyModeAccount)
        let currency = read(legacyCurrencyAccount)
        switch (mode, currency) {
        case (.failed, _), (_, .failed):
            return .unavailable
        case (.missing, .missing):
            return .absent
        default:
            func value(_ item: Item) -> String? {
                if case .value(let s) = item { return s }
                return nil
            }
            return .found(mode: value(mode), currency: value(currency))
        }
    }

    // MARK: Prefs

    func setDisplayMode(_ mode: String) {
        guard let mode = Self.normalizedMode(mode), mode != displayMode else { return }
        displayMode = mode
        defaults.set(mode, forKey: Keys.mode)
        changed.send()
    }

    func setDisplayCurrency(_ code: String) {
        guard let code = Self.normalizedCurrency(code), code != displayCurrency else { return }
        displayCurrency = code
        defaults.set(code, forKey: Keys.currency)
        updateLiveRateFlag()
        changed.send()
        // A new currency may need a rate this process has not fetched yet.
        Task { await refreshRates() }
    }

    /// Currencies the picker offers: every currency the last fetch returned,
    /// else a small fallback list. The selected one is always included.
    func supportedCurrencies() -> [SonarCurrency] {
        var codes = rates.isEmpty ? Self.fallbackCurrencyCodes : rates.keys.sorted()
        if !codes.contains(displayCurrency) { codes.insert(displayCurrency, at: 0) }
        return codes.map(Self.currency(for:))
    }

    private static func currency(for code: String) -> SonarCurrency {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = code
        return SonarCurrency(code: code, symbol: f.currencySymbol ?? code, decimals: f.maximumFractionDigits)
    }

    // MARK: Formatting

    var effectiveShowsFiat: Bool { displayMode == "fiat" && hasLiveRate }

    /// The EFFECTIVE money string: fiat only when fiat mode AND a live rate
    /// for the selected currency exist; otherwise grouped sats.
    func format(sats: Int64) -> String {
        guard effectiveShowsFiat, let perBtc = rates[displayCurrency], perBtc > 0 else {
            return sonarFormatSats(sats)
        }
        let fiat = Double(sats) / 100_000_000.0 * perBtc
        return fiatFormatter().string(from: NSNumber(value: fiat)) ?? sonarFormatSats(sats)
    }

    /// One formatter per selected currency: `NumberFormatter` is expensive to
    /// allocate and `format` runs on render paths (the 1 Hz payment status).
    private var cachedFiatFormatter: (code: String, formatter: NumberFormatter)?

    private func fiatFormatter() -> NumberFormatter {
        if let cached = cachedFiatFormatter, cached.code == displayCurrency { return cached.formatter }
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = displayCurrency
        f.locale = locale
        cachedFiatFormatter = (displayCurrency, f)
        return f
    }

    /// Typed fiat text → sats at the live rate. Without a rate the text is
    /// read as sats (callers only offer fiat entry while `hasLiveRate`).
    func parseFiatInput(_ text: String, currencyCode: String) -> Int64 {
        let cleaned = text
            .replacingOccurrences(of: ",", with: ".")
            .filter { $0.isNumber || $0 == "." }
        guard let value = Double(cleaned), value.isFinite, value >= 0 else { return 0 }
        guard displayMode == "fiat",
              let perBtc = rates[currencyCode.uppercased()], perBtc > 0
        else { return Int64(value) }
        return Int64((value / perBtc * 100_000_000.0).rounded())
    }

    // MARK: Rates

    /// Apply a fetch result. Empty/failed fetches keep whatever this process
    /// already fetched live; they never invent a rate.
    func applyRates(_ fetched: [SonarFiatRate]) {
        guard !fetched.isEmpty else { return }
        var next: [String: Double] = [:]
        for rate in fetched where rate.perBtc.isFinite && rate.perBtc > 0 {
            next[rate.currency.uppercased()] = rate.perBtc
        }
        guard !next.isEmpty else { return }
        rates = next
        updateLiveRateFlag()
    }

    private func updateLiveRateFlag() {
        let live = rates[displayCurrency] != nil
        if live != hasLiveRate {
            hasLiveRate = live
            changed.send()
        }
    }

    func refreshRates() async {
        do {
            applyRates(try await fetchRates())
        } catch {
            SecureLogger.warning("Money display: rate fetch failed: \(error)", category: .session)
        }
    }

    /// Fetch now and every few minutes until `stopRefreshing()`. Called from
    /// the post-local-paint startup and on foreground — never on first paint.
    func startRefreshing() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshRates()
                try? await Task.sleep(nanoseconds: Self.refreshInterval)
            }
        }
    }

    func stopRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Panic wipe: forget the prefs (the next account starts from defaults).
    func wipe() {
        stopRefreshing()
        for key in [Keys.mode, Keys.currency, Keys.migrated, Keys.defaulted] {
            defaults.removeObject(forKey: key)
        }
        rates = [:]
        hasLiveRate = false
        displayMode = "fiat"
        displayCurrency = Self.normalizedCurrency(locale.currency?.identifier) ?? "EUR"
        changed.send()
    }

    /// Production fetcher: the blocking FFI call (≤10s) on a utility GCD
    /// queue — never the main thread, never the cooperative pool.
    nonisolated static func fetchYadioRates() async throws -> [SonarFiatRate] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let rates = try fetchFiatRates().map {
                        SonarFiatRate(currency: $0.currency, perBtc: $0.perBtc)
                    }
                    continuation.resume(returning: rates)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
