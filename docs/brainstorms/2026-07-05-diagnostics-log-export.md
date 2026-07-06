# Diagnostics Log Export (Relay Sync Debugging)

Date: 2026-07-05
Status: approved — implement Approach B

## Clarified Problem Statement

**Goal:** Let a remote user who's gone out of sync with the relay capture and
hand us a diagnostic bundle — persisted on-device logs covering the relay-sync
path — via an in-app Share button, on both iOS (`ios/`) and the Compose
Multiplatform app (`apps/sonar/`).

**Context / gap found in the codebase:**
- iOS `SecureLogger` (`ios/localPackages/BitLogger/Sources/SecureLogger.swift`)
  writes only to os_log (unified log) — ephemeral, tether-only.
- Android `sonarLog`
  (`apps/sonar/composeApp/src/androidMain/kotlin/chat/bitchat/sonar/Logging.android.kt`)
  goes to logcat only.
- The Rust core uses `tracing` (57 points in `core/sonar-core/src/client.rs`,
  e.g. `sync()` watermark at ~line 2004, backfill failures ~1993/2053/2077/2086)
  but **no subscriber is ever installed for the app path — core logs are silent
  on device**.
- There is NO on-device log persistence, no in-app viewer, no export/share, no
  "report a problem" flow on either platform.
- Missing core log points: relay connect/disconnect state changes, EOSE
  completion, subscription/response counts (`client.rs` ~174–192, ~696).

## Decisions (user-confirmed)

1. **Collection:** user-initiated Share (in-app "Export diagnostics" → share
   sheet / share intent). No auto-upload backend for now.
2. **Content:** full app logs, redacted by default (hash npub/IDs, no message
   content); an explicit opt-in **verbose debug toggle** enables content-level
   logging for a repro session. The account key (`nsec` / `marmot-nsec`) must
   NEVER be logged, even in verbose mode — hard filter, not a toggle.
3. **Platforms:** iOS + Android together (Cross-Platform Feature Rule, no
   tracked gap).

## Constraints

- Logging/persistence must stay off the hot path: no side effects on the
  Compose render path, no blocking of chat open / send / scroll (Signal-
  Comparable Performance Rule).
- Bounded on-device storage: rotating files with a small cap (default ~5 MB
  total per layer, rotate ×3) — confirmed default, adjustable.
- Redaction defaults on; verbose only via explicit user toggle.
- Never log account key material anywhere.
- Benchmark harness markers (`SONAR_BENCH`) must keep working (subsystem
  `chat.bitchat`, category `session`).

## Chosen Approach: B — Federated sinks, merge on export

Each layer owns its own rotating file sink; the Share button zips them plus a
sync-state snapshot.

1. **Rust core (`core/sonar-ffi/`)**: new `setup_logging(dir, verbose)` FFI
   installing a `tracing-subscriber` + `tracing-appender` rotating file sink.
   Add the missing relay diagnostics in `core/sonar-core/src/client.rs`:
   relay connect/disconnect, EOSE completion, subscription/response counts,
   watermark advancement / resync-cursor moves, decrypt failures.
2. **iOS**: tee `SecureLogger` output into a rotating file (keeping os_log
   behavior); call `setup_logging` at core init with the app-group/documents
   log dir.
3. **Android/Compose**: tee `sonarLog` into a rotating file; call
   `setup_logging` at core init.
4. **Diagnostics UI (both platforms)**: Settings → Diagnostics screen with
   relay connection status, last sync watermark per chat, verbose-debug
   toggle, and "Share debug bundle" (zips core + platform log files + a
   sync-state snapshot JSON including the per-chat resync floor / watermark
   table).
5. **Redaction**: shared redaction rules (hash npub/event IDs by default, drop
   message content unless verbose); hard filter for key material in every
   sink.

### Why B over the alternatives
- **A (core-owned unified ring buffer)**: best correlation but requires a new
  platform→core log-push FFI surface; more work, more hot-path risk. B keeps
  the door open to upgrade later.
- **C (read back OS logs)**: iOS `OSLogStore` is viable, but Android logcat
  read-back is unreliable/blocked on modern OS versions, forcing a file
  appender anyway — collapses into B.

## Success criteria

- A stuck user can go Settings → Diagnostics → Share and produce a bundle we
  can read: relay connect/disconnect, EOSE, subscription counts,
  watermark/resync-cursor moves, decrypt failures across Rust core + platform
  layers, time-ordered (interleave by timestamp across files).
- Works on a shipped, non-tethered build on both platforms.
- Default bundle contains no message content or raw npub; verbose changes that
  only with explicit consent; account key never appears.
- No measurable regression on the cold-start benchmark (`scripts/bench/`) or
  chat open/send/scroll.

## Non-goals

- No automatic server-side upload (possible follow-up).
- No full telemetry/observability pipeline.
- Not fixing the underlying resync bug — this is the instrument to diagnose
  it.
