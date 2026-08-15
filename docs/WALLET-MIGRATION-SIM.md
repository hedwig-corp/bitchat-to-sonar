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
```

Tear down with `docker rm -f sim-mint-src sim-mint-dst`.

## What it does and does not prove

**Verified by an actual run**, not by inspection:

| Property | Evidence |
| --- | --- |
| Value conservation | fund 5000 → migrate 2000 → destination holds exactly 2000 |
| Custody-consent gate | `migrate` without `--accept-custody-change` refuses |
| Fee cap (fail-closed) | `--max-fee-sats 0` refuses: quoted fee 20 exceeds cap |
| Destination max | `--amount-sats 2000 --dest-max-sats 100` refuses |
| melt→mint hand-off | payment reports `Complete`, settlement watch reports `settled` |
| `settle` resume | re-running `settle` after a migration re-reports the right balance |
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

## Known gap: the settlement watch has no timeout

Freeze the destination mint after the melt (`docker pause sim-mint-dst` two
seconds into a `migrate`) and the command prints

```
{"plan":{"amount_sats":1000,"destination_baseline_sats":0,"source_fee_sats":10}}
{"paid":{"amount_sats":1000,"fees_sats":2,"id":"01a005c8-…","status":"Complete"}}
```

and then **hangs indefinitely** — observed past ten minutes with
`--settle-polls 4`. The poll count cannot bound it: one poll blocks forever on a
mint that accepts the connection and never answers, which is what a hung server
looks like (a *refused* connection fails fast instead).

The state is recoverable — unfreezing and running `settle` found the funds, with
the balances conserved exactly — but the hang lands at the worst moment in the
whole flow: after the money has left the source, and on a branch that never
prints the resume instruction, because that text only exists on the `Pending`
path. An operator who did not already know to interrupt and run `settle` would
be staring at a dead terminal holding a paid migration. In the app the same
shape is a spinner that never resolves.

Fixes worth considering: a per-request timeout on the destination sync so a
poll can fail into `Pending` instead of blocking, and printing the resume
instruction as soon as the payment succeeds rather than only when settlement
gives up.

## Known gap this harness found: `prepare_send` does not check affordability

`migrate` **without** `--amount-sats` (drain the whole balance) fails on a Cashu
source:

```
{"plan":{"amount_sats":4949,"destination_baseline_sats":0,"source_fee_sats":50}}
Error: Backend("source wallet: backend error: Insufficient funds")
```

`plan_drain` reserves `amount + quoted fee` and leaves 1 sat of slack, which the
mint's input fee then eats. The deeper cause is in the backend, not the engine:
`CdkWallet::prepare_send` asks the mint for a melt quote but never checks that
local proofs cover `amount + fee_reserve + input fees`, so it can return a
`PreparedSend` the wallet cannot pay. `InsufficientFunds` surfaces later, inside
`send`.

It **fails safe** — the source balance is untouched — but it fails at the wrong
moment: in the app this is a user who reads a fee, consents, and only then gets
an error. It also leaves the abandoned destination quotes behind (the retry loop
can mint up to three).

This does not affect the Breez→Cashu direction that ships first: Breez is the
source there and does its own affordability check, while Cashu is only the
destination and does no melting. It does affect any future "send max" from a
Cashu wallet.
