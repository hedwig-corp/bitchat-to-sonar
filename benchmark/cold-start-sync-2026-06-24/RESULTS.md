# Cold-start + relay-sync benchmark — production result

Date: 2026-06-24.
Build: branch `perf/cold-start-sync-benchmark` (Debug, `SONAR_BENCH` markers).
Harness: `scripts/bench/` (method documented in `docs/PERFORMANCE.md`).

## Headline

On the **real account** (physical iPhone, 24 Marmot groups), a cold start takes
**~52–66 s to become synced** — and **~57 s of that (86%) is two blocking relay
publishes that run before the sync loop even starts**, not the sync itself
(`drainPending` is ~1.7 s).

The simulator (1 group) was ~1.55 s, so the stall only appears with a real
account + real relays.

## Environment

| | device | simulator |
|---|---|---|
| hardware | iPhone 14 Pro Max (iPhone15,3), iOS 26.x | iPhone 16 Pro simulator |
| account | real account, **24 Marmot groups** | provisioned, 1 group |
| signing | dev-signed (team ZQB239SHCM), Keychain works | unsigned, Keychain-independent bench path |
| relays | live (damus, nos.lol, primal, kaleidoswap, hedwig) | live |
| runs | 4 (split) + 5 (initial), `woke=1 notif=0` every run | 5, `woke=1` |

## Device phase breakdown (median, 4 runs — see `device-phase-table.txt`)

| phase | min | med | max | (ms) |
|---|---:|---:|---:|---|
| t0 → t1  open DB + local paint | 1059 | 1292 | 1551 | |
| t2 → t3  relay quorum connect | 528 | 690 | 3257 | |
| **t3 → t3a  publish KeyPackage + profile** | **42771** | **56740** | **65149** | |
| t3a → t3b  first event wait | 1767 | 2290 | 3212 | |
| t3b → t4  `drainPending` (MLS sync) | 611 | 1732 | 18346 | |
| **TOTAL t0 → t4  cold → synced** | **49206** | **65596** | **82950** | |

(`t1→t2` is concurrent — see `docs/PERFORMANCE.md`.)

## Root cause

`MarmotChatModel.connectRelaysIfNeeded` (`ios/bitchat/Views/MarmotChatView.swift`)
does `try? await publishKeyPackage()` then `try? await publishProfile()` **before**
`startPolling()`. Both call the core `publish_key_package` / `publish_profile` →
`nostr.send_event(...).await`, which **waits for relay acknowledgement** across
all 5 relays (the core notes at `core/sonar-core/src/client.rs:2706` that
`send_event()` awaits a relay OK and should be backgrounded). With a slow /
unreachable relay this stalls ~28 s per publish, so the sync loop doesn't start
for ~57 s.

This explains both reported symptoms:
- **slow to sync** — incoming messages aren't drained until the publishes finish;
- **slow to send** — sends use the same await-all-relays `send_event` path.

## Fix (highest impact first)

1. Move `publishKeyPackage()` + `publishProfile()` off the
   `connectRelaysIfNeeded` critical path into a detached background task so
   `startPolling()` runs immediately. Expected: cold → synced ~66 s → ~6 s.
2. Bound `send_event` publish latency (cap timeout / return after first relay OK).
3. Secondary: opening the 24-group DB is ~1.3 s (vs ~0.19 s for 1 group on sim).

## Reproduce

```bash
core/build-ios.sh
xcodebuild -project ios/bitchat.xcodeproj -scheme "bitchat (iOS)" -configuration Debug \
  -destination 'platform=iOS,id=<hardware-udid>' \
  -derivedDataPath /tmp/sonar-bench/DeviceDD -allowProvisioningUpdates build
xcrun devicectl device install app --device <hardware-udid> \
  /tmp/sonar-bench/DeviceDD/Build/Products/Debug-iphoneos/Sonar.app
UDID=<hardware-udid> RUNS=4 scripts/bench/device-bench.sh
```

## Data in this directory

- `device-markers-4run-split.txt` — raw `SONAR_BENCH` marker lines (4-run, with
  the `t3a`/`t3b` split). Reproduces `device-phase-table.txt`.
- `device-markers-5run.txt` — raw markers from the initial 5-run device pass.
- `device-phase-table.txt` — parsed device phase table (from the split log).
- `sim-phase-table.txt` — simulator baseline (1 group).
