# Unify relay fetch/publish and remove the unoptimized stack

Date: 2026-08-17.

## Clarified Problem Statement

**Goal:** One relay I/O style in core (scoped quorum fetch + first-ACK publish, circuit-breaker when disconnected) used by Marmot *and* iOS geohash, then delete `NostrRelayManager` and the remaining pool-wide `fetch_events` / `send_event` helpers — without mixing geohash relays into Marmot sync.

**Constraints:**
- Local-first: chat open / send / first paint must not wait on these fetches (Signal-Comparable Performance Rule).
- Keep live Marmot subscriptions (`subscribe_marmot`); do not go back to poll-only.
- White Noise / Marmot wire-compatible: same bootstrap relays, kinds, watermarks, batched `#h` catch-up.
- Geohash *behavior* stays: kind 20000/20001, NIP-17 geo DMs, GPS nearest-relay directory (bitchat overlap). The Swift WebSocket implementation goes; the product does not.
- Cross-platform: Compose already uses core for geohash (`sendGeohash` / `sendGeohashPresence`). iOS must match. Location notes (kind 1) are iOS-only today — moving them to core is the cutover, not a new Compose UI in this change (track the Compose gap).
- Tor: iOS geohash currently goes through `TorURLSession` in `NostrRelayManager`. Core Marmot already uses the process Tor/Arti path. Cutover must not send iOS geohash clearnet while Marmot is on Tor.
- Never uninstall device apps; do not touch account keys.

**Non-goals:**
- Rewriting nostr-sdk or replacing WebSockets with a custom protocol.
- Changing MIP-05 / Transponder / FCM push (wake still triggers `sync_force`).
- Killing live subscriptions or the watermarked catch-up queue.
- Shipping Compose location-notes UI in the same change.
- NIP-11 relay-information probing in the app (that stays `sonar-sim`).

**Success criteria:**
- Metadata fetch/publish (KeyPackage, kind-0, descriptor, Blossom list, stickers) uses the same quorum / first-ACK shape as chat — one dead relay does not block.
- Disconnected fetches cannot storm (`connected_relay_count() == 0` circuit breaker on every remaining fetch path; R-style watchdog from 2026-08-01).
- `self.nostr.fetch_events(...)` and pool-wide `send_event` / `send_event_builder` are gone from production `client.rs` (tests may still use nostr-sdk `Client` directly).
- iOS `NostrRelayManager` is deleted; geohash / location notes / geo DMs / presence go through core FFI. Status chip + Connection sheet read core diagnostics.
- `scripts/bench/device-bench.sh` / cold-start markers do not regress vs `docs/PERFORMANCE.md` (`t0→t4`, `t2→t4`, send first-ACK). Quote before/after.

**Contradiction resolved:** The question set both “delete NostrRelayManager / route geohash through core” and “leave geohash NostrRelayManager alone.” Interpretation: keep geohash *product* (channels, presence, geo DMs, location notes, GPS directory), delete the *Swift socket stack*.

## Current shape (why this exists)

Two stacks, two I/O styles:

1. **Optimized (chat only)** in `core/sonar-core/src/client.rs`:
   - Fetch: `fetch_marmot_events_from_relay_quorum` — per-relay `fetch_events_from`, first-N quorum, skip when zero connected.
   - Push: first-ACK fan-out via `send_event_to([url], …)` (content-first, PR #220 follow-up).
   - Live kind-445 tail + watermarked `sync_force` for suspend gaps.

2. **Unoptimized (still in core):**
   - `nostr.fetch_events(filter, timeout)` — whole pool, including geohash-nearest relays added by `ensure_geohash_relays` (up to 12 extra). Waits on their EOSE. Used for KeyPackage, kind-0, Blossom list.
   - `send_event` / `send_event_builder` — joins *all* connected relays. Used for KeyPackage, descriptors, stickers, geohash messages, NIP-17. One dead relay = full timeout. Chat already left this path because it delayed Sending→Sent.

3. **iOS-only second WebSocket stack:** `ios/bitchat/Nostr/NostrRelayManager.swift` (~1.3k lines) plus `GeoRelayDirectory.swift`. Callers: `ChatViewModel+Nostr`, `LocationNotesManager`, `GeohashPresenceService`, `NostrTransport`, `NetworkActivationService`, `SonarStatusChip`, `SonarRelayStatusSheet`. Compose has no equivalent; it already calls core.

Mixing is already a Marmot bug on Compose: `subscribe_geohash` adds geo relays to the *same* nostr-sdk `Client`. Quorum fetch scopes to `self.relays` to avoid waiting on them; leftover `fetch_events` does not. Deleting `NostrRelayManager` *without* isolating pools would import that mix onto iOS Marmot as well.

## Approaches Considered

### Approach A: Dual core pools + scoped I/O + iOS cutover
- Sketch: Split core into a Marmot `Client` (bootstrap relays only) and a geo `Client`/`RelayPool` (GPS nearest set). All Marmot fetch/publish go through quorum + first-ACK helpers; geo publish fans out only to that geohash’s relays. iOS geohash/notes/presence/DMs call new or existing FFI. Delete `NostrRelayManager`. Diagnostics read both pools.
- Affected files: `core/sonar-core/src/client.rs` (split pool, migrate `fetch_key_package` / `fetch_profile` / `blossom_servers` / `publish_sonar_descriptor` / `send_geohash*`), UniFFI + `ios/localPackages/SonarCore`, `ios/bitchat/Nostr/NostrRelayManager.swift` (delete), `ChatViewModel+Nostr.swift`, `LocationNotesManager.swift`, `GeohashPresenceService.swift`, `NetworkActivationService.swift`, `SonarRelayStatusSheet.swift` + Compose `RelayDiagnostics.kt` (core snapshot only). Tests: `core/sonar-core/tests/e2e.rs` geohash, `ios/bitchatTests` LocationNotes / GeohashPresence / NostrRelayURLCanonicalization.
- Tradeoffs: Isolates Marmot from geo relay count (the actual optimization). Largest change. Location notes need a small core API (kind 1 + `#g`) that Compose can ignore for now. Tor must be wired on the geo pool the same way as Marmot.
- Effort: L

### Approach B: Single pool, scoped I/O everywhere + iOS cutover
- Sketch: Never call pool-wide `fetch_events` / `send_event`. Always pass an explicit relay list (Marmot `self.relays` or `closest_relays_for_geohash`). Same circuit breaker. Then point iOS geohash at existing `subscribe_geohash` / `send_geohash` FFI and delete `NostrRelayManager`.
- Affected files: same `client.rs` call sites as A, plus the iOS callers above. No new pool type.
- Tradeoffs: Faster. Matches Compose today. Geohash relays still share connect/reconnect/Tor/status with Marmot — `fetch_events` contamination is gone, but pool size, CPU, and Connection-sheet noise remain. iOS Marmot would pick up Compose’s mix (today iOS keeps them separate).
- Effort: M–L

### Approach C: Keep NostrRelayManager as geo isolation; only fix core Marmot metadata I/O
- Sketch: Migrate remaining `fetch_events` / `send_event` in Marmot paths onto quorum + first-ACK. Leave iOS geohash on Swift sockets. Do not delete `NostrRelayManager`.
- Affected files: `client.rs` metadata/publish helpers only.
- Tradeoffs: Hits latency + watchdog + “delete old helpers” for Marmot. Does **not** remove the unoptimized iOS stack the user asked to kill. Two WebSocket implementations stay.
- Effort: M

## Recommendation

**Approach A.** Deleting `NostrRelayManager` onto a single shared pool (B) would make iOS Marmot worse: geohash currently lives on a *separate* socket set, which is the one thing the Swift stack still does right. Dual pools keep that isolation, put both on the optimized I/O, and let Compose stop adding geo relays to the Marmot client (`ensure_geohash_relays`).

Ship as two PRs if needed: (1) dual pool + migrate Marmot metadata I/O + circuit breaker on every fetch, (2) iOS cutover + delete `NostrRelayManager` + location-notes FFI. Do not merge (2) before (1).

Not 100% sure about Tor on the geo pool: confirm whether core’s nostr-sdk client already uses the same SOCKS as `TorURLSession` on iOS. If not, that is a blocker for PR 2, not a reason to keep `NostrRelayManager` forever.

## Open questions

- Tor path for the geo pool on iOS (Arti in-core vs host SOCKS). Blocker for cutover, not for PR 1.
- Location notes FFI shape (subscribe kind 1 + `#g` + neighbors). Compose gap: no UI this change.
- Whether Connection → Internet probe stays a host-side REQ→EOSE (today `NostrRelayManager` / `RelayBenchmark.kt`) or becomes a core helper.
- `docs/SONAR-DEMO-TESTPLAN.md` still says “Marmot sync is poll-based” — stale; update when shipping.

## Next

`/ship --from-brainstorm docs/brainstorms/2026-08-17-relay-fetch-push-unification.md`
