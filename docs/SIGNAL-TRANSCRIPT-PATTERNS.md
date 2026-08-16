# Signal transcript patterns → Sonar

Battle-tested transcript performance patterns from **Signal-iOS** and **Signal-Android**, mapped to Sonar (`ios/` + `apps/sonar/`).

Restart brief: [`docs/brainstorms/2026-07-18-signal-transcript-pattern-extraction.md`](brainstorms/2026-07-18-signal-transcript-pattern-extraction.md)  
Prior canvas: `signal-ios-chat-mapping.canvas.tsx`  
Related: R-009, PR #310, keyboard / chat-open benches in [`PERFORMANCE.md`](PERFORMANCE.md)

**Goal:** extract how Signal manages the chat transcript and make Sonar’s open / keyboard / scroll / pagination **as performant**, not clone Signal chrome.

Shared policy and Compose host live in **`packages/transcript-engine-*`** (KMP) and **`ios/localPackages/TranscriptEngine`** (SPM). See [`packages/transcript-engine/README.md`](../packages/transcript-engine/README.md).

---

## Shared DNA (adopt on both apps)

Both Signals keep chat fast the same way. Shells differ (top-align vs reverse); **performance policy does not**.

| # | Pattern | Signal idea | Sonar today | Adopt |
|---|---|---|---|---|
| 1 | **Local DB is chat state** | Open paints from local window; network updates DB later | Core pages + local-first rules | Keep; never gate open on relay |
| 2 | **Bounded load window** | ~viewport / pageSize×buffer; cap displayables | Partial `messages_page` / loadOlder | Finish cursor window; UI binds only active page |
| 3 | **Async land + merge** | Background fetch → commit list → then scroll | Mostly OK | Gate programmatic scroll on “list settled” |
| 4 | **Scroll continuity** | Token / distance-from-bottom / pending scroll re-request | `scrollTo(preserveID)` / Compose key+offset | Real continuity token (Phase 1→2) |
| 5 | **Owned bottom chrome** | Composer/IME via layout guide or insets — list frame stays full-height | Sibling composer + latch overlays | List owns bottom inset/padding = chrome |
| 6 | **wasAtTail → pin else lockstep** | Capture before inset change; pin live edge or offset+=Δ | `SNTailPinLatch` / `TranscriptTailPinner` | Fold into shared policy; keep 10ms coalesce |
| 7 | **Declarative open** | LiveEdge \| UnreadDivider \| Jump(id) | unreadAnchor / sn-bottom | One `OpenAction` enum both apps |
| 8 | **Stable identity + cheap bind** | Message id keys; typed VH; payloads; pre-measure | Keys OK; rebuild cost on agent DMs | Precomputed row VMs; no per-IME full window rebuild |
| 9 | **Instrumentation** | ConversationOpen metrics | `SONAR_BENCH` / chat_open_first_frame | Keep markers on local path only |
| 10 | **Thumbnail-first media** | List binds bubble-sized thumbs; full-res only in viewer; file-backed; no open-time transfer-state churn | **Compose ↔ Signal-Android:** path-sampled `decodeThumbnailFromPath` (Glide/`DecryptableUri` shape), disk RESOURCE thumbs, synthesise Available via `existsSync`, progress overlay throttled ~100ms; **iOS ↔ Signal-iOS:** ImageIO thumb + skip `@Published` on disk hit | Keep list off full `ByteArray`/ARGB; warm thumbs after download |
| 11 | **Quiet open paint** | DiffUtil / stable VH; first open paints once from local DB | Compose: **first open** awaits bounded local page then `push` (no snapshot→replace); reopen uses `retainedTranscriptByChat`; `sameTranscriptPaint`; layout-proof LiveEdge | Never mount Chat on a provisional snapshot that hydration will replace |
| 12 | **Upload bar + durable staging** | Attachments stage locally before network; photo/album progress paints under the bubble; voice notes use Signal Sending + control spinner (no horizontal bar); mid-upload kill resumes; upload work must not share the sync runner or the text-send FIFO (Signal isolates upload jobs from sync/text; Sonar matches that *host-lane* intent, not full JobManager job-split) | Core: `MediaUploadObserver` + `.sonar-media-staging` sidecar; Blossom PUT streams with byte progress; shared upload HTTP client (keep-alive, redirect-none); pipelined per-item encrypt→upload with concurrency 5; outbox publish only after URL; per-entry in-flight claim; `Committed`+outbox recovery payload before `mark_outbox_pending` so crash cannot re-upload a second kind-445; Failed TTL + orphan Committed purge; stage/load/terminal persist via `spawn_blocking`. **iOS:** `mediaQueue`/`mediaLane` for sendMedia* + resume (serial UniFFI tradeoff); wait for local node via `ensureConnected`, never `ensureRelayConnected` for Blossom. **Compose:** media off `marmotSendMutex` on `Dispatchers.IO` (uploads may overlap; claim guards double-work). Both: XChat-style bar for images/albums only (~100ms); voice = Sending + play-control spinner; tap cancels image upload; single-flight resume | Never lose staged plaintext on disconnect; never gate Blossom on relay; never double-publish one staged album; never put the under-image bar on voice notes; never FIFO-park text/sync behind a Blossom PUT |

---

## Shell difference (UX only — pick one later)

| | Signal-iOS | Signal-Android | Sonar |
|---|---|---|---|
| Axis | Chronological top→bottom | Reverse LM (index 0 = newest @ bottom) | Spike A vs B evidence hosts exist |
| Short feed | Top-aligned; empty above composer | Messages sit on composer | Same winner on both apps |
| Keyboard attachment | `keyboardLayoutGuide` + `updateContentInsets` | `InsetAwareConstraintLayout` + IME guideline | Same *ownership* math per platform |

Do **not** mix reverse coordinates with chronological pinners. Short-feed choice does **not** block Phase 1 (shared policy).

---

## Signal-iOS primitives (reference)

| Primitive | Role |
|---|---|
| `ConversationCollectionView` + `ConversationViewLayout` | Full-height UIKit list; sticky dates; continuity |
| `CVLoadCoordinator` / `MessageLoader` / `CVRenderState` | Bounded window; immutable pre-measured items |
| `updateContentInsets` | Own top/bottom inset; wasAtBottom → pin or lockstep |
| `keyboardLayoutGuide` on toolbar | Composer rides IME; collection frame unchanged; host must not also take SwiftUI keyboard safe-area |
| `DebouncedEventLastOnly(0.01)` | Coalesce inset thrash |
| `scrollToInitialPosition` / `CVScrollAction` | Open policy |
| `ScrollContinuity` / `lastKnownDistanceFromBottom` | Pagination without jump |

**Deliberately avoids:** SwiftUI `ScrollView`+`LazyVStack` as transcript; reverse layout; spacers / `contentInset.top` from contentSize to fake bottom-align; shrinking list height for keyboard; mutating cell frames for IME.

---

## Signal-Android primitives (reference)

| Primitive | Role |
|---|---|
| `ConversationLayoutManager` (`reverseLayout=true`) | Newest @ index 0; short feeds on composer |
| `ConversationDataSource` + `FixedSizePagingController` | `pageSize=25`, `bufferPages=3`; local IO |
| `submitList` + `ScrollToPositionDelegate` | Commit-gated scroll |
| `SnapToTopDataObserver` / was-at-tail insert snap | Auto-follow only at live edge |
| `InsetAwareConstraintLayout` / keyboard guideline | IME-owned chrome |
| Typed VH + pool + payloads | Cheap scroll/bind |
| `ThumbnailView` / `V2ConversationItemThumbnail` | Pre-size from DB w/h; Glide `.override(bubbleW,bubbleH)` + `DecryptableUri`; BlurHash placeholder; skip reload when slide unchanged |
| `TransferControlView` + `PartProgressEvent` | Progress overlay only; ~100ms throttle; not a list rebuild |
| `ZoomingImageView` / region decode | Fullscreen ≠ list decode path |
| Adapter DiffUtil / stable keys | Open hydration that matches the painted window is a no-op — no full conversation rebuild |

**Deliberately avoids:** full-history in adapter; scrolling before commit; snap-to-bottom on placeholder fills while in history; treating reverse as optional decoration without inverting open/pin/pagination; decoding capture-resolution bitmaps (or allocating full plaintext `ByteArray`s) into the conversation list; publishing transfer “Available” on every bind for local files; replacing the open transcript list identity when the bounded page is unchanged.

---

## What Sonar must stop

- Treating SwiftUI `ScrollView`+`LazyVStack` (or unowned Compose sibling shrink) as the long-term transcript engine.
- Top spacers / `contentInset.top` from `contentSize` to glue short chats to the composer.
- GeometryReader / `@State` height writes every keyboard frame.
- Fixed-delay double `scrollTo` as open/continuity.
- Full-window rebuild / reclassify on every IME tick.

---

## Phased adoption

### Phase 0 — Catalog (this doc) ✅
Pattern extraction complete (iOS + Android agents).

### Phase 1 — Shared scroll / open / inset policy ✅
Pure policy + tests (Swift + Kotlin mirrors):

- `OpenAction`: `liveEdge` | `unreadDivider` | `jump(id)`
- `wasAtTail` + inset delta → `pin` | `lockstep` | `ignore` (dragging)
- Continuity token shape: `(anchorId, edgeDistance or pixelOffset)`
- Fold `SNTailPinLatch` / Compose pinner into the policy

**Compose:** landed (`TranscriptScrollPolicy` + tests; pinner thin adapter).  
**iOS:** landed (`SNTranscriptScrollPolicy` + tests; latch/coalescer adapters; `SNMsgList` open/resnap call sites).

Policy helpers are production; list hosting cut over in Phase 2/3 below.

### Phase 2 — Native list hosts (Debug default ON → production) ✅
- **iOS:** `SNTranscriptCollectionHost` (`UICollectionView`, `keyboardLayoutGuide`, owned insets, lockstep, ContinuityToken, `SNTranscriptOpenAction`). **Debug default ON** when UserDefaults unset; Release also default ON after Phase 3 (kill switch `SONAR_TRANSCRIPT_COLLECTION_HOST=0` / Debug Settings).
- **Compose:** `TranscriptPhase2HostScaffold` (owned-pad LazyColumn, Lockstep via `decideInsetChange`, ContinuityToken, OpenAction). Top-align only. **Debug default ON** via `sonarTranscriptPolicyHostEnabled` (every build after Phase 3; kill switch `SONAR_TRANSCRIPT_PHASE2_HOST=0`). Spike B `reverseLayout` stays Settings-demo only.
- Landed outside the Phase 2 shell: iOS first-open awaits local page before `push(.dm)`; Compose keyed Day/Unread/Row feed items; media Ready/thumb skip-reload; SNMsgList ContinuityToken on loadOlder fallback.

### Phase 3 — Signal engine + production cutover ✅
- **iOS `SNTranscriptCollectionHost`:**
  - **Pre-measured cells** — `SNTranscriptRowHeightCache` (width-scoped, key = message id + text hash + state + cont/author/footer/expanded bits) + one off-screen `UIHostingController` sizing pass; FlowLayout `estimatedItemSize = .zero` and exact `sizeForItemAt`. `contentSize` is exact from the first layout — this removes the self-sizing under-measure that broke Phase 2 opens.
  - **Sticky day headers** — day sections via pure `snTranscriptDaySections` (unit-tested) + `sectionHeadersPinToVisibleBounds`; floating `SNStickyDayHeader` pill.
  - **Settled open** — snapshot commit, `layoutIfNeeded`, then one exact live-edge/divider offset (no visited-cell settle loop). Continuity edge-distance restore is exact.
  - **Read-more expansion** lives on the controller (survives cell reuse), reconfigures + re-measures the row.
  - **Stable media geometry** — decoded thumbs render into `snReservedMediaSize` (stored dims / fixed skeleton), so decode never reflows a measured row.
  - **Default ON in Debug + Release.** Kill switches: `SONAR_TRANSCRIPT_COLLECTION_HOST=0` env or Settings → Developer (Debug). `SNMsgList` remains the fallback shell + the Mac list engine (AppKit collection parity is the remaining tracked gap).
- **Compose:**
  - `ChatScreen` renders through `TranscriptPhase2HostScaffold` (owned pad + IME overlay + Pin/Lockstep) **by default in every build**; kill switch `SONAR_TRANSCRIPT_PHASE2_HOST=0` / `-Dsonar.transcript.policy.host=0` falls back to the sibling-composer shell.
  - **Sticky day headers** — `ChatFeedList` emits each Day item as a `stickyHeader` (same one-entry-one-index order, so continuity/open index math is unchanged); floating `StickyDayHeader` pill.
  - Row geometry was already data-driven (reserved media boxes), so LazyColumn item-index anchoring stays exact.
- Tests: `SNTranscriptDaySectionTests` (sections + height cache), `ChatFeedListItemsTest` (flattened list + index math), `TranscriptPhase2CutoverJvmTest` (default-ON kill-switch shape).
- Remaining follow-ups (tracked, non-blocking): Spike B reverseLayout product decision; Jump(id) from search; Mac AppKit list engine; off-main pre-measure if profile shows first-open measure cost on very large windows.
- **Jump(id) from reply chips:** quote-chip tap sets the existing open-action Jump target (`jumpMessageIdAtOpenByDM` / `openChatJumpMessageId`) while the chat is already open. Paint from the denormalized snapshot; do not fetch the parent on open.

---

## Parity checklist (both apps)

1. Fully-read open → live edge  
2. Unread open → divider at viewport top; keyboard does not yank to tail  
3. Keyboard at tail → last message above composer  
4. Keyboard in history → lockstep; no blank band / false unpin  
5. loadOlder / loadNewer → no jump (token, not hope-scroll)  
6. Short-feed matches chosen shell (A or B) on **both** platforms  
7. Agent-DM keyboard does not rebuild the whole window every frame  

### Device smoke (Phase 2/3 hosts ON)

Install Debug on Pixel (`./gradlew :composeApp:installDebug`; `adb install -r` only — never uninstall Sonar) and Vincenzo iPhone (Debug `xcodebuild` + `devicectl device install app`), force-stop, then:

1. First open of a chat (process cold) — no snapshot→rebuild flash  
2. Reopen same chat — instant retained paint  
3. Fully-read → live edge; unread → divider  
4. Keyboard at tail / in history (R-009)  
5. loadOlder — no jump  
6. Media-heavy chat — no decode/reflow thrash  
7. Day chips correct while scrolling up  

Spike B reverseLayout short-feed remains an explicit next cutover after this smoke passes.

---

## Spike A / B WIP

Uncommitted evidence hosts on `pr-310-keyboard-bench`:

- **A** — top-aligned; can swap real DM when `SONAR_SPIKE_SIGNAL_TRANSCRIPT_A=1`  
- **B** — reverse demo via Settings → Developer  

They illustrate shells. **Phase 1 policy is the next product step**, not more A/B polish.

---

## Key Sonar call sites (cutover map)

| Concern | iOS | Compose |
|---|---|---|
| List | `SonarComponents.swift` `SNMsgList` → UIKit host | `App.kt` `ChatScreen` LazyColumn |
| Latch | `SNTailPinLatch` / coalescer (via `SNTranscriptScrollPolicy`) | `TranscriptTailPinner` |
| Open / unread | `SNTranscriptScrollPolicy.openAction` + DM open | same in ChatScreen |
| Load window | core `messages_page` + convo loadOlder | `SonarAppState` loadOlder / loadNewest |
| Composer attach | `SNComposer` sibling → keyboardLayoutGuide | scaffold `imePadding` + owned pad |
| Tests / ledger | `SNTranscriptScrollPolicyTests`, `SNTailPinLatchTests`, R-009 | Compose pinner tests |
