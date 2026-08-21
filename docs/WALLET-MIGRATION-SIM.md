# Simulating the Breez→Cashu migration (no real funds)

The live migration is a one-way spend of real money, and the test budget is
small. This harness runs the **same engine, the same consent gates, and the
same settlement loop** against two throwaway Cashu mints with fake Lightning
backends, so the whole flow can be exercised repeatedly for free before any
real sats move.

`sonar-migrate-cli` picks its source in exactly one place; everything
downstream takes `&dyn WalletBackend`. `--source-mint` swaps the Breez source
for a Cashu one and changes nothing else.

## Run it

Two mints (source and destination) with nutshell's `FakeWallet` backend:

```bash
docker run -d --name sim-mint-src -p 3338:3338 \
  -e MINT_BACKEND_BOLT11_SAT=FakeWallet \
  -e MINT_LISTEN_HOST=0.0.0.0 -e MINT_LISTEN_PORT=3338 \
  -e MINT_PRIVATE_KEY=sim-source-mint-key-do-not-use-for-real-funds \
  cashubtc/nutshell:latest poetry run mint

docker run -d --name sim-mint-dst -p 3339:3339 \
  -e MINT_BACKEND_BOLT11_SAT=FakeWallet \
  -e MINT_LISTEN_HOST=0.0.0.0 -e MINT_LISTEN_PORT=3339 \
  -e MINT_PRIVATE_KEY=sim-dest-mint-key-do-not-use-for-real-funds \
  cashubtc/nutshell:latest poetry run mint
```

Then, from `core/sonar-wallet-breez`, with a **throwaway** key — never the real
account nsec, since the CDK store binds to the account it was created with:

```bash
export SONAR_NSEC=$(openssl rand -hex 32)
BIN=./target/debug/sonar-migrate-cli
ARGS=(--source-mint http://localhost:3338 --mint http://localhost:3339
      --source-cashu-dir /tmp/sim/src --cashu-dir /tmp/sim/dst)

"$BIN" "${ARGS[@]}" sim-fund --amount-sats 5000     # receives only, never spends
"$BIN" "${ARGS[@]}" status
"$BIN" "${ARGS[@]}" quote --amount-sats 2000        # prices it, spends nothing
"$BIN" "${ARGS[@]}" migrate --amount-sats 2000 --max-fee-sats 50 --accept-custody-change
"$BIN" "${ARGS[@]}" settle --settle-polls 24         # resume only; never spends
```

Tear down with `docker rm -f sim-mint-src sim-mint-dst`.

## Durable journal and exact resume

The destination working directory contains `cashu.migration.v1.json`. It is an
account-and-mint-bound, atomically replaced journal; corrupt, unsupported, or
misbound bytes fail closed instead of looking like "no migration". The state
machine is:

`AwaitingConsent` → `Sending` → `PaymentUnknown` / `SourcePending` /
`SourcePaid` → `MintPaid` → `Settled`.

`SourceFailed` and `ExpiredUnsent` are terminal no-spend states. Before calling
the source wallet, the engine writes `Sending`, fsyncs the file, renames it, and
fsyncs the parent directory. A restart therefore cannot call `send` again: it
must first look up the journaled `payment_hash`. Once `execute_once` returns
from the source call, the CLI prints the journal's `settlement_id`,
`payment_hash`, state, and resume command before it starts the settlement watch.
That resume record is also printed when the source returned an ambiguous error.

`status` reads the journal. `settle` takes only `--settle-polls`; it resumes the
journaled attempt and does not accept a baseline-balance argument. Source
reconciliation uses `HostMigrationSource.lookup_payment(payment_hash)`.
Destination reconciliation uses
`reconcile_tracked_receive(settlement_id, timeout)`, which checks the exact
mint quote created for the migration. A balance increase, including an
unrelated incoming payment for the same amount, cannot settle the attempt.

## What it does and does not prove

**Verified by an actual run**, not by inspection:

| Property | Evidence |
| --- | --- |
| Value conservation | fund 5000 → migrate 2000 → destination holds exactly 2000 |
| Custody-consent gate | `migrate` without `--accept-custody-change` refuses |
| Fee cap (fail-closed) | `--max-fee-sats 0` refuses: quoted fee 20 exceeds cap |
| Destination max | `--amount-sats 2000 --dest-max-sats 100` refuses |
| melt→mint hand-off | payment reports `Complete`, settlement watch reports `settled` |
| `settle` resume | re-running `settle` resumes the journaled settlement/payment identities; no baseline is supplied |
| Exact quote settlement | unrelated destination credits remain pending until the migration's own quote settles |
| No duplicate send | a durable `Sending` journal refuses a second `execute_once` |
| Corrupt-journal safety | malformed journal bytes fail construction closed |
| Crash resume, for real | destination mint frozen (`docker pause`) after the melt, process killed mid-watch, then `settle` recovered the funds — source down exactly 1003, destination up exactly 1000 |
| NUT-13 restore | deleting the whole destination wallet directory and reopening with only the account key recovers the full balance |

Two of those matter more than the rest. **NUT-13 restore** is what makes moving
funds into ecash survivable across a reinstall. **Crash resume** is the safety
net for the live run: it was tested by genuinely interrupting a migration after
the money had left the source, not by simulating the state.

Every figure above still comes from a fake backend; see below for what that
means.

**Not proven.** The two mints have *independent* fake backends, so the source
only pretends to pay and the destination independently believes its own invoice
was paid. Real Lightning settlement, real routing fees, and real failure modes
(stuck HTLCs, Boltz swap outages) are outside this harness — those are what the
live shots are for.

Two consequences worth knowing before reading simulation output:

- **A fake mint pays every invoice, including abandoned ones.** `quote`, and any
  `migrate` that stops at a gate, still create a destination mint quote; the
  fake backend settles them, so the destination balance can exceed what was
  migrated. In one run a single 2000-sat migration left 6000 at the destination
  — three quotes, all auto-paid. On a real mint an abandoned quote simply
  expires. Use fresh `--cashu-dir`s when checking conservation.
- **A Cashu source pays NUT-02 input fees the Lightning source does not.** With
  `input_fee_ppk = 100`, moving 2000 sats debits 2003 (2000 + 2 routing + 1
  input fee) while `fees_sats` reports only the routing fee. Do not read that
  1-sat gap as a Breez-side discrepancy.

## What the simulation could not have caught

The harness above validated the engine thoroughly and still missed everything
that only appears on a real device against a real Lightning wallet. Running the
migration on a Pixel 10 (against the real account, 813 sats) found five
defects, none of which the fake-mint simulation could reach:

1. **The host boundary erased every error.** `HostMigrationSource` is a UniFFI
   foreign trait, and it returned the flat `SonarFfiError`. A flat error cannot
   be lifted *out* of a foreign trait: UniFFI aborts the whole outer call with
   `Can't lift flat errors` and the Rust side never sees an `Err`. So
   `plan_drain`'s existing `InsufficientFunds` step-down could not run, and a
   whole-balance drain died on its first refusal. Fixed with a non-flat
   `HostWalletError`. The simulation missed it because both wallets were
   in-process Rust — no host boundary existed.
2. **The controller was built during composition**, so opening the mint (and a
   NUT-13 restore scan on a fresh store) blocked the UI thread.
3. **`DisposableEffect` keyed on the controller closed the instance it had just
   created**, producing `SonarMigration object has already been destroyed`.
4. **Every host failure was flattened to "wallet not available"** and logged
   nothing, which is what made 1–3 take several device cycles to tell apart.
5. **`:composeApp:buildAndroidRustCore` reported `UP-TO-DATE`** after an engine
   edit, so the APK shipped a stale `.so` and a real fix looked ineffective.
   Force `core/build-android.sh`, and confirm the change reached the binary:
   `strings …/jniLibs/arm64-v8a/libsonar_ffi.so | grep '<new string>'`.

The lesson is not that the simulation was wasted — it caught value-conservation
and settlement bugs cheaply and repeatably. It is that a fake-mint harness
proves the *engine*, and nothing about the *seams*: the FFI boundary, the UI
lifecycle, and the build pipeline each had a defect the engine tests could
never see.

## Minimum viable balance: 1,000 sats

A migration below the swap floor cannot succeed at any amount. Breez Liquid
pays Lightning through a Boltz submarine swap, and the live limits are:

```sh
curl -s https://api.boltz.exchange/v2/swap/submarine
# L-BTC->BTC: min=1000  max=25000000  fees 0.1% + 19 sat miner
# BTC->BTC:   min=25000
```

With 813 sats, every amount the engine tried (813 → 805 → 797 → 781 → 748) was
under the floor. Breez reports this as `Cannot pay: not enough funds`, which
reads like a fee-reserve problem and sends you chasing the wrong bug. **Budget
≥ ~1,050 sats for any live test**, and check the limits endpoint before
assuming a payment failure is ours.

## Pending settlement and drain safeguards

Each destination reconciliation call has a request timeout. A timeout leaves
the journal in `MintPaid` and returns `Pending`; it never turns a post-payment
network failure into a fresh send. Re-run `settle` after the mint is reachable.
The application presents the same condition as "Paid — waiting on the mint"
with a non-spending "Check again" action.

Whole-balance drain planning is fail-closed. It refuses a destination maximum
or fee-cap violation before consent. When a host reports typed
`InsufficientFunds`, or an older host returns an opaque insufficient-funds
message, the planner steps down through bounded smaller candidates. If none is
affordable it stops without paying; it never silently exceeds the displayed
fee or destination limit.
