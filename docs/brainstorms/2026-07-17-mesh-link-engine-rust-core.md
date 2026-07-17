# Move the BLE mesh link state machine into the Rust core

## Clarified Problem Statement

**Goal:** One implementation of the mesh link logic — announce/identity handling,
dial policy, per-instance links, liveness, Noise session lifecycle, pending
sends, relay — living in `sonar-core`, driven by thin per-platform BLE drivers.

**Why now:** every bug in PR #291 (zombie links, the multi-instance lottery,
write-queue races, liveness clock/TOCTOU/freeze bugs) was a *state machine* bug
fixed on Android only. iOS's 4,800-line `BLEService.swift` independently
implements the same machine and carries its own variants of the same bugs (the
`services.first` instance lottery is already tracked). The protocol bytes and
Noise crypto are already in Rust (`mesh.rs`, `noise.rs`); the platforms
duplicate only the orchestration.

**Constraints:**
- Wire behavior must stay byte-identical (bitchat + iOS interop is proven on
  device; do not change cadences, TTLs, packet shapes, or timeout windows).
- The radio itself cannot move: `android.bluetooth` / CoreBluetooth calls,
  scan/advertise settings, permissions, background modes, state restoration.
- iOS never exposes BLE MAC addresses — the engine keys links by an opaque
  `(connection handle, service instance)` pair the driver mints.
- No blocking on the render path; engine calls are lock-guarded state
  transitions, no I/O.

**Non-goals (this stage):**
- Porting iOS or Desktop drivers (tracked follow-ups; Android proves the shape).
- Moving gossip sync (`requestSync` 0x21) — Android ignores it today; parity.
- Protocol changes (ping/ack liveness remains the tracked long-term fix).

## Approach: event → command engine (chosen)

A deterministic, synchronous state machine behind one lock:

```
MeshEngine.on_<event>(..., now_ms) -> EngineOutput {
    commands: Vec<EngineCommand>,   // what the driver must do to the radio
    events:   Vec<EngineAppEvent>,  // what the app layer must be told
}
```

- **Events in:** scan result, client connected/failed/disconnected, service
  instances discovered, subscribe result, client rx (per link), server
  connected/disconnected/subscribed, server rx, dial-timer fired, tick.
- **Commands out:** `Dial{conn, after_ms}`, `Disconnect{conn}`,
  `Subscribe{conn, instance}`, `WriteLink{conn, instance, bytes, after_ms}`,
  `NotifyConn{conn, bytes, after_ms}`.
- **App events out:** peer announced, sonar payload, text/file/broadcast
  received, link established (same surface as today's `MeshGatt` listeners).
- **Time:** every entry point takes `now_ms` (monotonic, driver-supplied) —
  no clocks inside the engine, so every scenario is unit-testable, including
  the freeze-resume guard.

The engine owns: link registry keyed `(conn, instance)`, announce verify +
route classification + signing-key pinning, dial gating (dedup, 30s backoff,
MAX_CLIENTS, election, connect/announce timeouts), per-link rx liveness with
the 90s window + freeze guard, 30s heartbeat, Noise handshake/session
lifecycle (initiator/responder, 8s half-open retry), pending sends + flush,
broadcast dedup + relay (including sibling-instance relay), known-only policy,
fragmentation on send and reassembly on receive.

The Android driver keeps: scanning/advertising + scan watchdog, GATT plumbing,
the one-outstanding-op-per-connection write queue and its 10s stuck-op
recovery (platform flow control — iOS has different flow control), the
BluetoothDevice cache, and delayed-command scheduling (`after_ms`).

## Rejected alternatives

- **Callback-interface engine (engine calls back into Kotlin):** re-entrancy
  hazards across UniFFI under a held lock; returned command lists are simpler
  and deterministic.
- **Async engine with its own runtime:** brings a runtime into the hot BLE
  path and makes tests timing-dependent; ticks + `now_ms` are sufficient.
- **Big-bang port of all three platforms:** unverifiable; Android first is the
  smallest surface and we hold a proven on-device E2E recipe for it (dual Mac
  apps, per-instance DM acks).

## Implementation Plan (stage 1)

- `core/sonar-core/src/mesh_engine.rs`: `Engine` (pure struct + unit tests
  porting `MeshLinkLivenessTest` / `MeshAnnounceRouteTest` semantics and the
  dial/subscribe/announce/handshake flows end-to-end against a scripted
  driver).
- `core/sonar-ffi/src/lib.rs`: `MeshEngine` uniffi Object wrapping
  `Mutex<Engine>`; records/enums for events, commands, peers.
- Android: `MeshGatt.android.kt` becomes the driver (public surface used by
  `MeshRadio.android.kt` unchanged: `sendTextToPeer`, `hasLink`,
  `isLinkedAddr`, `peers`-feeding listeners, nickname/payload/allowlist).
- Verify: `cargo test -p sonar-core`, `:composeApp:jvmTest`, install on the
  Pixel 10 and re-run the dual-instance E2E (both Mac apps `route=Direct`,
  DM delivered-acks on both instance links, heartbeat, no spurious culls).

**Tracked platform gaps:** iOS driver (also fixes its instance lottery) and
Desktop driver (replace `MeshLink.kt` orchestration; `sonar-ble` stays the
peripheral) are follow-up PRs on the same engine.
