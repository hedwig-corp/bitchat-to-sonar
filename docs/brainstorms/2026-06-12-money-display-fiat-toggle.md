# Hide bitcoin/Lightning: fiat display + currency selector

Date: 2026-06-12
Status: clarified (brainstorm output, no code changes). Builds on PR #1 (commits on top).

## Context findings

- Sonar shows raw "sats" in many places: `SonarSettingsScreen` wallet row
  (`snPayFmt(balance) + " sats"`), `SonarPayViews` PaySheet (balance line, big
  amount, "sats" label, 1k/10k/21k chips, "Not enough sats"), the ⚡PAY
  sealed-coin bubbles, the Unify pay sheet, and setup copy that says
  "Lightning wallet" / "sats".
- Live fiat rates are NOT wired: `SonarWalletProviding.fiatText(forSats:)`
  returns nil; `SonarWallet`/`WalletBridgeService` expose no exchange rates.
- unify-wallet's money module already has `BitcoinAmount`, `ExchangeRate`,
  `FiatCurrency`, `AmountDisplayFormatter`, `CurrencyPreferenceRepository`, and
  live rates via Breez `WalletService.exchangeRates()` (`sdk.fetchFiatRates()`).

## Decisions taken (user, 2026-06-12)

- Input unit: **fiat entry too** (Unify parity) — a toggle inverts the keypad
  unit; fiat is converted to sats at the live rate (with rounding). Sats stays
  the on-wire unit.
- Default display: **fiat by default** (fall back to sats until a live rate
  exists).
- De-jargon: **hide all bitcoin/Lightning jargon** on default surfaces
  ("Balance", "Send money", chosen currency); "bitcoin/sats" only in the
  toggle + advanced settings; drop "Lightning/BOLT12".
- **Implementation = Approach B (chosen by the user, 2026-06-12):** reuse
  unify's money module rather than reimplement formatting in Swift. Treat the
  already-extracted KMP wallet code (`SonarWalletKit`, from unify-wallet) as a
  shared **Unify Wallet SDK** that Sonar consumes — export and reuse
  `BitcoinAmount`, `ExchangeRate`, `FiatCurrency`, `AmountDisplayFormatter`,
  `CurrencyPreferenceRepository`. Don't duplicate tested logic; the Swift UI
  renders the SDK's formatted output and forwards user input. Rationale: we
  already maintain the KMP framework, so the money module is a small additive
  export; this keeps Sonar and Unify consistent and centralizes money logic in
  one audited place. (Naming the shared library "Unify Wallet SDK" vs keeping
  `SonarWalletKit` is a separate, deferrable decision — see open questions.)

## Clarified Problem Statement

**Goal:** Make payments feel like plain money — balance and amounts shown by
default in the user's chosen fiat currency, with a "show in bitcoin" toggle,
fiat amount entry, and bitcoin/Lightning jargon hidden from default surfaces.

**Constraints:**
- Live fiat rates from Breez (`fetchFiatRates`, exposed via the wallet-kit);
  persisted currency + display-mode preference.
- Format applied everywhere amounts appear: wallet row, PaySheet (balance, big
  amount, chips, "Not enough"), ⚡PAY bubbles, Unify pay sheet.
- Fiat entry → fiat→sats conversion at the live rate with explicit rounding;
  bitcoin (sats) stays the unit actually sent.
- Honest fallback when no rate: show/enter in sats until a rate is available
  (never a fake rate).
- Wording: "Balance", "Send money", chosen currency; "bitcoin/sats" only in the
  toggle + advanced; drop "Lightning/BOLT12".
- 1:1 design (gold = money). Commits on top of PR #1.

**Non-goals:**
- Price charts, rate history, multi-wallet.
- Changing the on-wire unit (stays sats/BOLT12 underneath).

**Success criteria:**
- First launch: balance in local currency; Settings toggle flips to bitcoin and
  back; currency selector works and persists.
- In the PaySheet I can type EUR 2.00 → send the equivalent sats at the live
  rate; or invert and type sats.
- No "sats/Lightning/BOLT12" on default surfaces.
- No rate/offline: degrades to sats without crashing.

## Approaches Considered

### Approach A: Swift money layer fed by Breez rates
- Sketch: expose `exchangeRates()` (currency code → rate) and the supported
  currency list from the wallet-kit (Breez `fetchFiatRates`); `WalletBridgeService`
  fetches + caches; a Swift `SonarMoney` does conversion/format (sats↔fiat) with
  `NumberFormatter`; the preference (mode + currency) lives in `SonarAppStore`.
- Affected: `localPackages/SonarWalletKit/Sources/SonarWallet.swift` +
  `IosWalletBridge.kt` (new `exchangeRates`/`supportedCurrencies`),
  `WalletBridgeService.swift`, `SonarWalletStore.swift` (extend
  `SonarWalletProviding` with format/convert/displayMode/currency),
  `SonarAppStore.swift`, `SonarSettingsScreen.swift` (toggle + picker),
  `SonarPayViews.swift` (format everywhere + fiat input), de-jargon copy.
- Tradeoffs: Swift owns UI + preference; idiomatic currency formatting, no
  formatted-string round-trips over FFI. Minimal new Kotlin (just rates). Reuses
  Breez but not unify's `AmountDisplayFormatter`.
- Effort: M.

### Approach B: Reuse unify's Kotlin money module (format in Kotlin)
- Sketch: export `BitcoinAmount/ExchangeRate/FiatCurrency/AmountDisplayFormatter/
  CurrencyPreferenceRepository` via SonarWalletKit; convert + format in Kotlin,
  expose pre-formatted strings to Swift.
- Affected: SonarWalletKit (broad export) + `WalletBridgeService` + UI.
- Tradeoffs: maximum reuse of unify's tested logic (consistency with Unify). But
  pushing formatted strings + a preference across the FFI is awkward, the
  xcframework grows, and the Swift UI loses control over format/locale.
- Effort: M/L.

### Approach C: Hybrid — rates + currency list from Kotlin, format/preference in Swift
- Sketch: like A for format/preference (Swift), but take the currency list +
  decimals from unify's `FiatCurrency` for consistency, alongside the rates.
- Affected: like A, plus a small `FiatCurrency` export.
- Tradeoffs: currency-set consistency with Unify without porting the formatter to
  Kotlin. Marginal over A.
- Effort: M.

## Decision: Approach B (reuse the unify money module as a shared SDK)

Chosen by the user (2026-06-12), overriding the original A recommendation. We
already extracted unify-wallet into the KMP `SonarWalletKit` framework, so the
money module is a small additive export — reimplementing it in Swift (A) would
duplicate tested logic and diverge from Unify. Treat `SonarWalletKit` as the
shared **Unify Wallet SDK**.

How the FFI concern is handled cleanly (the only real cost of B):
- Export `BitcoinAmount`, `ExchangeRate`, `FiatCurrency`, `AmountDisplayFormatter`,
  `CurrencyPreferenceRepository` through `SonarWalletKit`; add bridge methods on
  `IosWalletBridge`: `supportedCurrencies()`, `setDisplayCurrency`/`displayMode`
  (persisted via the already-injected `KeyValueStore` — the preference lives in
  the SDK), `formatAmount(sats, mode)` → display string, `parseFiatInput(text,
  currency)` → sats (the fiat→sats conversion + rounding), and a balance/amount
  formatter that uses live Breez rates (`exchangeRates()`).
- Swift renders the SDK's formatted strings and forwards keypad input; it does
  NOT format money itself. The UI only owns layout + the toggle/picker controls.

Original A/C analysis retained above for the record; B wins on reuse +
Unify consistency now that the shared framework exists.

## Resolved (user, 2026-06-12)

- "bitcoin" unit = **sats** (no BTC switch for now).
- Offline / no live rate = **show sats, no fiat conversion** (never a fake or
  stale rate; the fiat-entry toggle is disabled until a rate is available).
- Currency set = **all currencies Breez returns, default = device-locale
  currency**, searchable picker.
- fiat→sats entry = **show the actual sats before sending** (confirm).

## Open questions (non-blocking)

- SDK naming: keep `SonarWalletKit`, or rename the shared library to "Unify
  Wallet SDK" and publish it standalone? Deferrable — the export works under
  either name and does not block this feature.
