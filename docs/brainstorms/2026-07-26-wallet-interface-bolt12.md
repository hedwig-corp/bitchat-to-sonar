# Wallet interface in a new `sonar-wallet` crate (BOLT12), Breez as first impl

Date: 2026-07-26 · Status: clarified via /brainstorm (answers from Vincenzo)

## Clarified Problem Statement

**Goal:** Introduce a backend-agnostic wallet interface in a new Rust crate `core/sonar-wallet`, covering the full wallet lifecycle, with the Breez SDK Liquid Rust crate as the first implementation — so the wallet backend can later be swapped (Cashu via CDK is the named candidate) without touching app code.

**Current state (grounded):**
- No wallet code exists in `core/` today. Breez SDK Liquid **0.12.4** is integrated three separate times, once per surface:
  - iOS: `ios/localPackages/SonarWalletKit/Sources/SonarWallet.swift` (Swift package `breez-sdk-liquid-swift`), driven by `ios/bitchat/Services/WalletBridgeService.swift` + `SonarWalletStore.swift`.
  - Android + desktop JVM: `apps/sonar/.../wallet/WalletBridge.kt` (`expect object`) with `WalletBridge.android.kt` / `WalletBridge.jvm.kt` actuals over the `technology.breez.liquid:breez-sdk-liquid-kmp` artifact.
  - iOS notification extension: `ios/SonarNotificationService/NotificationService.swift` runs BreezSDKLiquid **in the extension process** for offline BOLT12 / NDS wakes.
- Breez SDK Liquid is itself a Rust crate, so a single Rust-core implementation is feasible and retires three parallel bindings.

**Decisions taken (user answers):**
1. **Impl home:** new `core/sonar-wallet` crate — trait + Breez impl (feature-gated), consumed by `sonar-core`/`sonar-ffi`. Keeps wallet deps out of sonar-core's build graph.
2. **Scope:** full wallet lifecycle — seed create/restore from nsec, connect/disconnect, balance, BOLT12 offer create/cache, parse destination, send, payment event stream, fiat rates, webhook register/unregister, wipe.
3. **Swap target:** **Cashu via CDK** (plus "no specific target" hedge). This forces capability gating: ecash has no node start/stop, no NDS webhook, mint-mediated BOLT12, balance = sum of proofs.
4. **Rollout:** all platforms in one change-train, explicitly overriding the standing "no iOS/macOS work" default for this feature.

**Constraints (must not break):**
- **Account Key Durability Rule:** seed is nsec-derived; the trait must take entropy/seed *in* and never own OS keychain storage. Keychain/app-group sync (`syncCredsToAppGroup`) stays platform-side.
- **0xdead10cc lineage** (#134, #174, #448): foreground-only node start, close-on-background-wake, serial-queue close ordering, DB file-protection class. The Rust impl must expose lifecycle hooks (`connect`/`disconnect` fast paths) that let platforms keep this exact behavior.
- **iOS NSE offline-payment path:** the extension must still answer BOLT12 invoice_requests while the main app is dead. If the wallet moves behind sonarffi, the NSE must link the same framework and share the working dir cross-process — the historical SIGBUS/0xdead10cc source. This is the highest-risk single item.
- **Breez NDS webhook** registration (`NDS_URL`) is Breez-specific → capability-gated in the trait, not core surface.
- Local Secrets Rule: `BREEZ_API_KEY` flows through config as today.
- `core/build-ios.sh` / `build-android.sh` / desktop dylib must build `breez-sdk-liquid` for every target; binary-size delta to be measured.

**Non-goals:**
- No Cashu/CDK implementation in this change — only a trait shaped so CDK fits without rewrite.
- No UX changes to pay/receive flows; `SonarPayViews.swift` / Compose wallet screens keep their contracts.
- No change to PAYDONE/⚡ mesh payment signaling or `sonar-status`.
- No multi-wallet (simultaneous backends); selection is compile-time/config, one active backend.

**Success criteria:**
- `sonar-wallet` crate: `trait Wallet` (or `WalletBackend`) + `BreezWallet` impl + `WalletCapabilities`; unit tests against the trait; Breez impl integration-tested via `sonar-cli` (regtest/testnet where possible).
- All three surfaces drive the wallet through one UniFFI object; Swift/KMP/dylib Breez dependencies removed from app builds.
- iOS NSE offline BOLT12 receive still works (synthetic webhook test recipe from PR #179 memory).
- Cold-start bench (`scripts/bench/`) shows no regression on the startup path; wallet init stays off the chat-open critical path.
- No regression in R-ledger invariants; killed-app BOLT12 round-trip re-verified on Android (PR #295 recipe).

## Approaches Considered

### Approach A: Big-bang — crate + FFI + all three app migrations in one PR train, merged together
- Sketch: land `sonar-wallet`, expose via `sonar-ffi`, rewrite `SonarWalletKit`, `WalletBridge.*`, and the NSE in one release train; ship when all platforms pass.
- Tradeoffs: single review context, no dual-maintenance window; but the NSE/0xdead10cc surface, three build systems, and bench verification in one train makes an enormous, hard-to-bisect change. History (#134→#448) says background lifecycle bugs surface on devices over weeks.
- Effort: L (single multi-PR train, ~weeks)

### Approach B: Interface-first strangler — crate lands with Breez Rust impl; platforms cut over in ordered PRs within one train (desktop → Android → iOS app → iOS NSE)
- Sketch: PR1 `sonar-wallet` crate + trait + BreezWallet + tests + `sonar-cli wallet` subcommand (headless proof). PR2 sonar-ffi surface + desktop JVM cutover (already dylib-shaped, lowest risk). PR3 Android `WalletBridge.android` → FFI. PR4 iOS app (`SonarWalletKit` becomes a shim over sonarffi, lifecycle gating preserved). PR5 NSE cross-process path + killed-app verification.
- Affected: `core/sonar-wallet` (new), `core/sonar-ffi/src/lib.rs`, `core/build-*.sh`, `apps/sonar/.../wallet/*`, `ios/localPackages/SonarWalletKit/*`, `ios/SonarNotificationService/NotificationService.swift`.
- Tradeoffs: each step independently verifiable with the existing device-test recipes; brief window where iOS still runs native Breez (both impls pinned to 0.12.4 so wire behavior is identical). Slightly more total PR overhead.
- Effort: L overall, but decomposed into S/M steps

### Approach C: Contract-only first — trait in core, existing native bridges implement it via UniFFI foreign traits; Rust Breez impl later
- Sketch: define the trait + capabilities in `sonar-wallet`, expose as a UniFFI callback interface; Swift/Kotlin Breez bridges implement it; core gains the seam immediately with zero wallet-behavior change; the Rust Breez impl replaces the callbacks later.
- Tradeoffs: lowest immediate risk and the seam exists on day one; but keeps three Breez integrations alive indefinitely, adds a fourth surface (the callback layer), and double churn on every platform. Doesn't actually deliver "swap the implementation" until the second migration happens anyway.
- Effort: M now + L later (more total than B)

## Recommendation

**Approach B.** It satisfies "all platforms in one change" at the feature level (one train, one tracked completion) while keeping each cutover independently testable with the recipes this repo already has (killed-app BOLT12 synthetic webhook, device bench, NSE log capture). The NSE cross-process step — the riskiest — lands last, isolated, when the Rust impl is already proven on three surfaces. Approach A makes the 0xdead10cc class of bugs impossible to bisect; Approach C pays for the migration twice.

## Trait-shape notes for the Cashu future (design inputs, not scope)

- `WalletCapabilities { webhook: bool, node_lifecycle: bool, fiat_rates: bool, max_receivable: … }` — Breez=all true; CDK=webhook false, lifecycle trivial.
- Lifecycle verbs are `connect()/disconnect()` (fast, idempotent), not `start_node/stop_node` — Breez impl maps them to node start/stop with the existing foreground gating driven from the platform.
- Balance is a struct (`confirmed`, `pending_receive`, `pending_send`) — maps to Breez pending swaps and to Cashu pending mint/melt quotes.
- BOLT12 receive is `receive_offer() -> String` regardless of whether the offer comes from the node (Breez) or a mint (CDK BOLT12 quotes).
- Fee/limits query is its own method returning backend-specific ranges, since Liquid swap limits ≠ mint melt fees.
- Seed/entropy is an input parameter; storage stays with the caller (Account Key Durability Rule).

## Open questions (defer unless blocking)

- NSE process model: link full `sonarffi` in the extension (size/memory budget: NSE has ~24 MB) vs a slim `sonar-wallet`-only FFI target. Measure before PR5.
- Does `breez-sdk-liquid` 0.12.x build cleanly for all our targets (ios-sim arm64, android armv7!, desktop x86_64) inside `core/build-*.sh`? armv7 release APK support needs checking.
- Fiat-rate caching + display prefs: move into the crate (decision says full lifecycle) or leave display formatting platform-side and move only rate *fetching*? Lean: fetch in crate, format in apps.
- Wallet DB file location + protection class ownership when Rust owns the DB (today `applyDatabaseProtection` is Swift).
- `sonar-sim`/bench: add a wallet-init marker so the startup-path guarantee is enforced, not assumed.
