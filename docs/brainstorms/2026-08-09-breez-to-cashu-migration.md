# PR3: guided Breez→Cashu migration — orchestrator, FFI surface, and app UX

Date: 2026-08-09 · Status: clarified via /brainstorm (decisions from Vincenzo)
Depends on: PR #582 (`sonar-wallet-cdk`, **held for manual review — build now, open the PR only after #582 merges**).

## Clarified Problem Statement

**Goal:** Move a user's funds from the Breez Liquid wallet into the Cashu (CDK) wallet at `mint.hedwig.sh` as one guided, consented, crash-safe flow — a Rust migration orchestrator shared by both apps, surfaced through sonar-ffi, with the custody-change consent UI on iOS and Compose.

**Decisions taken (user answers, 2026-08-09):**
1. **Orchestrator + app UX in one train** ("Rust orchestrator + app UX now"): the orchestrator is pure Rust over two `dyn WalletBackend`s; PR3 also delivers the sonar-ffi surface for the CDK wallet, the UniFFI foreign-trait injection for the Breez side (apps implement it over their EXISTING native Breez integrations), and the consent/progress UI on both app surfaces. This front-runs the wallet part of the platform-cutover train deliberately.
2. **Single-shot drain**: one mint quote for (balance − fee headroom), one Breez send. Accepted tradeoff: all-or-nothing per attempt; mitigations below make a stuck attempt recoverable rather than lossy.
3. **Sequencing**: branch from the #582 head and build/test now (including live against `mint.hedwig.sh`); open the PR only after #582 passes manual review and merges — avoids the stacked-PR zero-CI trap (see memory: base ≠ main ⇒ no workflows fire).

**Feasibility fact that shaped the design (verified 2026-08-09):** `breez-sdk-liquid` + `cdk` (wallet-only features) **resolve in one cargo graph** — exactly one `libsqlite3-sys` (Breez's fork; CDK brings none). So the Breez island CAN host a binary linking both real backends. The island migration CLI is therefore the headless proving ground for the exact orchestrator code the apps will run — and the vehicle for the 2-shot live test *before* any app UX exists.

**Where each piece runs:**

| Piece | Home | Why |
|---|---|---|
| `MigrationEngine` (state machine) | new `core/sonar-wallet-migrate` crate (workspace member; depends only on `sonar-wallet`) | pure `dyn WalletBackend → dyn WalletBackend`; unit-testable with `MockWallet` pairs; no backend deps |
| `sonar-migrate-cli` | breez island (`sonar-wallet-breez/src/bin/`) | only place both REAL backends link together; runs the live 2-shot test end-to-end |
| CDK wallet FFI | `sonar-ffi` (uniffi Object wrapping `CdkWallet`) | CDK is sqlite-conflict-free, lives in-process with MDK/SQLCipher |
| Breez side in apps | UniFFI **foreign trait** (callback interface) `HostWalletBackend`, implemented in Swift/Kotlin over the existing native Breez SDK integrations | breez-rust can never enter sonar-ffi (links conflict); the native SDKs are already wired and battle-tested in both apps |
| Consent + progress UI | both apps (`ios/`, `apps/sonar/`) | Cross-Platform Feature Rule: user-facing feature ships on both surfaces |

**Constraints (must not break):**
- **Custody-change consent is explicit and blocking**: self-custodial Liquid → bearer proofs + mint trust. The consent screen names the mint, states that the mint holds the Lightning side, and that proofs live on-device (recoverable from nsec via NUT-13 against that mint). No silent migration, ever.
- **Crash-safety without a bespoke ledger**: both backends already persist the authoritative state. The engine derives progress from them — Breez's payment store (was the invoice paid?) and CDK's mint-quote store (quote exists / paid / minted; the #582 watcher mints on reconnect and NUT-13 restores from seed). A paid-but-unminted quote is recovered by CDK's own reconciliation. The engine adds only a thin journal (attempt id + quote id + amount) inside the CDK working dir for UX resume, never as the source of truth.
- **Fee discipline**: preflight `prepare_send` quote surfaced to the user with a hard cap; the fail-closed cap semantics from the CLIs carry over. Abort (no spend) if the quote fails or exceeds the cap.
- **Single-shot bounds**: refuse with a clear error when balance < Breez min-send or when (balance − fees) > mint max (500k sat at `mint.hedwig.sh`) — do NOT silently split; tell the user the bounds. (Auto-split is explicitly out of scope per decision 2.)
- **Boltz dependency surfaced**: the Breez leg is a swap; when the swap service is down the engine reports "swap service unavailable — retry later", it does not retry-loop.
- **Account Key Durability**: no new key material; both seeds derive from the nsec (`sonar-bolt12-v1`, `sonar-cashu-v1`). Migration must never touch or re-persist the nsec.
- **2-shot live-test budget still stands**: the island CLI runs the full protocol (all no-spend preflights, then shot 1 at minimum viable amount, verification gate, shot 2) BEFORE any app build ships the flow.

**Non-goals:**
- No auto-split/chunked drain (single shot chosen; revisit only if the bounds refusal proves painful).
- No third-party swap providers (SwapMarket/Coinos) anywhere in the product path — Breez's internal Boltz swap IS the Lightning leg.
- No reverse migration (Cashu→Breez) in this PR.
- No mint selection UI: `mint.hedwig.sh` is the configured mint; multi-mint is future work.
- No removal of the Breez wallet after migration — it stays until a deliberate later decision.

**Success criteria:**
- `MigrationEngine` state machine fully unit-tested over `MockWallet` pairs: happy path, fee-cap abort, mid-flight crash + resume (paid-but-unminted), quote-expiry, bounds refusals, mint-unreachable, swap-unavailable.
- `sonar-migrate-cli` completes a REAL small migration (shot 1) Breez→`mint.hedwig.sh` with the fee shown before spend, and survives a kill-mid-flight + rerun with no lost funds (CDK reconciliation mints the paid quote).
- Both apps: consent screen → fee preview → progress → done/failed-recoverable states; identical engine semantics because it IS the same engine.
- FFI: `SonarCashuWallet` + `HostWalletBackend` foreign trait + `MigrationEngine` exported; UniFFI checksums stable thereafter (doc-comment = ABI change — see memory).
- CI: engine crate in workspace tests; island CLI in the island job; app builds compile on both platforms' jobs.

## Approaches Considered

### Approach A: Rust orchestrator crate + island CLI only (v1 without app UX)
- Smallest reviewable unit; the CLI is the test vehicle; app UX deferred to the cutover PRs.
- Rejected by decision 1 — user wants the user-facing flow in this train.

### Approach B: Host-side orchestrators (Swift + Kotlin, twice)
- No new Rust; drives native Breez + CDK-via-FFI directly from each app.
- Rejected: money logic written twice is the mirror-pair drift disease this repo already documents (SonarAppState/SonarAppStore), applied to funds; no headless test path; the 2-shot budget cannot be spent on a flow that differs per platform.

### Approach C (CHOSEN): Rust orchestrator + FFI + app UX in one train
- Engine once in Rust, proven headlessly via the island CLI (both real backends in one process — feasibility verified), then surfaced through sonar-ffi with the Breez side injected as a host-implemented foreign trait, consent UI on both apps.
- Cost: the largest scope of the three (core + ffi + both apps); front-runs the wallet slice of the platform cutover. Accepted knowingly.
- Internal sequencing to keep it reviewable and to respect decision 3: staged commits (or stacked follow-up PRs after #582 merges) in this order — engine crate + tests → island CLI + live shot 1 → FFI surface → iOS UX → Compose UX. The live test gates everything after it.

## Recommendation

Approach C as decided. Build order matters more than PR boundaries: the engine and CLI land first and spend shot 1 of the live budget before any FFI or UI work begins, so the riskiest unknown (a real Breez→mint payment) is retired earliest and cheapest.

## Open questions (defer unless blocking)

- Foreign-trait shape: full `WalletBackend` mirrored over UniFFI, or a minimal `HostMigrationSource` (balance / prepare_send-equivalent / send / payment-status) — lean minimal; the engine only needs four calls from the Breez side.
- Fee headroom for the single shot: quote-then-adjust loop (quote for balance, subtract quoted fee, re-quote) vs a conservative fixed headroom — decide during implementation against real Breez quotes.
- Balance > mint-max UX copy: refuse with "migrate the remainder later" vs offering a second consented run — copy decision for the apps.
- Whether the NSE/notification path needs to know the migration happened (Breez webhook unregistration timing) — likely a follow-up with the Breez-retirement decision.
- Boltz health check pre-consent: worth a cheap probe before showing the fee screen so users don't consent into an immediate "swap unavailable".
