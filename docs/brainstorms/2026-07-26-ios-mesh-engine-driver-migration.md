# Phase 2: Port iOS BLE mesh onto the Rust `MeshLinkEngine`

Follow-up to [2026-07-17-mesh-link-engine-rust-core.md](2026-07-17-mesh-link-engine-rust-core.md),
which shipped the engine and the Android driver (PR #291) and explicitly left
the iOS driver as a tracked gap. Android has since proven the shape on device;
iOS discovery flakiness (2026-07-26) was root-caused to state-machine bugs that
the engine already fixes on Android — the same class the brainstorm predicted.

## Why now

- `BLEService.swift` is ~5,300 lines and reimplements the whole link state
  machine: announce verification, identity pinning, dial gating, liveness,
  relay, dedup, fragmentation. Every constant divergence is a latent interop
  bug (example: iOS evicted peers 21s after `lastSeen` while its own dense
  announce cadence is 30s ± 8s — guaranteed radar flapping; the engine's
  `LINK_STALE_MS = 90_000` had the correct derivation all along).
- The engine is **already exposed to Swift**: `ios/localPackages/SonarCore/Sources/SonarFFI.swift`
  contains the generated `MeshLinkEngine` bindings. iOS just never calls them.
- Hostile-peer hardening (#422) landed engine-side only. iOS has no identity
  pin bound at all (unbounded `peers` map). Single-implementation fixes stop
  happening once both platforms share the engine.

## Shape (mirrors the Android driver 1:1)

```
CoreBluetooth (scan/advertise/GATT)          ←  stays Swift
   └─ BLEDriver (new, thin)  ──UniFFI──▶  MeshLinkEngine (existing Rust)
        CB delegate callbacks → engine.on_*(event, now_ms)
        engine commands (Dial/Subscribe/WriteLink/NotifyConn/…) → CB calls
        engine AppEvents → existing delegate surface (BitchatDelegate,
        peer snapshots, .sonarPeerProfileUpdated)
```

Driver responsibilities (Swift keeps only what Android's driver keeps):

- scan/advertise config, duty cycling, state restoration, background modes
- connection handle minting: `CBPeripheral.identifier` UUID string is the
  opaque `conn`; `CBService` instances map to `(conn, instance)` — this
  fixes the tracked `services.first` instance lottery for free
- write pacing / flow control (CB's `canSendWriteWithoutResponse`,
  `updateValue` false-return re-queue) — platform-specific, NOT ported from
  Android's one-op queue
- monotonic clock: `DispatchTime.now()`-derived `now_ms` for every engine
  call; wall clock only via `set_wall_clock` (never `Date()` for deadlines)

Engine responsibilities (delete from Swift): announce/0x53 verify + pinning,
dial policy + backoff + election, per-link liveness (90s window, freeze
guard — CB state-restoration wakeups need exactly this), 30s heartbeat +
subscribe burst, Noise session lifecycle, relay + dedup, fragmentation
(205-byte chunks; the 256-byte reliable-write ceiling was measured against
iOS itself).

## Staging (each PR device-verified iPhone ↔ Pixel ↔ stock bitchat)

1. **Discovery leg only**: route scan results + connect/subscribe + announce
   RX/TX through the engine; keep the Swift message path reading from the
   engine's peer registry. Radar correctness is provable with the existing
   `provision-and-bench.sh` + a Pixel running the already-migrated stack.
2. **Receive path**: engine handles rx → app events replace
   `handleReceivedPacket` dispatch. Delete Swift dedup/relay/reassembly.
3. **Send path + Noise**: `send_text`/`send_file`/receipts through the
   engine; delete `pending_sends`-era Swift queues and the Swift Noise
   session orchestration (crypto already lives in Rust).
4. **Delete**: retire dead `BLEService` internals; `BLEServiceCoreTests`
   seams move to scripted-driver tests against the engine (the Rust tests
   already cover the semantics; keep thin Swift tests for the driver glue:
   state restoration, duty cycle, radio-off invalidation — R-006 stays
   pinned in Swift because the CB state handlers stay in Swift).

## Interop invariants (do not retune while porting)

- Announce cadences, TTL=7 direct classification, ±120s skew window, 900s
  announce age cap, dedup keying — wire behavior stays byte-identical.
- The engine's constants are the reference (`mesh_engine.rs:40-107`); where
  Swift constants differ today (retention windows, backoffs), the engine
  value wins — each divergence gets called out in the PR description.
- R-006 (radio-off retires links immediately): the driver must call
  `engine.reset()`/link-drop events from `centralManagerDidUpdateState` and
  `peripheralManagerDidUpdateState`, and the existing Swift tests keep
  guarding it.

## Risks / open questions

- **Background execution**: CB delivers events while backgrounded; the 15s
  engine tick needs a driver timer that survives suspension gaps — the
  engine's `SWEEP_RESUME_GAP_MS` re-seed handles the wake side, but the
  driver must not fake ticks it never ran.
- **macOS shares BLEService**: the driver must build for both, or macOS
  stays on legacy Swift until a follow-up (document the gap per the
  Cross-Platform Feature Rule).
- **Gossip sync (0x21)** stays Swift-side and out of the engine (parity with
  Android, which ignores it) — decide its fate separately.
- **Binary size / startup**: engine object is already linked (sonarffi
  ships it); no new cost expected, verify with `scripts/bench/`.
