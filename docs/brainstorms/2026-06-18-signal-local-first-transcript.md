# Signal-Style Local-First Transcript Loading

Date: 2026-06-18

This note records the design target for Sonar conversation loading after the
conversation recovery stabilization branch. The goal is not to copy Signal's
code; it is to preserve the performance property Signal has: opening an
existing conversation paints from local storage first, and network work only
mutates local state in the background.

## Signal Research

Primary references:

- Signal Android `ConversationRepository.getConversationThreadState` creates a
  `ConversationDataSource` and `PagingConfig` with a page size and buffer pages:
  https://github.com/signalapp/Signal-Android/blob/5929866ae02f8443d128c9a45a31ad32afa9b69d/app/src/main/java/org/thoughtcrime/securesms/conversation/v2/ConversationRepository.kt
- Signal Android `ConversationDataSource` implements `PagedDataSource`; `load`
  reads a bounded window from `SignalDatabase.messages.getConversation(threadId,
  start, length, filterCollapsed = true)` and records timing splits for message
  load, extra data fetch, model conversion, and header work:
  https://github.com/signalapp/Signal-Android/blob/5929866ae02f8443d128c9a45a31ad32afa9b69d/app/src/main/java/org/thoughtcrime/securesms/conversation/v2/data/ConversationDataSource.kt
- Signal iOS `CVLoadCoordinator` creates a `MessageLoader` backed by
  `ConversationViewBatchFetcher(InteractionFinder(threadUniqueId))`, kicks off
  initial mapping asynchronously, supports older/newer load windows, and listens
  to database changes to enqueue render reloads:
  https://github.com/signalapp/Signal-iOS/blob/4a369b66390f248a2a2c019620ce05e4124a6c89/Signal/ConversationView/Loading/CVLoadCoordinator.swift

Design inference from those sources:

- The transcript is local-storage-first. The visible conversation opens from a
  local database window, not from a server round trip.
- Conversation opening is bounded. Signal Android requests a page plus buffer;
  Signal iOS uses load requests and batch fetching rather than loading an entire
  unbounded history into the view.
- Network activity is not the first-paint dependency. Incoming network work
  should write or update the local store, then the UI reloads from that store.
- Performance is treated as a feature. Signal Android instruments conversation
  size/load/conversion timing; Sonar should keep similar measurement points for
  transcript open work.

## Sonar Problem Statement

Before this local-first slice, the Sonar paths had these performance hazards:

- Rust/core exposed only full history for Marmot groups:
  `SonarCore.messages(groupId)` and FFI `messages(group_id_hex) ->
  Vec<MessageInfo>`.
- iOS `MarmotChatModel.loadLocal()` loops every group and loads every message
  into `messagesByGroup`.
- iOS `SonarAppStore.openedDM` could be called by both a tap site and
  `SonarDMScreen.onAppear`, and each call could run `ensureConnected()`,
  `loadLocal()`, and relay-aware `refresh()`.
- Compose `SonarAppState.openChat()` assigned the visible `messages` only after
  `refreshChats()`.
- Rust `send_text()` publishes first and only records locally after
  `process_incoming(&event)`, so durable local visibility can wait on relay
  publish.

## Implemented First Slice

Branch: `codex/signal-local-first-transcript`

- iOS `openedDM` now keeps per-conversation Marmot warm-up work single-flight.
  Duplicate tap/on-appear opens for the same id join the in-flight work instead
  of starting parallel refreshes.
- iOS Marmot open work calls local hydration first through
  `loadLocalIfConnected(groupId:)`. When an existing Marmot group is known, it
  loads one local transcript page for that group instead of scanning every
  group. Relay-aware reconciliation runs separately via
  `refreshWhenConnected(groupId:)`.
- Compose `openChat` now assigns the local Marmot transcript before
  `refreshChats()`, using `SonarCore.messagesPage(chatId, limit, offset)` for
  the immediate transcript window. It re-reads the same bounded page after
  refresh only if the same chat is still open.
- Core/Rust/FFI now exposes a bounded local page API:
  `messages_page(group_id, limit, offset)`. Swift bindings are regenerated in
  `ios/localPackages/SonarCore/Sources/SonarFFI.swift`; Compose Android/JVM
  generated Kotlin bindings remain build-generated ignored artifacts.
- Core text send now records the message locally first, stores encrypted relay
  event metadata in a durable outbox sidecar, publishes in the background, and
  projects pending/sent/failed delivery state through Rust, FFI, iOS, and
  Compose.

This intentionally leaves existing tap-site pre-open calls in place: they can
start the local hydrate slightly before the destination view appears, while the
destination `onAppear` call is deduplicated by the store.

## Target Architecture

The long-term transcript path should work like this:

1. A conversation row or route is selected.
2. The app immediately hydrates the latest local transcript window for that one
   conversation.
3. The screen paints from that local window.
4. Background Marmot/Nostr sync starts or continues idempotently.
5. Sync writes new/deleted/updated messages to the local database.
6. UI updates react to local database changes.
7. Older/newer messages are loaded by bounded page or cursor requests.

Network work must not gate steps 2 or 3. Full-history scans and all-group
transcript reloads must not be on the chat-open critical path.

## Core-Owned Transcript Engine

Sonar should centralize the Signal-style transcript model in `sonar-core`, not
duplicate the same sequencing rules in Swift and Kotlin. The app layers should
render transcript state and request pages/actions; core should own the durable
state transitions.

`sonar-core` should own:

- Local message schema, migrations, and indexes.
- Latest, older, and newer transcript windows for one conversation.
- Incoming relay event validation, decrypt/process, dedupe, and DB upsert.
- Outgoing pending message insert before relay publish.
- Send status transitions such as pending, sent, failed, retrying.
- Relay echo reconciliation against local pending rows.
- Per-conversation/per-relay sync cursors and gap-fill state.
- Transcript change events after local DB mutations.

iOS and Compose should own:

- List rendering and scroll/anchor state.
- Calling `open_conversation(group_id, page_size)`.
- Calling `load_messages_before(group_id, cursor, limit)`.
- Calling `send_text(group_id, text)`.
- Displaying the message state returned by core.

The intended API shape is:

```text
open_conversation(group_id, page_size) -> ConversationSnapshot
load_messages_before(group_id, cursor, limit) -> MessagePage
load_messages_after(group_id, cursor, limit) -> MessagePage
send_text(group_id, text) -> LocalMessageId
observe_conversation(group_id) -> TranscriptEvent stream/poll API
start_background_sync() -> void
```

This gives both supported app surfaces the same behavior: local DB is the chat
state, network only mutates the DB, and UI reads bounded DB windows.

## Core API Direction

The first core API landed in this branch is a local transcript page:

```text
messages_page(group_id, limit, offset) -> [MessageInfo]
```

Implementation notes:

- MDK currently exposes `get_messages(group_id, Some(Pagination(limit, offset)))`
  with bounded offset pagination and default/max limits.
- Sonar wraps that as an additive API rather than changing `messages()`, so
  callers that still need broad/default history keep their current behavior.
- The Rust/core page is newest-first in local storage order; FFI sorts each page
  oldest-first for UI display consistency.
- The first app page size is 100 messages. That is an initial window, not a
  retention cap.
- Generated Kotlin UniFFI bindings and native libraries are ignored build
  artifacts; Gradle regenerates them via `buildDesktopRustCore` and
  `buildAndroidRustCore`. Swift `SonarFFI.swift` is checked in and was
  regenerated with `core/build-ios.sh`.

Remaining API work:

- Replace offset pagination with a stable cursor page:
  `messages_page(group_id, limit, before_cursor?) -> MessagePage`. The cursor
  should be based on local ordering keys such as `created_at`/`processed_at`
  plus event id, not just offset, so pagination stays stable while new messages
  arrive.
- Add explicit older/newer page UI and state on both iOS and Compose.
- Move sends toward a local outbox/pending persistence path before relay
  publish, matching Signal-style durable local visibility.

## Complete Production Plan

Ship this as one PR with separate commits. Each commit should compile and pass
its targeted tests so the PR is reviewable and bisectable.

### Commit 1: Document The Contract

- Keep `AGENTS.md`, `CLAUDE.md`, and this note aligned around the rule:
  local DB is the chat state, network only mutates the DB.
- Record the Signal Android/iOS research and Sonar-specific production target.

### Commit 2: Core DB Paging And Indexes

- Add explicit local transcript tables or verified storage mappings for:
  `group_id`, local ordering cursor, event/message id, sender, created time,
  body/media metadata, delivery state, and local pending id.
- Add or verify indexes on conversation id plus local ordering key, message id,
  and delivery state.
- Replace chat-open full-history access with bounded core APIs:
  latest page, page before cursor, and page after cursor.
- Add large-history tests with mixed chat and non-chat rows.

### Commit 3: Durable Pending Send And Outbox

- Landed first production slice in this branch: text sends insert/process the
  local row first, write encrypted relay event metadata to an outbox sidecar,
  publish to relays in the background, persist retry metadata across restart,
  and surface pending/sent/failed state to both app surfaces.
- Follow-up: extend the same local-first pending row semantics to media sends
  after encrypted upload staging is moved behind durable local state.

### Commit 4: Core Transcript Change Events

- Emit conversation-scoped transcript events after DB mutations.
- Include enough information for app layers to update/refresh one local window:
  inserted/updated/deleted ids, affected group id, and optional cursor hints.
- Keep relay sync invisible to UI except through these local-state changes.

### Commit 5: iOS Uses The Core Transcript Engine

- Open a DM by calling the core local snapshot API and painting immediately.
- Observe core transcript changes for the active conversation.
- Load older messages through cursor pages.
- Send through the core pending/outbox API, removing UI-only optimistic echoes.
- Keep relay connection and sync background-only for first paint.

### Commit 6: Compose Uses The Core Transcript Engine

- Match the iOS behavior on Compose: local page first, background sync second.
- Replace open-chat full refresh dependencies with core transcript snapshots.
- Load older messages through cursor pages.
- Send through the shared pending/outbox API.

### Commit 7: Production Performance Gates

- Add regression tests or benchmarks for:
  10k-message DM open, many groups, offline restart, slow relay, and pending
  send visibility.
- Add lightweight timing logs or metrics for:
  `chat_open_local_ms`, `first_paint_ms`, `page_load_ms`,
  `relay_sync_ms`, and `send_pending_insert_ms`.
- Verify real-device iOS startup/open behavior and Compose build/test behavior.

## Production Acceptance Criteria

- Opening an existing chat paints the latest local page without relay/network
  availability.
- Opening one chat does not load unrelated groups or full transcript history.
- Scrolling older history loads one bounded page at a time.
- Sending shows a durable pending row immediately and survives restart.
- Relay sync fills gaps and updates delivery state by mutating the DB.
- Incoming messages reach UI only after core writes or updates local state.
- iOS and Compose have the same transcript semantics through shared core APIs.

## Performance Rules For Future Work

- Preserve Signal-comparable open performance: first existing transcript paint
  comes from local storage, not from relay/server sync.
- Do not add new chat-open work that scans every group, loads every message, or
  waits for `ensureConnected()`, `sync()`, or `refresh()` before showing local
  messages.
- Keep sync idempotent and backgrounded. It may update local state after first
  paint, but it must not block first paint.
- For sends, the target design is local outbox/pending persistence first, then
  network publish updates delivery state.
- Instrument or inspect critical paths when changing transcript load behavior:
  time to first transcript paint, local page fetch, merge/model conversion, and
  background sync duration.
- If a platform cannot preserve this performance property in the same change,
  document the platform, reason, measured risk, and follow-up path.
