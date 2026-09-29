# Chat-list presenter (Compose pilot)

A pilot of Cash App's presenter architecture ([The state of managing state
with Compose](https://code.cash.app/the-state-of-managing-state-with-compose),
[Molecule 1.0](https://code.cash.app/molecule-1-0),
[Flow testing with Turbine](https://code.cash.app/flow-testing-with-turbine))
on the Compose Messages list: phone Home and the desktop sidebar. Android and
desktop only. The native SwiftUI app is the primary Sonar app and is not
touched; see [iOS gap](#ios-gap-and-the-path-into-sonar-core).

A presenter is a `@Composable` function that takes `events: Flow<Event>` and
returns one immutable `Model`, using the Compose **runtime** only (`remember`,
state, `LaunchedEffect`) and plain Kotlin control flow. No UI, no Android.

## Layers

```
 SonarCore (FFI, local store)
   │  ChatListCore: chats · conversationSummaries · recentMessagePages
   │                markConversationRead · conversationChanged
   ▼
 ChatListRepository            the list's local data layer (moved out of SonarAppState)
   chats · messagesByChat · latestByChat · unreadByChat
   refresh() single-flight + one trailing pass
   collectChanges() per-chat 50 ms debounce
   markRead() optimistic, suppressed while in flight
   │
   │        ChatListSources: the projection SonarAppState still owns
   │        (mesh↔npub fold, duplicate-group dedupe, pending chats,
   │         Note to Self, titles from kind-0, actions)
   ▼        ▼
 ChatListPresenter.present(events): ChatListModel
   merge across transports · pin Note to Self · unread per folded group set
   filter · events → actions
   ▼
 HomeScreen (App.kt) / DesktopSidebar (SonarDesktopRoot.kt)
   render model.rows; mute and Bluetooth presence resolved per visible row
```

Files: `apps/sonar/composeApp/src/commonMain/kotlin/chat/bitchat/sonar/chatlist/`.

`SonarAppState` keeps the same public surface (`chats`, `unreadByChat`,
`refreshChats()`, `markGroupsRead()`), now delegating to the repository, so
the other ~600 functions that read them did not change.

## How it runs

**Production calls the presenter from the UI composition**
(`state.chatListPresenter.present(events)` in `HomeScreen`, a
`waitForHydration = false` instance in the desktop sidebar). The presenter's
reads recompose on the UI frame clock, like the code it replaced.

We did not use `launchMolecule` in production. Molecule is a test dependency
only, so the app ships no new library. `launchMolecule` would add a second
`Recomposer` and a process-wide `Snapshot.registerGlobalWriteObserver`. That
observer schedules an apply notification after any state write anywhere in
the app, and `SonarAppState` has 86 state holders. Its `StateFlow` would also
reach the UI one collector hop later. The Cash App case for it, feeding a
View-based UI, does not apply to an all-Compose app.

**Tests run it headless**: `moleculeFlow(RecompositionMode.Immediate) {
presenter.present(events) }.flowOn(StandardTestDispatcher(testScheduler))`,
asserted with Turbine (`awaitItem()`, `expectNoEvents()`). Plain JVM, no
emulator, no relay.

Two traps we hit, both documented at `ChatListPresenterTest.models`:

1. **Turbine collects on an unconfined dispatcher.** Molecule schedules its
   snapshot apply on the collecting context, so without `flowOn` every single
   state write recomposes synchronously and emits its own model. A test that
   asserts a burst coalesces then fails for a reason the app does not have.
   A queued dispatcher is the faithful stand-in for the frame clock.
2. **Unapplied setup writes.** State written before the flow starts is not
   yet applied (nothing called `Snapshot.sendApplyNotifications()`), so the
   first recomposition after start is a redundant copy of the first model.
   The app's global snapshot manager applies as it goes, so tests flush first.

## What the tests cover

| Test | What it pins | Real call site? |
|---|---|---|
| `ChatListRepositoryTest` (9) | per-chat debounce (one chat, many chats), single-flight reload + one trailing pass, failure releases waiters, local paint from the summary index, optimistic mark-read held while in flight, failed mark releases suppression (#383), viewing suppress not stored, failed summary read keeps badges | yes: `SonarAppState` delegates to this class |
| `ChatListPresenterTest` (12) | first model painted before core answers, loading gate, desktop paints before hydration, merge + Note to Self pin across kinds, unread summed over folded groups (both kinds), mark-read → next model, a burst of writes → one model, filter, events → actions per kind, empty/invites, catch-up hint | presenter yes; the fold projection is faked |
| `ChatListAppStateTest` (4) | a real `SonarAppState` over a fake `ChatListCore`: sidebar paints the restored snapshot with zero core calls, a local reload reorders and folds duplicate groups into one badged row, opening a folded 1:1 marks every duplicate group read, a mesh-folded person's White Noise unread badges their Bluetooth row and opening it marks exactly that group | yes, end to end through the real projection |
| `NoteToSelfTest` (2 moved) | Note to Self pinned and never unread, now asserted on the rendered model | yes |

`ChatListAppStateTest` is the first test that constructs `SonarAppState` with
its core faked at a seam and drives a real open path. `docs/REGRESSIONS.md`
lists "anything needing a `SonarAppState` instance" as the highest-leverage
gap in the repo. The `ChatListCore` seam is how to close it path by path.

## Bug found: mesh-folded rows had no unread dot (fixed)

Compose built mesh-folded Home rows without `unread` or `verified`. A person
met over Bluetooth who then wrote over White Noise never got a dot on Android
or desktop, while iOS folds both into the row (`buildHomeDMRows`,
`hasUnreadMarmotMessage(in: groupSet)`). This is the `docs/CHAT-TYPES.md` bug
class: group-keyed state not resolved for the mesh kind. Writing the
"both chat kinds" presenter test is what surfaced it.

The fix carries on `MeshDmRow.groupIds` the groups `recomputeConversations`
already folds into each row. Those are the linked npub's direct groups, the
set `transcriptGroupIds` resolves when `openDm` read-marks the row. The
presenter sums the live unread map over them. Resolving the set again per row
would cost about 2 ms a row in Bech32 decodes (JVM, 278 groups), on the main
dispatcher. Ledger entry R-052, QA-142.

## Pain points

- **An eager whole-list model vs viewport-bounded reads.** Two per-row fields,
  mute and Bluetooth presence, walk the fold closure: `muteIdsFor` resolves
  duplicate and folded groups, O(chats) with Bech32 decodes. The old UI paid
  that only for visible rows. A model that carries them for every row pays it
  for every row on every change. They stay per visible row in the renderer,
  so the model is not quite "everything the UI needs". The real fix is
  core-side: precomputed per-conversation fields (below) or a paged model
  (Signal's `ConversationListDataSource`).
- **Hidden inputs defeat `remember`.** Much of the projection reads plain
  fields (`linkByFp`, `groupFoldMap`, version counters) that are not snapshot
  state, so `remember(keys)` inside the presenter would go stale. The
  presenter therefore reads the existing memoized projections (`visibleChats`,
  `marmotRow`) and does only O(rows) work per recomposition. Moving that
  projection into the presenter needs its inputs to become observable first.
- **A value-returning composable is not a restart scope.** Called directly,
  the presenter's reads invalidate the calling screen (`HomeScreen`), not a
  scope of their own. That costs the header and FAB a skip check per change.
  The measurements below show no regression.
- **Events are asynchronous.** A tap now reaches `openChat` one dispatch
  later, through the `LaunchedEffect` collector, instead of inside the click
  handler. The chat-open measurement below starts at the push and does not
  see this hop; it is sub-frame on the main looper.
- **Synchronous consumers pin the data layer.** Thirty `refreshChats()`
  callers await completion and then read `chats`, and delete paths write
  `chats` and read it back immediately. A Molecule-owned data layer would
  make those reads asynchronous, so the data stays in a plain repository
  with snapshot state and only the projection is a presenter.

## iOS gap and the path into sonar-core

**Platform:** iOS (`ios/`). **Reason:** the SwiftUI app is the primary app
and has its own, already memoized list (`SonarAppStore.dmRows`,
`buildHomeDMRows`, R-039); a Compose presenter cannot run there, and this
pilot does not retire the `SonarAppState.kt` ↔ `SonarAppStore.swift` mirror.
The mesh unread fix has no iOS gap: iOS already folds unread into mesh rows.
**Follow-up path:** move the shared list logic down into `sonar-core`, then
give each host a thin per-screen model over it (this presenter on Compose, an
`@Observable` list model on iOS).

What both hosts implement twice today, and where it should live:

| Logic | Compose today | iOS today | Proposed core home |
|---|---|---|---|
| Rows from the index + bounded pages, recency order with a stable tie-break | `ChatListRepository.publishLocal`, `hydrateLocalConversationRows`, `orderChatsByLocalRecency` | `MarmotChatModel` summaries + row cache | `conversation_list(limit, cursor)` over `conversation_summary` |
| Duplicate direct groups → one row (R-003) | `dedupeDirectMarmotChats` / `directMarmotPeerKey` (Bech32 per member per call) | `directMarmotGroups(matchingGroupId:)` | fold by counterpart pubkey in the index (core already knows members) |
| Unread summed over a conversation's groups; Note to Self never unread | `ChatListPresenter.rows` | `hasUnreadMarmotMessage(in:)`, `snPinNoteToSelfFirst` | `ConversationListRow.unread` |
| Mark-read with in-flight suppression and viewing suppression | `ChatListRepository.markRead` / `applyUnread` | `viewingUnreadGroupIds` | `mark_conversation_read(conversation_id)` that marks the whole set and returns the new row, so hosts need no suppression set |
| Change coalescing | per-chat 50 ms debounce + single-flight reload | `scheduleConversationRefresh` + R-037 coalescer | one `ConversationListChanged { ids }` per drain, batched in core |
| Bluetooth ↔ White Noise fold (fingerprint ↔ npub) | `recomputeConversations`, `transcriptGroupIds`, `groupFoldMap` | `buildHomeDMRows`, `marmotGroupIdsByConversationId` | once the link table lives in core (mesh is moving to Rust, #309), return mesh-folded rows with their `group_ids` |

A sketch of the core row, i.e. the fields `ChatListModel` needs, minus what is
host-only (live Bluetooth presence, navigation):

```rust
pub struct ConversationListRow {
    pub conversation_id: String,      // group id, or "mesh:<fingerprint>" once folded in core
    pub kind: ConversationKind,       // Marmot | MeshFolded | NoteToSelf
    pub group_ids: Vec<String>,       // the set unread is summed over and read-marking clears
    pub title_hint: Option<String>,   // group name; hosts overlay kind-0 names until core caches them
    pub preview: Option<MessagePreview>, // latest host-visible row (R-017 classification applied)
    pub latest_at_secs: i64,
    pub unread: u64,
    pub muted_until: Option<i64>,     // lets the list drop the O(chats) mute walk
}
fn conversation_list(&self, limit: u32, after: Option<Cursor>) -> Result<Vec<ConversationListRow>>;
fn mark_conversation_read(&self, conversation_id: &str) -> Result<ConversationListRow>;
```

With that API, `ChatListRepository` becomes a thin pager and `ChatListSources`
mostly disappears. On iOS, `buildHomeDMRows` shrinks to mapping rows plus
presence. The first step is the Marmot-only half (rows, duplicate fold,
unread, mark-read). It needs no mesh state in core and removes the most
duplicated code.

## Next steps

1. Move the remaining projection inputs to snapshot state (fold maps, version
   counters) so `visibleChats` / `marmotRow` can move into the presenter as
   `remember`ed derivations and their manual memo keys can go.
2. Route the share picker (`SonarShareToScreen`) through the presenter's
   `Filter` event. It filters Marmot rows by the raw group name, which is blank
   for most 1:1s, the same bug Search fixed for QA-A13/A14.
3. Core `conversation_list` / conversation-level `mark_conversation_read`
   (table above), then the iOS per-screen model over it.
