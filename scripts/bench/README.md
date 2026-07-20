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

## Physical iPhone (real account)

Install a signed Debug build over the existing app (never erase the container),
then:

```bash
UDID=<hardware-udid> RUNS=5 scripts/bench/device-bench.sh
```

Capture modes (`CAPTURE=auto|syslog|applog`):

- **syslog** — USB `idevicesyslog -m SONAR_BENCH` when `idevice_id` sees the UDID.
- **applog** — CoreDevice pull of
  `Library/Application Support/sonar-marmot/logs/ios/sonar-ios.log`
  (Wi-Fi-safe). Requires the app to configure `LogFileSink` before `t0_launch`
  so T0 is present in the file tee.

After background KeyPackage/profile publish, compare `t0→t4` and `t2→t4`;
`t3→t3a` is off the sync critical path.

## Text-send flow (iPhone, macOS, Android)

The shared Rust core emits these content-free markers for every Marmot text
send on every app surface:

| marker | duration field | meaning |
|---|---:|---|
| `send_local_pending` | `local_ms` | MLS event creation, local transcript processing, and durable pending-outbox write |
| `send_publish_start` | — | background relay fan-out started |
| `send_first_ack` | `rtt_ms` | first relay accepted the event; the row can flip from **Sending** to **Sent** |
| `send_publish_failed` | `rtt_ms` | every configured relay failed on this attempt; the outbox may retry it later |

Capture the platform log while sending a fixed number of text messages, then
feed it to the same parser:

```bash
scripts/bench/_send_aggregate.py --label "iPhone 14 Pro Max" /tmp/iphone-send.log
scripts/bench/_send_aggregate.py --label "macOS native" /tmp/macos-send.log
scripts/bench/_send_aggregate.py --label "Android emulator" /tmp/android-send.log
```

### Native Apple send automation

A signed **Debug** Apple build can run the normal `MarmotChatModel.send` path
without traversing a large transcript accessibility tree. The trigger is
compiled out of Release builds, requires an exact local conversation title,
aborts if that title is ambiguous, and paces sends one second apart:

```bash
xcrun devicectl device process launch \
  --device <coredevice-id> \
  --terminate-existing \
  --environment-variables \
  '{"SONAR_BENCH_SEND_COUNT":"50","SONAR_BENCH_SEND_TARGET":"Sonar agent DM","SONAR_BENCH_SEND_PREFIX":"device-send"}' \
  sh.hedwig.sonar
```

For the native macOS app, supply the same three variables when launching the
signed Debug executable:

```bash
SONAR_BENCH_SEND_COUNT=50 \
SONAR_BENCH_SEND_TARGET='Sonar agent DM' \
SONAR_BENCH_SEND_PREFIX='mac-device-send' \
  /path/to/Sonar.app/Contents/MacOS/Sonar
```

`SONAR_BENCH_SEND_COUNT` is bounded to 1–500. The app waits for relay setup,
resolves `SONAR_BENCH_SEND_TARGET` against the bounded local conversation
summaries, and sends through the same serialized model/service path as the
composer. On iOS the explicit Debug task temporarily disables the idle timer,
then restores it after the final queued send, so a physical-device batch does
not require XCTest or a manual keep-awake tap. `SONAR_BENCH
send_batch_finished` reports requested/dispatched counts without logging
message content.

### Repeatable send smoke checks

Use the batch driver for a **functional smoke check** on either a physical
Apple device or a simulator. A passing 50-message smoke run has all of the
following:

- `send_batch_finished requested=50 dispatched=50` in the app log;
- 50 accepted samples in the aggregator (each has both local-pending and
  first-ACK markers); and
- zero `failure-marked` samples.

Do not make a pull-request gate out of a live-relay latency threshold: relay
health, Wi-Fi, and concurrent traffic legitimately vary. Keep the simulator
smoke as a functional check, and run the signed physical-device batch nightly
to compare its median/p95 against the recorded device baseline.

#### Physical iPhone

Install a signed Debug build and start the log stream *before* launch. Obtain
the device identifier with `xcrun devicectl list devices`; use the hardware
UDID with `idevicesyslog`:

```bash
idevicesyslog -u <iphone-udid> -m SONAR_BENCH -o /tmp/iphone-send.log &
STREAM_PID=$!

xcrun devicectl device process launch \
  --device <coredevice-id> \
  --terminate-existing \
  --environment-variables \
  '{"SONAR_BENCH_SEND_COUNT":"50","SONAR_BENCH_SEND_TARGET":"Sonar agent DM","SONAR_BENCH_SEND_PREFIX":"iphone-smoke"}' \
  sh.hedwig.sonar

scripts/bench/_send_aggregate.py --label "iPhone smoke" /tmp/iphone-send.log
kill "$STREAM_PID"
```

This exercises the real account, Keychain, relay transport, device scheduler,
and native UI execution. It is the right target for latency monitoring.

#### iOS Simulator

Build/install the Debug simulator app, stream its unified log, and pass the
same variables with the `SIMCTL_CHILD_` prefix:

```bash
core/build-ios.sh
APP=$(scripts/bench/build-sim.sh)
xcrun simctl install booted "$APP"
xcrun simctl spawn booted log stream --level debug --style compact --color none \
  --predicate 'subsystem == "chat.bitchat"' > /tmp/simulator-send.log &
STREAM_PID=$!

xcrun simctl launch --terminate-running \
  --env SIMCTL_CHILD_SONAR_BENCH_SEND_COUNT=50 \
  --env 'SIMCTL_CHILD_SONAR_BENCH_SEND_TARGET=Sonar agent DM' \
  --env SIMCTL_CHILD_SONAR_BENCH_SEND_PREFIX=simulator-smoke \
  booted sh.hedwig.sonar

scripts/bench/_send_aggregate.py --label "iOS simulator smoke" /tmp/simulator-send.log
kill "$STREAM_PID"
```

The simulator validates the normal send model/service flow and marker contract
reproducibly, but its timing is not representative of a phone's radio, TLS,
power scheduling, or main-thread contention. Treat it as a correctness smoke,
not a device-latency measurement.

Apple writes the core markers to `os_log` (subsystem `chat.bitchat`, category
`core`), Android writes them to logcat tag `SonarCore`, and Compose Desktop
writes them to stderr. The parser uses the structured duration fields rather
than host timestamps, so the three results are directly comparable. Message
content and private keys are never logged.

An accepted sample has both `send_local_pending local_ms=` and
`send_first_ack rtt_ms=` for the same message ID. `failure-marked` is the
number of accepted messages that first exhausted every relay and later reached
an ACK through outbox retry. Rotated or overlapping snapshots are safe to pass
together: marker and failure counts are deduplicated by message ID.

For a fresh run in an append-only device log, save a pre-run JSON snapshot and
exclude every ID it observed from the post-run result (including rows that were
still awaiting an ACK at the snapshot boundary):

```bash
scripts/bench/_send_aggregate.py --json-out /tmp/pre.json /tmp/pre.log
scripts/bench/_send_aggregate.py --exclude-json /tmp/pre.json \
  --json-out /tmp/fresh.json /tmp/post.log
```

## Sticker pack download and cache flow

The shared Rust core emits content-free `SONAR_BENCH` markers at debug level on
every app surface. The Debug-only launcher temporarily enables those markers
for its run, then restores the user's diagnostics setting. Normal production
use therefore pays no info-level logging cost. The markers separate relay pack
metadata fetches, HTTPS image misses, verified disk hits, full-reference
transcript hits, and detached install-prefetch batches:

| marker | key fields | meaning |
|---|---|---|
| `sticker_pack_fetch` | `purpose`, `source`, `stickers`, `total_us` | kind-30031 relay lookup + validation + local metadata persistence on `source=network`, the last validated local definition on `source=fallback_disk` after a failed refresh, or the same in-flight result on `source=shared` |
| `sticker_image_fetch` | `purpose`, `source`, `bytes`, phase timings | HTTPS/verify/write on `source=network`, verified SHA disk read on `source=disk`, a coalesced in-flight result on `source=shared`, or host picker LRU hit on `source=memory` |
| `sticker_ref_cache_lookup` | `purpose`, `outcome`, `bytes`, `total_us` | local-only coordinate + shortcode + SHA authorization and image read used by transcripts |
| `sticker_pack_prefetch_finished` | `purpose`, `attempted`, `succeeded`, `failed`, `pack_us`, `total_us` | bounded first-20/four-task install prefetch batch |

### Automated physical-device cache ladder

Debug builds have an explicit launcher trigger that waits for the normal relay
attachment and runs the production host/core path in this order:

1. kind-30031 pack metadata relay fetch, with validated local metadata fallback if the refresh is unavailable;
2. initial image pass (`source=network` on a cold disk cache, otherwise disk);
3. host 25 MiB/100-entry LRU pass (`source=memory`);
4. host-memory reset followed by the verified Rust disk-cache pass;
5. host-memory reset followed by the coordinate + shortcode + SHA transcript
   authorization lookup.

The trigger does not install the pack, publish an installed-pack list, clear the
account, or alter chats. It only adds successfully verified public images to the
normal bounded cache. The pack address is mandatory launcher input so benchmark
data cannot silently become a user-visible fallback pack.

Android (force-stop preserves app data):

```bash
adb logcat -c
adb shell am start -S -n chat.bitchat.sonar/.MainActivity \
  --ez sonar_sticker_benchmark true \
  --es sonar_sticker_author <64-char-author-hex> \
  --es sonar_sticker_identifier <pack-identifier> \
  --es sonar_sticker_relays wss://relay.damus.io,wss://nos.lol \
  --ei sonar_sticker_image_limit 8 \
  --ei sonar_sticker_image_offset 0

# Wait for device_sticker_batch_finished, then capture and aggregate.
adb logcat -d -v threadtime SonarCore:I '*:S' > /tmp/android-stickers.log
scripts/bench/_sticker_aggregate.py \
  --label 'Pixel 10 Pro' /tmp/android-stickers.log
```

Apple (an optimized benchmark build may still define `DEBUG` for this hook):

```bash
xcrun devicectl device process launch \
  --device <coredevice-id> \
  --terminate-existing \
  --environment-variables \
  '{"SONAR_BENCH_STICKERS":"1","SONAR_BENCH_STICKER_AUTHOR":"<64-char-author-hex>","SONAR_BENCH_STICKER_IDENTIFIER":"<pack-identifier>","SONAR_BENCH_STICKER_RELAYS":"wss://relay.damus.io,wss://nos.lol","SONAR_BENCH_STICKER_IMAGE_LIMIT":"8","SONAR_BENCH_STICKER_IMAGE_OFFSET":"0"}' \
  sh.hedwig.sonar
```

With a USB syslog stream, use the capture command below. For a paired
network-only iPhone, copy the bounded app/core diagnostic logs after
`device_sticker_batch_finished` instead:

```bash
xcrun devicectl device copy from \
  --device <coredevice-id> \
  --domain-type appDataContainer \
  --domain-identifier sh.hedwig.sonar \
  --source 'Library/Application Support/sonar-marmot/logs' \
  --destination /tmp/iphone-sticker-logs

scripts/bench/_sticker_aggregate.py --latest-completed \
  --label 'iPhone 14 Pro Max' \
  /tmp/iphone-sticker-logs/core/sonar-core.log* \
  /tmp/iphone-sticker-logs/ios/sonar-ios.log*
```

Apple's host and Rust markers live in separate rolling files. The aggregator
merges their RFC3339 device timestamps; `--latest-completed` explicitly selects
the newest successful launcher run when older batches are still present, but
rejects a newer failed or incomplete run. Without that option it remains strict
and rejects captures containing anything other than exactly one completed batch.

`device_sticker_batch_finished` also reports the expected/loaded count for each
pass. The parser accepts exactly one completed launcher batch per invocation,
checks that `initial`, `memory`, `disk`, and `refs` all equal `stickers`, and
verifies each required timing field and the expected per-phase marker counts
before reporting comparable median/p95 timings. Foreground is the default
purpose, so overlapping detached prefetch markers cannot contaminate the device
comparison; pass `--purpose prefetch` explicitly to inspect them. If the first
window is already warm, advance `image_offset` instead of deleting a real
account's cache. The final durable pass must contain exactly `stickers` verified
`source=disk` markers; a second network download cannot masquerade as a disk
cache hit. Prefetch reports additionally require balanced attempted/succeeded/
failed counts and zero failures.

```bash
# Alternate USB captures for the same explicit launcher batch.
idevicesyslog -u <iphone-udid> -m SONAR_BENCH -o /tmp/iphone-stickers.log &

# Android device
adb logcat -c
adb logcat -v threadtime SonarCore:I '*:S' > /tmp/android-stickers.log &

# Aggregate one completed batch; --purpose can isolate overlapping prefetch.
scripts/bench/_sticker_aggregate.py \
  --label 'iPhone 14 Pro Max' /tmp/iphone-stickers.log
scripts/bench/_sticker_aggregate.py \
  --label 'Pixel 10 Pro' /tmp/android-stickers.log
scripts/bench/_sticker_aggregate.py \
  --purpose prefetch --label 'Pixel 10 Pro prefetch' /tmp/android-stickers.log
```

Compare devices by the parser's median/p95 rows, not by host timestamps. The
core records microsecond durations inside each operation, so Apple os_log,
Android logcat, and desktop stderr formatting do not affect the result. Live
relay/HTTPS timings are observational and must not become a latency CI gate;
cache-hit correctness and prefetch completion counts are suitable smoke checks.

## Android mesh → Radar publish (PR #316 / R-008)

Measures verified bitchat announce → conflated off-main snapshot → Radar state
paint on a physical Android device (Signal-style invalidation; same 1+1 trailing
shape as wallet balance refresh). See `docs/PERFORMANCE.md`.

```bash
# Debug APK on device, Bluetooth on, peer in range:
scripts/bench/android-mesh-radar-bench.sh --serial <adb serial> \
  --peer whitewholf --seconds 60 --open-radar --cold-start
```
