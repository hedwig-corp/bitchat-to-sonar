# Regression Invariants

Bugs this project has fixed **more than once**. Each entry states an invariant that
must keep holding, names the test that fails without it, and points at every
platform that implements it.

Read this before changing conversation, transcript, send, dedup, or notification
behaviour. Adding an entry is cheaper than debugging the same bug a third time.

## How to use it

- **Before you change a hotspot file** (see below): scan the invariants for the area you are touching.
- **Before you "simplify"**: check `Rejected` — an approach that looks obviously better has often already been tried and reverted.
- **When you fix a recurring bug**: add an entry. The `Guarded by:` test must fail without your fix.
- **When you fix something on one platform**: fill in the other platform's call site, or say why it does not apply. This is the single most common way these bugs come back.

`scripts/check-regression-ledger.sh` (run in CI) asserts every `Guarded by:`
citation still resolves to a real, enabled test: declared in a test location,
annotated (`@Test` / `#[test]` / `#[tokio::test]`), not `@Ignore`d, and inside the
named class's body. Entries therefore cannot rot silently when a test is renamed.

What it cannot check, and what review must:

- whether the test is still **meaningful**;
- whether it pins the **real call site** rather than a helper the test itself feeds (this is exactly how R-001 came back — see its `Not guarded` note);
- whether the test actually **runs in CI** (iOS tests currently do not).

Prefer `Not guarded:` / `Partly guarded:` notes over silence. A green checker on
an overclaiming entry is worse than an admitted hole, because it stops people
looking.

## Hotspot files

The files that attract the most fix commits. The top two are the same
conversation logic written twice, and a fix landing on one but not its mirror is
how most entries below came back.

Re-derive the ranking rather than trusting a number in a doc — absolute counts
depend on how you match "a fix" and go stale as `main` moves:

```sh
for f in \
  apps/sonar/composeApp/src/commonMain/kotlin/chat/bitchat/sonar/SonarAppState.kt \
  ios/bitchat/Views/Sonar/SonarAppStore.swift \
  ios/bitchat/Views/MarmotChatView.swift \
  core/sonar-core/src/client.rs
do
  printf '%4d  %s\n' "$(git log origin/main --follow --format='%s' -- "$f" | grep -cE '^fix(\(|!|:)')" "$f"
done
```

As of `ac75ef820` that yields **19 / 18 / 12 / 12** — the ordering, not the
magnitude, is the useful part. (Counting any subject starting with "fix"
case-insensitively roughly doubles every figure; counting only literal `fix:`
roughly halves it. The ranking is stable across all three.)

## Entry format

```markdown
### R-00N — <invariant in one line>
**Invariant:** what must always hold.
**Breaks as:** the user-visible symptom when it does not.
**Call sites:** iOS `File::symbol`; Compose `File.symbol`
**Guarded by:** `TestClass.testName`
**History:** #fixed -> #regressed -> #refixed
**Rejected:** approach tried before, and why it failed.
```

---

## R-001 — Send echoes reconcile against out-of-window canonical rows

**Invariant:** Optimistic send-echo matching searches the freshly read local page, not only the bounded/pinned render window.

**Breaks as:** Two identical outgoing bubbles, the second stuck on "Sending" forever.

**Why:** A conversation pinned to its older historical edge — or whose window is simply full — admits no new rows into the render window. The canonical copy of an outgoing send therefore never reaches the matcher, the echo is never fulfilled, and it renders next to the real row.

**Call sites:** iOS `MarmotChatView.swift::reconciledOptimisticMessages(freshCanonical:)`; Compose `SonarAppState.withSendEchoes` -> `TranscriptDisplayPolicy.reconcileSendEchoes(freshCanonical=)`

**Guarded by:** `MarmotOptimisticEchoTests.freshDatabaseRowOutsidePinnedWindowFulfillsEcho` (iOS, exercises `reconciledOptimisticMessages(freshCanonical:)`)

**Also guarded by:** `TranscriptDisplayPolicyTest.outOfWindowCanonicalRowFulfillsEchoAndIsAdmitted`, `TranscriptDisplayPolicyTest.windowedCanonicalRowIsNotAdmittedTwice`, `TranscriptDisplayPolicyTest.identicalOutOfWindowRowsConsumeEchoesOneForOne`

**Enforced by the compiler:** `freshCanonical` has **no default** on `reconcileSendEchoes`/`planSendEchoDisplay`. Dropping it at the `withSendEchoes` call site — the exact shape of this regression — is a compile error (`No value passed for parameter 'freshCanonical'`), not a silent behaviour change. That default was what let the Compose port omit the argument while every helper-level test stayed green, so the hazard is removed rather than tested for. Restoring a default would re-open this entry.

**History:** #215 fixed the same-second match -> #273 made cleanup conditional on the heuristic and regressed it -> #290 ported the iOS `freshCanonical` argument.

**Rejected:**
- *Removing the optimistic echo for established groups.* Premise "iOS has no echo" is **false** — `SonarAppStore.sendDm` calls `marmot.send`, which is `MarmotChatModel.send`, which does `appendOptimistic`. Removing it also loses the retryable row on send failure (toast only, message vanishes) and makes first paint wait on `send_text` behind `membership_gate`, violating the Signal-Comparable Performance Rule.
- *Widening the timestamp slack.* Lets a recent identical send consume a still-pending echo; see R-002.

---

## R-002 — An older identical row must not consume a new echo

**Invariant:** Only a canonical row stamped at/after the echo (minus a few seconds of slack) can fulfil it, and rows already visible when the echo was created are excluded.

**Breaks as:** Re-sending text identical to an older message makes the in-flight message vanish until the real send lands.

**Why:** `created_at` is whole-second and echo/canonical share no id, so matching is heuristic. Without a lower bound, an old identical row is a valid "match".

**Call sites:** iOS `MarmotChatView.swift::serverMessage(_:matchesOptimistic:excludingServerIDs:)` (`optimisticMatchSlack`); Compose `TranscriptDisplayPolicy.eligibleCanonicalRowsForSendEcho` + `SonarAppState.previouslyPublishedMessageIdsByEcho`

**Guarded by:** `TranscriptDisplayPolicyTest.priorIdenticalRowWithinFormerSlackDoesNotConsumeNewEcho`

**Also guarded by:** `TranscriptDisplayPolicyTest.priorSameSecondIdenticalRowDoesNotConsumeNewEcho`, `TranscriptDisplayPolicyTest.sameSecondCanonicalRowFulfillsOptimisticEcho`

**History:** #215 -> #290 (kept while fixing R-001).

**Rejected:** *Matching on content alone.* Cannot distinguish a repeated send from its own echo.

---

## R-003 — One person is one conversation

**Invariant:** A peer discovered over different transports, or holding duplicate direct Marmot groups, renders as exactly one chat row and one transcript, keyed by stable Noise fingerprint / npub identity.

**Breaks as:** The same person appears as two chats; messages route into the wrong conversation; duplicate transcripts.

**Call sites:** iOS `SonarAppStore.swift` (conversation folding); Compose `SonarAppState.duplicateDirectMarmotChats` / `preferredDirectMarmotChat` / `peerIdForMarmotGroup`

**Guarded by:** `ConversationRegressionSmokeTest.duplicateSaraGroupsKeepOneNewestTranscript`

**Also guarded by:** `ConversationRegressionSmokeTest.saraMessageCannotRouteIntoVincenzoConversation`, `ConversationRegressionSmokeTest.rotatingVincenzoAliasesCollapseWithoutAbsorbingSara`, `ConversationFoldTest.foldIdentityRequiresMatchingNpub`

**Partly guarded:** the cited tests pin *chat-list* dedup and identity routing. The "one transcript" half is not pinned: if duplicate groups still collapse to one row but transcript loading stopped merging every duplicate group's messages, all of them stay green. See Unguarded.

**History:** #164 deduped direct Marmot chats by peer; re-asserted by the "Fix What We Break Rule" in `CLAUDE.md`.

**Rejected:** *Splitting per transport.* This is the bug, not a feature — see the Fix What We Break Rule.

---

## R-004 — A message notifies at most once

**Invariant:** Notification dedup is keyed by message id, survives same-second messages, and its state is cleared on account wipe.

**Breaks as:** Duplicate notifications for one message; or (over-correcting) a real second message in the same second is silently swallowed.

**Why:** Timestamp-only dedup cannot separate "already notified" from "second message in the same second" — both directions are live regressions.

**Call sites:** iOS `SonarAppStore.swift` notification routing; Compose `SonarAppState` (`notificationSeenMessageIds` / `notificationLatestSecs`)

**Guarded by:** `EventDrivenRefreshTest.notifiesForSecondIncomingMessageInSameSecond`

**Also guarded by:** `EventDrivenRefreshTest.oldBackfillDoesNotRenotifyCachedLatest`, `EventDrivenRefreshTest.seedPassAndOpenChatDoNotNotify`, `EventDrivenRefreshTest.incomingBeforeOwnLatestStillNotifies`

**Not guarded:** the account-wipe half. The cited tests only exercise `newestUnseenIncoming`; none runs a wipe path. Both platforms now *implement* it — iOS clears `seenMarmotNotificationMessageIDs` in `clearAccountBoundLocalStateForRestore()` and `performWipe()`, next to the analogous `scannedPayMessageIDs = []` — but no test pins either. Pinning the iOS side needs a constructible `SonarAppStore`; no test builds one today. See Unguarded.

**History:** #276 deduped by message id -> #288 cleared the dedup state on account wipe, Compose only -> the iOS half was found missing while writing this ledger (the store outlives a wipe, so a restored account's messages could be silently swallowed) and fixed the same way.

**Rejected:** *Dedup on latest-timestamp only.* Drops a genuine second message in the same second.

---

## R-005 — A newer local send must not starve another chat's catch-up

**Invariant:** The missing-message resync floor is derived per conversation from its own local transcript, never from one global latest timestamp.

**Breaks as:** Sending in chat A advances a global watermark past chat B's unfetched messages; B's messages never arrive.

**Call sites:** `core/sonar-core/src/client.rs` (sync watermark / per-group catch-up); consumed by both apps

**Guarded by:** `client.rs::group_message_catchup_floor_uses_peer_message_not_later_local_send`

**History:** #160 added the per-group floor and its test -> #177 (watermark pinning) -> #252 (forced sync skipped the batched fetch). Stated as a rule in `CLAUDE.md` under the Signal-Comparable Performance Rule.

**Note:** `ConversationRegressionSmokeTest.coldRestartPaintsPersistedOrderThenNewSaraMessageMovesOnlySara` looks related but only checks restored chat ordering; it stays green if the floor regresses. The Rust test above is the real guard.

**Rejected:** *One global latest-timestamp floor.* Exactly the starvation above.

---

## R-006 — Radio power-off retires mesh links immediately

**Invariant:** When the Bluetooth radio becomes unusable (`.poweredOff`, `.unauthorized`, `.resetting`), every `peers[*].isConnected` must be demoted immediately; DM routing must never rely on the ~8-13s `checkPeerConnectivity` sweep to notice a dead radio.

**Breaks as:** A DM composed right after turning Bluetooth off is handed to the dead radio ("via mesh" in the composer) instead of falling back to White Noise; the send silently dies.

**Why:** CoreBluetooth delivers no `didDisconnectPeripheral` / `didUnsubscribeFrom` for links the radio drops, so the normal disconnect paths never clear `isConnected`.

**Call sites:** iOS `BLEService.swift::invalidateMeshLinks(reason:)` (called from both CB state handlers); Compose: not yet implemented — no adapter-off receiver exists and Android links may self-clear via `MeshGatt.onConnectionStateChange`; unproven, see Unguarded.

**Guarded by:** `BLEServiceCoreTests.bluetoothPoweredOff_stopsRoutingOverMesh`, `BLEServiceCoreTests.bluetoothUnauthorized_stopsRoutingOverMesh`, `BLEServiceCoreTests.bluetoothResetting_stopsRoutingOverMesh`, `BLEServiceCoreTests.announceAfterRadioOffDoesNotResurrectMeshRoute`

**Coverage (honest):** All four drive the **central** state machine through the DEBUG seam `_test_handleCentralState`, which calls `handleCentralState(_:central:)` with a `nil` manager. So they pin the demote logic and the announce gate (`meshRadioAvailable`), but **not**:
- the real `centralManagerDidUpdateState` delegate callback — the seam bypasses CoreBluetooth entirely, and `CBManagerState` cannot be forced on a live manager;
- the **peripheral-role** handler (`peripheralManagerDidUpdateState`), which carries its own copy of the teardown (`subscribedCentrals` / `centralToPeerID` / `characteristic`). A regression there — e.g. dropping `invalidateMeshLinks` from its `.resetting` case — would not fail any test;
- the real race the gate exists for: the tests deliver the late announce *after* the invalidation deterministically, rather than exercising the actual `messageQueue`/`bleQueue` interleaving;
- the CoreBluetooth-side teardown calls (`stopScan`, `cancelPeripheralConnection`, `stopAdvertising`), since `central` is `nil` in tests.

**History:** #302.

**Rejected:**
- *A `bluetoothState` check inside `SonarAppStore.meshReachable`.* The view-model copy is updated asynchronously and starts at `.unknown` — a second, staler source of truth; and `peers[*].isConnected` has six other consumers (presence, topology, images, calls) that would keep lying.
- *Shortening `blePeerInactivityTimeoutSeconds`.* Keeps the bug class and causes disconnect flapping on healthy links.

---

## R-007 — Return inserts a newline in every message composer

**Invariant:** Message composers are multiline fields where Return inserts a newline; only the adjacent send button sends the draft.

**Breaks as:** Return intermittently sends or dismisses the keyboard instead of inserting a newline, depending on the app surface and software keyboard.

**Call sites:** Apple `SNMessageComposerField` (used by `ContentView`, `SNComposer`, and `MarmotConversationView`); Compose `MessageComposerTextField` (used by `ChatScreen`, `GeoDmScreen`, and `SonarChannelScreen`)

**Guarded by:** `MessageComposerFieldUiTest.returnKeyInsertsNewlineInSharedComposer`

**Coverage (honest):** The JVM UI test presses a real desktop Enter key against the shared Compose field and also pins `ImeAction.None`, so both the hardware-key path and the Android software-IME contract fail if the policy regresses. Apple routes every message composer through one SwiftUI field with `.submitLabel(.return)` and no submit handler, but iOS tests do not currently exercise software-keyboard input in CI.

**History:** `a4a9e6a5e` made the composers multiline but left conflicting submit/default IME behavior -> #313 reported the intermittent Return failure -> #314 centralized and pinned the policy across both apps.

**Rejected:**
- *`ImeAction.Default` on Compose.* It is already `BasicTextField`'s effective default and lets the platform/keyboard choose the action, so it does not change the failing path.
- *Fixing only the reported screen.* The issue did not identify a platform or conversation type, and the same product contract had diverged across six reachable composers.

---

## R-008 — Verified bitchat peers appear in Radar before Sonar capabilities

**Invariant:** A verified normal bitchat announce is immediately visible in
Radar. The later Sonar `0x53` packet upgrades that stable-fingerprint item in
place; capability settling applies only to conversation folding.

**Breaks as:** A nearby stock bitchat user is absent for 1.5 seconds, or forever
when no later UI refresh publishes the already-verified radio snapshot.

**Call sites:** iOS `SonarAppStore.swift::nearbyPeers`; Compose
`SonarAppState.updateMeshPeersFromRadio` / `MeshRadio.setPeerUpdateListener`

**Guarded by:** `NearbyDiscoveryPolicyTest.verifiedBitchatPeerIsVisibleBeforeSonarCapabilitiesArrive`

**Also guarded by:** `NearbyDiscoveryPolicyTest.unchangedKnownPeerPolicyIsACompleteNoOp`,
`NearbyDiscoveryPolicyTest.peerUpdateBurstKeepsOnlyOnePendingRefresh`,
`NearbyDiscoveryPolicyTest.freshAnnounceNeverCrossesNativeLinkBoundary`

**Partly guarded:** the tests pin the shared Compose Radar filter, the
change-only policy gate, conflated callback queue, and fresh-peer native-call
gate used by the real call sites. Android listener wiring and the native iOS
call site are compile-checked but have no platform-runtime test; iOS tests still
do not run in CI. PR #316 was additionally reproduced and verified on the
physical Pixel 10 Pro that reported the ANR.

**History:** #57 introduced the 1.5-second conversation recovery hold on both
platforms -> #316 added a bounded Compose snapshot refresh but left the Radar
hold in place -> #316 scoped settling back to conversations and added push
invalidation for verified peer/profile changes.

**Rejected:**
- *Removing the settle window everywhere.* Reopens R-003 by briefly rendering
  the same person as separate mesh and White Noise conversation rows.
- *Depending only on the one-second snapshot poll.* Avoids a permanent stale UI
  but still adds visible latency after the radio has already verified the peer.
- *Launching one UI coroutine per radio callback and notifying after every
  policy assignment.* Creates a feedback loop (`profile refresh` -> `policy`
  -> `peer update`) and an unbounded main-thread queue. Policy writes must be
  change-only, event bursts conflated, and native snapshot reads off-main.

---
## R-009 — Layout must never steal a pinned transcript tail

**Invariant:** While the reader is at the transcript tail, a layout/content change (keyboard opening, composer growth, window resize, media growth, or an appended message) must keep the newest message visible above the fold; only the user's own scroll may unpin. In particular, "am I at the bottom" state that the change itself invalidates must not gate the re-pin.

**Breaks as:** Opening the keyboard hides the last screenful of messages behind the IME, or a newly sent bubble remains below the fold until manual scroll. Once the sentinel-based near-bottom flag flips false, later layout changes can become no-ops.

**Why:** Both list stacks are top-anchored: viewport shrink or content growth keeps the first visible row, not the last. Both platforms' live "near bottom" signals are consumed by that same change, so the pinner must carry the previous frame's tail state and separately observe genuine user scrolling. Timers (the #303 iOS fix pinned at now/+0.35s) lose to whatever settles after them.

**Call sites:** iOS `SonarComponents.swift::SNMsgList` (`SNTailPinLatch` + `SNUserScrollObserver` + sentinel/count/viewport events); Compose `App.kt::TranscriptTailPinning` (`TranscriptTailPinner.onFrame`).

**Guarded by:** `SNTailPinLatchTests.shrinkKeepsPinningWhileSentinelIsCovered`

**Also guarded by:** `SNTailPinLatchTests.appendedOutgoingRowAtTailFollows`, `SNTailPinLatchTests.replacedTailAtCapacityStillFollows`, `SNTailPinLatchTests.nonKeyboardLayoutTheftSnapsBack`, `SNTailPinLatchTests.keyboardShowWithoutShrinkDoesNotLeaveStickyPin`, `SNTailPinLatchTests.userScrollAwayIsRespectedAfterTailReturns`, `SNTailPinLatchTests.nonTouchScrollTowardTopCountsAsUserScroll`, `SNTailPinLatchTests.programmaticTailFollowIsNotUserScroll`, `SNTailPinLatchTests.downwardDecelerationAtVisibleTailIsIgnored`, `SNTailPinLatchTests.layoutDrivenUpwardOffsetIsNotUserScroll`, `SNTailPinLatchTests.nonTouchHistoryScrollAfterResizeStillCounts`, `SNTailPinLatchTests.anchoredOpenNeverPins`, `TranscriptTailPinnerTest` and `TranscriptTailPinningUiTest` (Compose, real `LazyListState` wiring).

**Coverage (honest):** The Swift tests pin only the latch decision — a helper the SwiftUI body feeds itself, exactly the shape rule 2 warns about; nothing exercises the `GeometryReader`/`ScrollViewReader` wiring or that `scrollTo` actually lands (and iOS tests do not run in CI). The Compose UI test is the stronger guard. A raced/failed pin on iOS is only caught by eye.

**History:** #283 (Compose) -> #303 (iOS, notification + fixed delays; incomplete) -> this fix (previous-frame pinner + explicit user-scroll observation).

**Rejected:**
- *Fixed-delay double pin after `keyboardWillShow` (#303).* The 0.35s timer races the safe-area animation and anything that settles later (late transport-leg merge, sticker/media decode); one lost race also strands `isNearBottom` at false, disabling every later keyboard open.
- *`defaultScrollAnchor(.bottom)`.* iOS 17+ only (deployment target is 16.0), and it would fight the unread-anchor open, which deliberately starts in history.
- *Flipping the ScrollView 180°.* Structurally bottom-anchored, but inverts every gesture/accessibility behaviour and would rewrite the whole transcript surface.


## Unguarded

Gaps we know about. Each line is a concrete backlog item; fold it into its `R-`
entry once a test exists. Listing a gap is the point — an entry that overclaims
its coverage is worse than an honest hole, because it stops people looking.

- **R-003, the one-transcript half.** Cited tests pin chat-list dedup and identity routing, not "duplicate groups' messages merge into a single transcript". The merge lives in `SonarAppState.duplicateDirectMarmotChats` (private, needs an instance); `dedupeDirectMarmotChats` — the pure seam the tests use — only covers the chat-list half. Closing it means extracting the transcript-source selection into a pure function, or an injectable `SonarCore`.
- **R-004, account wipe, both platforms.** Now implemented on iOS and Compose, but pinned by no test. The Compose path needs an injectable `SonarCore`; the iOS path needs a constructible `SonarAppStore`, and no iOS test builds one today (`MarmotOptimisticEchoTests` only exercises static functions).
- **Anything needing a `SonarAppState` / `SonarAppStore` instance.** The three gaps above share one root cause: neither app object can be constructed in a test, so only pure helpers are reachable. This is the single highest-leverage testing investment in the repo — see the injectable-core note in the Signal architecture notes. Until then, prefer removing a hazard (as R-001 does with a mandatory parameter) over testing for it.
- **iOS tests do not run in CI.** No workflow invokes `xcodebuild test` / `ios/bitchatTests`, so `MarmotOptimisticEchoTests` guards R-001 only for someone running it locally. `scripts/check-regression-ledger.sh` verifies the test *exists*; nothing verifies it still *passes*. Until an iOS test job exists, treat Swift citations as weaker than Kotlin/Rust ones.
- **Account key durability.** `CLAUDE.md`'s Account Key Durability Rule lists five blocking invariants (never delete-before-add, never regenerate on keychain error, ...) with no regression test cited here.
- **Compose side of R-006 (Bluetooth-adapter-off).** Compose has no `ACTION_STATE_CHANGED` receiver — nothing pushes adapter-off into `MeshRadio`, whose `stop()` has the right teardown but only runs on discovery-policy changes. Android links may self-clear via `BluetoothGattCallback.onConnectionStateChange`, so whether R-006 applies there is unproven; needs a Pixel with a peer in range to confirm. `apps/sonar` has no `androidUnitTest` source set, so the decision would have to move into a pure `commonMain` helper the way `bleScanRestartReason` did.
- **Duplicate-send.** Nothing pins "one tap produces exactly one canonical row". Worth adding if the duplicate bubble in #290 ever proves to be two real canonical rows rather than an echo — that was investigated and left unproven.
- **Mesh-folded chat id resolution.** Group-keyed state (`unreadByChat`, snapshots, read-marking) must be resolved through `transcriptGroupIds`, never indexed with a `mesh:` route id — and position/count logic must not trust a mesh chat's first painted feed before it catches up with `latestKnownMessageSecs` (the BLE window publishes before the White Noise leg merges). Both broke the unread divider for mesh chats only (PR #303, commits 070c00f3e + 80feb4ade); no test pins either invariant. `transcriptGroupIds` needs instance state, so pinning likely means extracting the resolver or an in-process store test. See `docs/CHAT-TYPES.md`.
- **Sticker ref resolution on the hosts (#307).** The bug fixed there — a stale session pack LRU pinning a validated-local fallback, so a newly-added sticker showed the failed placeholder for the session while older ones rendered — lives in `SonarAppState.stickerImage(ref)` and `MarmotChatModel.stickerData(for:)`. Both need a real `SonarCore`, so none of the following is pinned; the helper tests in `StickerSendEchoTest` / `MarmotStickerOptimisticTests` only self-feed the key and retry-schedule functions and would stay green if the whole repair were deleted. Same root cause as the three gaps above. Unpinned invariants, all of which have already broken once:
  - **A received sticker renders even when its pack is not installed.** The installed set (`installedPackCoordinates`) gates only the *picker* via `shouldExposeCachedStickerPack` — what you may SEND. Anything a peer sends must resolve from the reference alone. If an install check ever leaks into the ref-render path, every sticker from a pack the recipient does not have goes black.
  - **A "not in pack" verdict is only trusted when a relay was actually reached.** `fetch_sticker_pack_singleflight` falls back to stale validated-local metadata when the relay fetch fails, so negative-caching an offline answer would keep a good sticker black for the session — the same class of bug #307 fixes. Guarded in code by the `isRelayConnected()` condition on `rememberUnresolvableStickerRef`, by nothing else.
  - **An explicit tap on the failed placeholder always retries**, bypassing the negative cache (`userInitiated`), so a wrong verdict is never a dead end.

  The core half IS pinned (`sticker_ref_prefetch_claims_are_cross_batch_and_released`, `cancel_on_wiped_session_abandons_inflight_fetch_after_wipe`).
