# Relay smoke test

Daily automated check that Sonar/Marmot encrypted DM delivery works against the
target relay (`wss://nostr.relay.hedwig.sh`) and the Sonar bootstrap relays,
measuring delivery/loss, latency, and errors. Runs on GitHub Actions
(`.github/workflows/relay-smoke.yml`); can be run locally.

## What it measures

Each run provisions a seeded set of ephemeral identities, builds a random
pairwise-DM graph, and exchanges encrypted messages over two relay sets:

- **target** — `wss://nostr.relay.hedwig.sh` (the relay under test)
- **control** — the default Sonar bootstrap relays (`damus`, `nos.lol`, `primal`)

Per relay set: `sent`, `received`, `lost`, `loss_pct`, latency
(min/median/p95/max in ms), and CLI errors. The run is then classified:

| `overall`     | target | control | meaning                          |
|---------------|--------|---------|----------------------------------|
| `pass`        | pass   | *       | healthy                          |
| `relay_issue` | fail   | pass    | problem is the **target relay**  |
| `regression`  | fail   | fail    | **Sonar/Marmot** regression      |

The control set is what makes a target-relay failure actionable: if the control
passes, the Sonar stack is healthy and the target relay is at fault. If both
fail, it's a Sonar-side regression. The harness exits non-zero on any non-`pass`
classification (usable as a gate).

## Why a control set, and why "listen before send"

NIP-17/Marmot gift-wrap events are delivered **live** — the receiver must be
subscribed before the sender fires. A naive "send, then drain" sequence reports
false loss (the event has already passed). The harness starts each receiver's
`sonar-cli listen` first, waits for it to connect, then has the senders fire, and
matches received messages by their decrypted `content` payload (the `send`
output carries no message id; the receive side carries `id`, `sender`, and
`content`). The control relay set then isolates relay-side delivery bugs from
Sonar-side ones.

## Run locally

```sh
# build the CLI once
( cd core && cargo build -p sonar-cli --release )

# full run (no DM report, no issue)
SKIP_REPORT=1 scripts/smoke/relay-smoke.sh

# reproducible topology
SEED=42 SKIP_REPORT=1 scripts/smoke/relay-smoke.sh

# target relay only (skip control comparison)
SKIP_CONTROL=1 SKIP_REPORT=1 scripts/smoke/relay-smoke.sh

# small / fast
IDENTITIES=3 MESSAGES_PER_PAIR=1 SKIP_REPORT=1 scripts/smoke/relay-smoke.sh
```

Output is a single metrics JSON object on stdout. Tunables
(env > `scripts/smoke/relay-smoke.config.json` > built-in default):

`TARGET_RELAY`, `CONTROL_RELAYS`, `SKIP_CONTROL`, `IDENTITIES`, `FANOUT`,
`MESSAGES_PER_PAIR`, `RECEIVE_TIMEOUT_SECS`, `SEED`, and thresholds
`MAX_LOSS_PCT` / `MAX_P95_LATENCY_MS` / `MAX_ERRORS`.

## Reporting (DM) — one-time reporter setup

To DM a human-readable summary to a Sonar npub, the harness needs a persistent
**reporter identity** (`nsec`). It must stay out of git (Local Secrets Rule) and
live in a CI secret. One-time, on your machine:

```sh
export SONAR_CLI_HOME="$HOME/.sonar-smoke-reporter"
mkdir -p "$SONAR_CLI_HOME"
core/target/release/sonar-cli init        # generates the reporter nsec
core/target/release/sonar-cli identity    # note the reporter npub
```

Copy the `nsec1...` from `SONAR_CLI_HOME` and store it as the GitHub Actions
secret `SONAR_SMOKE_REPORTER_NSEC`. Never commit it. Same `nsec` → same `npub`
on every host, so recipients see a stable "Sonar Smoke" contact.

**Prerequisite:** the report recipient (`report.npub` in the config, default
`npub10srglj0rdsmtehwlflxptwz74c955c2y7jrhdmjm5gr6gycpsp5sg3fm3c`) must have a
Marmot KeyPackage published to the target/control relays; otherwise the reporter
cannot start the DM and the report will not land.

## CI

`.github/workflows/relay-smoke.yml` runs daily (`schedule`, 06:17 UTC) and on
demand (`workflow_dispatch`, accepts `seed`, `skip_control`, `identities`). It
builds `sonar-cli`, runs the harness with `OPEN_ISSUES=1` and the reporter
secret, and uploads `metrics.json` as a workflow artifact. On a non-`pass` run it
opens a GitHub issue with the classification, the metrics, and the `SEED` to
reproduce locally.

## Caveats

- **Latency is an upper bound.** Measured from send wall-clock to the receiver
  listener emitting the decrypted message — includes the listener poll interval
  and processing. Primary signals are delivery/loss and error rate; latency is
  directional only.
- **DM-only.** Exercises 1:1 Marmot groups (`sonar-cli send --to`). Multi-member
  MLS groups need a `create-group` / `send-group` CLI capability — tracked as a
  follow-up, see `docs/brainstorms/2026-07-13-relay-hermes-smoke-test.md`.
- **Ephemeral identities** are created fresh each run and discarded.
- **Hermes exploratory layer** (brainstorm "Approach B") runs on-demand on an
  operator host with Hermes installed — see `docs/HERMES-AGENT.md` § "Exploratory
  relay smoke". It is not part of the daily gate.
