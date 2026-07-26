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

**Call sites:** iOS `SonarAppStore.swift` (`dmRows` + `snCollapseMeshDMRowsByIdentity` / `sonarPeerKey`); Compose `SonarAppState.duplicateDirectMarmotChats` / `preferredDirectMarmotChat` / `peerIdForMarmotGroup` / `meshConversationAliasGroups`

**Guarded by:** `ConversationRegressionSmokeTest.duplicateSaraGroupsKeepOneNewestTranscript`

**Also guarded by:** `ConversationRegressionSmokeTest.saraMessageCannotRouteIntoVincenzoConversation`, `ConversationRegressionSmokeTest.rotatingVincenzoAliasesCollapseWithoutAbsorbingSara`, `ConversationFoldTest.foldIdentityRequiresMatchingNpub`, `SonarConversationFoldTests.sameNpubMeshFingerprintsCollapseToOneHomeRow`, `SonarConversationFoldTests.rotatingVincenzoAliasesCollapseWithoutAbsorbingSara`, `SonarConversationFoldTests.liveMeshRoutePrefersConnectedAliasOverCanonical`, `SonarConversationFoldTests.rekeyAlignsLiveMeshRowWithFullPeerKeysCanonical`, `SonarConversationFoldTests.filterPeerKeysDropsConflictingFavoriteClaim`

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

## R-007 — Composer Return is platform-correct (newline on mobile, send on desktop)

**Invariant:** On iOS/Android soft keyboards, Return inserts a newline and only the adjacent send button sends. On macOS / Compose desktop, bare Return/Enter sends the draft (desktop messenger default). Multiline desktop shortcuts (Shift/Option+Return) are deferred.

**Breaks as:** On phones, Return intermittently sends or dismisses the keyboard instead of inserting a newline. On desktop, Return neither sends nor inserts a newline (the #314 macOS regression).

**Call sites:** Apple `SNMessageComposerField` (used by `ContentView`, `SNComposer`, and `MarmotConversationView`); Compose `MessageComposerTextField` (used by `ChatScreen`, `GeoDmScreen`, and `SonarChannelScreen`)

**Guarded by:** `MessageComposerFieldUiTest.returnKeySendsDraftOnDesktopComposer` (and `returnKeyInsertsNewlineWhenDesktopSendDisabled` for the mobile-style path)

**Coverage (honest):** The JVM UI test presses a real desktop Enter key against the shared Compose field with `onSend` wired and pins `messageComposerEnterSends` + `ImeAction.None`. Apple macOS uses `.onKeyPress(.return)` + `.onSubmit`; iOS keeps `.submitLabel(.return)` with no submit handler. iOS tests do not currently exercise software-keyboard input in CI.

**History:** `a4a9e6a5e` made the composers multiline but left conflicting submit/default IME behavior -> #313 reported the intermittent Return failure -> #314 centralized Return=newline everywhere, which left macOS Return dead (neither send nor newline) -> desktop Enter=send restored while keeping mobile newline.

**Rejected:**
- *`ImeAction.Default` on Compose.* It is already `BasicTextField`'s effective default and lets the platform/keyboard choose the action, so it does not change the failing path.
- *Fixing only the reported screen.* The issue did not identify a platform or conversation type, and the same product contract had diverged across six reachable composers.
- *Shipping Shift/Option+Return newline in the same change.* Prefer Enter=send now; track the combo in #334.

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

**Call sites:** iOS production (Phase 3 cutover) `TranscriptEngine` `TranscriptCollectionHostViewController` (`transcriptOwnedBottomContentInset` in `TranscriptOwnedInset.swift`, applied in `TranscriptCollectionHost.swift::updateOwnedInsetsFromChrome`) via Sonar adapter `SNTranscriptCollectionHostAdapter.swift` → `SNTranscriptCollectionHost.swift`; iOS fallback `SonarComponents.swift::SNMsgList` (`SNTailPinLatch` + `SNUserScrollObserver` + sentinel/count/viewport events); Compose production `packages/transcript-engine-compose` (`TranscriptHostScrollEffects` / Sonar shim `TranscriptPolicyHostScaffold.kt`) (`TranscriptTailPinSession` + `decideInsetChange` Pin/Lockstep); Compose fallback `App.kt::TranscriptTailPinning` (`TranscriptTailPinner` → `TranscriptTailPinSession` / `packages/transcript-engine-policy`).

**Guarded by:** `SNTailPinLatchTests.shrinkKeepsPinningWhileSentinelIsCovered`

**Also guarded by:** `SNCollectionHostInsetTests.ownedInsetUsesViewportSpaceNotContentSpace`, `SNCollectionHostInsetTests.ownedInsetStableAcrossScrollPositions`, `SNCollectionHostInsetTests.mediaHeightFingerprintChangesWhenDimsArrive`, `SNCollectionHostInsetTests.floatingComposerGapRequiresSingleKeyboardOwner`, `SNTailPinLatchTests.keyboardFrameChangeCapturesVisibleTailBeforeShrink`, `SNTailPinLatchTests.expandKeepsPinningAfterPhantomKeyboardInsetClears`, `SNTailPinLatchTests.preLayoutKeyboardClampIsNotUserScroll`, `SNTailPinLatchTests.tailRevisionTracksOnlyCountAndLiveEdge`, `SNTailPinLatchTests.tailSnapBurstCoalescesUntilDelivery`, `SNTailPinLatchTests.appendedOutgoingRowAtTailFollows`, `SNTailPinLatchTests.replacedTailAtCapacityStillFollows`, `SNTailPinLatchTests.nonKeyboardLayoutTheftSnapsBack`, `SNTailPinLatchTests.keyboardShowWithoutShrinkDoesNotLeaveStickyPin`, `SNTailPinLatchTests.userScrollAwayIsRespectedAfterTailReturns`, `SNTailPinLatchTests.nonTouchScrollTowardTopCountsAsUserScroll`, `SNTailPinLatchTests.programmaticTailFollowIsNotUserScroll`, `SNTailPinLatchTests.downwardDecelerationAtVisibleTailIsIgnored`, `SNTailPinLatchTests.layoutDrivenUpwardOffsetIsNotUserScroll`, `SNTailPinLatchTests.nonTouchHistoryScrollAfterResizeStillCounts`, `SNTailPinLatchTests.anchoredOpenNeverPins`, `SNTailPinLatchTests.keyboardDismissOvershootIsClampedToContentBounds`, `SNTailPinLatchTests.transcriptOpenUsesBottomAnchorOnlyWhenFullyRead`, `SNTailPinLatchTests.fullyReadOpenResnapsUntilLiveEdgeLands`, `SNTailPinLatchTests.clearLiveEdgeOpenRequiresOwnedChrome`, `SNTailPinLatchTests.markLeftBottomIgnoresProgrammaticLiveEdgeOpen`, `SNTranscriptScrollPolicyTests.insetFollowPinsWhenWasAtTail`, `SNTranscriptScrollPolicyTests.insetFollowLockstepsWhenAwayFromTail`, `SNTranscriptScrollPolicyTests.insetFollowIgnoresWhileDraggingOrPrepending`, `SNTranscriptScrollPolicyTests.captureWasAtTailBeforeInsetChangeMatchesSignal`, `SNTranscriptScrollPolicyTests.openActionFullyReadIsLiveEdge`, `SNTranscriptScrollPolicyTests.openActionPendingUnreadIsUnreadDividerEvenWithoutResolvedId`, `SNTranscriptScrollPolicyTests.openActionUnsetCaptureIsProvisionalLiveEdge`, `SNTranscriptScrollPolicyTests.openActionSettledZeroIsLiveEdge`, `SNTranscriptScrollPolicyTests.openActionSettledNonZeroIsUnreadDivider`, `TranscriptScrollPolicyTest.openAction_unsetCapture_isProvisionalLiveEdge`, `TranscriptScrollPolicyTest.openAction_settledZero_isLiveEdge`, `TranscriptTailPinnerTest`, `TranscriptTailPinningUiTest` (Compose, real `LazyListState` wiring), `TranscriptScrollPolicyTest.session_keyboardShrink_atTail_pinsSnap`, `TranscriptScrollPolicyTest.insetChange_atTail_pins`, `TranscriptScrollPolicyTest.insetChange_userScrolling_ignores`, `TranscriptScrollPolicyTest.insetChange_prepending_ignores`.

**Coverage (honest):** Production iOS is the Phase 3 collection host: owned bottom inset from composer occlusion in **viewport** coordinates (`transcriptOwnedBottomContentInset` / `snCollectionHostOwnedBottomContentInset` shim, `.never` adjustment — converting into the scroll view's content space collapses the inset at the tail of a long chat; guarded by `SNCollectionHostInsetTests` at the Sonar shim call site and duplicated in SPM `TranscriptOwnedInsetTests`, which the regression ledger does not scan), pre-measured cells (`TranscriptRowHeightCache` + `sizeForItemAt`), and `TranscriptTailPinLatch` + 10 ms coalescer on inset Δ / contentSize growth in `TranscriptCollectionHost.swift`. The representable must `.ignoresSafeArea(.keyboard)` so SwiftUI does not shrink the host while `keyboardLayoutGuide` also lifts the composer — otherwise the bar floats ~one IME height above the keyboard (`transcriptFloatingComposerGap` / `snCollectionHostFloatingComposerGap`; helper-level only — device smoke still confirms the modifier). Kill-switch fallback remains `SNMsgList` (sibling composer ⇒ `snOwnedTranscriptBottomContentInset` = 0; still wants SwiftUI keyboard avoidance). Compose production is `TranscriptHostScrollEffects` in `transcript-engine-compose` (real Pin/Lockstep; Sonar shim `TranscriptPhase2ScrollEffects`); legacy `TranscriptTailPinning` is kill-switch only. The Swift tests pin latch/open-policy helpers and inset coordinate math — not that `scrollTo` lands (iOS tests still do not run in CI). In particular, `clearLiveEdgeOpenRequiresOwnedChrome` / `markLeftBottomIgnoresProgrammaticLiveEdgeOpen` guard the pure predicates; they do **not** pin that `TranscriptCollectionHost` wires `clearLiveEdgeOpenIfSettled` after inset commit or keeps advancing the contentSize watermark. The Compose UI test is the stronger guard for pin. Device smoke remains the recommended hardware gate for keyboard pin, unread open, and mesh-image remeasure; CI additionally runs SPM `TranscriptOwnedInsetTests` / open-action goldens on PRs that touch `ios/localPackages/TranscriptEngine/**`.

**History:** #283 (Compose) -> #303 (iOS, notification + fixed delays; incomplete) -> this fix (previous-frame pinner + explicit user-scroll observation, Signal `wasScrolledToBottom` shape) -> phantom empty band (viewport expand ignored) -> rejected LazyVStack spacer / `contentSize` top-inset experiments that yanked GIAN / Ocean LCI Alert or opened DMs mid-history -> conditional `defaultScrollAnchor` for fully-read opens only -> alpha.11 still opened mid-DM (one `scrollTo` vs under-measure; latch unpinned until sentinel) -> `needsLiveEdgeOpen` re-snap until live edge lands -> unset unread capture treated as `0` chased the tail then jumped to the divider (fixed: optional settle + hold) -> collection host cleared `needsLiveEdgeOpen` on pre-chrome `isScrolledToBottom()` and pre-latch scroll callbacks set `hasLeftBottom`, ending open recovery a flick short of the last message (clear only after owned chrome; ignore programmatic left-bottom during live-edge open).

**Rejected:**
- *Fixed-delay double pin after `keyboardWillShow` (#303).* The 0.35s timer races the safe-area animation and anything that settles later (late transport-leg merge, sticker/media decode); one lost race also strands `isNearBottom` at false, disabling every later keyboard open.
- *Unconditional `defaultScrollAnchor(.bottom)`.* Fights unread-anchor opens. Conditional (fully-read only) is what shipped.
- *Dynamic top spacer inside LazyVStack.* `contentSize` includes the spacer ⇒ feedback loop yanked chats (GIAN / Ocean LCI Alert).
- *`contentInset.top = max(0, viewport − contentSize)` from LazyVStack metrics.* `contentSize` under-measures on open ⇒ DMs started away from the last message. Rejected.
- *`.frame(minHeight:alignment:.bottom)` on LazyVStack.* Ignored by LazyVStack.
- *Flipping the ScrollView 180°.* Structurally bottom-anchored, but inverts every gesture/accessibility behaviour and would rewrite the whole transcript surface.
- *Keeping SwiftUI keyboard avoidance alongside `keyboardLayoutGuide`.* Double IME ownership floats the composer ~one keyboard height above the IME and inflates the owned bottom inset so the live edge is clipped under the bar.

**Platform gap:** Compose `LazyColumn` is still top-anchored for short feeds (no `reverseLayout` / fill-height bottom arrangement). Same empty-band class of bug may exist there; follow-up is a Compose short-transcript bottom align that keeps unread-anchor opens intact. The pre-chrome `needsLiveEdgeOpen` clear race fixed here is **iOS Phase-3 collection host only** — Compose clears on layout-proof live-edge checks, and MsgList waits for the `sn-bottom` sentinel rather than owned composer chrome.

---

## R-010 — nsec restore must not wipe durable kind-0 `nip05`

**Invariant:** After nsec restore (or lost local nick/handle prefs), the app must fetch own kind-0 before any opportunistic republish; it must never publish blank/stale metadata, never mint `anonXXXX` over a cleared nick, never reclaim a non-Sonar `nip05` at the registrar, never emit kind-0 when remote `nip05` cannot be preserved in the core sidecar, and never override a name/`nip05` already present on remote kind-0 with a divergent local value.

**Breaks as:** Profile shows blank/"you" after restore; relaunch invents `anon####` and replaces the durable relay profile; external `alice@example.com` becomes `alice@sonarprivacy.xyz` (or is omitted) on the next connect-path publish.

**Why:** Kind-0 is a replaceable event. `publish_profile` only attaches `nip05` from the core handle sidecar. Local nickname/handle prefs are device-bound and wiped on restore, so hydrate-before-publish and Sonar-domain-only reclaim are load-bearing.

**Call sites:** iOS `MarmotChatView.swift::hydrateOwnProfileFromRelays`, `SonarAppStore.adoptOwnKind0Profile` / `noteOwnHandleSidecarSeeded`, `ChatViewModel.clearNicknameForAccountRestore`; Compose `SonarAppState.hydrateOwnProfileFromRelays`

**Guarded by:** `OwnProfileHydrationTest.externalNip05MustNotReclaimOrPublish`

**Also guarded by:** `OwnProfileHydrationTest.restoreWithBlankLocalStateAdoptsKind0NameAndHandle`, `OwnProfileHydrationTest.blankLocalWithoutRemoteMustNotPublish`, `OwnProfileHydrationTest.remoteKind0NameAndNip05WinOverDivergentLocal`, `OwnProfileHydrationTest.renameMustNotPublishWhenHandlePrefLacksCoreSidecar`, `OwnProfileHydrationTest.needsRelayFetchOnlyWhenRestoreSymptomsPresent`, `OwnProfileHydrationTests.externalNip05MustNotReclaimOrPublish`, `OwnProfileHydrationTests.remoteKind0NameAndNip05WinOverDivergentLocal`, `OwnProfileHydrationTests.restoreClearedNicknameMustNotMintAnonymousOnRelaunch`

**History:** #342 hydrate-before-publish → still wiped via `$relayConnected` / anon mint / external reclaim → tightened publish gate + empty-nick sentinel + Sonar-domain reclaim.

**Rejected:**
- *Delete nickname prefs key on restore.* Relaunch treated missing key as first install and minted `anonXXXX`.
- *Keep iOS `$relayConnected` republish beside Marmot connect-path publish.* Second writer could emit without sidecar `nip05`.
- *Treat `handleLocalToClaim == null` alone as publish-safe.* External `nip05` then published without sidecar and wiped the remote field.

**Not guarded:** End-to-end restore against live relays (host hydrate orchestration needs a constructible `SonarAppState` / `SonarAppStore`). iOS unit tests do not run in CI. Connect-path session short-circuit after the first own-profile fetch (iOS `didFetchOwnProfileThisSession`) is not unit-tested.

---

## R-011 — Mesh→White Noise first send keeps a visible echo

**Invariant:** When a mesh-folded Sonar DM falls back to White Noise (no live
Noise link), the outgoing bubble must paint immediately on the mesh chat id and
must not be cleared until a folded White Noise canonical row exists.

**Breaks as:** Banner/toast says "Out of range — continuing over White Noise…",
then the typed message is missing for a couple of seconds (or flickers off
"Sending · internet") while `startChat` / relay publish / `refreshOpenDm` catch up.

**Call sites:** Compose `SonarAppState.sendOverMarmot` /
`reconcileMeshMarmotSendEcho` / `flushPendingMarmot`; iOS
`SonarAppStore.queuePendingMeshMarmotSend` / `flushPendingMarmotSends`

**Guarded by:** `MeshMarmotSendEchoTest.meshWhiteNoiseEchoStaysUntilCanonicalRowExists`

**Not guarded:** the real `sendOverMarmot` call site (needs a constructible
`SonarAppState`); asymmetric BLE discovery that forces the WN fallback in the
first place (MeshRadio dial/scanner — device-bound).

**History:** Observed on Android chatting with Mac when BLE discovery was
one-sided / no live Noise link; chat correctly continued over White Noise but
the send echo was cleared before the canonical row merged.

**Rejected:**
- *Routing mesh DMs over BLE without `hasMeshLink` / `isPeerConnected`.* Reopens
  R-006-style dead-radio sends.
- *Navigating the open mesh chat onto the raw Marmot group id after `startChat`.*
  Splits one person into two conversations (R-003).

## R-012 — Notification privacy settings must shape local copy

**Invariant:** When Notifications are enabled, the Show names and Message preview toggles must control whether sender/group labels and message text appear in user-visible local notifications. Hard-coding the private fallback (`New Sonar message` / `Open Sonar to read it.`) while callers pass real sender/body is a regression.

**Breaks as:** Settings show names/preview on, but every mesh/mention (and push-wake) banner stays anonymous and content-free.

**Why:** PR #58 routed push through the core renderer for privacy, then also replaced `NotificationService.sendPrivateMessageNotification` / `sendMentionNotification` with always-private placeholders — discarding the arguments callers already pass. The toggles wrote to UserDefaults but those paths never read them.

**Call sites:**
- iOS `NotificationService.swift` (mesh/mention) → `SonarLocalNotificationRouter` + `SonarNotificationPreferenceStore`
- iOS `SonarPushProcessor.swift` (Transponder wake) → unread conversation summaries + same router/prefs; replaces NSE placeholder/`nseDecorated` banners by tip identity
- iOS `SonarNotificationService/NotificationService.swift` (killed-app Transponder NSE) → App Group Marmot SQLCipher + `SonarNSEDecoratePolicy`
- iOS `SonarAppStore.swift` (process-alive Marmot) already used the router
- Compose `SonarNotificationRouter` / `SonarPushProcessingService` (parity reference)

**Guarded by:** `SonarNotificationPrefsTests.privateMessageRespectsPreviewOptIn`

**Also guarded by:** `SonarNotificationPrefsTests.mentionSeamRespectsPreviewOptIn`, `SonarNotificationPrefsTests.privateMessageRespectsDefaultPrivacy`, `SonarNotificationPrefsTests.privateMessageRespectsNamesOff`, `SonarNotificationPrefsTests.disabledSuppresses`, `SonarNotificationPrefsTests.nsePlaceholderMatchesIdentityNotCopy`, `SonarNotificationPrefsTests.nsePlaceholderWipeRespectsWakeSnapshot`, `SonarNotificationPrefsTests.nseOwnedReplaceMatchesTipIdentity`, `SonarNotificationPrefsTests.unreadDeltaRequiresHydratedBaseline`, `SonarNotificationPrefsTests.unreadDeltaSkipsUnchangedStale`, `SonarNotificationPrefsTests.drainPreviewMatchesTruncation`, `SonarNSEDecoratePolicyTests.namesOffHidesGroupAndSender`, `SonarNSEDecoratePolicyTests.previewOffHidesBody`, `SonarNSEDecoratePolicyTests.diagnosticsAreOpaque`, `SonarNSEDecoratePolicyTests.expireKeepsDecorated`, `SonarNotificationRouterTest.previewsRequireOptIn` (Compose)

**Not guarded:** That `sendPrivateMessageNotification` / `sendMentionNotification` still call the routed seams (no UNUserNotificationCenter spy). Push-wake ownership span / live catch-up generation need a constructible `MarmotChatModel` / `SonarAppStore`. NSE `apply()` wiring that stamps `sonar.nseDecorated` / clears `sonar.nsePlaceholder` is only indirectly covered via policy helpers — a call-site regression could keep helper tests green. iOS tests do not run in CI. Android host/FCM decorate + banner-replace parity with this NSE path is a tracked platform gap (see PR #381 / `docs/brainstorms/2026-07-19-ios-nse-marmot-hydrate.md`).

**History:** #58 / #144 introduced the core renderer and privacy toggles → mesh helpers were left on hard-coded private copy → #152 filed the symptom → this fix wires mesh + push-wake through the router/prefs (Android #297 already rendered from unread summaries) → #362 / #381 land killed-app NSE hydrate (SQLCipher keep-symbols, flock retry, decorate policy, host replace of `nseDecorated`).

**Rejected:**
- *Always-private local copy "for privacy".* That ignores the user's explicit Show names / Message preview opt-in and makes the Settings toggles lie.
- *Relay `fetchProfile` inside the NSE decorate path.* Burns the ~30s extension budget and held the store lock under network I/O; names resolve on the host replace path instead.


---

## R-013 — A tapped chat push must catch up before the visit ends

**Invariant:** Opening the app from a Transponder/Marmot chat notification must kick a forced gap-recovery sync (and prefer the open chat's catch-up) so the notified message lands in the local transcript during that foreground visit. Per-group historical catch-up must not starve under live traffic, and distant floors must not share one widened `#h` scan.

**Breaks as:** User sees "New Sonar message", opens the chat, and finds nothing — the banner came from the NSE/generic wake path while the local DB still lacks the row. Or the message appears minutes later (or never) because catch-up advances only on idle wake cycles / one group per pass.

**Call sites:**
- Core: `client.rs` (`should_fetch_group_messages_on_sync`, batched catch-up / `plan_catchup_buckets`, preferred-group gate)
- iOS: `NotificationDelegate.didReceive` → `MarmotChatModel.refreshAfterForeground()`; scenePhase also routes through the same single-flight refresh
- Compose: `SonarAppState.openConversationFromNotification` / `requestImmediateSync` → `forcedCatchupSync` (including queued cold-launch taps)

**Guarded by:** `client.rs::forced_sync_fetches_group_messages_even_when_live`, `client.rs::catchup_batch_leads_with_preferred_and_respects_cap`, `client.rs::catchup_buckets_isolate_distant_floors`, `client.rs::catchup_gate_one_shot_preferred_bypass`

**Also guarded by:** `client.rs::forced_sync_notifications_surface_through_drain`, `client.rs::catchup_bucket_since_applies_lookback_exactly_once`, `client.rs::catchup_buckets_zero_floor_isolated_and_capped`, `client.rs::catchup_gate_rejects_concurrent_pass`, `client.rs::catchup_gate_empty_pass_does_not_throttle_next`, `client.rs::prefer_catchup_promotes_active_group`, `SonarNotificationPrefsTests.localMarmotWakeMarkerSurvivesRouting`

**Not guarded:** the iOS tap → `refreshAfterForeground` wiring and the Compose notification-open → `forcedCatchupSync` / "catching up…" chip. Both need a constructible store (see Unguarded). Real-device APNs validation remains #262.

**History:** #166 (foreground/push relay sync) → #252 (forced sync skipped the live batched `#h` fetch — primary invisible-on-open bug) → #254/#255 (catch-up starvation + push-tap kick + catching-up chip; consolidated here onto current main). Related floor starvation is R-005.

**Rejected:**
- *Waiting only on `scenePhase` / socket-connected "Online".* iOS cold-launch taps can miss the refresh, and "Online" lied while catch-up had not run.
- *Unbounded full-history fetch on every wake.* Violates the Signal-Comparable Performance Rule; the batched/bucketed catch-up keeps per-pass work bounded.


---

## R-014 — Every BLE fragment write stays inside the reliable 256-byte block

**Invariant:** No single GATT write the mesh engine emits may exceed
`RELIABLE_GATT_WRITE_BYTES` (256). `FRAGMENT_CHUNK_SIZE` must stay *derived* from
that budget minus the measured per-write overhead and a safety margin — never
hand-tuned to a literal.

**Breaks as:** a Pixel sends media to an iPhone, Android's GATT callbacks all
report success, and the file never arrives. Nothing is logged as an error on
either device. iOS acknowledges a 512-byte characteristic write at the link
layer without ever surfacing it to `didReceiveWrite`, so the fragments are
accepted and dropped. Text long enough to fragment fails the same way.

**Call sites:** `mesh_engine.rs::write_maybe_fragmented` (the only producer of
fragment writes; both the `WriteLink` client path and the `NotifyConn` server
path go through it). Hosts must write the emitted bytes verbatim —
`MeshGatt.writePacket` / `notify` on Compose, `BLEService` on Apple.

**Guarded by:** `mesh_engine.rs::every_fragment_write_stays_in_the_reliable_block`

**Not guarded:** the host side. Nothing asserts Android or CoreBluetooth actually
writes what the engine emitted, so host-side re-chunking or an added envelope
would slip through. Also unguarded: that 256 is still the reliable bucket on
future hardware — that came from Pixel 10 / iPhone 14 Pro Max tracing, not from
a spec.

**History:** Shipped as `FRAGMENT_CHUNK_SIZE = 350`, which encoded to exactly a
512-byte write for every fragment — the failing size. First repaired by dropping
to a literal 160 (a 2.2x round-trip cost with no stated derivation), then
replaced with the derived 205 after measuring that the per-write overhead is a
constant 43 bytes and the exact cliff is a 213-byte chunk.

**Rejected:**
- *Capping at the GATT write layer instead, where the MTU is known.* The limit is
  not the MTU — it is bitchat's PKCS#7 block set (`BLOCK_SIZES` in `mesh.rs`). A
  221-byte raw fragment pads up to 512 because `optimal_block_size` adds a
  16-byte AEAD allowance, so the constraint has to be applied where fragments are
  cut, not where they are written.
- *Keeping a hand-tuned literal with a comment.* The failure is invisible from
  both ends, so a future header field silently re-breaking it is the likely
  regression. Deriving it makes that a failing test instead.
- *Using the exact 213-byte ceiling.* Zero headroom; any added header field
  crosses the cliff.

## R-015 — An optional TLV must never destroy the payload it rides on

**Invariant:** The `0x05` message-id TLV on a BLE file transfer exists only to
enable a delivery receipt. A malformed, empty or oversized value must degrade to
"no receipt" on both encode and decode, on both platforms — never fail the
packet.

**Breaks as:** a peer sends a photo and it silently never arrives, because the
receiving decoder returned `nil` for the whole `FilePacket` over an unusable
optional hint. On the sending side an unusable id failed `encode()`, which
surfaces as "not connected" and no media sent.

**Call sites:** `mesh.rs::file_packet::FilePacket::encode` / `decode` (the
`T_MESSAGE_ID` arm) and `BitchatFilePacket.encode()` / `decode()` (the
`.messageID` case). Both directions on both platforms — a one-sided fix leaves
the pair asymmetric, which is worse than either behaviour alone.

**Guarded by:** `mesh.rs::malformed_optional_message_id_degrades_instead_of_dropping_the_file`, `BitchatFilePacketTests.testUnusableMessageIDCostsTheReceiptNotTheTransfer`, `BitchatFilePacketTests.testMalformedMessageIDTLVStillDecodesTheFile`

**Not guarded:** cross-implementation behaviour against stock bitchat, which does
not know tag `0x05` at all — that path relies on unknown tags being skipped, and
nothing here exercises a real stock decoder. iOS tests also do not run in CI.

**History:** Introduced with the receipt feature: both sides rejected the packet
on a bad id, so an optional extension could destroy the media. Found in review
of #312.

**Rejected:**
- *Failing loudly so a bad id is noticed.* The id is chosen by the sender and
  arrives unauthenticated; failing gives any peer a way to make our media vanish.
- *Fixing only decode.* Encode returning nil aborts a send the user asked for,
  for a field that carries no user content.

## R-016 — A suspend-interrupted node aborts blocking relay FFI instead of parking

**Invariant:** After `SonarNode.interrupt_for_suspend()`, every relay call that
the host can have parked on its serial work queue returns an "interrupted for
suspend" error promptly — both when the latch was already set and when the call
is already parked mid-wait — instead of blocking for the remainder of its relay
timeouts. And a close must **fence** node installation before it latches, so a
connect that finished a moment earlier cannot install an un-latched node behind
it.

**Which calls, and why that boundary:** suspendable = runs automatically
(no user waiting on it) and self-heals on the next connect — `sync_once`,
`sync_force`, `ensure_subscriptions`, `retry_outbox`,
`publish_key_package_background`, `publish_sonar_descriptor`,
`register_push_token`, `fetch_profile`,
`fetch_sonar_descriptor`. Deliberately **not** suspendable: user-initiated MLS
mutations (`send_text`, invite accept/decline, group create/leave, `start_dm`).
Those have a user waiting on the result, and aborting them would surface as
lost work rather than as a deferred retry. `ensure_subscriptions` is the one
that matters most in practice and was missed by the first cut of this fix — it
is the *idle-timeout* path, so it is the call most likely to be in flight when
the app backgrounds with nobody touching the screen.

**Breaks as:** `RUNNINGBOARD 0xdead10cc` TestFlight crashes: iOS suspends the
process while the SQLCipher store in the App Group container is still open,
because `MarmotService.closeNode()`'s first hop — the one that drops the node
and releases the store lock — is a `workQueue.async` on a **serial** queue and
queues behind whatever uncancellable blocking Rust is already parked there.
Round 1 (#446) closed the store after background wakes; round 2 (#448) stopped
*new* prefetch work from flooding the queue; round 3 (1.12.2 build 30, killed
85s after launch) proved neither helps when a full `SonarClient::sync` is
*already in flight* at suspension — the ~30s background-task grace expires
before the sync returns.

**Why:** `block_on` at the FFI boundary cannot observe Swift cancellation, and
iOS gives no way to extend the deadline. The only seam that works is dropping
the future at its next await point: each interruptible method now races its
future against a one-way `tokio::sync::watch` latch
(`SonarNode::block_on_suspendable`), and `closeNode()` /`wipeDatabase()` flip
the latch race-free (snapshot under `nodeLock`) BEFORE the first serial-queue
hop.

**Why dropping `sync` cannot tear MLS or DB state** — this is the load-bearing
safety argument, and it rests on an invariant the code already enforces
rather than on new care taken here. A dropped future stops at an **await
point**, meaning every synchronous span between awaits has already run to
completion. In `MarmotEngine::process_incoming` (`core/sonar-core/src/marmot.rs`)
the only await is the gift-wrap unwrap, which is pure crypto and touches no
store; the MLS mutation and its SQLCipher writes run **synchronously** under
`mls_write()`, guarded by the standing rule stated at that call site: *the lock
must never span an await*. `process_group_message` is a plain `fn` for the same
reason. So an interrupt can land only *between* events or *before* any state
mutation — never mid-commit. Per-event progress is already durable
(`mark_sync_event_processed`), unfinished events are re-fetched from the
watermark, and a dropped publish re-runs via outbox/re-registration. If that
no-await-under-`mls_write` invariant is ever broken, this entry breaks with it.
The status quo it replaces is a `SIGKILL` at an arbitrary instruction, which is
strictly worse than a drop at an await point.

**The fence is part of the invariant, not a detail.** `interruptNodeForSuspend()`
sets `nodeClosing` and snapshots the node under **one** `nodeLock` hold, and it
must do so *before* the caller's `workQueue` hop — not inside it. `workQueue` is
FIFO, so a relay connect that already enqueued its install closure runs *first*,
ahead of the close hop that bumps `sessionGeneration`; the install's generation
check therefore still passes. Installing there publishes a brand-new,
un-latched node to `SonarPushRegistration.setSonarNode`, which kicks a blocking
`registerPushToken` on the global utility queue holding a strong `SonarNode`
**outside** `nodeLifecycleGroup` — so the close cannot wait for it, and the
SQLCipher handle outlives the close. The install closure in `connect` therefore
checks `nodeClosing` (not just `sessionGeneration`), and the close hop also
interrupts the node it actually removes as defence in depth.

**Both install paths need the fence, not just the relay one.** `connect()`
(relay) and `connectLocal()` (local-only, Signal-style first paint) each assign
`service.node` and each hand it to `SonarPushRegistration.setSonarNode`.
`connectLocal` checked `nodeClosing` only *before* opening, and `SonarNode.connect`
opens SQLCipher in between — wide enough for a close to fence. Fixing only the
relay path left the same hazard reachable through local connect. There are
exactly two `service.node =` install sites and exactly two `setSonarNode` calls;
if a third appears it needs the same treatment.

**The fence check and the node assignment must be one `nodeLock` hold.** The
first attempt at this checked `nodeClosing`, released the lock, then reacquired
it to assign — and `interruptNodeForSuspend()` fits in that gap: it sets
`nodeClosing` and latches only the *old* node, after which the closure installs
the fresh one regardless. The close hop's `removedNode?.interruptForSuspend()`
does eventually catch it, but only after `setSonarNode` may already have handed
the node to a registration thread the close never waits for, and `storeLock` has
already been released — so the handle can outlive the close and overlap NSE
access to the same store. Both hazards were found by review on PR #449, not by
a test; there is no seam to drive either race.

**Call sites:** iOS `MarmotService.swift::closeNode(keepClosed:)` and
`MarmotService.swift::wipeDatabase()` (both via `interruptNodeForSuspend()`),
plus the `nodeClosing` guard in the `connect` install closure; core
`sonar-ffi/src/lib.rs::block_on_suspendable`. Compose: not applicable —
Android has no RunningBoard shared-container file-lock kill; nothing calls
`interruptForSuspend` there (the binding exists but is inert).

**Making a call suspendable is only half the change — its error path must be
audited too.** Every `catch` that previously only ever saw a real relay failure
now also sees a deliberate abort, and the polling loop showed why that matters:
its idle `ensureSubscriptions()` handler set `errorText`, dropped
`relayConnected`, and armed `scheduleRelayConnect(delaySeconds: 2)`. Because
`closeNode()` clears `nodeClosing` when it completes, that timer would **reopen
the SQLCipher store about two seconds later while the app was still
backgrounded** — reintroducing the very kill this entry exists to prevent, and
doing it *more* often than before, since the call now fails fast where it used
to block. (`closeStoreAfterBackgroundWake()` already cancels `relayConnectTask`
for exactly this reason; the scenePhase `suspendStoreForBackground()` path does
not.) Before making any further call suspendable, read its callers' error paths
first.

There are **three** such handlers, and they were found one at a time across
three review rounds — if a fourth suspendable call is ever added, audit for a
fourth handler rather than assuming these are all of them:
  - the polling loop's *idle* branch (the one described above);
  - the polling loop's *live* branch, where `try?` silently swallowed the
    marker — harmless-looking, except the loop then iterated once more and that
    iteration's `notConnected` fell into the idle catch and armed the reconnect
    anyway, so the bug arrived by a longer route;
  - `performRelayConnect`'s generic catch, because `connect()` *ends* with a
    (suspendable) `retryOutbox()`, so a background transition mid-connect
    surfaces the marker there and it would schedule its own retry.
All three now return without arming a reconnect; foreground resume restarts
polling via `performConnect`.

**The abort must not read as a failure.** A suspend abort is a deliberate
control-flow signal, not a relay error, and two host paths originally treated it
as one — both are regressions this entry now owns:
`MarmotChatModel.refreshWhenConnected` / the `ensureGapRecovery` task wrote it
to `errorText`, showing the user a literal "sync interrupted for suspend"
banner on the next foreground; and `SonarPushRegistration.attemptRegistration`
classified it `.failed`, burning all three attempts with 2s+4s backoff sleeps
against a node whose latch is one-way and can never succeed. Both now classify
it terminal: `MarmotChatModel.isSuspendInterrupted` suppresses the banner, and
`RegistrationAttempt.suspended` defers to the next `setSonarNode()`. Because
`SonarFfiError` is `#[uniffi(flat_error)]` only the rendered message crosses the
boundary, so both match the substring named by `SUSPEND_INTERRUPT_MARKER`
(`core/sonar-ffi/src/lib.rs`) — the same message-matching pattern already used
by `isMediaUploadInFlight`. **Renaming that marker silently breaks both hosts**;
the constant exists so the Rust side has one source of truth and the tests
assert against it rather than a duplicated literal.

**Guarded by:** `lib.rs::interrupted_node_fails_sync_fast_instead_of_parking`, `lib.rs::interrupt_aborts_in_flight_suspendable_wait`

**Not guarded:** the Swift half — that `closeNode()` actually fires the
interrupt before its queue hop, and that the install closure honours the fence —
is unpinned (iOS tests do not run in CI, and `MarmotService`'s node/queue
internals are private). The install/close FIFO race in particular has no test
seam at all: it needs two `workQueue` hops interleaved at a specific point.
Verification remains a TestFlight build surviving backgrounding mid-sync. Nothing mechanically
enforces the no-await-under-`mls_write` invariant the drop-safety argument
above depends on; it is a comment and a code shape, so a future `await` added
inside that lock would silently invalidate this entry.

**Residual, not fixed here — the lease wait.** The interrupt unblocks the
*serial-queue* half of the close. `closeNode()` then waits on
`nodeLifecycleGroup`, which covers leases taken on `mediaQueue` / `sendQueue` /
`readQueue` too, and a Blossom media upload can hold one for minutes — far past
both the iOS wake window and the `beginBackgroundTask` grace that
`closeStoreAfterBackgroundWake()` relies on. That path is *not* implicated in
any of the three crash logs (rounds 1-3 are all sync / push-registration), and
making media suspendable means abandoning a user's in-progress send, so it is
deliberately left alone. Follow-up: decide whether media should be suspendable
(it has durable staging + resume, so it is recoverable) or whether the close
should stop waiting on the media lane at all.

**History:** #446 (round 1: close after background wakes) -> #448 (round 2:
stop flooding the queue, bound the close wait) -> build 30 crash (round 3:
in-flight sync uninterruptible) -> this fix.

**Rejected:**
- *Releasing the flock/`storeLock` ahead of the node.* Reverted in #448 review:
  the NSE opens its own `SonarNode` the instant it wins the flock, and two
  processes committing against one MLS store can fork group state. See the
  round-2 notes below.
- *Bounding `sync` with a shorter internal timeout.* Suspension can arrive 1s
  after a sync starts; no fixed budget closes the race, it only shrinks it.
- *Swift-side `withTimeout` around the FFI.* A task group awaits its children
  before rethrowing, so it cannot bound work that ignores cancellation — the
  same reason documented on `closeStoreWithDeadline` in round 2.

---

## R-017 — Unread accounting counts only rows the transcript renders

**Invariant:** `conversation_summary.unread_count` increments only for incoming
messages a host actually paints as a transcript row. Any event hidden from the
transcript (⚡PAYDONE settlements, ☎CALL signaling, non-kind-9 application
rumors) must not raise it. Corollary: **exactly one** decoder decides "hidden
control line" — core's `MessageClassification` — and every host reads that
verdict rather than re-parsing `content`. Two decoders means two answers, and
the counter and the transcript then disagree on edge inputs.

**Breaks as:** "opening a chat lands in the middle of the conversation and I
have to scroll down". Also phantom unread badges on chats where nothing visible
arrived (a missed call alone marks the chat unread).

**Why:** Both hosts place the Signal-style unread divider by walking
`unread_count` **visible** incoming rows back from the tail
(`TranscriptDisplayPolicy.firstUnreadTranscriptIndex`,
`SNMsgList.resolveUnreadAnchor`). Counting an invisible event has no row to
consume, so the walk overshoots by one real message per hidden event — and when
the budget exceeds the visible incoming rows in the loaded window, the open
lands on the oldest one in it. Core already classifies exactly what hosts hide
(`MessageClassification::PayDone` / `CallControl`); only the unread counter
ignored it.

The counter alone is not enough, because the hosts held a *second* decoder.
iOS already switched on the core classification (`SonarAppStore.payMapping`),
but Compose re-parsed the raw string in the `ChatScreen` feed filter, and the
two disagree on edge inputs: core trims leading whitespace before classifying
and validates the payment id, `PayLine.decode` does neither. So
`" ⚡PAYDONE|1|abc"` rendered but did not count (divider one row short) and
`"⚡PAYDONE|1|hello world"` counted but did not render (the original bug,
intact). Compose now reads `SonarMsg.classification` and falls back to the
string decode only for locally-built rows that have no core classification.

**Call sites:** `client.rs::upsert_index_for_message` (the `counts_unread`
argument of `ConversationIndex::upsert_summary`) and
`marmot.rs::process_group_message` (kind-9 gate) in shared core; Compose
`TranscriptDisplayPolicy.isTranscriptVisibleRow` (fed by `SonarCore.toCommon`
on both Android and JVM), consumed by the `ChatScreen` feed filter; iOS
`SonarAppStore.payMapping` (already classification-driven, unchanged).

**Guarded by:** `client.rs::hidden_control_lines_do_not_count_as_unread_at_the_index_call_site`

**Also guarded by:** `conversation_index.rs::host_hidden_messages_do_not_increment_unread`, `marmot.rs::only_host_rendered_classes_are_transcript_visible`, `conversation_index.rs::mine_messages_do_not_increment_unread`, `TranscriptDisplayPolicyTest.coreClassificationWinsOverTheLocalStringDecode`, `TranscriptDisplayPolicyTest.coreClassificationDecidesVisibilityForCoreRows`, `TranscriptDisplayPolicyTest.rowsWithoutCoreClassificationKeepTheStringDecode`

**Enforced by the compiler:** `counts_unread` has **no default** on
`upsert_summary`; a new call site cannot silently fall back to counting
everything.

**Not guarded:** the host walk itself against a real core count (needs a
constructible `SonarAppState` / `SonarAppStore` — see Unguarded), and the
residual case where a legitimately large unread budget exceeds the loaded
window, which still anchors on the oldest visible incoming row. Existing
inflated counts on installed devices self-heal on the next chat open, since
`mark_read` zeroes the counter; nothing tests that migration. The Kotlin tests
pin the pure policy function, not that `ChatScreen` passes the real rows
through it, and the two `MessageInfo.toCommon` mappers (androidMain / jvmMain)
are duplicated by hand — a classification dropped from one of them is a
compile-clean regression on that platform only.

**Platform gap:** the fallback path still runs two decoders for rows with no
core classification (mesh, optimistic echoes). Those never reach the
conversation index, so they cannot drift the counter — but a mesh ⚡PAYDONE and
a Marmot one are still judged by different code. Desktop is additionally
blind to ☎CALL there: `SonarCore.jvm.kt::callParseControl` returns `null`
unconditionally, so only the classification path hides call control on JVM
(pre-existing, now partly fixed for core rows).

**History:** #303 introduced the unread-anchored open; the counter it consumes
had been "every non-mine message" since the conversation index landed, so the
disagreement shipped with the feature and surfaces only in chats carrying
calls/payments. Layout-side mid-history opens are R-009 — a different mechanism
with the same symptom, which is why both need reading before touching open
behaviour.

**Rejected:**
- *Filtering control lines host-side before counting.* The hosts do not have the
  hidden rows to subtract — they were never fetched into the window — and it
  would have to be written twice, the exact shape of the cross-platform drift
  this ledger tracks.
- *Teaching `PayLine.decode` to trim and validate ids like core does.* Closes
  today's two divergent inputs by duplicating the validation rules in Kotlin, so
  the next change to either decoder re-opens the gap. Reading the classification
  deletes the second decoder for core rows instead.
- *Also suppressing `latest_content` / `latest_at_secs` for control lines.* A
  call or settlement is a real conversation event; keeping chat-list recency
  intact is deliberate, and changing ordering is a separate product call.
- *Dropping non-kind-9 rumors at the index instead of at `process_incoming`.*
  They would still ring a notification for a row no host can render.

## Unguarded

Gaps we know about. Each line is a concrete backlog item; fold it into its `R-`
entry once a test exists. Listing a gap is the point — an entry that overclaims
its coverage is worse than an honest hole, because it stops people looking.

- **R-003, the one-transcript half.** Cited tests pin chat-list dedup and identity routing, not "duplicate groups' messages merge into a single transcript". The merge lives in `SonarAppState.duplicateDirectMarmotChats` (private, needs an instance); `dedupeDirectMarmotChats` — the pure seam the tests use — only covers the chat-list half. Closing it means extracting the transcript-source selection into a pure function, or an injectable `SonarCore`.
- **R-004, account wipe, both platforms.** Now implemented on iOS and Compose, but pinned by no test. The Compose path needs an injectable `SonarCore`; the iOS path needs a constructible `SonarAppStore`, and no iOS test builds one today (`MarmotOptimisticEchoTests` only exercises static functions).
- **R-013, host push-tap / catching-up chip.** The iOS local-banner marker is pinned as a pure seam; the real `NotificationDelegate` → `refreshAfterForeground` call, full sync-lifetime indicator, and Compose notification-open → `forcedCatchupSync` route still need constructible app stores. Real-device APNs/FCM validation remains #262.
- **Anything needing a `SonarAppState` / `SonarAppStore` instance.** The three gaps above share one root cause: neither app object can be constructed in a test, so only pure helpers are reachable. This is the single highest-leverage testing investment in the repo — see the injectable-core note in the Signal architecture notes. Until then, prefer removing a hazard (as R-001 does with a mandatory parameter) over testing for it.
- **Out-of-range mesh DM echo dedup + Marmot reconcile (R-011 outbox half).** The outbox-flush path (`flushOutboxNow` -> `sendMesh(messageId)` + durable `removeMeshEcho` after Marmot) extends R-011's echo lifecycle to a second entry point. The O(1) dedup in `sendMesh` (`messageId == null || messageId !in meshEchoIds`) and the bounded reconcile (`removeMeshEcho` polls `marmotMessagesForPeer` up to 10x100ms before clearing the echo; on outbox eviction `failMeshEcho` marks the echo "Couldn't send") are both untested -- `SonarAppState` cannot be constructed in a test. Same root cause as the entry above. (Compose media retry is now covered by #397's `SonarMediaOutbox`/`queueMeshMediaForRetry`, so the earlier display-only media-echo gap no longer applies on Android.)
- **iOS tests do not run in CI.** No workflow invokes `xcodebuild test` / `ios/bitchatTests`, so `MarmotOptimisticEchoTests` guards R-001 only for someone running it locally. `scripts/check-regression-ledger.sh` verifies the test *exists*; nothing verifies it still *passes*. Until an iOS test job exists, treat Swift citations as weaker than Kotlin/Rust ones.
- **Mesh-DM peer-ID rotation orphaning (PR #397 Compose + PR #405 iOS).** Messages keyed by short BLE ID (16-hex) are orphaned when the peer reconnects with a rotated RP address. Compose side fixed in #397 (`echoMeshMessage` + `enqueueOutbox`); iOS side fixed in #405 (`didDisconnectFromPeer` always migrates to stable Noise key). **Residual gap:** when `derivedStableKeyHex` is nil (Noise session never established or already torn down), messages stay under the dead short BLE ID — `consolidateMessages` does not scan for orphaned 16-hex keys. Needs orphan-recovery scan in `PrivateChatManager.consolidateMessages` or deferred migration on reconnect. **Second residual gap:** when a peer has both an outbound peripheral connection and an inbound central subscription (dual BLE leg), losing either leg triggers `didDisconnectFromPeer` unconditionally (`BLEService.swift:1573` / `:4823` / `:5032`). The migration removes the short-key transcript, but messages arriving over the surviving leg continue to be stored under that short peer ID, splitting the conversation again. `notifyPeerDisconnectedDebounced` (debounce window at `:4823`) mitigates rapid double-disconnects but does not check if the other leg is still live. Fix requires per-leg connection-count tracking in `BLEService` so `didDisconnectFromPeer` only fires when all legs are gone. Neither platform has a test for this path; iOS tests don't run in CI.
- **Account key durability.** `CLAUDE.md`'s Account Key Durability Rule lists five blocking invariants (never delete-before-add, never regenerate on keychain error, ...) with no regression test cited here.
- **Compose side of R-006 (Bluetooth-adapter-off).** Compose has no `ACTION_STATE_CHANGED` receiver — nothing pushes adapter-off into `MeshRadio`, whose `stop()` has the right teardown but only runs on discovery-policy changes. Android links may self-clear via `BluetoothGattCallback.onConnectionStateChange`, so whether R-006 applies there is unproven; needs a Pixel with a peer in range to confirm. `apps/sonar` has no `androidUnitTest` source set, so the decision would have to move into a pure `commonMain` helper the way `bleScanRestartReason` did.
- **iOS NIP-05 verified badge cache key.** `nip05Verified` is keyed by `"canonicalKey(npub)|address"`, but the badge branch in `SonarContactProfileScreen.swift` read it by `address` alone, so the lookup always missed and the checkmark never rendered while the handle text rendered unconditionally. Verified and forged handles were therefore indistinguishable. Fixed by routing all three sites through one `static func nip05CacheKey(npub:address:)` (PR #411), which is deliberately static and npub-explicit so it is reachable without constructing the screen — unlike the `SonarAppStore` gaps above. `Nip05BadgeCacheKeyTests` pins that one handle claimed by two different keys yields two different entries. **The citation is weak on purpose:** iOS tests do not run in CI (see below), so nothing verifies it still passes. What is *not* pinned is the call-site wiring — a fourth site hand-building the key again, or the badge reading a different key than `verifyHandleIfNeeded` writes, is exactly the original bug and no test would catch it. Compose is structurally immune (`SonarContactProfileScreen.kt` scopes the state with `remember(peerNpub, nip05)`), so there is no Android mirror to pin.
- **Apple media sends must not lose the account gate to an automerge.** Rebasing this change onto main dropped every `isCurrentAccountWork(generation)` check from `MarmotChatModel.sendMedia`/`sendMediaMulti` while keeping main's bare `ensureConnected`/`appendOptimistic`/`service.…` calls inside the PR's escaping `launchIndependentAccountWork { model, generation in … }` closure. The bare calls do not compile (`implicit use of 'self' in closure`), so the breakage was loud; the *silent* half is that a closure receiving `generation` and never checking it turns the account-mutation gate into a no-op on exactly the two paths it was added for. Both are restored: the calls are `model.`-qualified and the guards bracket every suspension point, with the listener release and echo discard deliberately running even for retired work so only the user-visible failure row is skipped. Every `sendChain` producer must carry the gate, not just the ones that looked like the pattern: `send(_ texts:to:)` and `sendQueuedText` assigned new chain tails with no generation/suspension check, and a batch spanning multiple awaits keeps assigning tails *after* a quiesce has already snapshotted the chain — so it could publish against the old account while the wipe proceeded. The batch also re-checks between items. Unpinned — iOS tests do not run in CI and no test constructs `MarmotChatModel` with a controllable send, so the only thing standing between this and a silent regression is that the uncompilable form fails loudly next to it.
- **Sender-chosen mesh message ids are receipt-only.** The BLE file-transfer packet now carries an optional `message_id` TLV so the recipient can return an encrypted `delivered` receipt. That id arrives unauthenticated inside the Noise payload, so it must never become the identity of a *local* row: on Apple the incoming media row keeps its own generated `BitchatMessage.id` and the wire id is used only for `sendDeliveryAck`, and on Compose every id match that can withdraw or suppress a row is gated on `it.mine` (`drainMeshMedia` duplicate check, `drainMeshSendFailures`, both matches in `drainMeshMediaSendFailures`). Without those guards a peer could pick an id colliding with one of our outgoing rows and either suppress its own incoming media or have our failure path delete/evict that row. Nothing pins this: all four Compose sites need a constructed `SonarAppState`, and the Apple site needs a `BLEService` with a live peer. Close it with an injectable receive seam plus a two-device test where the peer deliberately reuses a known local id.
- **Ordinary `MeshRadio.stop()` must not discard undrained delivery signals.** With the Rust engine no longer queuing plaintext (`pending_sends` removed for fail-fast `send_text`), the app router is the only retry owner, and `MainActivity.onDestroy()` calls `stop()` — so an ordinary activity teardown mid-send must still hand the router its failure or the row stays "Sent" with its bytes neither delivered nor re-queued. **This took two attempts:** moving the inbox clear out of `stop()` into `MeshRadio.discardPendingDeliverySignals()` was not enough, because `stop()` also incremented the single `deliveryGeneration`, and `reportSendFailures` filtered on it — so the failure was still dropped, just one layer lower. The two jobs are now separate counters: `deliveryGeneration` advances on every `stop()` (a delayed `WriteLink`/`NotifyConn` must never inject stale ciphertext into a restarted radio's queue) while `privacyEpoch` advances only in `MeshGatt.discardAcceptedDeliveries()`, and only the latter gates reporting. Order-independent: whichever of `stop()` / discard runs first, the epoch check drops a report that must not land. Unpinned on both platforms — `stop()` needs a real BLE stack, and the regression is the *call-site and counter wiring*, which is exactly what broke twice.
- **Lost wakeup in the per-peer Marmot fallback flush owner.** `flushPendingMarmot` skips a peer whose `pendingMarmotFlushJobs[npubHex]` is still `isActive`, and `Job.isActive` stays true while the owner's `finally` runs. A send enqueued in that window therefore sat in `pendingMarmotSends` with no owner until an unrelated trigger fired. The owner now re-arms from `finally` when its peer queue is non-empty again. Safe unconditionally in this shape because the snapshot is removed up front and a failed send marks its echo "Couldn't send" rather than being requeued, so re-arming cannot spin. Unpinned: `flushPendingMarmot` needs a constructed `SonarAppState` with an injectable send.
- **Do not re-add a Marmot fallback FIFO without a caller.** The rebase onto main kept main's `mutableMapOf<String, MutableList<PendingMeshMarmotSend>>` for the folded-mesh Marmot fallback while a typed `PendingMarmotOutbox` + `PendingMarmotOutboxTest` rode along from the pre-rebase design with zero production callers. A green test over dead code is exactly the overclaim this ledger forbids, so both were deleted rather than wired. The behaviour that ships is main's: a failed fallback send marks its echo "Couldn't send" and is dropped, and because `createSendEcho` defaults `viaInternet = true` the row satisfies `sonarCanRetryMessage`, so the user gets a retry affordance instead of a silent loss. If ordered auto-retry is wanted later it needs a TTL (the deleted type had none, unlike `SonarOutbox`) and a real caller in `flushPendingMarmot` — and the re-arm below then needs its `drainedQueueEmpty` guard back, because a retained failing head would otherwise spin.
- **Android asynchronous BLE send failures.** `MeshGatt` now carries app-owned text/media metadata beside every queued GATT write/notification, resets the Noise route on a rejected, failed, disconnected, or stuck operation, and exposes one failure for router fallback. Intentional shutdown advances a delivery generation and clears already-buffered app failures so erased plaintext/media cannot be resurrected as a fallback send. Pixel 10 / iPhone 14 Pro Max tracing also reproduced two Android platform hazards: duplicate MTU callbacks started service discovery twice and enqueued every CCC subscription twice (the target instance then failed with GATT status 1), while 512-byte characteristic writes reported success without ever reaching iOS `didReceiveWrite`. Discovery is now single-flight and the shared Rust fragment size keeps every encoded media frame at or below 256 bytes; `recipient_delivery_receipt_round_trips_for_text_and_media` pins the frame ceiling and receipt codec. No JVM test can drive `BluetoothGattCallback`, so the callback ordering still needs an Android driver seam. Keep a physical Pixel/iPhone smoke that covers duplicate callbacks, a media transfer, and a link drop mid-fragment.
- **Marmot fallback lifecycle.** Compose now keeps failed per-peer fallback sends at the head of a typed FIFO, stops the mesh radio, and cancels plus joins setup/fallback/general-outbox jobs before chat erase, account restore, or full wipe. Text, sticker, retry, and media core calls also share the account-mutation gate. `PendingMarmotOutboxTest` pins FIFO ownership and exact-head removal, but no test constructs `SonarAppState` to prove the lifecycle boundary. Apple already serializes text/sticker sends through one chain and now also owns parallel media/retry and direct-chat setup tasks, holding their suspension through host cache/wallet deletion. Existing tests construct `MarmotChatModel`, but cannot inject a controllable send, and no test constructs `SonarAppStore` to pin the full boundary. Close both with injectable app-state/service seams.
- **Sender-side no-receipt timeout is the last piece of BLE delivery state.** Receivers on Apple and Compose Android carry the sender's optional media message id, persist the file/transcript, and return the encrypted `delivered` receipt, so senders distinguish transport acceptance (`Sent`) from recipient persistence (`Delivered`) for text and media. The receiver halves that make a sender retry safe are in place: Compose dedups incoming text and media by the sender-chosen wire id (never matching one of our own rows) and **re-ACKs** a duplicate; Apple keeps a bounded sender-scoped `seenPrivateFileMessageIDs` set — needed because packet dedup keys on `senderID-timestamp-type`, which a retry does not collide with. Two follow-on corrections were needed there: the Apple duplicate check has to run **before** `enforceIncomingFilesQuota` and `saveIncomingFile`, or a retry leaves an orphan copy nothing references while its bytes evict older attachments live transcripts still point at; and the ack must be gated on the transcript write actually reaching disk — `MessageStore.write` swallowed the error, so queue drainage proved only that the write *ran*, and a full disk produced "Delivered" on the sender for a row the recipient loses at restart. `afterPendingWrites(for:)` now returns that outcome and the receipt is withheld on failure. What remains is the *sender* half: a bounded no-receipt timeout that re-enters the ordered outbox under the same id and gives up as "Couldn't send", gated on peers that have proven they ack (a stock bitchat peer never returns a media receipt, so an ungated timeout would spam it or wrongly fail a delivered message). Until then a row whose receipt is lost stays `Sent`, recoverable only by the user re-sending. None of the receiver dedup/re-ACK/durability paths is pinned: they need a constructed `SonarAppState`, or a `BLEService` plus an injectable failing store. Compose Desktop handles text receipts but returns `false` for `sendMeshMedia`; native macOS shares the Apple media implementation — an explicit platform gap, not evidence desktop media passed this path.
- **Duplicate-send.** Nothing pins "one tap produces exactly one canonical row". Worth adding if the duplicate bubble in #290 ever proves to be two real canonical rows rather than an echo — that was investigated and left unproven.
- **iOS expand-button hit target (#357, PR #358; structural fix PR #426).** The invariant is "the Show more / Show less control is a full 44pt tap target on all three iOS bubble surfaces" — `SNMsgBubble` (`SonarComponents.swift`), `SonarMessageBubbleView`, `TextMessageView`. It is enforced *only* by view-tree shape: `.buttonStyle(.plain)` hit-tests the button's **label subtree**, so `.frame(minHeight: 44)` and `.contentShape(Rectangle())` must sit inside the `label:` closure. Chained onto the `Button` wrapper instead — which is what the `Button(<title>) { <action> }` convenience initializer invites — they widen the layout box and leave the blank part of the 44pt area dead. That is exactly how #358's first attempt failed review while looking correct. **Now structural rather than remembered:** all three surfaces render the shared `ShowMoreButton` (`ios/bitchat/Views/Components/ShowMoreButton.swift`), which owns the label-subtree shape and `ShowMoreButton.minimumHitTarget`, so a fourth surface cannot reintroduce the bug without editing that one file. Still no test, and none would run: iOS tests are not in CI (see below), and hit-region behaviour needs a UI test rather than a unit test — the shared component is the guard. Compose is structurally immune — in `MessageBubble` (`App.kt`) `heightIn(min = 44.dp)` sits outside `clickable`, so the constraint propagates into the clickable node. The expanded/collapsed accessibility state is now set on both platforms (iOS `.accessibilityValue`, Compose `stateDescription`) from the localized `content.message.expanded` / `.collapsed` keys; PR #426 also replaced Compose's hardcoded English `"Show more"` / `"Show less"` with the already-translated resources. **What is still unpinned:** nothing verifies the a11y value is actually announced, and nothing prevents a new surface from hand-rolling its own expand control instead of using `ShowMoreButton`.
- **Mesh-folded chat id resolution.** Group-keyed state (`unreadByChat`, snapshots, read-marking) must be resolved through `transcriptGroupIds`, never indexed with a `mesh:` route id — and position/count logic must not trust a mesh chat's first painted feed before it catches up with `latestKnownMessageSecs` (the BLE window publishes before the White Noise leg merges). Both broke the unread divider for mesh chats only (PR #303, commits 070c00f3e + 80feb4ade); no test pins either invariant. `transcriptGroupIds` needs instance state, so pinning likely means extracting the resolver or an in-process store test. See `docs/CHAT-TYPES.md`.
- **Sticker ref resolution on the hosts (#307).** The bug fixed there — a stale session pack LRU pinning a validated-local fallback, so a newly-added sticker showed the failed placeholder for the session while older ones rendered — lives in `SonarAppState.stickerImage(ref)` and `MarmotChatModel.stickerData(for:)`. Both need a real `SonarCore`, so none of the following is pinned; the helper tests in `StickerSendEchoTest` / `MarmotStickerOptimisticTests` only self-feed the key and retry-schedule functions and would stay green if the whole repair were deleted. Same root cause as the three gaps above. Unpinned invariants, all of which have already broken once:
  - **A received sticker renders even when its pack is not installed.** The installed set (`installedPackCoordinates`) gates only the *picker* via `shouldExposeCachedStickerPack` — what you may SEND. Anything a peer sends must resolve from the reference alone. If an install check ever leaks into the ref-render path, every sticker from a pack the recipient does not have goes black.
  - **A "not in pack" verdict is only trusted when a relay was actually reached.** `fetch_sticker_pack_singleflight` falls back to stale validated-local metadata when the relay fetch fails, so negative-caching an offline answer would keep a good sticker black for the session — the same class of bug #307 fixes. Guarded in code by the `isRelayConnected()` condition on `rememberUnresolvableStickerRef`, by nothing else.
  - **An explicit tap on the failed placeholder always retries**, bypassing the negative cache (`userInitiated`), so a wrong verdict is never a dead end.

  The core half IS pinned (`sticker_ref_prefetch_claims_are_cross_batch_and_released`, `cancel_on_wiped_session_abandons_inflight_fetch_after_wipe`).

- **A background wake must close the Marmot store before iOS suspends the process (0xdead10cc, round 2).** #446 added `closeStoreAfterBackgroundWake()` but the close could not win the race, and 1.12.1 build 29 crashed with the same `RUNNINGBOARD 0xdead10cc` 31s after a background launch. Round 3 (build 30) hit the remaining hole — an *in-flight* sync the close cannot preempt — now covered by R-016; the hazards below are still real and separately load-bearing. Three things had to be true together, and each is a separate hazard worth keeping:
  - **Nothing may flood `MarmotService.workQueue` during a background wake.** That queue is *serial*, and `fetch_sonar_descriptor` parks in uncancellable Rust for two `FETCH_TIMEOUT` fetches (`core/sonar-core/src/client.rs`, 10s each). `loadLocalSummaries(resolveMembers: true)` kicks one `ensureProfile` + `ensureSonarDescriptor` per group member and `SonarPushProcessor` calls it three times per wake, so a handful of contacts queues minutes of blocking work ahead of `closeNode()`'s own `workQueue.async` hop. Both prefetches are now gated on `MarmotChatModel.canPrefetchFromRelays` (`applicationState != .background`). The gate sits *before* the in-flight dedup inserts, so a skipped wake does not leave a poisoned `profileFetches` / `descriptorFetches` entry that suppresses the next foreground fetch.
  - **The flock must NOT be released ahead of the node, and the close must not be abandoned bare.** Releasing `storeLock` early to beat the queue was tried and reverted during review: the NSE opens its own `SonarNode` on the same store the instant it wins the flock (`NotificationService.collectMarmotNotificationsAfterWake`) and drains MLS events, so two processes would commit against one store and could fork group state. `NotificationService` states the contract directly — never unlock under an open handle. That trades a background kill for a corrupted MLS store, which is worse. What actually makes an early return safe is a `UIApplication` background task held across `closeNode()` (same pattern as `suspendStoreForBackground()`), so the wake can report its fetch result on time while iOS keeps the process alive until the store is genuinely shut.
  - **No blocking FFI may hold a `SonarNode` across a retry sleep.** `SonarPushRegistration.registerTransponderIfReady` captured the node and slept 2s then 4s between attempts, outside the lease system — so the Rust node, its SQLCipher handle, and that handle's locks on the shared store outlived `closeNode()`'s `clearSonarNode()` entirely. The node is now re-read per attempt inside `attemptRegistration`, which returns `.nodeGone` and stops when the session was closed.

  The deadline around the close is a safety net, not the fix. It must not be built on `withTimeout`: that is a `withThrowingTaskGroup`, and **a task group awaits its children before rethrowing**, so it cannot bound work that ignores cancellation — `closeNode()` parks in `withCheckedContinuation` behind the serial queue and never observes it. #446 made the *sync* deadline land by adding `Task.isCancelled` to the `ensureConnected()` / `ensureRelayConnected()` poll loops; the close has no such seam. `closeStoreWithDeadline` therefore runs the close in a detached task and polls a latch, abandoning the wait rather than cancelling it, and reruns `reconnectIfForegroundAfterWakeClose()` once the close actually lands — the caller's own recheck may have run while the node was still open and done nothing.

  **Unpinned on iOS.** `canPrefetchFromRelays` is a `private var` on `@MainActor MarmotChatModel`, which no test constructs (same root cause as the `SonarAppStore` gaps above), and iOS tests do not run in CI regardless. Extracting an `applicationState -> Bool` seam would pin a helper, not the two call sites that matter — exactly the R-001 failure mode. Verification is a TestFlight build surviving repeated background push wakes with relays slow or unreachable.

  **No Compose mirror.** Android has no RunningBoard file-lock kill and no App Group / NSE cross-process store, so the crash is iOS-only. `SonarAppState.ensureSonarDescriptorHex` does run the same unbounded background prefetch, where it costs battery and wakelock time rather than the process; gating it on Android is tracked follow-up work, not part of this fix.
