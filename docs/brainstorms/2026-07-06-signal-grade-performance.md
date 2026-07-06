# Signal-grade performance for Sonar conversations (Approach B)

Date: 2026-07-06. Grounded in on-device measurements (iPhone 14 Pro Max, 32
Marmot groups) and the fixes shipped earlier today (PR #177 core watermark fix;
render-storm fixes in NostrRelayManager/SonarAppStore on this branch).

## Clarified Problem Statement

**Goal:** Bring Sonar to Signal-level perceived performance on the three key
metrics — conversation UI (typing/scroll/open), send latency, cold
start→synced — starting from iOS as the reference surface, with Compose gaps
explicitly tracked and closed right after.

**Constraints:**
- Existing repo rules stay binding: local-first paint (never block on relay),
  no work on the render path, per-chat resync (never a global timestamp).
- Structural refactor is allowed, but delivered as incremental, measurable PRs
  (device-bench before/after each phase).
- The serialized MLS engine queue remains the only place MLS state is mutated
  (no-lock invariant).

**Non-goals:**
- Feature parity with Signal features Sonar doesn't have yet (stories, group
  calls, ...).
- Optimizing the geohash/BLE mesh path beyond preventing it from degrading the
  chat surface.
- Rewriting the UI toolkit (SwiftUI/Compose stay; we adopt Signal's
  architecture, not UIKit).

**Success criteria** (measured with `scripts/bench/device-bench.sh` +
Instruments):
- Chat open: first paint from local DB <100ms; 60fps typing/scroll with
  multi-thousand-message transcripts.
- Send: local echo <50ms; "sent" state ≤2s on healthy relays; one dead relay
  adds no perceived latency.
- Cold start on the real device: `t0→t4` ≤5s (today 55–115s); `t3→t3a` ≤10s
  (today ~50s).
- Zero transcript re-renders for unrelated events (presence, wallet, BLE).

## Measured baseline (2026-07-06, why this plan exists)

- `SonarDMScreen.body` rebuilds the whole `dmMsgs()` array on every store
  invalidation: per message it re-runs `payMapping`, `meshMediaItem`,
  `meshParseStickerContent`, time formatting, then sorts — on the main thread.
- `SonarAppStore` republishes 9 upstream `objectWillChange` publishers 1:1;
  before today's throttle the store invalidated ~10×/sec (geohash presence
  kind-20001 firehose incrementing a dead `@Published` relay-stats counter).
- Cold start: `t3_relay_connected → t3a_published` ≈ 50s on every run —
  `publishKeyPackage` + `publishProfile` run sequentially on the serial engine
  queue BEHIND the PR #166 foreground refresh chain
  (`ensureSubscriptions` + `syncForce` + `drainPending`), and `startPolling`
  (message receive) only starts after them. Each Rust `send_event` waits up to
  10s (`WAIT_FOR_OK_TIMEOUT`) per relay via `join_all`.
- Sends queue behind whatever occupies the serial engine queue; the optimistic
  echo stays in "sending" until `sendText` gets its turn.

## Selected approach: B — Signal-style render pipeline (CVLoader-like)

How Signal-iOS does it (`ConversationViewController` + CV pipeline):
`CVLoadCoordinator` listens to GRDB database changes, coalesces invalidations,
and has `CVLoader` build a complete immutable `CVRenderState` on a background
serial queue (view models, attributed strings, measured layout). The main
thread only applies the prebuilt diff. Row-scoped invalidation (touched
interaction ids), a bounded load window (~30 messages + older/newer paging),
an isolated composer, and caches everywhere (names, avatars, thumbnails).

### Phase 1 — Conversation UI (iOS)
A `ConversationLoadCoordinator` per open conversation: changes to
`messagesByGroup`/DB produce an immutable, pre-parsed render state
(`[SNMessage]` with pay/media/sticker already classified, time strings already
formatted) on a background queue, published as a diff to a small
per-conversation `ObservableObject`. `SonarDMScreen` reads only precomputed
state; the monolithic store no longer feeds the transcript. Bounded window
(~30 messages + paging) if `messagesByGroup` is not already page-bounded.
Equatable row views so SwiftUI skips unchanged bubbles.

Files: new `ios/bitchat/Views/Sonar/ConversationViewState.swift` (or similar),
`SonarDMScreen.swift`, `SonarAppStore.swift` (dmMsgs → coordinator),
`MarmotChatView.swift` (model change hooks).

### Phase 2 — Cold start & send critical path (iOS + core)
Start the drain loop (`startPolling`) immediately after `t3_relay_connected`;
run `publishKeyPackage` + `publishProfile` concurrently and OFF the serialized
engine-queue critical path (they don't mutate MLS ordering relative to drain).
Keep `sendText` ahead of maintenance work on the queue where possible.

Files: `ios/bitchat/Views/MarmotChatView.swift` (connectRelaysIfNeeded,
startPolling), `ios/bitchat/Services/MarmotService.swift` (queue usage),
possibly `core/sonar-core/src/client.rs` (publish helpers).

### Phase 3 — Cross-platform parity (core Rust slice of Approach C)
Move message classification (pay/media/sticker control lines) into
`sonar-core` at ingest time (the conversation index already exists), exposed
over FFI as ready view-model pages with per-conversation version counters, so
Compose inherits it instead of reimplementing `dmMsgs` in Kotlin.

Files: `core/sonar-core/src/client.rs`, `conversation_index`, `sonar-ffi`,
thin adapters per platform.

### Alternatives considered
- **A. Incremental surgery only** (memoize `dmMsgs`, Equatable rows, parallel
  publishes): fast and low-risk but leaves O(transcript) per render and the
  monolithic-store invalidation class of bugs; Compose inherits nothing.
- **C. Full core-owned view state (libsignal-core pattern)** end-to-end:
  best long-term parity, but largest effort/risk up front; adopted here only
  as the Phase 3 slice.

## Rollout / verification
Each phase ends with a `device-bench` run and a before/after number in the PR
description. Phase order: 1 (UI) → 2 (cold start/send) → 3 (parity). Compose
gaps from Phases 1–2 are tracked issues with a follow-up path, per the
cross-platform rule.

## Tracked platform gaps (Compose — apps/sonar/), per the cross-platform rule
PR #178 lands the core (Rust) and Apple (iOS) surfaces. The core changes are
FFI-additive, so Android/desktop keep compiling, but two capabilities are
iOS-only until a follow-up:

1. **Background cold-start publishes.** `publish_key_package_background` /
   `publish_profile_background` are only called from iOS
   (`MarmotChatView.connectRelaysIfNeeded`). `SonarCore.android.kt` /
   `SonarCore.jvm.kt` startup still call the blocking `publishKeyPackage()` /
   `publishProfile()`, so Android/desktop keep blocking on relay OK acks that
   iOS no longer waits for. Follow-up: switch the Compose startup + profile
   publish to the `*_background` variants.
2. **Core-owned message classification.** `MessageInfo.classification` is
   consumed only by iOS; Kotlin's `MessageInfo.toCommon()` drops the field and
   `App.kt` still classifies on the render path via the looser
   `PayLine.decode(m.content)` (which, unlike core, would bubble a malformed
   line like `⚡PAY|1|bad id|5|extra`). Follow-up: map `classification` in
   `toCommon()` and render from it, retiring the Kotlin parser on the render
   path.

Both are tracked as spawned follow-up tasks; neither blocks the iOS/core
correctness this PR delivers.

## Open questions
- Is `messagesByGroup` already page-bounded? If not, Phase 1 includes
  Signal-style `loadInitialMapping` windowing.
- Does the geohash presence firehose need source-side reduction (tighter
  subscriptions/sampling), or is render isolation enough? Re-measure after
  today's fixes.
