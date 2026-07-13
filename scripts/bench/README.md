# Sonar cold-start + relay-sync benchmark (iOS Simulator)

Measures how long a **cold start** of the Sonar iOS app takes to become usable
and to finish its first **Nostr/Marmot relay sync**, broken down by phase. Built
to investigate "slow to sync / slow to send" by showing *where* the startup time
actually goes.

## What it measures

The app emits `SONAR_BENCH` markers to the unified log (`SecureLogger`, subsystem
`chat.bitchat`, category `session`). The harness cold-starts the app repeatedly
(terminate the process, relaunch — the container is **never erased**, so the
identity + Marmot groups persist) and diffs the marker timestamps:

| marker | meaning |
|---|---|
| `t0_launch` | app entered `BitchatApp.init()` — earliest in-process point |
| `t1_local_paint` | local groups hydrated from the encrypted DB (first paint, no relays) |
| `t2_relay_connect_begin` | relay attach begins |
| `t3_relay_connected` | relays quorum-connected (`service.connect()` returned) |
| `t4_first_drain` | first relay event burst applied to local storage (initial sync produced data) |

Reported phases: `launch→t0` (process + SwiftUI init), `t0→t1` (open DB + local
paint), `t1→t2` (the deliberate local-first pre-relay delay), `t2→t3` (relay
quorum connect), `t3→t4` (initial sync drain), and the totals `launch→t4` and
`t0→t4`.

`t4` carries `woke=`/`notif=`: `woke=1` means the relay replayed stored group
events (the real re-sync path); `woke=0 notif=0` means nothing new to sync this
run — in that case `t3→t4` is just the 25 s idle wait, **not** sync cost.

## Build (one time)

```bash
core/build-ios.sh                              # Rust core → sonarffi.xcframework (incl. sim slice)
APP=$(scripts/bench/build-sim.sh)              # Debug build for the simulator → prints Sonar.app path
```

Notes on the build:
- **Debug** is required — the markers are only public in the unified log in DEBUG.
- **arm64-only** — the Arti + sonarffi simulator slices are arm64 (Apple Silicon);
  a universal/x86_64 sim build fails to link.
- **Unsigned** — CLI builds of this app sign ad-hoc with empty entitlements (the
  `sh.hedwig.sonar` bundle id belongs to the Hedwig team; a personal team can't
  provision it), so Keychain returns `errSecMissingEntitlement` (-34018). Rather
  than fight signing, the benchmark provisioning path is **Keychain-independent**:
  with `SONAR_BENCH_NSEC` set, `MarmotChatModel.performConnect` adopts the env
  identity directly and `MarmotService.databaseConfig` derives the encrypted-DB
  key as `SHA256(nsec)` — both `#if DEBUG` only. So the reliably-launchable
  unsigned build is exactly what we want, and the derived DB key is stable across
  cold-start runs so the existing-account DB persists.

## Run

### Quick (phase breakdown, freshly-generated identity)
Validates the pipeline and shows the identity-independent costs (process init,
local paint, the pre-relay delay, relay quorum connect). `t4` will be `woke=0`
(an empty account has nothing to re-sync).

```bash
scripts/bench/cold-start-bench.sh --app "$APP" --runs 5
```

### Faithful (existing account re-syncing real messages)
Uses `sonar-cli` as a headless counterparty to seed a real 1:1 Marmot group
(DMs auto-join on the recipient) and to push a fresh message before each run, so
each cold start exercises the real re-sync path (`woke=1`).

```bash
cargo build -p sonar-cli --release
scripts/bench/provision-and-bench.sh --app "$APP" --runs 5 --msgs-per-run 1
```

## How provisioning works

`provision-and-bench.sh` generates two identities with `sonar-cli` (`--home`
isolates them), launches the sim with `SIMCTL_CHILD_SONAR_BENCH_NSEC=<nsecA>` so
it adopts identity A (DEBUG-only hooks: `BitchatApp.init` also force-completes
onboarding, `performConnect` adopts the identity, `databaseConfig` derives the
DB key — all Keychain-free). It waits for the sim to report `t3_relay_connected`,
publishes A's KeyPackage, then retries B→A DMs until A's KeyPackage is found on
the relays. Relays are pinned (`--relay`) to the app's
`MarmotService.defaultRelayUrls` so events actually reach the sim. DMs
(member_count ≤ 2) auto-join on the recipient (core `marmot.rs::process_incoming`),
so no UI interaction is needed.

All identities/keys are throwaway and live under `/tmp/sonar-bench/` — never
commit them. The `SONAR_BENCH_NSEC` hook and markers are `#if DEBUG` only.

## Output

Raw per-run logs land in `/tmp/sonar-bench/runs/run_*.ndjson`. The aggregator
(`_aggregate.py`) prints a min/median/max table per phase.

## Text-send flow (iPhone, macOS, Android)

The shared Rust core emits these content-free markers for every Marmot text
send on every app surface:

| marker | duration field | meaning |
|---|---:|---|
| `send_local_pending` | `local_ms` | MLS event creation, local transcript processing, and durable pending-outbox write |
| `send_publish_start` | — | background relay fan-out started |
| `send_first_ack` | `rtt_ms` | first relay accepted the event; the row can flip from **Sending** to **Sent** |
| `send_publish_failed` | `rtt_ms` | every configured relay failed |

Capture the platform log while sending a fixed number of text messages, then
feed it to the same parser:

```bash
scripts/bench/_send_aggregate.py --label "iPhone 14 Pro Max" /tmp/iphone-send.log
scripts/bench/_send_aggregate.py --label "macOS native" /tmp/macos-send.log
scripts/bench/_send_aggregate.py --label "Android emulator" /tmp/android-send.log
```

Apple writes the core markers to `os_log` (subsystem `chat.bitchat`, category
`core`), Android writes them to logcat tag `SonarCore`, and Compose Desktop
writes them to stderr. The parser uses the structured duration fields rather
than host timestamps, so the three results are directly comparable. Message
content and private keys are never logged.
