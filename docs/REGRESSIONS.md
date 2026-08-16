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

**Breaks as:** Opening the keyboard hides the last screenful of messages behind the IME, or a newly sent bubble remains below the fold until manual scroll. Once the sentinel-based near-bottom flag flips false, later layout changes can become no-ops. Two further shapes. First, reported 2026-07-31 on iOS 1.12.5 and reproduced on device-shaped runs: a conversation shorter than the viewport opens pinned to the TOP with a screen-tall empty band between the last bubble and the composer. Second, found while investigating the first and proven only in the harness: a viewport shrink whose owned inset happens NOT to change skips the re-pin entirely and parks the tail behind the composer. Note the honest limit — the live IME does **not** trigger that second shape today, because `.ignoresSafeArea(.keyboard)` keeps the host full-height so the composer riding `keyboardLayoutGuide` always moves the owned inset. It is reachable by rotation, Slide Over / Split View, and by any future regression that lets SwiftUI keyboard-avoid the host again (the #347 shape). Treat it as a guard, not as an observed field bug.

**Why:** Both list stacks are top-anchored: viewport shrink or content growth keeps the first visible row, not the last. Both platforms' live "near bottom" signals are consumed by that same change, so the pinner must carry the previous frame's tail state and separately observe genuine user scrolling. Timers (the #303 iOS fix pinned at now/+0.35s) lose to whatever settles after them. The two 1.12.5 shapes have their own causes, both structural rather than racy: a scroll view cannot scroll content it does not have, so with `contentInset.top` forced to 0 an underfilled feed has exactly one resting offset (the top) and no amount of pinning moves it; and the change signal that triggers a re-pin was keyed on the OWNED INSET, which measures composer chrome — a host that shrinks while the composer rides the keyboard guide changes neither, so the re-pin never ran at all.

**Call sites:** iOS production (Phase 3 cutover) `TranscriptEngine` `TranscriptCollectionHostViewController` (`transcriptOwnedBottomContentInset` + `transcriptShortFeedTopContentInset` in `TranscriptOwnedInset.swift`, both applied in `TranscriptCollectionHost.swift::updateOwnedInsetsFromChrome`, whose change signal must include `collectionView.bounds.height`) via Sonar adapter `SNTranscriptCollectionHostAdapter.swift` → `SNTranscriptCollectionHost.swift`; iOS fallback `SonarComponents.swift::SNMsgList` (`SNTailPinLatch` + `SNUserScrollObserver` + sentinel/count/viewport events); Compose production `packages/transcript-engine-compose` (`TranscriptHostScrollEffects` / Sonar shim `TranscriptPolicyHostScaffold.kt`) (`TranscriptTailPinSession` + `decideInsetChange` Pin/Lockstep); Compose fallback `App.kt::TranscriptTailPinning` (`TranscriptTailPinner` → `TranscriptTailPinSession` / `packages/transcript-engine-policy`).

**Guarded by:** `SNTailPinLatchTests.shrinkKeepsPinningWhileSentinelIsCovered`

**Also guarded by (real call site, SPM, runs in CI):** `TranscriptCollectionHostLayoutTests.shortFeedRestsOnTheComposerInsteadOfLeavingAnEmptyBand`, `TranscriptCollectionHostLayoutTests.viewportShrinkWithUnchangedOwnedInsetStillRePinsTheTail`, `TranscriptCollectionHostLayoutTests.shrinkThatOverflowsAShortFeedStillLandsOnTheComposer`, `TranscriptCollectionHostLayoutTests.tallFeedKeepsNoTopInsetAndStaysOnTheLiveEdge`

**Also guarded by:** `SNCollectionHostInsetTests.shortFeedTopInsetBottomAlignsOnlyWhileContentUnderfillsTheViewport`, `SNCollectionHostInsetTests.ownedInsetUsesViewportSpaceNotContentSpace`, `SNCollectionHostInsetTests.ownedInsetStableAcrossScrollPositions`, `SNCollectionHostInsetTests.mediaHeightFingerprintChangesWhenDimsArrive`, `SNCollectionHostInsetTests.floatingComposerGapRequiresSingleKeyboardOwner`, `SNTailPinLatchTests.keyboardFrameChangeCapturesVisibleTailBeforeShrink`, `SNTailPinLatchTests.expandKeepsPinningAfterPhantomKeyboardInsetClears`, `SNTailPinLatchTests.preLayoutKeyboardClampIsNotUserScroll`, `SNTailPinLatchTests.tailRevisionTracksOnlyCountAndLiveEdge`, `SNTailPinLatchTests.tailSnapBurstCoalescesUntilDelivery`, `SNTailPinLatchTests.appendedOutgoingRowAtTailFollows`, `SNTailPinLatchTests.replacedTailAtCapacityStillFollows`, `SNTailPinLatchTests.nonKeyboardLayoutTheftSnapsBack`, `SNTailPinLatchTests.keyboardShowWithoutShrinkDoesNotLeaveStickyPin`, `SNTailPinLatchTests.userScrollAwayIsRespectedAfterTailReturns`, `SNTailPinLatchTests.nonTouchScrollTowardTopCountsAsUserScroll`, `SNTailPinLatchTests.programmaticTailFollowIsNotUserScroll`, `SNTailPinLatchTests.downwardDecelerationAtVisibleTailIsIgnored`, `SNTailPinLatchTests.layoutDrivenUpwardOffsetIsNotUserScroll`, `SNTailPinLatchTests.nonTouchHistoryScrollAfterResizeStillCounts`, `SNTailPinLatchTests.anchoredOpenNeverPins`, `SNTailPinLatchTests.keyboardDismissOvershootIsClampedToContentBounds`, `SNTailPinLatchTests.transcriptOpenUsesBottomAnchorOnlyWhenFullyRead`, `SNTailPinLatchTests.fullyReadOpenResnapsUntilLiveEdgeLands`, `SNTailPinLatchTests.clearLiveEdgeOpenRequiresOwnedChrome`, `SNTailPinLatchTests.markLeftBottomIgnoresProgrammaticLiveEdgeOpen`, `SNTranscriptScrollPolicyTests.insetFollowPinsWhenWasAtTail`, `SNTranscriptScrollPolicyTests.insetFollowLockstepsWhenAwayFromTail`, `SNTranscriptScrollPolicyTests.insetFollowIgnoresWhileDraggingOrPrepending`, `SNTranscriptScrollPolicyTests.captureWasAtTailBeforeInsetChangeMatchesSignal`, `SNTranscriptScrollPolicyTests.openActionFullyReadIsLiveEdge`, `SNTranscriptScrollPolicyTests.openActionPendingUnreadIsUnreadDividerEvenWithoutResolvedId`, `SNTranscriptScrollPolicyTests.openActionUnsetCaptureIsProvisionalLiveEdge`, `SNTranscriptScrollPolicyTests.openActionSettledZeroIsLiveEdge`, `SNTranscriptScrollPolicyTests.openActionSettledNonZeroIsUnreadDivider`, `TranscriptScrollPolicyTest.openAction_unsetCapture_isProvisionalLiveEdge`, `TranscriptScrollPolicyTest.openAction_settledZero_isLiveEdge`, `TranscriptTailPinnerTest`, `TranscriptTailPinningUiTest` (Compose, real `LazyListState` wiring), `TranscriptScrollPolicyTest.session_keyboardShrink_atTail_pinsSnap`, `TranscriptScrollPolicyTest.insetChange_atTail_pins`, `TranscriptScrollPolicyTest.insetChange_userScrolling_ignores`, `TranscriptScrollPolicyTest.insetChange_prepending_ignores`.

**Coverage (honest):** Production iOS is the Phase 3 collection host: owned bottom inset from composer occlusion in **viewport** coordinates (`transcriptOwnedBottomContentInset` / `snCollectionHostOwnedBottomContentInset` shim, `.never` adjustment — converting into the scroll view's content space collapses the inset at the tail of a long chat; guarded by `SNCollectionHostInsetTests` at the Sonar shim call site and duplicated in SPM `TranscriptOwnedInsetTests`, which the regression ledger does not scan), pre-measured cells (`TranscriptRowHeightCache` + `sizeForItemAt`), and `TranscriptTailPinLatch` + 10 ms coalescer on inset Δ / contentSize growth in `TranscriptCollectionHost.swift`. The representable must `.ignoresSafeArea(.keyboard)` so SwiftUI does not shrink the host while `keyboardLayoutGuide` also lifts the composer — otherwise the bar floats ~one IME height above the keyboard (`transcriptFloatingComposerGap` / `snCollectionHostFloatingComposerGap`; helper-level only — device smoke still confirms the modifier). Kill-switch fallback remains `SNMsgList` (sibling composer ⇒ `snOwnedTranscriptBottomContentInset` = 0; still wants SwiftUI keyboard avoidance). Compose production is `TranscriptHostScrollEffects` in `transcript-engine-compose` (real Pin/Lockstep; Sonar shim `TranscriptPhase2ScrollEffects`); legacy `TranscriptTailPinning` is kill-switch only. The Swift tests pin latch/open-policy helpers and inset coordinate math — not that `scrollTo` lands (iOS tests still do not run in CI). In particular, `clearLiveEdgeOpenRequiresOwnedChrome` / `markLeftBottomIgnoresProgrammaticLiveEdgeOpen` guard the pure predicates; they do **not** pin that `TranscriptCollectionHost` wires `clearLiveEdgeOpenIfSettled` after inset commit or keeps advancing the contentSize watermark. The Compose UI test is the stronger guard for pin. Device smoke remains the recommended hardware gate for keyboard pin, unread open, and mesh-image remeasure; CI additionally runs SPM `TranscriptOwnedInsetTests` / open-action goldens on PRs that touch `ios/localPackages/TranscriptEngine/**`. As of 2026-07-31 `TranscriptCollectionHostLayoutTests` closes the "not that `scrollTo` lands" hole for the resting-geometry cases: it drives the real `TranscriptCollectionHostViewController` through a `UIWindow` layout pass and asserts the measured gap between the last row and the owned composer chrome, so it fails on a broken call site even when every helper stays green (all three shrink/short-feed cases were verified red before the fix). It still does **not** cover the live IME (`keyboardLayoutGuide` is inert in the harness — window resize is the stand-in), animated appends, or media remeasure.

**History:** #283 (Compose) -> #303 (iOS, notification + fixed delays; incomplete) -> this fix (previous-frame pinner + explicit user-scroll observation, Signal `wasScrolledToBottom` shape) -> phantom empty band (viewport expand ignored) -> rejected LazyVStack spacer / `contentSize` top-inset experiments that yanked GIAN / Ocean LCI Alert or opened DMs mid-history -> conditional `defaultScrollAnchor` for fully-read opens only -> alpha.11 still opened mid-DM (one `scrollTo` vs under-measure; latch unpinned until sentinel) -> `needsLiveEdgeOpen` re-snap until live edge lands -> unset unread capture treated as `0` chased the tail then jumped to the divider (fixed: optional settle + hold) -> collection host cleared `needsLiveEdgeOpen` on pre-chrome `isScrolledToBottom()` and pre-latch scroll callbacks set `hasLeftBottom`, ending open recovery a flick short of the last message (clear only after owned chrome; ignore programmatic left-bottom during live-edge open) -> 1.12.5 field report: short chats opened top-aligned with a screen-tall band above the composer and the keyboard hid the newest row, because the collection host forced `contentInset.top = 0` (no bottom alignment for a feed shorter than the viewport) and gated its re-pin on the owned inset rather than on the layout — fixed by `transcriptShortFeedTopContentInset` plus a bounds-height term in the change signal.

**Rejected:**
- *Fixed-delay double pin after `keyboardWillShow` (#303).* The 0.35s timer races the safe-area animation and anything that settles later (late transport-leg merge, sticker/media decode); one lost race also strands `isNearBottom` at false, disabling every later keyboard open.
- *Unconditional `defaultScrollAnchor(.bottom)`.* Fights unread-anchor opens. Conditional (fully-read only) is what shipped.
- *Dynamic top spacer inside LazyVStack.* `contentSize` includes the spacer ⇒ feedback loop yanked chats (GIAN / Ocean LCI Alert).
- *`contentInset.top = max(0, viewport − contentSize)` from LazyVStack metrics.* `contentSize` under-measures on open ⇒ DMs started away from the last message. Rejected **for the SwiftUI list**. The same formula is what shipped for the Phase-3 collection host (`transcriptShortFeedTopContentInset`) and it is safe there for one reason: rows are pre-measured through `TranscriptRowHeightCache` + `sizeForItemAt`, so `UICollectionView.contentSize` is exact rather than a running estimate. Do not port it back to `SNMsgList` — that path keeps `.defaultScrollAnchor(.bottom)`.
- *Gating the re-pin on the owned inset alone.* The inset is a function of composer chrome, not of the viewport; a host that shrinks while the composer rides the keyboard guide changes neither `barHeight` nor `contentInset.bottom`, so `updateOwnedInsetsFromChrome` returned before ever consulting the latch. The bounds height is now part of the same change signal.
- *`.frame(minHeight:alignment:.bottom)` on LazyVStack.* Ignored by LazyVStack.
- *Flipping the ScrollView 180°.* Structurally bottom-anchored, but inverts every gesture/accessibility behaviour and would rewrite the whole transcript surface.
- *Keeping SwiftUI keyboard avoidance alongside `keyboardLayoutGuide`.* Double IME ownership floats the composer ~one keyboard height above the IME and inflates the owned bottom inset so the live edge is clipped under the bar.

**Platform gap:** Compose `LazyColumn` is still top-anchored for short feeds (no `reverseLayout` / fill-height bottom arrangement) — confirmed 2026-07-31 at the production call site `App.kt::ChatFeedList`, which passes only `contentPadding` and no `verticalArrangement`. The iOS fix was NOT mirrored in the same change: `Arrangement.Bottom` interacts with the `stickyHeader` day markers in that same list (a pinned "Today" chip can float at the top of the empty band), and this session had no Android device/emulator to verify it on. Follow-up: add `verticalArrangement = Arrangement.Bottom` to `ChatFeedList` plus a `TranscriptTailPinningUiTest` case for a short feed with a sticky day header, and mirror the viewport-shrink re-pin — the Compose host reacts to `bottomInset` changes, so a keyboard resize that leaves the inset untouched has the same hole `updateOwnedInsetsFromChrome` had. The pre-chrome `needsLiveEdgeOpen` clear race fixed here is **iOS Phase-3 collection host only** — Compose clears on layout-proof live-edge checks, and MsgList waits for the `sn-bottom` sentinel rather than owned composer chrome.

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

## R-018 — An unreadable local store must never paint as an empty conversation

**Invariant:** A local transcript read that returns nothing is only painted when
the store was actually readable. "Core is not readable yet" and "this
conversation has no messages" must not reach the UI as the same answer, and an
empty window must never be cached as a conversation's contents.

**Breaks as:** Opening a chat shows a black transcript — header, verified
banner and composer, no rows — and the messages appear seconds later when an
unrelated sync event repaints. Typing works throughout, which is what makes it
read as a rendering bug rather than a loading one.

**Why:** `SonarCore.messagesCursorPage` / `messagesPage` answered `emptyList()`
when `node` was null (still booting after a cold launch, or being replaced),
which is indistinguishable from a genuinely empty conversation. The transcript
committed that as the page, and `refreshTranscriptGroupWindow` then *cached* the
empty window — after which `current != null` short-circuited every later refresh
and the chat stayed blank until something else published rows. The `!started`
fallback did not cover it, because `started` is true well before every read path
has a node.

**Call sites:** Compose `SonarCore.android.kt` / `SonarCore.jvm.kt`
(`messagesPage` / `messagesCursorPage` now `requireNode()`);
`TranscriptDisplayPolicy.transcriptReadIsUntrusted` consumed by
`SonarAppState.refreshTranscriptGroupWindow`;
`SonarAppState.scheduleBlankTranscriptRecovery` wired into `openChat`, `openDm`
and `restoreTranscriptSession`. iOS: not implemented — see platform gap.

**Guarded by:** `TranscriptDisplayPolicyTest.emptyReadIsUntrustedWhenLocalMetadataKnowsMessages`

**Also guarded by:** `TranscriptDisplayPolicyTest.blankRecoveryRunsWhenEmptinessCannotBeProven`, `TranscriptDisplayPolicyTest.blankRecoverySkipsAConversationProvenEmpty`

**Coverage (honest):** the cited tests pin the pure trust decision (including
that a genuinely empty conversation stays paintable, or a new chat would hold a
stale window forever) and the recovery gate. They do **not** pin that
`refreshTranscriptGroupWindow` consults the first, that the empty window is no
longer cached, that the read APIs throw instead of returning empty, that mesh
recovery resolves through `localTranscriptRowsForChat`, or the retry loop itself
— all of which need a constructible `SonarAppState` (see Unguarded). The
recovery budget (8 s, 100 ms → 800 ms backoff) is a judgement call, not a
measured one.

**Two ways the recovery can miss, both deliberate:** its read must resolve the
conversation's real sources (a mesh route id is not a Marmot group id — hand it
to a group-page read and every retry answers "no messages"), and its gate must
not treat "we cannot tell yet" as "genuinely empty" (the mesh snapshot is keyed
by group id, so a cold-launch mesh route knows of no history until `chats` /
`npubRawFor` resolve). Both were live in the first cut of this fix.

**Apple half (#450):** landed after the Compose half. The Apple read path
already had the first half right — `MarmotService`'s lanes THROW when no node
is leased, so an unreadable store can never answer with an empty page that
gets committed as a conversation's window. The missing half was the recovery:
an open that lost the race with store readiness (or one on a conversation
whose Marmot group had not resolved yet) left the transcript black until an
unrelated sync event published rows. `SonarTranscriptRecoveryPolicy`
(`shouldRecoverBlankTranscript`, same three inputs as the Compose gate) plus
`MarmotChatModel.scheduleBlankTranscriptRecovery`, wired into
`loadLocalWindow`, re-read local storage on a bounded backoff (~6.3s,
100ms → 800ms) without ever blocking first paint.

**Apple call sites:** `SonarTranscriptRecoveryPolicy.shouldRecoverBlankTranscript`
consumed by `MarmotChatModel.scheduleBlankTranscriptRecovery`, called from
`loadLocalWindow` (the chat-open hydrate) and cancelled per group when a
conversation is dropped and wholesale on account reset.

**Also guarded by (Apple):** `SonarTranscriptRecoveryPolicyTests.recoveryRunsWhenLocalMetadataKnowsMessages`, `SonarTranscriptRecoveryPolicyTests.recoveryRunsWhenEmptinessCannotBeProven`, `SonarTranscriptRecoveryPolicyTests.recoverySkipsAConversationProvenEmpty`

**Not guarded (Apple):** same shape as the Compose half — the tests pin the
pure gate and the budget, not that `loadLocalWindow` consults it, that the
retry loop stops on the first non-empty read, or the cancellation paths. iOS
tests also do not run in CI.

**History:** Reported with screenshots: chat open on a black transcript, rows
appearing "after a while". Distinct from R-017 (which mis-*places* the divider
on a populated transcript) and from R-009 (which mis-*scrolls* one) — all three
surface to the user as "the chat opened wrong", which is why the first two fixes
did not touch this path.

**Rejected:**
- *Waiting for a readable store before `push`.* Keeps the user on Home with a
  dead tap; the Signal-Comparable Performance Rule wants the chat open
  immediately, painting whatever local state exists.
- *Letting the next sync/poll repaint it.* That is exactly today's behaviour and
  what produced the reported delay — it ties first paint to a network-driven
  event.
- *Returning `emptyList()` but flagging a boolean alongside it.* Every caller
  would have to remember to check the flag; throwing routes through the
  `runCatching { … }.getOrNull()` both call sites already have.

---

## R-019 — A Bluetooth power cycle must rearm the radio, not silently deafen it

**Invariant:** When the Bluetooth adapter goes off and comes back — which is
exactly what airplane mode does — the mesh radio must tear down on OFF and
restart on ON, without the process being killed.

**Breaks as:** the user toggles airplane mode (or Bluetooth) and the app never
discovers anyone again. It still looks healthy: advertising state is shown, no
error surfaces, the scan watchdog keeps ticking.

**Why:** three failures compound, and each alone is survivable:
1. Nothing observed the adapter — no `ACTION_STATE_CHANGED` receiver existed in
   `androidMain`, and `startMeshRadio()` ran only from `onCreate` / the
   permission callback.
2. `scanning` latches. The OS tears down scan and advertiser on power-off but
   nothing clears the flag, so `if (scanning || !available()) return` in
   `MeshRadio.start()` makes every later start a no-op.
3. The watchdog could not heal it **and hid that it could not**:
   `startScanInternal` reused the cached `BluetoothLeScanner` (invalidated by
   the power cycle) inside `runCatching`, then stamped `lastScanStartMs` /
   `lastScanCallbackMs` / `lastNewDiscoveryMs` unconditionally — resetting its
   own staleness heuristic on every failed restart so it never escalated.

**Call sites:** Compose `MainActivity.adapterStateReceiver` →
`bleAdapterAction` (`MeshRadio.kt`) → `MeshRadio.stop()` / `startMeshRadio()`;
Apple: not applicable — `centralManagerDidUpdateState` fires on every
transition and `.poweredOn` re-runs `startScanning()` (see R-006). Desktop: not
applicable — `MeshRadio.jvm.kt` `start()` has no latch and re-enters
`BleBridge` cleanly.

**Guarded by:** `MeshLinkLivenessTest.adapterOffTearsDownAndAdapterOnRestartsTheRadio`,
`MeshLinkLivenessTest.adapterTransitionalStatesAreIgnored`

**Coverage (honest):** both tests pin the pure `commonMain` decision
(`bleAdapterAction`) — OFF ⇒ teardown, ON ⇒ restart, transitional ⇒ ignore —
which is the tier that actually runs in CI (`apps/sonar` has no
`androidUnitTest` source set). They do **not** cover the receiver registration
itself, the `IntentFilter`, the scanner re-acquisition, or the
stamp-only-on-success change; no JVM test can drive a `BroadcastReceiver` or a
`BluetoothLeScanner`. Those were verified by hand on a Pixel 4 XL: 0
`MeshRadio: discovered` lines across a 15s Bluetooth-off window, 6 within 20s of
it returning, `scanning + advertising` logged, no app restart. Keep that adb
recipe (`adb shell svc bluetooth disable|enable`, count discoveries per window)
for re-verification — `MeshRadio.stop()` logs nothing, so measure discovery
counts rather than looking for a teardown line.

**History:** carried as an unproven "Compose side of R-006" gap until a user
reported it from airplane mode on a Pixel 10.

**Rejected:**
- *Relying on the scan watchdog.* It cannot re-acquire an invalidated scanner,
  and its unconditional timer stamping made a permanently dead scanner look
  healthy — the reason this went unnoticed.
- *Calling `start()` on app resume instead of a receiver.* The adapter can cycle
  while the app is foregrounded, which is the reported case; resume never fires.
- *Putting the decision in `MainActivity`.* `apps/sonar` has no
  `androidUnitTest` source set, so it would have shipped untested — the same
  reason `bleScanRestartReason` lives in `commonMain`.

## R-020 — A backgrounded app must never reopen the store it just closed

**Invariant:** Once the scene-phase suspend hook has closed the Marmot node, no
*self-healing* timer may reopen it while the app is still backgrounded, and the
loops that arm those timers must be stopped by the same hook that closes the
node. Deliberate reopens (the push wake, the foreground resume) are unaffected.

**Breaks as:** `RUNNINGBOARD 0xdead10cc`, round 4 — TestFlight **1.12.3 (31)**,
the build shipping R-016. Distinguishing feature versus rounds 1-3: the process
had been alive **8h43m**, the main thread was idle in its run loop, and no
thread was in `SonarClient::sync` or `register_push_token` at all (R-016 works).
What the log showed instead was two loops actively parked in
`MarmotService.leasedNodeOperation` — `waitForMarmotEvent` and `callWaitEvent`.
That is the tell: `leasedNodeOperation` refuses a lease when `nodeClosing` is
set or `node` is nil, so being *inside* one proves the node was **open**. The
question was never "what blocks the close" (rounds 1-3) but "what reopened it".

**Why:** `suspendStoreForBackground()` — the scenePhase `.background` path —
closed the node but left `syncTask` running, where its sibling
`closeStoreAfterBackgroundWake()` cancels it. The polling loop then walked a
route R-016 does not cover:

1. `waitForMarmotEvent(25)` slices the wait into 25 one-second
   `leasedNodeOperation` calls. With the node gone each throws `notConnected`,
   `try?` discards it, the loop sleeps its slice, and after 25s returns `false`.
2. The `false` branch calls `ensureSubscriptions()`, which throws
   `ServiceError.notConnected` — a plain "no node", **not**
   `SUSPEND_INTERRUPT_MARKER`. R-016's terminal `isSuspendInterrupted(error)`
   check therefore does not fire.
3. Control falls into the generic catch, which arms
   `scheduleRelayConnect(delaySeconds: 2)`.
4. `connectRelaysIfNeeded()` had no app-state check, so it reopened SQLCipher
   while backgrounded — and `connect()` finishes with `startPolling()`, whose
   next idle timeout arms step 3 again. The reopen sustains itself indefinitely,
   which is why the process survived hours before RunningBoard collected it.

R-016 anticipated the *shape* of this and closed only half of it: it audited the
error paths reachable when the latch fires, and its own notes record the
asymmetry — "`closeStoreAfterBackgroundWake()` already cancels `relayConnectTask`
for exactly this reason; the scenePhase `suspendStoreForBackground()` path does
not." The steady state *after* the close, where the error is `notConnected`
rather than a suspend abort, was left open.

**The gate is on the timer, not on connect.** `connectRelaysIfNeeded()` must
stay callable while backgrounded: `SonarPushProcessor`'s wake reaches it through
`ensureRelayConnected()` and needs relays with the app in `.background`, and it
owns a bounded close afterwards. Every caller of `scheduleRelayConnect`, by
contrast, is a retry firing on a timer with nobody waiting on it. So
`scheduleRelayConnect` consults `RelayConnectionPolicy.shouldAutoReconnect` when
the timer **fires**, not when it is armed — the delay routinely straddles the
foreground→background transition, and a schedule-time check would miss exactly
the case that crashes.

**A cancelled polling loop must return before any error classification.** Quiescing
`syncTask` is only half of it — the loop must also not mistake its own shutdown for a
relay failure. `ensureSubscriptions()` is parked in Rust and cannot observe Swift
cancellation, so it runs to completion and then throws `notConnected` once the node is
gone, or aborts with `SUSPEND_INTERRUPT_MARKER` because R-016 made it suspendable. On
the suspend path the task is cancelled *and* the error carries the marker, so an
order that classifies first lets `isSuspendInterrupted` win and clear `syncTask`.

That matters because `Task` is a **struct**: there is no `===`, so the loop cannot
express "only clear the slot if it is still mine" (`stopPolling()` hit the same wall
for `mediaResumeTask` and says so at its call site). A late-returning cancelled task
therefore nils a slot a fast foreground resume may already have refilled, the next
`startPolling()` passes its `guard syncTask == nil`, and two concurrent loops both
call the **destructive** `drainPendingMarmot` — racing the notification metadata
`noteDrainedForPushWake` reads. So the cancellation check goes first, in both catch
blocks, and a cancelled loop returns without touching shared state at all.

An `isDeliberatelyStopped(_:)` helper that also matched `ServiceError.cancelled` was
tried and removed: `ensureSubscriptions()` goes through `MarmotService.run()`, which
can only produce `invalidInput`, `core`, or `notConnected` — the `.cancelled` throws
all live on the connect path (`connect` / `connectLocal` / `connectNode`, gated on
`nodeClosing`) or inside `leasedNodeOperation`, neither of which `run()` touches. It
could never fire, and dead code on this path reads as coverage that is not there.

**The call loop leaked past its call.** `SonarAppStore.startCallLoop()` was only
ever cancelled by `resetCallState()` (wipe/erase), never by `finalizeCall`, so
after the first call of a session it parked in 1s `callWaitEvent` slices
forever — taking a node lease every second and keeping the SQLCipher handle hot.
That is thread 22 of the crash log, 8h in. It cannot *reopen* the store, so it
did not cause this crash, but it delays every `closeNode()` and burns battery.
Cancelled in `finalizeCall` now; `startCallLoop()` is idempotent so the next
call restarts it. It is deliberately **not** stopped on background — an active
call must survive backgrounding.

**Call sites:** iOS `MarmotChatView.swift::scheduleRelayConnect` (the gate),
`MarmotChatView.swift::suspendStoreForBackground` (the quiesce), and
`SonarAppStore.swift::finalizeCall` (the call-loop cancel); policy in
`RelayConnectionPolicy.swift::shouldAutoReconnect`. Compose: the *crash* does not
apply — Android has no RunningBoard file-lock kill, same reason as R-016 — but the
*rule* does, and Android got there first. `RelayConnectionPolicy.kt` already carries
`shouldRetrySupersededAttach(foreground:)` with the same reasoning ("looping would
rebuild sockets the OS is suspending"), and #440 fixed Android's analogous
background-rebuild churn as a battery/wakelock bug rather than a kill. The two
predicates stay separate — Kotlin's covers a superseded in-flight attach, iOS's any
timer-driven reconnect — but share polarity and cross-reference each other, so the
mirror stays diffable. An earlier draft of this entry claimed Compose was simply not
applicable; that was an overclaim from a grep that missed the Kotlin file.

**Guarded by:** `RelayConnectionPolicyTests.backgroundedAppMustNotSelfHealRelayConnection`, `RelayConnectionPolicyTests.foregroundAppStillSelfHealsRelayConnection`

**Not guarded — and this is a real hole, not a formality.** The test pins the
*policy helper*, not the call site, which is precisely the R-001 failure mode
this document warns about: a future edit could delete the `guard` in
`scheduleRelayConnect` and both tests stay green. `MarmotChatModel` is
`@MainActor` with private task state and no test constructs it, and iOS tests do
not run in CI regardless. Specifically unpinned: that
`suspendStoreForBackground()` cancels `syncTask`; that the cancellation check stays
**above** `isSuspendInterrupted` in both catch blocks — nothing but a code comment
stops someone hoisting the classifier back on top; that `finalizeCall` cancels
`callLoopTask`; and that no *fourth* path reopens the store while backgrounded.
Verification is a TestFlight build backgrounded for hours with relays flapping.

**History:** #446 (round 1) -> #448 (round 2) -> #449 / R-016 (round 3,
in-flight sync uninterruptible) -> build 31 crash (round 4: reopen after the
close) -> this fix.

**Rejected:**
- *Making `wait_for_marmot_event` / `call_wait_event` suspendable in Rust.* The
  obvious read of the crash log, and wrong: both Swift wrappers already slice
  into **1s** FFI parks, so neither can hold `closeNode()` for meaningfully
  longer than a second. Latching them would have shipped a no-op and left the
  reopen in place.
- *Blanket-gating `connectRelaysIfNeeded()` on `applicationState`.* Kills the
  push wake, which must attach relays precisely while backgrounded.
- *Checking the app state when `scheduleRelayConnect` is armed.* The delay
  spans the transition; the crash case arms in the foreground and fires after.
- *Relaxing the Compose `shouldRetrySupersededAttach(foreground)` gate the way
  #461 relaxed its sibling `connectRetryDelayMs`.* Proposed twice off the same
  plausible reading — `foreground` is window focus on desktop
  (`Main.kt` `WindowFocusListener`), `platformShouldInvalidateRelayOnBackground()`
  is `false` there, so alt-tab appears to strand a superseded attach until the
  30 s heartbeat. **The premise is wrong: on desktop that branch is
  unreachable.** `relayEpoch` advances only in `invalidateRelayConnection()`,
  whose only callers are `SonarAppState.onProcessBackgrounded()` (gated on
  `shouldInvalidateOnBackground()`, and `SonarDesktopRoot` installs only
  `onForeground`, so it is never even reached) and Android's
  `SonarPushProcessingService`. Epoch frozen ⇒ `latchAfterAttach` always `true`
  ⇒ no desktop attach is ever superseded. The change would have bought nothing
  and loosened the gate this entry exists to keep tight. `connectRetryDelayMs`
  was a legitimate case because it only scales a delay inside a loop already
  committed to retrying; this one decides *whether* to reconnect. Note the
  unreachability is emergent — two independent facts, not one assertion — so a
  desktop push or process-lifecycle path would make the branch live and this
  rejection stale.

## R-021 — A payment destination pays what the payload says, not what we guessed

**Invariant:** Every payable payload is resolved before the wallet sees it — a
BIP-21 URI pays the rail inside it (`lno` > `lightning` > address), a BOLT11
carries its own amount and is never handed one of ours, and a decimal BTC
`amount` is converted digit-by-digit rather than through a `Double`.

**Breaks as:** Silently paying the wrong thing, or nothing at all.
`bitcoin:bc1q…?lno=lno1…` was labelled "Bitcoin address · On-chain" and the whole
URI — query string included — was handed to the wallet, so the BOLT12 offer in
`lno=` was never paid and the send failed with
`AmountMissing: "Expected invoice with an amount"`.

**Why:** This looks like string handling and is really money handling, and each
rule is invisible unless you already know it. The BOLT11 amount ends at the
*last* `1`, not the first, because bech32 excludes `1` from the data charset —
read it the obvious way and `lnbc21u1…` becomes 2 BTC instead of 2,100 sats.
BIP-21 hides the good rails in the query string behind an on-chain address that
parses fine on its own, so a prefix check finds "an address" and stops looking.
And Breez takes a BOLT11's amount from the invoice: passing our own risks
`"Receiver amount and invoice amount do not match"`, and an amountless invoice
cannot be paid at all no matter what we pass.

**Call sites:** Compose `wallet/PaymentDestination.kt::bolt11AmountSats`,
`screens/SonarScanQrSheet.kt::scannedKind`,
`SonarAppState.kt::payDestination`; iOS
`SonarScanQrSheet.swift::SNScannedKind`,
`SonarAppStore.swift::payDestination`

**Guarded by:** `Bolt11AmountTest.everyMultiplierScalesCorrectly`,
`Bolt11AmountTest.microBtcInvoiceIsTwentyOneHundredSats`,
`Bip21ScanTest.unifiedUriPrefersTheBolt12Offer`,
`Bip21ScanTest.btcToSatsIsExactAndRefusesWhatItCannotRepresent`

**History:** #491.

**Rejected:** Passing our own parsed amount alongside a BOLT11 that already
carries one — it reads as harmless belt-and-braces and is the opposite, because
any disagreement with the invoice (the parser rounds `p`-denominated amounts up)
becomes `"Receiver amount and invoice amount do not match"`. Also rejected:
offering the keypad for an amountless invoice, which looks like a courtesy but
is a control that always fails, since the SDK refuses the payment regardless of
the amount supplied.

**Not guarded:** No test asserts the wallet is actually called with a *nil*
amount for a BOLT11 — that needs a wallet double — and the amountless refusal in
`payDestination` has no test on either platform. iOS has no unit test for
`SNScannedKind` at all: the Kotlin tests are the only coverage, so a Swift-side
divergence would not be caught. Nothing here is exercised end-to-end against a
real wallet.
## R-022 — A muted chat must not alert on any delivery path

**Invariant:** Per-chat mute suppresses banner, sound, and haptic on EVERY
delivery path — foreground, background drain, and the killed-app notification
extension — not only the paths that run inside the app process. Rows and unread
badges still accrue.

**Breaks as:** A muted chat rings on the lock screen while the app is killed.
With a trill it rings the loud nudge bell, which is the abuse vector mute exists
to close.

**Why:** Mute shipped in #336 against the in-process paths only. iOS keeps the
mute map in `.standard` UserDefaults, which the Notification Service Extension
cannot read (separate container), so the NSE hydrate path decorated and sounded
muted chats regardless. #443 mirrors the map into the App Group and gates the
NSE decorate on it.

**Call sites:**
- iOS `SonarNotificationService/NotificationService.swift` (killed-app hydrate) → `SonarNSEDecoratePolicy.isMuted` over the App Group mirror written by `SonarChatMuteStore.mirrorToAppGroup`
- iOS `SonarPushProcessor.swift` (drain + summary paths) and `NotificationService.sendLocalNotification` (central in-process gate)
- Compose `SonarPushProcessingService.notifyUnreadConversations` → `decodeMuteMap(SonarCore.loadBlob("mute.byChat"))`

**Guarded by:** `SonarNSEDecoratePolicyTests.nseMuteCheck`

**Also guarded by:** `SonarNSEDecoratePolicyTests.mutedDMSenderDoesNotSilenceGroups` (a muted DM's sender key must not silence that peer's messages in unmuted groups — the NSE judges directness with `meaningfulGroupName`, mirroring the host's gate in `SonarPushProcessor`), `SonarNSEDecoratePolicyTests.nseMuteCandidatesMatchStoreNormalization`, `SonarTrillMessageTests.testMutedChatTrillIsRowOnly`, `SonarTrillMessageTests.testMuteKeyNormalizationBridgesIdShapes`, `SonarTrillTest.muteSuppressesUntilExpiryAndForeverNeverExpires`, `SonarTrillTest.muteMapRoundTripsThroughBlob`

**Not guarded:** The NSE `apply()` call-site wiring. The cited tests pin
`SonarNSEDecoratePolicy.isMuted` and the key-shape agreement, not the filter
inside `hydrateMarmotAndDecorate`, so a call-site regression keeps them green —
the exact failure mode R-001 warns about. Nothing pins the host's
`removeDeliveredNSEOwnedBanners` backstop on the mute branches. Pre-existing
mutes are not mirrored until `SonarChatMuteStore.shared` is first constructed,
so an app updated but never launched fails open. Compose
`notifyUnreadConversations` mute-skip has no test. iOS tests do not run in CI.
The drain path's *sender* match is only as good as the stored key encoding:
core emits the drain sender as 64-hex but group members/profiles as bech32, so
`muteKeys` now stores both encodings of every pubkey-shaped key. A peer key
stored in some third shape (e.g. a Noise fingerprint) would still miss, and no
test pins the two-encoding storage.

Also not guarded: nothing pins that a REMOTE group name cannot buy the DM
branch of the mute lookup. `meaningfulGroupName` is now placeholder-only
(`sonar agent dm`) for exactly that reason — treating generic strings like
`new chat` as "this is a DM" let a group's name route it through the
sender-keyed lookup and suppress its killed-app banner for anyone who muted
a DM with the sender.

**Rejected:** Suppressing in the NSE *before* hydrate using the push payload's
group-id hint (`SonarNSEDecoratePolicy.hintGroupIdHex`) to avoid taking the
store lock — the wake drain is not scoped to the hinted group, so an unmuted
chat's message arriving in the same wake would be silenced along with the muted
one. Moving the iOS mute map into the App Group outright, or onto the core blob
store like Android: correct end state, but it migrates live mute state on a path
where a miss means silent notification loss.

## R-022 — Restore recovers the account, or leaves it exactly as it was

**Invariant:** Every path into the account store either restores the backup or
changes nothing. Staged bytes are promoted only when a restore was actually
requested; a pasted key that matches the signed-in account wipes nothing; and a
dry run reads a backup without touching the live store on any platform.

**Breaks as:** Chats gone with no way back. Three distinct shapes, all shipped
in the same feature:

1. Boot reconcile promoted any staging file that opened under the live key. A
   backup taken by *this* install stages a DB the live key opens, so the key
   check cannot reject it — an interrupted restore left debris that the next
   launch silently promoted, rolling the account back to the backup.
2. Re-pasting your own `nsec` ran the full account-replacement path: wallet
   storage, host caches, and the Marmot store wiped, then restore from Blossom.
   For the current account that trades a live database for the last upload, and
   for anyone who never opened the backup screen — where the disclosure gate
   means nothing was ever uploaded — it destroyed everything with nothing to
   restore.
3. The dry run scratched the decrypted index into `env::temp_dir()`. Android app
   processes have no `TMPDIR` and cannot write `/tmp`, so the one affordance for
   checking a backup is real before a delete-and-reinstall failed on every
   Android device, and users could only take the backup on faith.

**Why:** All three are invisible from the code. The staging file *looks* like
proof a restore is in flight, and the case where it is not is exactly the case
the key check cannot detect. `restoreAccount` reads as "replace this account",
so the same-key call looks like a no-op and is the most destructive input it
accepts. And `tempfile::tempdir()` is correct on every platform the tests run
on — the host suite passes because macOS `/tmp` is writable.

**Call sites:** core `account_backup.rs::reconcile_staged_account_restore`,
`::restore_account_files`, `::preview_account_backup`; Compose
`SonarAppState.kt::restoreAccount`, `SonarCore.android.kt::importIdentity`,
`SonarCore.jvm.kt::importIdentity`, `SonarCore.android.kt::previewAccountBackup`;
iOS `SonarAppStore.swift::restoreAccount`,
`MarmotChatView.swift::restoreIdentity`, `MarmotService.swift::previewBackup`

**Guarded by:**
`account_backup::tests::reconcile_discards_staging_with_no_intent_marker`,
`account_backup::tests::preview_scratch_lives_beside_the_database`,
`account_backup::tests::preview_leaves_the_live_account_byte_identical`

**History:** #368.

**Rejected:** Comparing staged and live modification times instead of an intent
marker — mtime is not a fact about intent, it is a fact about the filesystem,
and a restore staged before the last local write would be discarded for looking
old. Also rejected: keeping the same-key guard only in the core import, which
would still let the store-level path wipe wallet storage and host caches before
the core ever sees the key.

**Not guarded:** The same-key `nsec` guard has no test on either platform — both
entry points need a constructible app object (see the Unguarded root cause), and
verifying it by hand means typing a real account key. The intent marker is
proven end-to-end only by the `backup_roundtrip_driver` example, which is not
run by CI. Nothing pins that restored chats *render*: the Android leg was
verified at the file level, and the synthetic backup used has no MLS groups
behind its conversation summaries.

## R-023 — Re-pasting your own key is never an account replacement

**Invariant:** Importing an `nsec` replaces the account only when it is a
*different* account. The key already signed in is a no-op, and a blank incoming
key never authorises a wipe.

**Breaks as:** Every chat gone, unrecoverably. Import wipes wallet storage, host
caches and the Marmot store, then restores from Blossom. For the current account
that trades a live database for whatever was last uploaded — and for anyone who
never opened the backup screen, the disclosure gate means nothing was ever
uploaded, so there is nothing to restore.

**Why:** `restoreAccount` reads as "replace this account", so the same-key call
looks like the harmless case and is in fact the most destructive input it
accepts. The wipe happens before any comparison the old code made, and the user
who triggers it is usually doing something they believe is safe — re-entering
their own key to "re-sync".

**Call sites:** Compose `SonarAppState.kt::restoreAccount`,
`SonarCore.android.kt::importIdentity`, `SonarCore.jvm.kt::importIdentity`; iOS
`SonarAppStore.swift::restoreAccount`, `MarmotChatView.swift::restoreIdentity`.
All five route through the shared predicate rather than comparing inline.

**Guarded by:** the whole `AccountReplacementTest` (Compose) and
`AccountReplacementTests` (iOS) pair —
`rePastingYourOwnKeyIsNotAReplacement`,
`anEmptyIncomingKeyNeverReplaces`,
`surroundingWhitespaceDoesNotDefeatTheGuard`,
`caseDoesNotMakeItADifferentAccount`,
`exoticWhitespaceIsTreatedIdenticallyOnBothPlatforms`,
`aDifferentKeyReplacesTheAccount`, `noCurrentAccountReplaces`,
`aPrefixOrTruncationIsNotTheSameAccount`, and the iOS `test`-prefixed twins
(`AccountReplacementTests.testRePastingYourOwnKeyIsNotAReplacement`,
`AccountReplacementTests.testAnEmptyIncomingKeyNeverReplaces`,
`AccountReplacementTests.testCaseDoesNotMakeItADifferentAccount`)

**History:** #368, #519.

**Rejected:** Comparing raw npub strings without normalizing — bech32 is
case-insensitive, so `NPUB1…` and `npub1…` are the same account, and a raw
comparison fails open on the destructive side. Also rejected: each platform
using its own idiomatic trim (`String.trim` vs `.whitespacesAndNewlines`),
which disagree on U+00A0 — a non-breaking space around a pasted key was a
no-op on iOS and a wipe on Android. Both now trim an identical ASCII set;
agreeing matters more than which answer, and refusing to strip exotic
whitespace is the safer of the two. Also rejected: comparing raw `nsec` strings — encodings differ and the comparison
would silently fail open on the destructive side. Also rejected: leaving the
comparison inline at each of the five call sites, which is how it shipped
originally; five copies of a data-loss guard is five chances to drop one, and
the pure predicate is the only part reachable from a test.

**Not guarded:** The call sites themselves. No test proves each of the five
actually consults the predicate before wiping — that needs a constructible
`SonarAppState` / `SonarAppStore` (see Unguarded). A caller that skipped the
check entirely would still pass every test here. R-001 regressed exactly this
way: a missing argument at a call site while every helper-level test stayed
green.
## R-024 — A Noise session belongs to the identity its handshake authenticated

**Invariant:** A completed Noise handshake may only be filed under an identity that the authenticated remote static key derives. Validating a replacement must never cost the established session it is trying to replace.

**Breaks as:** An attacker is authenticated as someone else. On iOS the victim's peer ID is mapped to the attacker's fingerprint and announced to every `onPeerAuthenticatedHandlers` subscriber; in Rust `sendable_route` hands the victim's DMs to the attacker's session and `handle_encrypted` attributes the attacker's traffic to the victim. Separately, one unauthenticated packet claiming a peer's ID tore that peer's working session down.

**Why:** Noise XX authenticates the remote static key, but nothing else in the packet does. iOS took the peer ID straight from the packet header. The Rust engine took the fingerprint from an announce, which is a self-contained signed packet that anyone who overhears it can replay verbatim on their own link. So in both cases a genuine handshake with the attacker's own key was filed under a name the attacker chose.

**Call sites:** iOS `NoiseSessionManager.swift::authenticatedRemoteKey(_:matches:)` (called from `handleIncomingHandshake`); Rust `mesh_engine.rs::authenticated_fingerprint` (called from `finish_noise_client` / `finish_noise_server`), plus the `direct` demotion in `handle_announce`

**Guarded by:** `mesh_engine.rs::replayed_announce_cannot_bind_an_attacker_link_to_the_victim_route`, `mesh_engine.rs::late_replayed_announce_cannot_move_an_authenticated_link`

**Also guarded by:** `NoiseSessionBindingTests.handshakeAuthenticatedByAnotherKeyCannotClaimAPeerID`, `NoiseSessionBindingTests.forgedReplacementHandshakeLeavesTheEstablishedSessionIntact`, `NoiseSessionBindingTests.unauthenticatedHandshakeMessageAloneCannotTearDownASession`, `NoiseSessionBindingTests.genuineRehandshakeStillReplacesTheEstablishedSession`

**Not guarded:** the Swift citations above are weaker than the Rust ones by construction. Since #518 an `iOS build` workflow runs `xcodebuild build`, so the Swift half is at least **compiled** on every PR — but it still **executes no iOS tests** (that job's own comment defers test execution as a follow-up needing a UI test target). So `check-regression-ledger.sh` proves those four tests *exist*, the build proves they still *compile*, and nothing proves they still *pass*. The two Rust tests are the machine-checked half: both were verified failing without the fix and both run in CI on every PR. Mutation testing on macOS during review of #462 confirmed the Swift four are not one over-broad test written four times — forcing `authenticatedRemoteKey` to `return true` fails exactly the two that pin the binding and leaves the two that pin candidate isolation passing.

Also not guarded: the fail-open default. `authenticatedRemoteKey` still returns `true` for a peer ID that is neither 16-hex nor 64-hex (#464). That branch is unreachable from the wire — `BinaryProtocol.decodeCore` reads a fixed 8-byte sender field, so a wire ID is always 16-hex — but it is a fail-open last line inside an authentication check, and only in-app callers keep it honest. Rust recovery after a peer rotates its identity on a surviving link is likewise unpinned (#483). The short branch has the same shape: it compares the derived ID against the claimed ID's `bare` part, so it accepts the authenticated key under *any* prefix. That is required for correctness — `isShort` is true for a prefixed 16-hex ID such as `mesh:<16hex>`, and a whole-ID `==` would have rejected the *genuine* peer behind one — but it does mean the prefix carries no weight in the check. Unchanged on the wire, where `PeerID(hexData:)` always yields an unprefixed ID and `bare == id`; like the fail-open default above, only in-app callers keep it honest.

Also not guarded: the expired-session recovery this entry's decrypt path depends on. `handleNoiseEncrypted` catches only the two pre-session `NoiseSecurityError` cases so that `sessionExpired` — raised by `SecureNoiseSession.decrypt` *after* the established-session guard — still reaches the failure-counting path and clears an aged-out session. Nothing pins that, on either platform, because there is no seam for it: `sessionStartTime` is a `private let` with no test setter, while the `#if DEBUG` setters that do exist (`setLastActivityTimeForTesting`, `setMessageCountForTesting`) drive `needsRenegotiation()` and the encrypt-side `sessionExhausted`, neither of which is this path. A `setSessionStartTimeForTesting` would make it an ordinary test (#525). Widening that catch back to the whole enum is the regression, and it would be silent.

**This is a mirror pair.** Drift is the failure mode: a change to one platform that is not made to the other silently reopens the hole on that platform. See the Cross-Platform Feature Rule.

**History:** ported from an upstream bitchat fix in #462, which also extended the invariant to the Rust mesh engine that Android and desktop run.

**Rejected:**
- *Tearing down the established session when a replacement handshake arrives.* That is the original behaviour and it is the denial of service: any unauthenticated peer destroys a working session with one forged message. The candidate slot exists so validation costs nothing until it succeeds.
- *Resetting the Rust link's Noise session when an announce names a different fingerprint.* This looks like the natural recovery path for a rotated identity, but announces are replayable, so it hands an attacker the same one-packet teardown by replaying any victim's announce onto a healthy link. The link is demoted to non-direct instead, which keeps the peer visible in the radar as relayed while refusing to move the route.
- *Dropping only `noise` and leaving `bind` on a rejected Rust handshake.* `bind_allowed` consults `bind.fingerprint` without requiring an established session, so the attacker's link would keep counting as the victim for allowlist fan-out and keep announcing as that peer. The whole binding is cleared.

## R-025 — A fulfilled echo must not retire before its canonical row is windowed

**Invariant:** A send echo fulfilled by a canonical row that is OUTSIDE the
published render window stays pending (hidden — the admitted row renders in its
place) until the row is inside the window. Only a windowed canonical row may
permanently retire its echo.

**Breaks as:** A just-sent message vanishes from the open chat — typically when
the user scrolls during "Sending" — and reappears only when delivery flips to
Sent and the newest-page merge re-admits the row.

**Why:** On Compose the echo is the out-of-window row's ONLY carrier:
`withSendEchoes` short-circuits once `pendingSendEchoes` is empty, and
`admittedCanonical` is recomputed per publish from live echoes, never persisted.
`loadOlderMessages` publishes through `prependConversationRows`, which by
construction cannot introduce a row newer than the pre-scroll window — so after
a one-shot retire (#273's `terminalAcceptedEchoIds` + #290's out-of-window
fulfilment) a scroll-up publish contains neither the echo nor the canonical row.
The same shape hid behind hard `clearSendEcho` calls whose replacing publish is
gated stricter than the clear (`isCurrentTranscriptSession` / `refreshOpenDm`
early-returns) — R-011's mechanism recurring past the first send.

**Call sites:** Compose `SonarAppState.planSendEchoDisplay` /
`TranscriptDisplayPolicy.reconcileSendEchoes` (`windowedFulfilledEchoIds`), and
the clear gates in `SonarAppState.send` (reconcile), `reconcileMeshMarmotSendEcho`,
`sendSticker`. iOS does not share the bug: `reconciledOptimisticMessages` merges
the admitted row into `messagesByGroup` (the retained model), so it survives
without the echo — but any port of the Compose recompute-per-publish shape
reintroduces it.

**Guarded by:** `TranscriptDisplayPolicyTest.sentRowStaysVisibleAcrossScrollShapedPublishesUntilWindowed`

**Also guarded by:** `TranscriptDisplayPolicyTest.acceptedEchoFulfilledOutOfWindowIsNotRetired`,
`TranscriptDisplayPolicyTest.delayedCanonicalRowFulfillsTerminalAcceptedEchoAndPermitsCleanup`
(windowed retire still happens — the #273 cleanup is preserved)

**History:** #215 → #273 (`terminalAcceptedEchoIds`) + #290 (out-of-window
fulfilment) composed into the one-shot → this fix.

**Rejected:**
- *Persisting `admittedCanonical` rows in per-chat state.* More lifecycle to
  invalidate on session begin/end/erase; the echo already IS that state.
- *Dropping the hard `clearSendEcho` calls entirely (plan-only retire).* An
  echo whose canonical row never re-enters the newest window (30+ newer rows
  arrive while the chat is closed) would ghost as "Sending" forever; the hard
  clear stays for the not-on-screen case where nothing visible can be erased.

**Not guarded:** The real `withSendEchoes` / `clearSendEcho` call sites — both
need a constructible `SonarAppState` (the standing gap below). The sequence test
drives the documented `withSendEchoes` contract, not the member itself; a future
edit to `withSendEchoes` that diverges from that contract (e.g. reordering the
retire before the render-list build) would not be caught.

**Sticker echoes:** covered by the same lifecycle. A sticker echo and its
canonical row both carry empty content plus the sticker ref (`privateDmMessage`
parses the marker, mirroring iOS `sendSticker`), so
`eligibleCanonicalRowsForSendEcho` compares `stickerRef` in addition to content
— without it, an own media row or a *different* sticker (both empty-content)
could falsely consume a sticker echo. `sendStickerItem`'s clear uses the same
publish gate as the text send.

**Known un-gated clears (residual, pre-existing):** `retrySendEcho`'s Marmot
path and the pending-chat flush paths (`flushPendingDirectMarmot`,
`flushPendingMarmotGroupSends`) still hard-clear on success without the publish
gate; a retry/first-send whose canonical row lands out-of-window can drop until
the newest-edge reload. Same shape, separate call sites — gate them the same
way when touched.


## R-027 — Return must commit an open IME composition before it sends

**Invariant:** On macOS the composer claims bare Return to send. It must only do
so when no IME composition is open. While text is marked (uncommitted), Return
belongs to the text system: it commits the composition, and the *next* Return
sends.

**Breaks as:** the sent message is missing its last character(s), and so is the
composer — the text simply vanishes. It reads as "the message I sent got cut",
with no error and nothing to retry.

**Why:** `.onKeyPress(keys: [.return])` runs during AppKit key dispatch, ahead of
the text system, and returning `.handled` consumes the event. If marked text is
pending, nothing ever commits it: the composition is discarded. This is not the
R-026 race — Apple reads the draft from the store at send time and has no stale
capture — it is data that never reached the store at all.

**Who hits it:** anyone whose input goes through a composition — dead-key accents
(`option+e`, `e` → `é`), press-and-hold accent menus, macOS inline predictive
text, and every CJK IME. Latin-alphabet ASCII typing never composes, which is why
this hid for so long and why an ASCII-only reproduction shows nothing.

**Call sites:** Apple `SNMessageComposerField` (macOS branch only — iOS has no
Return handler; the send button owns sending). Compose is unaffected: its desktop
Enter path does not consume keys ahead of an IME commit, and Android Return is a
newline.

**Guarded by:** `SNComposerReturnMarkedTextTests.bareReturnSendsWhenNothingIsComposing`, `SNComposerReturnMarkedTextTests.returnDuringCompositionDoesNotSend`, `SNComposerReturnMarkedTextTests.modifiedReturnNeverSends`

**Coverage (honest):** the tests pin the pure predicate
`snReturnSendsComposerDraft`, not the wiring — nothing asserts that the call site
actually asks `NSTextView.hasMarkedText()`, and iOS/macOS tests do not run in CI
at all. The behaviour was verified by hand instead, in an isolated SwiftUI app
reproducing the composer (store → `Binding` → `TextField(axis: .vertical)` →
`.onKeyPress`): the same keystrokes gave `read=5 "perch"` before the fix and
`read=6 "perch´"` after. That reproduction is the evidence; the unit tests only
stop the predicate from being rewritten.

**Rejected:**
- *Deferring the send by a runloop turn* (`Task { onSend() }`) so the commit
  lands first. It would paper over this case, but Return would still be consumed,
  so a composition that needs a second key (CJK candidate selection) would still
  lose it — and it adds a reorder hazard to every send.
- *Reading the field's text at commit time instead.* Nothing to read: the marked
  character never reaches the binding, so no amount of care on the read side
  recovers it.
- *Blaming the SwiftUI binding flush.* Measured and ruled out first: with ASCII
  input the binding was complete at Return in every trial, including with the
  main thread blocked 120 ms per keystroke. The composition state was the
  difference, not timing.

## R-028 — The wake-window store close must be reachable, not merely scheduled

**Invariant:** A Marmot push wake must be able to *start* `closeNode()` inside
the iOS background window no matter where its drain is. The close cannot be the
last statement of the drain, because the drain contains calls that no Swift
deadline can interrupt.

**Breaks as:** `RUNNINGBOARD 0xdead10cc`, round 5 — TestFlight **1.12.5 (33)**,
the build shipping R-020. Killed **51s** into a background launch (`Role:
unknown`, launch 00:55:21 → kill 00:56:13). Distinguishing feature versus rounds
1-4: three node-touching threads were live at kill — `call_wait_event` under a
`leasedNodeOperation`, `sync_once`, and `register_push_token` — and the latter
two were parked in **`block_on_suspendable`, un-aborted**. That is the whole
diagnosis: R-016's latch aborts exactly those two calls, so their still being
parked proves `interruptNodeForSuspend()` never ran, i.e. `closeNode()` was
never called at all in those 51 seconds. Rounds 1-3 asked what *blocks* the
close and round 4 asked what *reopens* the store; this one is the close never
being *reached*.

**Why:** the close sat below the drain in `processMarmotWakeup`, and the drain
could outlast the window on its own arithmetic. One first pass cost, against a
`marmotWakeWindowSeconds` of **28**:

| step | cost |
| --- | --- |
| NSE flock yield | 2.5s, charged to nothing |
| `ensureConnected()` | up to 10s (its own default, unbudgeted) |
| `withTimeout(marmotPushSyncTimeoutSeconds) { refresh() }` | 25s |

2.5 + 10 + 25 = **37.5s of a 28s window**, before `notifyDrained` / name
resolution and before the `guard applicationState == .background` and
`closeStoreWithDeadline` below it. The close was not late; it was unreachable.
Only the rerun branch was wrapped in an outer deadline — the first pass, the one
every wake runs, had no ceiling at all.

**The deadline that was already there does not bound Rust.** `withTimeout` is
built on `withThrowingTaskGroup`, which awaits its children before it can
rethrow. This file's own `closeStoreWithDeadline` doc comment says so. So when
`refresh()` parks in a blocking `sync_once`, the 25s "timeout" expires and then
waits for the park anyway. The *only* thing in the process that can end that
park is `closeNode()` → `interruptNodeForSuspend()`, which runs off-queue — the
very call the drain was standing in front of.

**Fix shape:** arm the close on a **timer**, not on the drain finishing. A
detached task sleeps the window and then closes if the app is still
`.background` (the same gate the in-line close uses), so the FFI abort is
reachable from anywhere in the drain. The drain then fails out through its
normal error paths and the push syncs on the next wake/foreground — the outcome
a rerun that overruns its budget already produces. Secondarily, budget the pass
close-first: `SonarWakeBudgetPolicy.passBudget` reserves
`closeReserveSeconds` and charges the yield and the connect against the same
budget as the sync, so the common case closes on its own and never needs the
timer.

**The timer must not resurrect R-020 — and the first attempt did.** A rerun
re-enters `runMarmotWakeup`, which begins with `ensureConnected()`, so any rerun
admitted after the closer has fired reopens the store while still backgrounded.
There are **two** rerun loops, and review only caught this by checking both:

- the *outer* `while keepDraining` loop, which always had a remaining-window
  gate, and
- the *inner* `repeat { … } while marmotWakeNeedsRerun`, which had **none** and
  also reused the first pass's budget.

The inner loop was harmless before the deadline closer existed — the store
stayed open for the whole wake, so its `ensureConnected()` was a no-op. Adding a
close that can fire *underneath* the drain turned it into a live reopen path.
Both loops now share one gate and re-budget per pass.

`rerunMinSeconds` is likewise **derived, not tuned**: `closeReserveSeconds +
minPassSeconds`. Setting it to `closeReserveSeconds` alone admitted a band
(`remaining` in `(8, 11]`) where `passBudget`'s `minPassSeconds` clamp inflated
a 1s slot back to 3s and the pass then ate 2s of the close's reserve.

**The closer fires at `windowSeconds - closeReserveSeconds`, not at the window
edge.** The close is not instant, so arming it at the edge would have it *start*
when iOS is already entitled to suspend us — the same kill, a few seconds later.

**Call sites:** iOS `SonarPushProcessor.processMarmotWakeup` /
`runMarmotWakeup`, budgeting in `SonarWakeBudgetPolicy`. **Not applicable to
Compose:** Android/RunningBoard has no file-lock kill, and the Compose Marmot
wake runs under a foreground service rather than a fixed ~30s window, so there
is no deadline to budget against and no flock to release before suspension.
Deliberate platform asymmetry, not a missing mirror.

**Guarded by:** `SonarWakeBudgetPolicyTests.fullWindowPassLeavesCloseReserve`, `SonarWakeBudgetPolicyTests.syncTimeoutCannotEatCloseReserve`, `SonarWakeBudgetPolicyTests.rerunRefusedWhenOnlyCloseReserveRemains`, `SonarWakeBudgetPolicyTests.admittedRerunAlwaysLeavesCloseReserve`, `SonarWakeBudgetPolicyTests.deadlineCloserFiresWithReserveLeft`

**Coverage (honest):** the tests pin the **arithmetic only** — that a pass can
never claim the close's reserve, that raising the shared
`marmotPushSyncTimeoutSeconds` cannot push the close back out of the window, and
that the rerun gate shuts before the deadline closer fires. That is genuinely
the half that regressed (a constant mismatch), and it is the half that will
regress again when someone retunes a timeout.

**The watchdog reports itself instead.** Since no test can reach it, it emits
`WAKECLOSER armed` / `fired` / `close returned` / `stood down` /
`skipped` through `SecureLogger` (category `.session`) — deliberately NOT this
file's `os.Logger`, because only the `SecureLogger` sink is packaged into the
shareable bundle by `SonarDiagnostics`. That makes the untestable half
observable in the field. Exactly one terminal marker follows each `armed`,
because every path through the closer settles the same latch — an earlier draft
let `skipped` fall through and emit `stood down` too, which read as a
contradiction. In a user's Settings → Diagnostics → Share capture:

| terminal marker | meaning |
| --- | --- |
| *(none)* | the wake never returned and the timer never ran — a different bug from this one |
| `fired` → `close returned` | the drain overran and the close was forced: R-028 working |
| `stood down` | the drain finished inside the window; the in-band close did the work |
| `skipped` | the app left `.background`; the foreground path owns the node |
| `cancelled …` | the wake finished as the closer was waking; benign |

The closer's sleep is anchored to `wakeStart`, not to when the detached task
starts running, so `fired` genuinely means "the deadline measured from the same
origin as every other budget here". Read these before theorising about a future
round.

Nothing tests the **watchdog itself**, which is the half that actually fixes the
crash. `SonarPushProcessor` is `@MainActor`, takes a live `MarmotChatModel`, and
the failure only exists against a real blocking FFI park — no unit test
constructs it, and iOS tests do not run in CI regardless
([[ios-not-built-in-ci]]). This is an R-001-shaped hole and is recorded as one:
deleting the `wakeDeadlineCloser` task leaves every test green. Real
verification is a TestFlight build backgrounded through a push wake with relays
slow or unreachable.

**Rejected:**
- *Making `call_wait_event` suspendable in Rust like R-016 did for sync.* This
  is the obvious read of the log — `callWaitEvent` is the thread holding a
  lease — and it is wrong for the second time (R-020 rejected it too). The Swift
  wrapper already slices into **1s** FFI parks, so it cannot hold the close. It
  is present in the log as *evidence the node was open*, not as a cause. Check a
  wrapper's slicing before concluding an FFI park is long.
- *Lowering `marmotPushSyncTimeoutSeconds` to fit the window.* It is shared with
  foreground sync, where 25s is correct; scoping the wake's budget locally keeps
  one constant from serving two deadlines.
- *Bounding the first pass with another `withTimeout`, matching the rerun.* The
  symmetry is appealing and it is what the rerun branch already does, but it
  fixes nothing on the path that crashed: a task-group deadline cannot end a
  park in uncancellable Rust. It would have shipped a no-op with a plausible
  diff. The budget changes here are for tidiness of the common case; the timer
  is the fix.
- *Releasing the flock ahead of the node to buy time.* Already rejected in
  `closeStoreAfterBackgroundWake` and still wrong: the NSE opens its own
  `SonarNode` the moment it wins the flock, and two processes committing against
  one MLS store can fork group state. A background kill is better than a
  corrupted store.
- *Suppressing the drain's own close once the deadline closer has fired.* The
  two can both run — the closer aborts the parked FFI, the drain unwinds, and
  its post-loop close then runs against an already-closed node. Traced and left
  alone: `closeNode()` is idempotent, the `workQueue` is serial so the two hops
  cannot interleave destructively, and a node installed by a foreground resume
  between them is not killed (the second call's queue hop was enqueued before
  that install). The cost is one redundant background-task begin/end; shared
  state to dedupe it would buy nothing and add a lifetime to reason about.
- *Deriving the window from `UIApplication.backgroundTimeRemaining`* instead of
  a constant, the way `AutoBackupBackgroundScheduler` does. It reports
  `.greatestFiniteMagnitude` until a background task is active, which is exactly
  the situation during `didReceiveRemoteNotification`, so it would read as
  "unlimited" precisely when the budget matters.
## R-029 — Send the draft the field holds, not the one the view graph remembers

**Invariant:** on macOS, the text a send puts on the wire comes from the field
editor whenever there is one — `snLiveComposerDraft` is `fieldEditor ?? binding`,
so the binding is the *fallback*, not the source. A `@Binding` read inside the
composer view is a mirror, and nothing guarantees it is current when a send
fires. The resolved text is then **passed** to the send callback, so no caller
re-reads its own binding. This is a macOS rule: iOS has no AppKit field editor,
so the resolver there is the binding — see the iOS gap under Coverage.

**Breaks as:** type, press Return, and the message that goes out is a *prefix* of
what was typed — usually **exactly the first character**. The composer clears as
if everything was sent. No error, nothing to retry. Reported (again) as "the text
gets cut when I type fast and press enter".

Note "fast" understates it: measured at 50 ms/keystroke — ordinary typing, each
key in its own runloop turn — `testing` sent as `t` and `abcdefg` as `a`. Bursts
and paced typing both truncate; the burst is merely the easiest to reproduce.

**Why:** a `@Binding` read inside a SwiftUI view is served from the view graph
and only refreshes when that view re-renders. `SonarAppStore.composerDrafts` is
deliberately **not** `@Published` — publishing per keystroke would re-enter the
UIKit transcript host while typing — so typing invalidates nothing and the
composer does not re-render. Meanwhile SwiftUI's macOS `TextField` is backed by
an `NSTextView` whose storage advances on every keystroke. The two diverge for
as long as no unrelated publish happens to re-render the composer, and `.onKeyPress`
then sends whatever prefix the graph last saw. The usual last refresh is the
`composerDraftHasText` boundary publish on the *first* character — which is
exactly why the truncation so often lands at one character.

This is **not** R-027. R-027 was data that never reached the store (an IME
composition discarded by a consumed Return); this is data that reached the store
fine and was not read. R-027's own notes ruled out "the binding lags" — correctly
for that bug, and only for ASCII in an isolated app whose store *was* published.

If you are about to re-derive this as "the store had not caught up with the
`NSTextView`": it had. The harness samples all three at the same instant and the
store tracked the field editor exactly — `binding="t"(1) store="testing"(7)
editor="testing"(7)`, 7/7 samples. Reading `composerDraft(for:)` or the binding
again is therefore not a fix; only the read site was wrong. (A review panel
proposed exactly this and was refuted by that column.)

**Call sites:** Apple — `SNMessageComposerField.commitAndSend` (Return and
`onSubmit`), which now hands the resolved text to `onSend`, plus every caller of
that callback: `SNComposer.send` (whose send button reads `liveDraft`),
`MarmotChatView`, `ContentView.sendMessage`. Only `SNComposer` is on a live
screen: `SonarRootView` is the app's only scene, `ContentView` is instantiated
nowhere, and `MarmotConversationView` is reachable only from `MarmotChatView`.
Their Return paths take the resolved text like everyone else; their *send
buttons* still read their own bindings, which is a real but dormant instance of
this bug — mirror `SNComposer.liveDraft` there if either view is ever revived.
Compose is **structurally immune**,
not merely unaffected: `composerDrafts` is a `mutableStateMapOf` and
`BasicTextField(value:onValueChange:)` renders that state directly, so the field
cannot display text the state does not hold. Do not "optimise" that into an
unpublished draft map without re-reading this entry.

**Guarded by:** `SNComposerLiveDraftTests.fieldEditorWinsOverAStaleBinding`, `SNComposerLiveDraftTests.anEmptyFieldEditorIsNotAMissingOne`, `SNComposerLiveDraftTests.bindingIsUsedWhenThereIsNoFieldEditor`

**Coverage (honest):** the tests pin the pure resolver `snLiveComposerDraft`,
not the wiring — nothing asserts that the call sites actually consult the field
editor rather than their binding, and iOS/macOS tests do not run in CI at all.
That is the R-001 shape, so the hazard was reduced structurally instead: `onSend`
now *takes* the text, so a caller cannot silently keep reading its own stale
binding. The behaviour was measured in a harness reproducing the exact wiring
(unpublished store → closure `Binding` → `TextField(axis: .vertical)` →
`.onKeyPress`), driven by `NSApp.postEvent`: before, **7/7** sends truncated —
0 characters under a burst, and the **first character only** at 50 ms/keystroke
— while store and field editor both held the full word; after, 6/6 sends matched
the field across both regimes. The send-button path was driven separately with a
posted mouse click: the field editor stayed first responder through the click in
4/4 trials (`focused=true`, editor readable), so `liveDraft` resolves from the
editor there rather than falling back.

**The iOS gap.** The whole mechanism is AppKit: `snFocusedFieldEditorText()` is
`#if os(macOS)`, and `SNComposer.liveDraft` returns the plain binding on iOS. If
UIKit's `TextField` backing store can run ahead of the binding the same way, iOS
sends are exposed and nothing here would catch it. It has not been reproduced or
ruled out — iOS sends via a button tap, and the press itself re-renders the
composer, which is probably why no iOS report exists. Untested either way; do not
read this entry as covering iOS.

What is **not** pinned: the `NSApp.keyWindow?.firstResponder as? NSTextView`
lookup itself, and the focus gate on `SNComposer.liveDraft`.

**Rejected:**
- *Publishing `composerDrafts`.* Fixes the staleness at the source and is what
  Compose does, but it re-enters `updateUIViewController` → `applySnapshot` on
  every keystroke — the exact cost the unpublished map exists to avoid, and a
  Signal-Comparable Performance Rule violation.
- *Reading the field editor and leaving `onSend: () -> Void` alone.* Writing the
  live text back through the binding does not refresh the *caller's* binding
  either — `SNComposer.send()` would still read its own stale copy. The text has
  to be passed, not just committed.
- *Deferring the send a runloop turn so the binding catches up.* Same objection
  R-027 raised: it reorders every send to paper over a read bug.
- *Trusting the field editor unconditionally in `SNComposer.liveDraft`.* The send
  button can be clicked while another text view (the sidebar search) is first
  responder, which would send that field's text. Gated on `composerFocused`. The
  gate does not cost anything on the normal path: a posted-click harness showed
  the composer keeps focus and first responder through the click (4/4), so the
  editor is still the one consulted.

## R-030 — A conversation's transcript reads every bucket its chat row reads

**Invariant:** the mesh transcript source resolves `ChatViewModel.privateChats`
through the same universe of keys the chat-list row folds — identity aliases
**plus** the 64-hex shapes (fingerprint, raw Noise public key) that
`canonicalPeerKey` maps back onto those aliases. A row visible in a chat-list
preview must be reachable by that chat's transcript.

**Breaks as:** the chat list shows a message the open transcript does not have.
It is not a refresh lag — the bucket is what gets persisted, so the divergence
survives restarts. Reported as "the Sara chat is not in sync with the transcript".

**Why:** an incoming NIP-17 internet DM is stored under the sender's **Noise
public key hex** (`ChatViewModel+Nostr.processNostrMessage` →
`PeerID(str: noiseKey.hexEncodedString())`), and is mirrored onto the 16-hex
short id only while `unifiedPeerService` holds a live entry
(`mirrorToEphemeralIfNeeded`). Out of BLE range there is no mirror. Every
identity resolver canonicalises to the short id, so the transcript never named
that bucket; `dmRows` did, because it folds *every* bucket through
`canonicalPeerKey`. The two 64-hex shapes are the trap — the fingerprint is
`sha256(noise key)` and the short id is its first 16 hex, so a raw Noise key
shares no **string prefix** with either, and only reduces to the alias by
hashing (`canonicalPeerKey`'s `PeerID(publicKey:)` branch). Prefix-shortening a
64-hex key — what `canonicalStoredKey` does — silently misses it. See
`docs/CHAT-TYPES.md`, id shape 6.

**Call sites:** iOS `SonarAppStore.meshPrivateChatKeys(forConversationId:)` →
`snMeshNoiseKeyBuckets` / `snMeshPrivateChatKeys` / `snMergeMeshPrivateChats`,
feeding `meshPrivateMessages` and `meshPrivateMessageCount`. Compose does not
apply: `SonarAppState.drainDirectDms` keys incoming direct DMs by
`peerIdForNpubHex(...)` into `meshChats`, so no Noise-key bucket exists there.

**Guarded by:** `SonarConversationFoldTests.outOfRangeInternetDmBucketIsPartOfTheTranscript`

**Also guarded by:** `SonarConversationFoldTests.fingerprintShapedBucketAlsoResolves`,
`SonarConversationFoldTests.anotherPeersNoiseKeyNeverJoinsTheTranscript`,
`SonarConversationFoldTests.aliasBucketWinsOverAStalerMirroredCopy`,
`SonarConversationFoldTests.mirroredRowIsNotRenderedTwice`,
`SonarConversationFoldTests.nonHexAndAliasShapedBucketsAreNotDuplicated`,
`SonarConversationFoldTests.receivedInternetRowOverridesTheConversationTransport`

**Not guarded:** that `meshPrivateChatKeys` is what `dmMsgs` actually calls, and
that `meshPeerAliases` yields the short id the buckets derive to — both need a
constructible `SonarAppStore` (the standing gap below). The hazard is reduced
instead: `meshPrivateMessages`/`meshPrivateMessageCount` have no `privateChats`
access of their own, so the key set is the only way in. Validated against a live
store at fix time — 146 rows across 6 conversations were unreachable.

**Rejected:**
- *Deriving the extra bucket from `FavoritesPersistenceService`* (the map
  `findNoiseKey(for:)` uses to choose the storage key). Shipped first, then
  replaced: the favorite can be removed after the rows land, and the bucket
  cannot — an unfavourite would have hidden the transcript again. Matching the
  store's own keys needs no cache and no invalidation hook.
- *Re-keying `privateChats` at write time instead.* The 64-hex key is load-bearing
  on the mesh side: it is what says "no live Noise session", and read receipts,
  `startPrivateChat` and session routing all key off it.
- *Last-write-wins dedup.* Several send paths (`sendPrivateMessage` → `.sent`,
  its failure branches) update delivery status on ONE bucket, so a mirrored copy
  can be staler. Merge is first-key-wins with aliases ordered first.

---

## R-031 — A connect in flight at suspension must be abortable, not merely awaited

**Invariant:** every path that can hold the SQLCipher store open must be
reachable by the suspend hook — including the one that *opens* it.
`SonarNode.connect` is handed a host-owned `SonarSuspendLatch`, created and
registered **before** the constructor runs, so `interruptNodeForSuspend()` can
abort a connect that has no node yet. And the connect's lifecycle lease spans
its whole store-holding window — from before the App Group flock to after the
node is installed or the flock abandoned — so `closeNode()` never returns while
this connect still holds something.

**Breaks as:** `RUNNINGBOARD 0xdead10cc`, round 6 — TestFlight **1.12.3 (31)**,
killed **91s** after launch. Distinguishing feature versus rounds 1-5: exactly
one thread was touching the node, and it was in `MarmotService.connectNode` →
`SonarNode::connect` → `SonarClient::connect`, parked in a bare
`runtime.block_on` — *not* `block_on_suspendable`. No lease loop, no `sync_once`,
no `register_push_token`, and no drain to overrun a window. There was no node at
all. The reporter's other symptom is the same fault seen from the UI: a connect
that never completes opens no relay subscriptions, so a radar scan finds nobody
over nostr ("the scan turned up no one either via bluetooth or nostr, and then
crashed").

**Why:** `SonarClient::connect` opens SQLCipher **first**
(`MarmotEngine::persistent`) and only then awaits — the relay quorum wait, then
`subscribe_marmot()` and `retry_outbox()` at the end of `with_engine`. Those last
two are on R-016's *suspendable* list as standalone FFI methods, precisely
because they park; inside the constructor they park with the store open and
nothing to latch, because `SonarNode` — which owns the latch — is the value
`connect` has not returned yet. `interruptNodeForSuspend()` reads `node`, sees
nil, and no-ops. `closeNode()` then does the only thing left: parks on
`nodeLifecycleGroup.notify` waiting for the connect's lease, the
`beginBackgroundTask` grace expires, RunningBoard collects us.

**This is the mirror image of round 3.** R-016 asked "which calls can park the
close?" and answered with a list of methods *on a node*. The question it did not
ask is what holds the store before there is a node to enumerate methods on. The
latch therefore had to move out of `SonarNode` into its own object the host can
hold first; `SonarNode` keeps the one it was passed, so `interrupt_for_suspend()`
and a mid-connect latch are one object and one code path rather than two
mechanisms that must agree.

**Extending the lease is part of the fix, not tidying.** The lease used to be
created inside `connectNode` and released in *its* error path, while the store
lock was abandoned one frame later in `connect()`'s `catch`. So a failing connect
could release the lease — letting `closeNode()` return and `endBackgroundTask()`
fire — with the App Group flock still held: the same kill by a narrower margin.
That window was theoretical while connects failed rarely and never at a
correlated moment. Latching them makes "connect fails exactly as we suspend" the
**common** case, so the fix would have manufactured its own next round.

**Two ordering rules the review pass extracted, both load-bearing.** The first
draft of this fix got each wrong, and each failure mode is a fresh instance of
the crash it fixes:

1. *The pending-latch registry is a list, not one optional.* `connect()` has no
   single-flight guard of its own — it depends on `relayBusy` in
   `MarmotChatView.connectRelaysIfNeeded`, a flag in another file that no test
   pins (the R-001 shape). With a single slot, a second connect registering
   orphans the first connect's latch while its `SonarNode.connect` still holds
   SQLCipher open, and nothing can ever reach that orphan again. Holding every
   in-flight latch keeps the invariant inside `MarmotService` rather than
   resting on a caller's flag.
2. *Register the latch BEFORE acquiring the store lock.*
   `registerPendingConnectLatch()` throws `.cancelled` when a close has fenced
   us, and the `catch` that calls `abandonStoreLockHold` sits below it. Taking
   the flock first leaks it on exactly that throw — and a held App Group flock
   with no open handle is its own 0xdead10cc ingredient, since RunningBoard
   kills for the *lock*, not for the handle.

**Why an install can never carry an already-fired latch** — the obvious next
worry, and it is closed by construction rather than by timing.
`interruptNodeForSuspend()` sets `nodeClosing` and snapshots the latch list in
**one** `nodeLock` hold, and the install checks `nodeClosing` under that same
lock before assigning `service.node`. So either the latch fired first and the
install bails (the node is dropped, closing its handle), or the install won and
the node is reached by the ordinary `liveNode?.interruptForSuspend()` line. The
`nodeClosing` clear that would reopen the gap cannot overtake the install
either: it lives below `closeNode`'s `nodeLifecycleGroup.notify`, and the
connect holds its lease until after the install.

**What the latch cannot do, stated honestly:** a dropped future stops at an
*await* point, so the abort covers the relay quorum wait, `subscribe_marmot` and
`retry_outbox` — the unbounded, network-shaped part, and the part the crash log
shows. It does **not** cover the synchronous prologue: the SQLCipher open, MDK
migrations, and `materialize_index_if_empty()`. Those have no await points, and
no Swift-side deadline can bound them either (R-028 established that
`withTimeout` cannot interrupt Rust). If a future round shows a thread inside
`MarmotEngine::persistent` rather than in a relay wait, this entry does not cover
it and the answer is to make that work interruptible in Rust, not to add another
timer.

`connectLocal` is deliberately **not** latched, and the reason is a trade, not
that a latch is useless there. Be precise about what it would buy, because an
earlier draft of this entry overclaimed and a review caught it: with no relays
there is no quorum wait and `subscribe_marmot` / `retry_outbox` return
immediately against an empty pool, so a latch could never *abort* anything on
that path — everything it holds the store for is synchronous. What a latch would
still buy is the `biased` select's **pre-check**: a refusal to open SQLCipher at
all, at a checkpoint later than `connectLocal`'s own opening
`guard !service.nodeClosing`. The gap between the two is real, mostly the
blocking flock in `prepareStoreLockForConnectSync()`.

It is declined anyway because the refusal is the expensive part.
`suspendStoreForBackground()` fires unconditionally on background — it is not
gated on a restore in progress — so a suspend landing in that window fails
`performConnect()`, and `restoreIdentity`'s `guard await performConnect() else`
rolls back through `wipeDatabase()`. That branch does protect the account key (a
`.restored` outcome throws before the wipe; a first-time import never deletes its
nsec), so this was never account loss. But widening a wipe path to fix a crash on
a different path is the wrong trade, and the Account Key Durability Rule makes it
a blocking one to get wrong. Note the trade is not latch-specific: a plain
`nodeClosing` re-check placed there would fail `performConnect()` identically.

**The residual hole this leaves, named rather than waved away:** a background
transition landing after `connectLocal`'s guard still opens the store, and the
close then queues behind that whole synchronous span on `workQueue`. It is
bounded by local disk work (SQLCipher open, MDK migrations, and
`materialize_index_if_empty` on a first run after upgrade) rather than by an
unbounded network wait, which is why it is out of scope here and why the crash
log shows the relay path. It is **pre-existing** — this is exactly the state
`main` is in — and closing it needs the synchronous prologue to become
interruptible in Rust, not another Swift checkpoint.

**Call sites:** iOS `MarmotService.connect` (lease + latch registration),
`MarmotService.pendingConnectLatches` / `registerPendingConnectLatch` /
`clearPendingConnectLatch` (the registry),
`MarmotService.connectNode`,
`MarmotService.interruptNodeForSuspend` (the flip), and the `closeNode` /
`wipeDatabase` hops (belt-and-braces flip); core
`SonarNode::connect` / `SonarSuspendLatch` in `core/sonar-ffi/src/lib.rs`.
`NotificationService.swift` passes `nil` deliberately — the NSE is a separate
process with no scene-phase hook, bounded by
`serviceExtensionTimeWillExpire` instead. **Not applicable to Compose**, for the
same reason as R-016/R-020/R-028: no RunningBoard file-lock kill and no fixed
suspend deadline. Android and desktop pass `null` at all three
`SonarNode.connect` sites in `SonarCore.android.kt` / `SonarCore.jvm.kt`, each
annotated so the asymmetry is visible from the call site rather than only here.

**Guarded by:** `sonar_ffi::tests::prelatched_connect_aborts_without_opening_the_store`, `sonar_ffi::tests::latch_aborts_in_flight_connect`

**Coverage (honest):** unusually good for a 0xdead10cc entry — the mechanism is
in Rust, so it is testable, and both tests fail against the pre-fix constructor
with `unexpected error: no relay connected within timeout` rather than by timing
out (verified, not assumed). `latch_aborts_in_flight_connect` pins the real
crash shape: the store is open, the connect is parked in a relay wait against an
unroutable address, and only the latch can end it.

**Not guarded — and it is the Swift half, again.** Nothing pins that
`interruptNodeForSuspend()` flips `pendingConnectLatch`, that `connect()`
registers one before taking the store lock, or that the lease outlives
`abandonStoreLockHold`. Deleting any of the three leaves both Rust tests green,
because they call the FFI directly. That is the R-001 shape and it is recorded as
one: `MarmotService` is a singleton over live FFI, no iOS test constructs it, and
iOS tests do not run in CI regardless ([[ios-not-built-in-ci]]). Real
verification is a TestFlight build backgrounded during a cold relay connect with
relays slow or unreachable — the `SecureLogger` line the connect abort produces
(`connect interrupted for suspend`, category `.session`) is visible in a
Settings → Diagnostics → Share capture.

**History:** #446 (round 1) -> #448 (round 2) -> #449 / R-016 (round 3) ->
R-020 (round 4, reopen after close) -> #538 / R-028 (round 5, close never
reached) -> build 31 crash (round 6: nothing to close *yet*) -> this fix.

**Rejected:**
- *Bounding the connect from Swift with `withTimeout` / a deadline task.* R-028
  already established that `withThrowingTaskGroup` awaits its children, so the
  deadline expires and then waits for the Rust park anyway. The only thing that
  can end a `block_on` is dropping the future inside it.
- *Closing the store from the close side by releasing the flock without the
  handle.* `closeStoreAfterBackgroundWake()` states the contract: never unlock
  under an open handle, or the NSE opens the same store and two processes commit
  against one MLS state. Trading a background kill for a forked group is worse.
- *Deferring the SQLCipher open until after the relay quorum,* so the parked
  window holds no file. It inverts the local-first ordering the whole Signal
  Comparable Performance Rule depends on — the store open is what makes first
  paint possible before the network — and it would leave `retry_outbox`, which
  needs the store, holding it anyway.
- *Making `connect` non-blocking at the FFI boundary* (return a handle, poll it).
  A larger change with the same reachability problem: something still owns an
  open store between "started" and "installed", and every host would need
  rewriting for a crash that only one host can suffer.

## R-032 — An empty profile fetch must never license a from-scratch kind-0 republish

**Invariant:** kind-0 is replaceable: whoever publishes last owns the whole
event. Sonar manages only `name`/`display_name` (plus `nip05` for a claimed
handle), so every publish merges over the current relay profile, which stays
authoritative whenever present. When the publish-time fetch comes back empty,
the persisted own-profile cache is the merge floor; when the fetch is empty
and the cache exists but is *unreadable*, the publish is skipped outright —
only a fetch-empty + cache-*missing* combination (a genuinely fresh device)
licenses publishing from scratch. A merge result identical to the relay copy
is not sent at all, and publishes are serialized so no two interleave their
fetch/merge/store steps.

**Breaks as:** the user sets a picture/bio in Damus/Primal/Amethyst; some time
later their profile is bare again everywhere — name and Sonar handle only.
No error anywhere: the app that did it was "successfully publishing its
profile".

**Why (twice):** the first wipe was the blind publish fixed by fetch-and-merge
in #390. The second is the hole #390 left: `fetch_metadata` returning no event
is ambiguous — a genuinely fresh key and a flaky network that missed the relay
holding the profile look identical — and the merge treated both as "publish
from scratch". The odds looked small per publish, but the connect path
republished kind-0 on every relay attach (~26 identical events observed in one
day from one device), so the bad roll was a matter of time; once one bare event
lands with the newest `created_at`, it propagates to every relay and all later
merges faithfully preserve the bare state. The fix adds the
`sonar.db.sonar-profile.json` sidecar as a merge floor for the empty-fetch
case, and skips the send entirely when the merge equals the relay copy (which
also removes the churn that multiplied the exposure).

**Who hits it:** anyone using the same nsec in Sonar and any other Nostr
client, on any platform — the publish path lives in `sonar-core`, so Android,
iOS, and desktop all had it.

**Call sites:** one shared implementation:
`core/sonar-core/src/client.rs` `publish_profile` /
`publish_profile_background` (`resolve_profile_publish` is the decision).
Compose reaches it via `SonarCore.publishProfile` (connect-path
`completeRelayStartup`, `updateNickname`, `claimHandle` in `SonarAppState.kt`);
Apple via `publishProfile`/`publishProfileBackground`
(`SonarAppStore.swift`, `MarmotChatView.swift`). No per-platform variant
exists, deliberately.

**Guarded by:** `client.rs::empty_fetch_falls_back_to_cached_profile`, `client.rs::unchanged_profile_skips_republish`, `client.rs::cache_never_resurrects_fields_deleted_remotely`, `client.rs::fresh_key_with_no_cache_publishes`, `client.rs::empty_fetch_with_unreadable_cache_skips_publish`, `client.rs::unreadable_cache_with_present_remote_still_publishes`, `own_profile.rs::sidecar_round_trip_and_wipe`, `own_profile.rs::corrupt_sidecar_reads_as_unreadable_not_missing`, `e2e.rs::profile_republish_against_empty_relay_keeps_sidecar_fields`

**Coverage (honest):** the unit tests pin the pure decision
(`resolve_profile_publish`) and the sidecar round-trip; the e2e test pins the
foreground wiring against a real relay — publish rich, reopen the same DB
against an *empty* relay, rename, and assert the republished event still
carries picture/about (this is the R-001 call-site shape the unit tests
cannot see). Still unasserted: the background path's wiring (same code shape,
no test drives `publish_profile_background` through the sidecar),
`created_at` stability on skip, and the publish lock's serialization (the
lock is trivially correct by construction, but nothing would fail if it were
removed).

**Rejected:**
- *Always merging the cache over the fetched profile.* Resurrects fields the
  user deliberately deleted through another client. The cache is a floor only
  when the fetch saw nothing; a present relay copy stays authoritative.
- *Treating an empty fetch as an error and never publishing.* Bricks
  first-publish for genuinely fresh keys, and blocks the self-heal republish
  when relays really did lose the event. The cache distinguishes the two.
- *Fixing only the churn (skip-if-unchanged) without the cache.* Shrinks the
  exposure but the wipe stays one bad fetch away; the first empty fetch after
  a nickname edit still strips the profile.

## R-033 — Auto-backup spends the user's data plan only for bytes that changed

**Invariant:** an automatic account backup may not run on a metered link unless
the user opted in, and may not re-upload an account whose plaintext fingerprint
still matches the last successful upload *within the refresh window* (the user's
own cadence, capped at a week — it deliberately does re-upload identical bytes
at that boundary). Only messages **this device produced** may shorten the backup
cadence; received history rides the daily floor. Skipping is never a failure,
and "wait for Wi-Fi" is never allowed to become "never back up".

**Breaks as:** iOS Settings → Mobile Data showing **Sonar 66.3 GB** in one
billing period — 20× the next-heaviest app on the same phone (Instagram, 3.35
GB), with 81.9 of the device's 82.4 GB roaming. That works out to ~2.2 GB/day
sustained, which no amount of chat text explains; it is a large payload on a
schedule.

**Why:** four mechanisms multiplied.

1. *Every upload is a full snapshot.* `seal_account_backup_files` reads the
   whole SQLCipher DB **plus** the conversation index and PUTs the sealed blob
   (cap 200 MiB). There is no delta format.
2. *Nothing on the server can dedupe it.* `seal_account_backup` draws a fresh
   random nonce per run, so an unchanged account produces different ciphertext
   and a different sha256 every time. Blossom is content-addressed and still
   sees a brand-new blob. **Dedup has to happen before encryption or not at
   all** — this is the part that makes the naive "the server will collapse
   them" intuition wrong.
3. *The real cadence was 30 minutes, not daily.* `backup_is_due` fires as soon
   as the policy is `dirty` and `opportunistic_debounce_secs` has passed, and
   `mark_backup_dirty` ran on **every incoming message** as well as every send.
   An account in one active group was therefore dirty essentially always; the
   24 h `daily_interval_secs` only ever throttled a *quiet* account.
4. *No code anywhere distinguished Wi-Fi from cellular.* iOS never read
   `NWPath.isExpensive`; `BGProcessingTaskRequest` asked only
   `requiresNetworkConnectivity`; Android asked `NetworkType.CONNECTED`, not
   `UNMETERED`. Meanwhile the executors are the hottest triggers in the app —
   iOS runs one on **every** transition to background plus a `BGAppRefresh`
   re-armed 3 minutes later (the scheduler's own doc comment measures 18 runs
   in a 53-hour device log), and Compose mirrors both.

48 uploads/day × a ~46 MB sealed account reproduces 2.2 GB/day exactly. Roaming
is what removed the last accidental brake: the design leaned on "it will mostly
happen on Wi-Fi", and for this user no upload ever was.

**A skip is not a failure, and must not read as one.** Three places conflated
them, all found by review rather than by the tests above: Compose returned a
bare `Boolean` so a manual tap on an already-current account toasted
"Backup failed — try again when online"; `AutoBackupWorker` mapped the refusal
to `Result.retry()` and burned its backoff slots re-discovering the same no-op;
and iOS logged "Auto account backup uploaded" when nothing was uploaded. The
outcome is now tri-state (`AccountBackupOutcome`) on Compose and a returned
`Bool` on iOS. A false "backup broken" alarm on a healthy account is the same
class of bug as the "Last backup: 6 days ago" one this entry already avoids.

**A skip must also close the window it opened.** `seal_account_backup_files`
stamps `record_backup_attempt` *before* the redundancy check. While
`attempt_dirty_seq` is set, `mark_backup_dirty` re-persists the policy on the
MESSAGE HOT PATH instead of taking its cached early-out — so returning early
without clearing it left a per-message disk write armed until the next attempt.
Success and failure both clear it; so must a skip. `attempt_plain_hash` is
cleared on load from disk for the same reason `attempt_dirty_seq` already was:
a seal that stamped and then died (this app is killed in the background
routinely) must not leave a fingerprint for a later success to promote, or every
seal after that would skip against a blob Blossom never received.

**A skip is also evidence, and must act on it.** The redundancy check proves
the bytes read under this attempt match the last successful upload, so the skip
clears two things (multi-model review found both): stale `dirty` — a send
landing mid-attempt but before the DB read is *in* the sealed bytes yet keeps
`dirty=true` at success, and left set with nothing new to upload it re-seals
and re-hashes the whole account every opportunistic pass, forever — and stale
`last_error`, which would otherwise keep a red Settings row under a provably
backed-up account. The `dirty` clear uses the same `attempt_dirty_seq` guard as
`record_backup_success` — a bump *after* the attempt snapshot keeps `dirty`,
because that send is not proven covered; the `last_error` clear is
unconditional, matching how success clears it.

**Guarded by:** `client.rs::only_our_own_messages_make_the_account_backup_urgent`
(pins the real index call site — inbound must not dirty, outbound must)

Every citation below is deliberately on ONE line per `Guarded by:` prefix.
`check-regression-ledger.sh` greps for lines *starting* with the prefix, so a
citation wrapped onto a continuation line is silently never verified — the
first draft of this entry had eight of those. If you reflow this block, keep
each prefix's citations on its own single line or they stop being checked.

**Also guarded by:** `account_backup.rs::second_seal_of_an_untouched_account_is_refused`, `account_backup.rs::seal_runs_again_once_the_account_changes`, `account_backup.rs::plaintext_fingerprint_tracks_content_not_nonce`, `account_backup.rs::unchanged_account_inside_the_refresh_window_is_redundant`, `account_backup.rs::the_refresh_window_never_outlives_the_chosen_cadence`, `account_backup.rs::a_failed_attempt_drops_its_fingerprint`, `account_backup.rs::a_redundant_seal_closes_the_attempt_window_it_opened`, `account_backup.rs::a_crashed_seals_fingerprint_does_not_survive_reload`, `account_backup.rs::no_recorded_success_is_never_redundant`, `account_backup.rs::changed_account_is_never_redundant`, `account_backup.rs::unchanged_account_past_the_refresh_window_uploads_again`, `account_backup.rs::a_redundant_skip_clears_stale_dirty`, `account_backup.rs::a_send_during_the_skips_own_window_keeps_dirty`, `account_backup.rs::a_redundant_skip_clears_a_stale_error`

**Also guarded by:** `AutoBackupNetworkPolicyTest.meteredLinkBlocksAutomaticBackupByDefault`, `AutoBackupNetworkPolicyTest.coreRefusalToReuploadAnUnchangedAccountIsNotAFailure`, `AutoBackupNetworkPolicyTest.alreadyUpToDateIsNotAFailure`, `AutoBackupNetworkPolicyTest.optingInAllowsAutomaticBackupOnCellular`, `AutoBackupNetworkPolicyTest.realBackupFailuresAreStillFailures`

**Also guarded by:** `MarmotAccountBackupFlowTests.automaticBackupIsBlockedOnAMeteredLinkByDefault`, `MarmotAccountBackupFlowTests.optingInAllowsAutomaticBackupOnCellular`, `MarmotAccountBackupFlowTests.unmeteredLinksAreNeverGated`, `MarmotAccountBackupFlowTests.coreRefusalToReuploadAnUnchangedAccountIsNotAFailure`, `MarmotAccountBackupFlowTests.realBackupFailuresAreStillFailures`

**Both platform call sites.** Core is shared: `upsert_index_for_message`
(`client.rs`) and the fingerprint check in `seal_account_backup_files`
(`account_backup.rs`) fix the cadence and the redundant-upload halves for every
host at once. The metered gate is per-host and had to land twice —
iOS `MarmotChatModel.runAutoBackupIfDue` (the single funnel all four iOS
executors pass through: the 15-minute in-app loop, the opportunistic
background-transition run, `BGAppRefresh` and `BGProcessing`), and Compose
`SonarAppState.runAutoBackupIfDue` + `runOpportunisticBackupOnBackground` plus
`AutoBackupWorker`'s `NetworkType.UNMETERED` constraint **and** its run-time
re-check. macOS inherits the core half and shares `SonarBackupScreen`.

**The gate is re-checked at the upload boundary, not just at executor entry.**
Relay drain, checkpoint, seal and reconnect take seconds on a large account, so
a Wi-Fi→cellular handoff between the entry check and the PUT would ship the
whole snapshot anyway. Both surfaces re-check immediately before the upload and
abort, recording a benign failure so `dirty` stays set for the next window.

**TRACKED GAP (Compose Desktop).** The JVM has no portable metered-network API,
so `isNetworkMetered()` is a hard-coded `false` there and the preference cannot
be enforced. The Backup screen therefore HIDES the toggle on that target
(`meteredNetworkPolicySupported`) rather than offering a data-saving control
that silently does nothing — a UI promising something it cannot deliver is the
same defect class as the "Backup failed" toast on a healthy account. A desktop
on a phone hotspot still auto-uploads full snapshots. Follow-up: implement
`isNetworkMetered()` per desktop OS (Windows exposes a connection-cost API;
macOS and Linux need separate paths), then flip the flag and the toggle returns
with no other edits. Deliberately not in this change: the reported incident is
iOS cellular, and a half-working desktop probe would be worse than an admitted
gap.

**Why the refresh window tracks the user's cadence rather than a flat constant.**
An unchanged account still re-uploads once per chosen interval (capped at
`UNCHANGED_REFRESH_SECS`). Two reasons, and the first is the one that would have
generated a bug report: Settings shows the age of the last successful upload, so
a "Daily" user reading *"Last backup: 6 days ago"* concludes backup is broken
and cannot see that the reason is "nothing changed". Second, the blob lives on a
host we do not control, and re-establishing it on their schedule bounds
retention/GC exposure. The saving that matters was never this — it is killing
the 30-minute opportunistic re-upload and keeping all of it off cellular.

**Two ways this gate could have meant "no backups", both closed.** (1) The
Compose opportunistic path returned *before* enqueueing the one-shot worker, so
a user on cellular got nothing scheduled at all and fell back to the 12-hour
periodic. The one-shot carries an `UNMETERED` constraint precisely so
WorkManager can **park** it and run it the moment Wi-Fi arrives; it is now
enqueued unconditionally and only the in-process upload consults the gate.
(2) iOS read `NetworkActivationService.pathIsExpensive`, which is pessimistic
until the first `NWPathMonitor` callback — and `start()` is only ever called
from the UI scene, so a `BGProcessing`/`BGAppRefresh` launch could evaluate the
gate against a default that never updates and silently skip every background
backup. The gate now calls `currentPathIsExpensive()`, which starts the monitor
on demand and reads `currentPath`, answering `false` when there is no route at
all (let the upload fail on its own terms rather than be suppressed as
"expensive").

**Not guarded.** The *Swift* half, again, for the reason
[[ios-not-built-in-ci]] records: the gate lives in `MarmotChatModel`, which no
iOS test constructs, and iOS tests do not run in CI regardless. What is pinned
is the pure predicate (`autoBackupAllowedOnCurrentPath`,
`isUnchangedAccount`); delete the **call** in `runAutoBackupIfDue` and every
test stays green. That is the R-001 shape and it is admitted as one. Also
unpinned: `NetworkActivationService.currentPathIsExpensive()` and its
start-on-demand behaviour, Android's `isNetworkMetered()` actual (needs a
`ConnectivityManager`), the `NetworkType` mapping in
`AutoBackupWorker.networkType()`, and the unconditional one-shot enqueue.
`only_our_own_messages_make_the_account_backup_urgent` pins the index call site
but not `spawn_send_bookkeeping`, which is the other site that marks dirty on a
real local send. Real verification is Settings → Mobile Data on a device left on
cellular for a day, cross-checked against `SecureLogger` `.session` lines
(`Auto-backup executor: skipped (metered link, cellular backup off)` /
`Account backup skipped — unchanged since the last successful upload`).

**Rejected:**
- *Letting the daily floor re-upload identical bytes anyway.* It is a full
  snapshot; "identical" means the existing blob already satisfies it. The
  cadence-bounded refresh window above is the compromise that keeps the UI
  honest without paying 1440 uploads/month.
- *Hashing the sealed ciphertext instead of the plaintext.* Cannot work — the
  nonce is fresh per seal, so sealed bytes never repeat. This is the trap that
  makes the bug counter-intuitive and it is why the fingerprint is taken over
  the package's plaintext (DB ‖ index ‖ db_key, length-delimited).
- *A `(mtime, size)` change token instead of a content hash.* Nearly free, but
  wrong here: SQLite in WAL mode leaves the main file's mtime untouched while
  the `-wal` holds new commits, so it can report "unchanged" for an account
  that changed. A false *unchanged* is the one failure direction this module
  must never risk. The hash costs nothing extra because the seal has already
  read the bytes.
- *Adding a `skip_if_unchanged` parameter so manual "Back up now" can force an
  upload.* It would change two `#[uniffi::export]` signatures, and the
  committed Swift/Kotlin bindings are generated — a checksum move no CI job
  watches ([[uniffi-doc-comment-is-an-abi-change]]). The error crosses as a
  rendered string instead (`SonarFfiError` is a `flat_error`), the same
  contract `AccountBackupMissing` already relies on. Manual backup of an
  unchanged account is a no-op that returns cleanly rather than an error.
- *Bumping `last_success_at` on a redundant skip so the UI reads "just now".*
  It would make the refresh window unreachable — `now - last_ok` could never
  grow — leaving a GC'd blob as the only backup, forever.
- *Gating media downloads and relay sync on the same flag.* Measured first:
  media is view-driven and durably cached under Application Support (no refetch
  loop), and relay sync is watermark-scoped and event-driven. Neither is a
  GB/day source, and gating chat traffic on Wi-Fi would break the product.

## Unguarded

- **A 2-member pending welcome must remain visible in both hosts' invite UI.**
  #498 made core stop filtering `member_count <= 2` out of
  `pending_group_invites` so a rate-limited first-contact DM parks visibly
  (`core/sonar-core/src/marmot.rs::pending_group_invites`); both hosts render
  the list unfiltered today (Compose `App.kt` invite section, iOS
  `SonarHomeScreen`), but no test stops either host from filtering it back
  out — the classic mirror-pair failure. Related invariant, also unpinned: the
  kind-445 fetch filters must stay ACTIVE-groups-only or a parked contact's
  opening message becomes permanently undecryptable (comment at the call
  site).

Gaps we know about. Each line is a concrete backlog item; fold it into its `R-`
entry once a test exists. Listing a gap is the point — an entry that overclaims
its coverage is worse than an honest hole, because it stops people looking.

- **A background auto-backup must close the store it reopened (0xdead10cc, round 6).** TestFlight **1.12.6 (34)** — the build shipping R-028 — killed on an iPhone15,3 **28 minutes** into a background launch (`Role: unknown`, launch 13:51:44 → kill 14:19:34). **Confirmed on the device, not inferred.** The crash-build logs pulled from the reporting iPhone (`devicectl device copy from --domain-type appDataContainer`, read-only) show the whole mechanism in 35 seconds: `12:18:59.404` `BLE status [entered-background]` (so `suspendStoreForBackground()` armed its close) -> `12:19:01.355` core `refinery: current version: 6` + `relays added relay_count=0`, i.e. the store REOPENED by the backup's `performConnect` -> `12:19:02.643` `relays added relay_count=5` (`connectRelaysIfNeeded`) -> `12:19:09.861` `Auto account backup uploaded` -> `12:19:34.497` the 0xdead10cc kill -> `12:19:35.5` relaunch. Note the path: the `BGAppRefresh` at `12:04:09` logged `not due` and ran no backup, so the reopen came from the **opportunistic scenePhase-`.background`** executor, which starts silently at the transition. Read that before assuming a future round is the BGTask path — and note the opportunistic path logs nothing on start, so the caller is identified by timing plus elimination (`skipped (busy=false inFlight=true)` at `12:19:03` is a second, later caller finding the first already running). Rounds 1-3 asked what *blocks* the close, round 4 what *reopens* the store, round 5 (R-028) why the close was never *reached*. This one is a background entry point that has **no close at all**. `AutoBackupBackgroundScheduler.handle(_:label:)` ran `runAutoBackupIfDue` → `backupAccount()`, which closes the node to seal and then deliberately ends **reopened** — `performConnect()` + `connectRelaysIfNeeded()` + `startPolling()`, so the Blossom upload has a live node — and then called `setTaskCompleted` and returned. A BGTask launch never gets a scenePhase `.background` transition, so `setForeground(false)` → `suspendStoreForBackground()` — the only hook that closes the store before suspension — never runs in that process, and R-028's `WAKECLOSER` timer is scoped to `processMarmotWakeup`. iOS suspended us holding the App Group flock and the SQLCipher WAL. **The kill needs no expiry:** a backup finishing comfortably inside its window still left the store open, which is why this survived a path whose only protection was `task.expirationHandler = { work.cancel() }` — and Swift cancellation cannot end a park in uncancellable Rust anyway (R-028's `closeStoreWithDeadline` says so for the push wake). The crash log matches exactly: `register_push_token` parked in `block_on_suspendable` **un-aborted** (R-028's proof that no `interruptNodeForSuspend()` ever ran, on a node freshly installed by the backup's own reconnect → `setSonarNode` → `registerTransponderIfReady`), plus `wait_for_marmot_event` from the polling loop `backupAccount()` restarts, plus a residual `call_wait_event` lease — the last of which is *evidence the node was open*, not a cause, exactly as R-028 warns. Fixed by closing via `closeStoreAfterBackgroundWake()` before `setTaskCompleted`, gated on `.background` like every other close path and paired with a DETACHED `reconnectIfForegroundAfterWakeClose()` (the `.background` check happens BEFORE a close that can take seconds, so a user who foregrounds in that window would otherwise be left with a visible app and no node). Detached, not inline and not gated: the callee awaits an in-flight `refreshTask` before its own foreground guard, so awaiting it inline would put 25s+ between the close and `setTaskCompleted`, while gating it on `.background` here would skip exactly the foreground-during-the-await case it exists for. `SonarPushProcessor` gates its in-band call only because the detached one in `closeStoreWithDeadline` backstops that ordering; this path has no second call. The BGTask `expirationHandler` stays cancel-only — see `Rejected`. The same close follows `runOpportunisticBackgroundBackupIfDue`, whose reopen lands *behind* the `suspendStoreForBackground()` armed earlier in the same scenePhase handler (an R-020-shaped reopen-after-close its `backgroundTimeRemaining` guard makes less likely to start but never safe to finish). **Unguarded and structurally so:** `AutoBackupBackgroundScheduler` is `@MainActor`, needs a `SonarAppStore` and a real `BGTask`, and the fix is "call the close" — there is no arithmetic to extract the way R-028 extracted `SonarWakeBudgetPolicy`, and a `shouldClose(state:)` helper test would be the exact R-001 shape (delete the call and it stays green). It reports itself instead, like R-028's `WAKECLOSER`: `Auto-backup <label>: closing the store before suspension` / `store closed` / `store left open — app is foreground` through `SecureLogger` (category `.session`, the only sink `SonarDiagnostics` packages into a shareable capture). Real verification is a TestFlight build left backgrounded until a `BGAppRefresh`/`BGProcessing` backup fires. **Not applicable to Compose** for the same reason as R-028: no RunningBoard file-lock kill, and the backup worker runs under WorkManager rather than a suspension deadline. **Rejected:** *Closing from the BGTask `expirationHandler` too.* It reads as the obvious completion of this fix and is a worse bug: expiry can land while `prepareSealedAccountBackup()` is mid-seal, that seal runs on `accountBackupQueue` so the close is not serialized behind it, and `closeNode(keepClosed: false)` ends by clearing `nodeClosing` — the exact fence the seal holds until after it releases `sealStoreLock`. That function's own comment says dropping it early lets a connect take a second `LOCK_EX` on a different fd and "would leave the Marmot store permanently closed". An unopenable account database is worse than a background kill. *Closing inside `backupAccount()`.* Four throw/return exits after the reopen and Swift `defer` cannot `await`, so it would duplicate the close on every exit and grow the repo's #3 hotspot file. *Not reopening at all on the background executors* (the upload is node-free, so it would remove the root cause rather than race it) — genuinely attractive, but the reopen feeds `reconnected` into `MarmotAccountBackupFlow.outcome`, so skipping it would mark healthy background backups as failures. That blocker is real but shallow — `MarmotAccountBackupFlow` is 35 lines with one call site and 5 pure tests, so a `reconnectRequired:` discriminator plus a `reopenAfterSeal: Bool = true` threaded through `backupAccount` and set `false` by the two background executors is ~20 lines. It is the better end state and, unlike the fix shipped here, it is TESTABLE: the whole post-seal tail (`pushSealedAccountBackup`, `noteBackupSuccess`/`Failure`, `loadBackupPolicy`) is node-free `dbPath`-keyed FFI, and `prepareSealedAccountBackup` already ends with the fence cleared and `sealStoreLock` released — so with no reopen there is nothing left to close and residual (2) disappears entirely. Deferred only to keep this PR to the crash. **Known residuals.** Round-2 review refuted the first draft of this list, so it is stated carefully. (1) *The close does still run on expiry* — `work.cancel()` stops nothing (no link in the seal/connect/upload chain is cancellation-aware) and `work` is `Task<Bool, Never>`, so `await work.value` cannot return early. What overruns on expiry is the **BGTaskScheduler contract**, not the store lifetime: `setTaskCompleted` sits behind that same await, and iOS terminates an app that fails to complete after expiry. Main's shape, but this PR lengthens the tail; the fix is a completion latch in the handler, NOT a close (see `Rejected`). (2) *The close is slow but it lands.* It waits on `nodeLifecycleGroup` for the relay attach `backupAccount()` just kicked, which nothing can cancel — `connectRelaysIfNeeded()` never assigns its `Task` to `relayConnectTask`, `connectNode` takes its lease before the blocking connect, and core's `SonarNode::connect` uses a plain `block_on` whose `suspend_interrupt` does not exist yet. But the relay quorum wait is capped (`RELAY_CONNECT_TIMEOUT`, 5s) and `closeStoreAfterBackgroundWake()` holds a `beginBackgroundTask` across the close, so the store *is* released and the 0xdead10cc cause *is* removed. Two sharper edges remain: the unbounded blocking `flock(LOCK_EX)` in `prepareStoreLockForConnectSync` runs on the same serial `workQueue` the close's first hop needs, and this call site awaits the close bare where the push path deliberately abandons the wait via `closeStoreWithDeadline` (which is `private` to `SonarPushProcessor`). (3) *The real open invariant, of which this bug was one symptom:* **any `MarmotChatModel` operation still holding `busy` / `accountBackupInFlight` across the background transition reopens the store with nothing scheduled to close it.** `suspendStoreForBackground()` fires first, the opportunistic executor bails on `guard !busy, !accountBackupInFlight`, and the in-flight operation then reopens. A manual Settings backup is the reachable instance today; the nsec-restore and erase-and-reconnect paths have the same shape. The per-call-site close shipped here does **not** generalize to it — that needs one hook (a background-state check at the tail of `performConnect`, or the ownership counter Android already has as `MarmotSessionGate.isLiveUiSession`). Round 7 should start here.
- **The in-app auto-backup timer must not reopen the store while backgrounded (0xdead10cc, round 7).** TestFlight **1.12.7 (36)** — the build shipping rounds 1–6 (#544/#545 included) — killed on an iPhone15,3 45 minutes after launch. **Confirmed on the device, not inferred** (same read-only `devicectl` log pull as round 6). Timeline: `23:40:54` `entered-background` (suspend close ran; opportunistic executor logged `not due`) → `23:48:07` core `refinery: current version: 6` + `relays added relay_count=0` then `relay_count=5`, 150-group catch-up queued — the store REOPENED, still backgrounded → `23:48:37` `Auto-backup BGAppRefresh: running` then 3ms later `skipped (busy=false inFlight=true)` → `23:49:07` `Auto account backup uploaded` → `23:50:25` 0xdead10cc. The reopener is the **15-minute in-app loop** (`scheduleAutoBackupCheck`): its ticks logged `deferred (app active)` at 23:03/23:18/23:33 and the 23:48:06 tick landed on a BLE-kept-alive **backgrounded** process. `suspendStoreForBackground()` cancelled `syncTask`/`relayConnectTask` but never `autoBackupTask`; `runAutoBackupIfDue`'s deferral guard checks only `.active`, so `.background` sailed through, `backupAccount()` sealed → reopened (`performConnect` + relays + `startPolling`, matching the crash threads: `wait_for_marmot_event` + `call_wait_event` parked in bare `block_on` inside live leases) → uploaded, and the timer caller ignored the `true` return that every background executor uses to close. Round 6's `BGAppRefresh` close could not save it: it fired mid-flight, saw `inFlight=true`, correctly returned `reopenedStore=false`, skipped its close, and `setTaskCompleted` freed iOS to suspend us. This is round 6's residual (3) made concrete — an in-flight backup straddling the background transition with nothing scheduled to close it. Fixed three-layered in `MarmotChatView.swift`: (a) `suspendStoreForBackground()` and `closeStoreAfterBackgroundWake()` cancel `autoBackupTask` (the wake path matters too — a background push wake's `performConnect` re-arms the loop at 45s); (b) `runAutoBackupTimerTick()` never STARTS a backup while `.background` — the tick holds no `beginBackgroundTask` assertion, so iOS may suspend mid-seal even if it would close after; (c) a run that started `.active`/`.inactive` and finished backgrounded closes via `closeStoreAfterBackgroundWake()` + detached `reconnectIfForegroundAfterWakeClose()` — the same one-directional gate and foreground-race shape as `AutoBackupBackgroundScheduler.closeStoreIfStillBackgrounded`, and the self-cancel it triggers just ends the loop, which foreground re-arms. **Unguarded and structurally so**, same as round 6: `MarmotChatModel` is UIKit-bound, iOS tests do not run in CI, and a `shouldRun(state:)` helper test is the R-001 shape. It reports itself through `SecureLogger`: `Auto-backup timer: skipped while backgrounded — background executors own it` / `closing the store before suspension` / `store closed`. **Still open from round 6's residual (3):** a manual Settings backup, nsec-restore, or erase-and-reconnect holding `busy`/`accountBackupInFlight` across the transition — the general hook (background check at the tail of `performConnect`, or Android's `MarmotSessionGate.isLiveUiSession` ownership counter) remains the end state. **Not applicable to Compose:** no RunningBoard file-lock kill; WorkManager owns background backups. **Second occurrence, same night, cleaner fingerprint** (1.12.7 (36), same device, launch `23:50:35` — the relaunch from the kill above — to kill `01:11:01`): `00:55:09` `entered-background` with no `became-active` after it; `00:55:44` timer tick logs `not due`; **exactly +15:00.00** the next tick at `01:10:44` finds the backup due; `01:10:45.9` core logs `refinery: current version: 6` + `relays added relay_count=0` (the seal's `performConnect` reopen), `01:10:47.1` `relay_count=5` (`connectRelaysIfNeeded`), `01:10:49` `cached push token from group member` (`setSonarNode` → the `register_push_token` thread parked in the crash log); `01:10:57.7` `Auto account backup uploaded` **with no close line after it**; kill 3.4s later. The caller is pinned by elimination, not guesswork: `BGProcessing` at `01:00:16` and `BGAppRefresh` at `01:04:31` both logged `not due` and ran nothing, and the opportunistic executor always logs its close — proven at `00:35:01` **the same night**, where `uploaded` is immediately followed by `opportunistic: closing the store before suspension` / `store closed`. Only the in-app timer uploads with no close. That `00:35:01` pair is also positive evidence that round 6's fix works: the opportunistic path closed correctly while the timer path, 35 minutes later, did not. **The 15:00.00 tick interval is the diagnostic** — when a future round shows a reopen with no close, diff the timestamps of the two preceding `runAutoBackupIfDue` log lines before hunting for a new mechanism. **Named residual of the fix:** a straddling tick whose seal+reopen+upload outlives the `beginBackgroundTask` window (~30s; both field-measured backups took ~13s) is suspended after the expiry handler with the close unreached — closing from the expiry handler is this entry's own `Rejected` item (mid-seal fence hazard), so this is accepted for the same reason the BGTask handler's expiry stays cancel-only.
- **A background backup must never reopen the store at all, and a backgrounded relay attach needs an owner (0xdead10cc, round 8).** Two kills on 2026-08-01, both on builds carrying rounds 1–7, both **confirmed on the device** (`devicectl` read-only log pull + the device's own `.ips` reports, which record exactly one `SQLite page cache` region open at each kill). **Kill A — 1.12.9 (38), 23:03:17, the smoking gun:** `22:51:04` suspend close ran (`publish_sonar_descriptor interrupted for suspend` proves the latch fired) → `23:03:13` `Auto-backup BGAppRefresh: running` → `23:03:15` `backupAccount` seal failed `ServiceError error 1` (`.cancelled` — provenance UNRESOLVED: nothing in `prepareSealedAccountBackup`'s own chain throws `.cancelled`, which is itself the open puzzle; the typed-error dump shipped in this round names the case next time) → its failure path still ran the unconditional post-seal reopen (`performConnect` + `connectRelaysIfNeeded`, whose Task is assigned to no slot and awaited by nobody) → `23:03:15.7–16.9` the executor's `closeStoreIfStillBackgrounded` logged `store closed` → the straggler attach reopened SQLCipher → kill **200ms later**. The round-6 entry's own `Rejected` note blueprinted this fix and deferred it; round 8 ships it: `backupAccount(reopenAfterSeal: false)` for the BGTask + opportunistic executors (the upload is node-free), `reconnectRequired` threaded through `MarmotAccountBackupFlow.outcome`, and a `RelayConnectionPolicy.mayAttachRelays(foreground:pushWakeOwned:)` gate at `connectRelaysIfNeeded` — only the push wake (which brackets its drain in `pushWakeOwnership` and closes after itself) may attach while backgrounded. Guarded by: `MarmotAccountBackupFlowTests.backgroundRunWithoutReconnectRequirementSucceedsClosed` / `backgroundRunStillSurfacesUploadFailure` and `RelayConnectionPolicyTests.backgroundedAttachWithoutOwnerRefused` — helper-level pins (the R-001 caveat applies; the call sites are UIKit-bound and iOS tests do not run in CI). **Kill B — 1.12.8 (37), 16:57:15, mechanism still open:** a 30s foreground session, backgrounded 16:56:42, killed 33s later ≈ at the suspend close's `beginBackgroundTask` expiry, with the node ALIVE (the `sonar-change-fwd` listener thread parked — it exits when the node drops), **zero** FFI in flight and every queue idle. So either the suspend close hung on `nodeLifecycleGroup` (a leaked lease with no running work) or it completed and a strong `SonarNode` ref outlived it — the crash cannot distinguish because `suspendStoreForBackground()` logged nothing. Round 8 makes it self-reporting (`Suspend close: closing/store closed` + an expiry warning): the NEXT such report names the branch. Do not hunt a new reopen engine for a kill of this shape until those lines are read. **Rejected (again):** gating `performConnect` on background — `connectLocal`'s own comment documents that a refused connect during an nsec restore rolls back through `wipeDatabase()`; a blanket gate there risks data loss and needs the ownership-counter end state (Android's `MarmotSessionGate.isLiveUiSession`) first. **Not applicable to Compose** (no RunningBoard file-lock kill; WorkManager owns background backups). Operational note: `sonar-core.log` rotates away within minutes when relays are unreachable (2MB of `Failed to stream events` spam — the same condition that filed four `Sonar.cpu_resource_fatal` reports that day, a separate open issue); the iOS log retains days and is the one to trust for old windows.
- **The lazy store open needs an owner too (0xdead10cc, round 9).** One kill on 2026-08-02, **1.12.10 (39) — the build shipping round 8**, **confirmed on the device** (same read-only `devicectl` log pull; the TestFlight `.crash` carries no VM summary, so the reopen is pinned by the logs alone). Timeline (local +0200): `13:51:25.9` `became-active` — a **5-second** foreground visit → `13:51:26.1` core `refinery` + `relays added relay_count=0` (`performConnect`'s `connectLocal`) → `13:51:26.6` `relay_count=5` (the attach) → `13:51:30.6` backgrounded, `Suspend close: closing` → `13:51:30.798` the in-flight attach dies behind the close fence (`received termination request` ×5, so `connect()` returned `NoRelayConnected`/cancelled and its task exited SILENTLY through the r8-audited catch — no attach gate log because no attach retried) → `13:51:30.838` `Suspend close: store closed` (round 8's self-reporting close worked: the close COMPLETED, distinguishing this from Kill B) → **`13:51:30.991` `refinery` + `relays added relay_count=0` — the store REOPENED 150ms after "store closed"**, `subscribe_marmot done`/`with_engine complete` at 172ms, sticker-ref parse spam at `13:51:31.8` (= `performConnect`'s `loadLocalSummaries`) → kill `13:52:02.4`, BLE-restore relaunch 1s later. The reopen is a full `performConnect` (`connectLocal` shape, no attach after — `scheduleRelayConnect`'s r8 gate refused silently), and every direct `performConnect` caller (restore, erase, backup reconnect, onboarding) logs or was user-visible and idle, so by elimination it entered through **`connectIfNeeded` — the lazy open funnel** that `ensureConnected`, chat-open warmups, send fallbacks and view appear hooks all share. A caller fired during the transition, found `node == nil` (the close mid-flight), queued `performConnect` behind the close on the serial `workQueue`, and `connectLocal` sailed through because `closeNode(keepClosed: false)` had already cleared `nodeClosing`. Rounds 4–8 gated the *attach* paths one entry point at a time; this kill proves the store-open half needed the same treatment at the funnel, not the entries. Fixed: `RelayConnectionPolicy.mayOpenStore(foreground:pushWakeOwned:)` consulted by `connectIfNeeded` at call time AND at execution time inside its task (the r8 revalidation lesson — the scene can background between the two). The push wake holds `pushWakeOwnership` across its whole pass (`SonarPushProcessor.wake`, begin at the top, `defer` end) and reaches the store through this same funnel, so ownership admits it; explicit flows call `performConnect` directly and stay ungated — the r8 `Rejected` note (a refused connect during nsec restore rolls back through `wipeDatabase()`) still stands and is why the gate sits on `connectIfNeeded`, not `performConnect`. Guarded by: `RelayConnectionPolicyTests.backgroundedLazyStoreOpenWithoutOwnerRefused` / `pushWakeMayOpenStoreBackgrounded` / `foregroundLazyStoreOpenNeverGated` — helper-level pins (the R-001 caveat applies: `MarmotChatModel` is UIKit-bound, iOS tests do not run in CI, and deleting the `guard` in `connectIfNeeded` keeps all three green). **Named residual:** the gate is also carried into `performConnect` as `lazyOpenGate` and rechecked after the identity-load awaits, immediately before `connectLocal` — those awaits are where the fatal open sat queued while the suspend close completed, so the caller-side checks alone still raced. What remains is a `.inactive`-straddle between that last recheck and `SonarNode.connect` taking SQLCipher — microseconds, no awaits between them — and closing even that needs the ownership-counter end state (Android's `MarmotSessionGate.isLiveUiSession`) every 0xdead10cc round since 6 has named. Explicit `performConnect` callers pass `lazyOpenGate: nil` and are never refused (the r8 nsec-restore rejection stands). **Not applicable to Compose** (no RunningBoard file-lock kill). Forensic note: the identical clean backgrounding at `13:13:47` (close, no reopen, 37 quiet minutes) is the control — when triaging a future round, find the nearest clean transition and diff what ran in the fatal one; here the only difference was the 5s foreground visit leaving a connect/attach/refresh generation still in flight at the transition.
- **R-003, the one-transcript half.** Cited tests pin chat-list dedup and identity routing, not "duplicate groups' messages merge into a single transcript". The merge lives in `SonarAppState.duplicateDirectMarmotChats` (private, needs an instance); `dedupeDirectMarmotChats` — the pure seam the tests use — only covers the chat-list half. Closing it means extracting the transcript-source selection into a pure function, or an injectable `SonarCore`.
- **R-023's five call sites.** The predicate is pinned on both platforms, but nothing proves each of the five import paths actually consults it before wiping. Same root cause as the entries below: neither app object can be constructed in a test. Until then this is a helper-level guard on a data-loss path, which is precisely the shape R-001 regressed through.
- **R-004, account wipe, both platforms.** Now implemented on iOS and Compose, but pinned by no test. The Compose path needs an injectable `SonarCore`; the iOS path needs a constructible `SonarAppStore`, and no iOS test builds one today (`MarmotOptimisticEchoTests` only exercises static functions).
- **R-013, host push-tap / catching-up chip.** The iOS local-banner marker is pinned as a pure seam; the real `NotificationDelegate` → `refreshAfterForeground` call, full sync-lifetime indicator, and Compose notification-open → `forcedCatchupSync` route still need constructible app stores. Real-device APNs/FCM validation remains #262.
- **Anything needing a `SonarAppState` / `SonarAppStore` instance.** The three gaps above share one root cause: neither app object can be constructed in a test, so only pure helpers are reachable. This is the single highest-leverage testing investment in the repo — see the injectable-core note in the Signal architecture notes. Until then, prefer removing a hazard (as R-001 does with a mandatory parameter) over testing for it.
- **Out-of-range mesh DM echo dedup + Marmot reconcile (R-011 outbox half).** The outbox-flush path (`flushOutboxNow` -> `sendMesh(messageId)` + durable `removeMeshEcho` after Marmot) extends R-011's echo lifecycle to a second entry point. The O(1) dedup in `sendMesh` (`messageId == null || messageId !in meshEchoIds`) and the bounded reconcile (`removeMeshEcho` polls `marmotMessagesForPeer` up to 10x100ms before clearing the echo; on outbox eviction `failMeshEcho` marks the echo "Couldn't send") are both untested -- `SonarAppState` cannot be constructed in a test. Same root cause as the entry above. (Compose media retry is now covered by #397's `SonarMediaOutbox`/`queueMeshMediaForRetry`, so the earlier display-only media-echo gap no longer applies on Android.)
- **A running iOS process is not a rendered UI.** `BitchatApp.init()` read `_sonarStore.wrappedValue` before SwiftUI installed the `@StateObject`, so each access built a throwaway store: the throwaway connected and opened the account while the view's store never left its launch state, and the app sat on the splash forever. It shipped because the simulator check verified the process stayed alive and read `t1_local_paint groups=137` from the log — both true, both from the wrong instance. The **mechanism** is now pinned: `scripts/check-stateobject-init.sh` (CI: `.github/workflows/swiftui-lifecycle.yml`) fails on any `_x.wrappedValue` read inside an `init()` in a file declaring a `@StateObject` — verified by reintroducing the exact line and re-running, and by confirming the clean tree passes. Like the share-extension check below it is deliberately not cited as `Guarded by:`: it is a shell check, not a test in this ledger's citation grammar. **What it does not pin** is the entry's actual claim — that the app renders. Any other route to a split instance (a helper taking the projected value, the same mistake via `@ObservedObject`) still passes, and no iOS test builds an app scene. Until a UI test target exists (#520) treat "the process is alive" and "the log looks healthy" as insufficient evidence for any launch-path change, and screenshot the screen. Found on an iPhone 14 Pro Max in #368.
- **iOS tests do not run in CI.** No workflow invokes `xcodebuild test` / `ios/bitchatTests`, so `MarmotOptimisticEchoTests` guards R-001 only for someone running it locally. `scripts/check-regression-ledger.sh` verifies the test *exists*; nothing verifies it still *passes*. Until an iOS test job exists, treat Swift citations as weaker than Kotlin/Rust ones.
- **Mesh-DM peer-ID rotation orphaning (PR #397 Compose + PR #405 iOS).** Messages keyed by short BLE ID (16-hex) are orphaned when the peer reconnects with a rotated RP address. Compose side fixed in #397 (`echoMeshMessage` + `enqueueOutbox`); iOS side fixed in #405 (`didDisconnectFromPeer` always migrates to stable Noise key). **Residual gap:** when `derivedStableKeyHex` is nil (Noise session never established or already torn down), messages stay under the dead short BLE ID — `consolidateMessages` does not scan for orphaned 16-hex keys. Needs orphan-recovery scan in `PrivateChatManager.consolidateMessages` or deferred migration on reconnect. **Second residual gap:** when a peer has both an outbound peripheral connection and an inbound central subscription (dual BLE leg), losing either leg triggers `didDisconnectFromPeer` unconditionally (`BLEService.swift:1573` / `:4823` / `:5032`). The migration removes the short-key transcript, but messages arriving over the surviving leg continue to be stored under that short peer ID, splitting the conversation again. `notifyPeerDisconnectedDebounced` (debounce window at `:4823`) mitigates rapid double-disconnects but does not check if the other leg is still live. Fix requires per-leg connection-count tracking in `BLEService` so `didDisconnectFromPeer` only fires when all legs are gone. Neither platform has a test for this path; iOS tests don't run in CI.
- **Android offline BOLT12 wake: settle path and service lifecycle (PR #295).** The `invoice_request` answer path is now pinned end to end at the boundary that matters — `NdsReplyUrlTest` (androidUnitTest, 12 cases) covers the reply-URL pin, the single control between a forged NDS push and a redirected payment invoice, including the two bypasses that survived review: `java.net.URL` does **not** normalize dot-segments (only `URI.normalize()` does), and percent-encoded traversal re-appears once the far side decodes. What is **not** pinned is everything downstream of it. (1) `handleSettledReceive`'s exit signal is now pinned: the decision moved to a pure `settleWakeOutcome(settled, liveEvent, firstThisWake, alreadyNotified)` in commonMain with `SettleWakeOutcomeTest` (9 cases) naming the actual failures rather than covering a truth table — the historical-receive regression, the foreground-claimed trap, and two invariants (`PENDING` never notifies under any combination; notifying implies ending the wake). Mutation-checked: reintroducing the exact `289dda986` regression fails two of them. The **call site** is still unpinned — nothing proves the service passes the right `liveEvent` at each of its two call sites, which is precisely how R-001 escaped, so prefer extending this seam over re-inlining the logic. (2) `paymentEventOf`'s `paymentHash`-before-`txId` id stability, whose whole purpose is that a Lightning receive keeps one id across `PENDING` → `COMPLETE`; keying `txId` first double-ledgers and double-notifies. (3) The service lifecycle: `inFlightWakes` stopping the service only at zero, and the per-delivery `enterForeground()` re-arm of the shortService window. All three need either an Android `Service` driver (Robolectric) or an injectable `SonarCore`; none is reachable from `commonTest` today. The settle path has also never run on device — every captured receive settled inside a single wake, so cross-wake dedup and the `PENDING` branch are reasoning-only. This is simultaneously the most-churned and least-verified code in that PR.
- **Account key durability.** `CLAUDE.md`'s Account Key Durability Rule lists five blocking invariants (never delete-before-add, never regenerate on keychain error, ...) with no regression test cited here.
- **R-019 receiver wiring and scanner re-acquisition.** The pure decision
  (`bleAdapterAction`) is pinned, but the `BroadcastReceiver` registration, the
  `IntentFilter`, the scanner re-acquisition in `startScanInternal`, and the
  stamp-only-on-success change have no automated test — no JVM test can drive a
  `BroadcastReceiver` or a `BluetoothLeScanner`. (An `androidUnitTest` source
  set does exist as of PR #295 — see `NdsReplyUrlTest` — but it is a plain JVM
  target, so it still cannot drive Android framework classes; this needs
  Robolectric or a driver seam.) Verified by hand on a Pixel 4 XL.
- **iOS NIP-05 verified badge cache key.** `nip05Verified` is keyed by `"canonicalKey(npub)|address"`, but the badge branch in `SonarContactProfileScreen.swift` read it by `address` alone, so the lookup always missed and the checkmark never rendered while the handle text rendered unconditionally. Verified and forged handles were therefore indistinguishable. Fixed by routing all three sites through one `static func nip05CacheKey(npub:address:)` (PR #411), which is deliberately static and npub-explicit so it is reachable without constructing the screen — unlike the `SonarAppStore` gaps above. `Nip05BadgeCacheKeyTests` pins that one handle claimed by two different keys yields two different entries. **The citation is weak on purpose:** iOS tests do not run in CI (see below), so nothing verifies it still passes. What is *not* pinned is the call-site wiring — a fourth site hand-building the key again, or the badge reading a different key than `verifyHandleIfNeeded` writes, is exactly the original bug and no test would catch it. Compose is structurally immune (`SonarContactProfileScreen.kt` scopes the state with `remember(peerNpub, nip05)`), so there is no Android mirror to pin.
- **Apple media sends must not lose the account gate to an automerge.** Rebasing this change onto main dropped every `isCurrentAccountWork(generation)` check from `MarmotChatModel.sendMedia`/`sendMediaMulti` while keeping main's bare `ensureConnected`/`appendOptimistic`/`service.…` calls inside the PR's escaping `launchIndependentAccountWork { model, generation in … }` closure. The bare calls do not compile (`implicit use of 'self' in closure`), so the breakage was loud; the *silent* half is that a closure receiving `generation` and never checking it turns the account-mutation gate into a no-op on exactly the two paths it was added for. Both are restored: the calls are `model.`-qualified and the guards bracket every suspension point, with the listener release and echo discard deliberately running even for retired work so only the user-visible failure row is skipped. Every `sendChain` producer must carry the gate, not just the ones that looked like the pattern: `send(_ texts:to:)` and `sendQueuedText` assigned new chain tails with no generation/suspension check, and a batch spanning multiple awaits keeps assigning tails *after* a quiesce has already snapshotted the chain — so it could publish against the old account while the wipe proceeded. The batch also re-checks between items. Unpinned — iOS tests do not run in CI and no test constructs `MarmotChatModel` with a controllable send, so the only thing standing between this and a silent regression is that the uncompilable form fails loudly next to it.
- **Sender-chosen mesh message ids are receipt-only.** The BLE file-transfer packet now carries an optional `message_id` TLV so the recipient can return an encrypted `delivered` receipt. That id arrives unauthenticated inside the Noise payload, so it must never become the identity of a *local* row: on Apple the incoming media row keeps its own generated `BitchatMessage.id` and the wire id is used only for `sendDeliveryAck`, and on Compose every id match that can withdraw or suppress a row is gated on `it.mine` (`drainMeshMedia` duplicate check, `drainMeshSendFailures`, both matches in `drainMeshMediaSendFailures`). Without those guards a peer could pick an id colliding with one of our outgoing rows and either suppress its own incoming media or have our failure path delete/evict that row. Nothing pins this: all four Compose sites need a constructed `SonarAppState`, and the Apple site needs a `BLEService` with a live peer. Close it with an injectable receive seam plus a two-device test where the peer deliberately reuses a known local id.
- **Ordinary `MeshRadio.stop()` must not discard undrained delivery signals.** With the Rust engine no longer queuing plaintext (`pending_sends` removed for fail-fast `send_text`), the app router is the only retry owner, and `MainActivity.onDestroy()` calls `stop()` — so an ordinary activity teardown mid-send must still hand the router its failure or the row stays "Sent" with its bytes neither delivered nor re-queued. **This took two attempts:** moving the inbox clear out of `stop()` into `MeshRadio.discardPendingDeliverySignals()` was not enough, because `stop()` also incremented the single `deliveryGeneration`, and `reportSendFailures` filtered on it — so the failure was still dropped, just one layer lower. The two jobs are now separate counters: `deliveryGeneration` advances on every `stop()` (a delayed `WriteLink`/`NotifyConn` must never inject stale ciphertext into a restarted radio's queue) while `privacyEpoch` advances only in `MeshGatt.discardAcceptedDeliveries()`, and only the latter gates reporting. Order-independent: whichever of `stop()` / discard runs first, the epoch check drops a report that must not land. Unpinned on both platforms — `stop()` needs a real BLE stack, and the regression is the *call-site and counter wiring*, which is exactly what broke twice.
- **Lost wakeup in the per-peer Marmot fallback flush owner.** `flushPendingMarmot` skips a peer whose `pendingMarmotFlushJobs[npubHex]` is still `isActive`, and `Job.isActive` stays true while the owner's `finally` runs. A send enqueued in that window therefore sat in `pendingMarmotSends` with no owner until an unrelated trigger fired. The owner now re-arms from `finally` when its peer queue is non-empty again. Safe unconditionally in this shape because the snapshot is removed up front and a failed send marks its echo "Couldn't send" rather than being requeued, so re-arming cannot spin. Unpinned: `flushPendingMarmot` needs a constructed `SonarAppState` with an injectable send.
- **Do not re-add a Marmot fallback FIFO without a caller.** The rebase onto main kept main's `mutableMapOf<String, MutableList<PendingMeshMarmotSend>>` for the folded-mesh Marmot fallback while a typed `PendingMarmotOutbox` + `PendingMarmotOutboxTest` rode along from the pre-rebase design with zero production callers. A green test over dead code is exactly the overclaim this ledger forbids, so both were deleted rather than wired. The behaviour that ships is main's: a failed fallback send marks its echo "Couldn't send" and is dropped, and because `createSendEcho` defaults `viaInternet = true` the row satisfies `sonarCanRetryMessage`, so the user gets a retry affordance instead of a silent loss. If ordered auto-retry is wanted later it needs a TTL (the deleted type had none, unlike `SonarOutbox`) and a real caller in `flushPendingMarmot` — and the re-arm below then needs its `drainedQueueEmpty` guard back, because a retained failing head would otherwise spin.
- **Android asynchronous BLE send failures.** `MeshGatt` now carries app-owned text/media metadata beside every queued GATT write/notification, resets the Noise route on a rejected, failed, disconnected, or stuck operation, and exposes one failure for router fallback. Intentional shutdown advances a delivery generation and clears already-buffered app failures so erased plaintext/media cannot be resurrected as a fallback send. Pixel 10 / iPhone 14 Pro Max tracing also reproduced two Android platform hazards: duplicate MTU callbacks started service discovery twice and enqueued every CCC subscription twice (the target instance then failed with GATT status 1), while 512-byte characteristic writes reported success without ever reaching iOS `didReceiveWrite`. Discovery is now single-flight and the shared Rust fragment size keeps every encoded media frame at or below 256 bytes; `recipient_delivery_receipt_round_trips_for_text_and_media` pins the frame ceiling and receipt codec. No JVM test can drive `BluetoothGattCallback`, so the callback ordering still needs an Android driver seam. Keep a physical Pixel/iPhone smoke that covers duplicate callbacks, a media transfer, and a link drop mid-fragment.
- **Marmot fallback lifecycle.** Compose now keeps failed per-peer fallback sends at the head of a typed FIFO, stops the mesh radio, and cancels plus joins setup/fallback/general-outbox jobs before chat erase, account restore, or full wipe. Text, sticker, retry, and media core calls also share the account-mutation gate. `PendingMarmotOutboxTest` pins FIFO ownership and exact-head removal, but no test constructs `SonarAppState` to prove the lifecycle boundary. Apple already serializes text/sticker sends through one chain and now also owns parallel media/retry and direct-chat setup tasks, holding their suspension through host cache/wallet deletion. Existing tests construct `MarmotChatModel`, but cannot inject a controllable send, and no test constructs `SonarAppStore` to pin the full boundary. Close both with injectable app-state/service seams.
- **Sender-side no-receipt timeout is the last piece of BLE delivery state.** Receivers on Apple and Compose Android carry the sender's optional media message id, persist the file/transcript, and return the encrypted `delivered` receipt, so senders distinguish transport acceptance (`Sent`) from recipient persistence (`Delivered`) for text and media. The receiver halves that make a sender retry safe are in place: Compose dedups incoming text and media by the sender-chosen wire id (never matching one of our own rows) and **re-ACKs** a duplicate; Apple keeps a bounded sender-scoped `seenPrivateFileMessageIDs` set — needed because packet dedup keys on `senderID-timestamp-type`, which a retry does not collide with. Two follow-on corrections were needed there: the Apple duplicate check has to run **before** `enforceIncomingFilesQuota` and `saveIncomingFile`, or a retry leaves an orphan copy nothing references while its bytes evict older attachments live transcripts still point at; and the ack must be gated on the transcript write actually reaching disk — `MessageStore.write` swallowed the error, so queue drainage proved only that the write *ran*, and a full disk produced "Delivered" on the sender for a row the recipient loses at restart. `afterPendingWrites(for:)` now returns that outcome and the receipt is withheld on failure. What remains is the *sender* half: a bounded no-receipt timeout that re-enters the ordered outbox under the same id and gives up as "Couldn't send", gated on peers that have proven they ack (a stock bitchat peer never returns a media receipt, so an ungated timeout would spam it or wrongly fail a delivered message). Until then a row whose receipt is lost stays `Sent`, recoverable only by the user re-sending. None of the receiver dedup/re-ACK/durability paths is pinned: they need a constructed `SonarAppState`, or a `BLEService` plus an injectable failing store. Compose Desktop handles text receipts but returns `false` for `sendMeshMedia`; native macOS shares the Apple media implementation — an explicit platform gap, not evidence desktop media passed this path.
- **Content shared into Sonar must never be sent without a chosen recipient.** The iOS share extension staged into App Group `UserDefaults` and the app's `checkForSharedContent` called `chatViewModel.sendMessage(...)` on next foreground. With no `selectedPrivateChatPeer` that path falls through to the **public mesh broadcast** (`ChatViewModel.sendMessage`, the `selectedPrivateChatPeer != nil` branch), so a link shared from Safari went to everyone in BLE range rather than the person the user meant — and it targeted the legacy bitchat view model, not the `SonarAppStore` the UI actually renders, so the user often saw nothing at all. Both platforms now route every share through a recipient picker: iOS `SonarAppStore.ingestPendingShares` → `SNShareSheetContent` → `sendPendingShare(to:)`, Compose `SonarAppState.handleSharedContent` → `Screen.ShareTo` → `sendPendingShare(chat)`. Android's old behaviour was different but also wrong — shared text was written into the Search *query field* (`SonarSearchScreen`), which read as searching for the link. **What is pinned:** the pre-recipient classification only — `SharedContentTest` (invite-vs-picker-vs-empty routing, filename/MIME normalisation) and `SonarSharePayloadTests` (staging format, path-escape-safe filenames, caps). **What is not:** that the picker is the *only* way a share reaches a send. Both `sendPendingShare` implementations need a constructed `SonarAppStore` / `SonarAppState` — the same root cause as the gaps above — so nothing stops a future call site from reaching `sendMessage`/`send` directly with share content again. That is the invariant that broke, and it is unguarded.
- **An app extension's resources must actually be target members.** `bitchatShareExtension` had a Sources build phase and nothing else: no `PBXResourcesBuildPhase`, and the target was not in any `fileSystemSynchronizedGroups`. `bitchatShareExtension/Localization/Localizable.xcstrings` therefore never reached the `.appex`, and every `String(localized:)` in the extension rendered its raw key — users saw a black sheet reading `share.status.shared_link`. Note the shape of this bug: the catalog existed, was fully translated into 16 locales, and a source-level localization check would have passed. Only the *bundle* was wrong. `scripts/check-share-extension-resources.sh` (CI: `.github/workflows/share-extension.yml`) parses the project file and fails without the fix — verified by reverting the target block and re-running. It is deliberately not cited as `Guarded by:` because it is a shell check, not a test in this ledger's citation grammar, and `scripts/check-regression-ledger.sh` would not resolve it. **What it checks:** the target has a Resources phase, carries its synchronized group, excludes `Info.plist`/`.entitlements` from that group, and that every key `ShareViewController` asks for exists in every locale. **What it does not:** that the strings are correct, or that the extension behaves. iOS is not built in CI (see below), which is why this had to be a project-file parse rather than an Xcode-level guard.
- **A degraded RNG path must never succeed quietly.** Five of seven production `SecRandomCopyBytes` call sites discarded the `OSStatus`. `SecRandomCopyBytes` leaves its buffer untouched on failure and every caller started from a zero-filled buffer, so an RNG failure yielded an all-zeros NIP-44 nonce, an all-zeros geohash device seed (identical derived private keys, then persisted to the keychain), and replayable verification nonces. Same shape in Rust (`let _ = getrandom(..)` in `media_staging.rs`) and in Compose (mesh/pay/trill ids from clock-seeded `kotlin.random` while iOS used CSPRNG-backed `UUID()`). Note the shape: nothing crashed, nothing logged, and every unit test passed — the failure is invisible until someone enumerates your keys. This is the COLDCARD firmware bug class (Block, 2026-07). `scripts/check-rng-hygiene.sh` (CI: `.github/workflows/rng-hygiene.yml`) fails without the fix — verified by reintroducing each defect, including the four bypasses a review panel found against the first draft of the script. Like the share-extension check above it is deliberately not cited as `Guarded by:`: it is a shell check, not a test in this ledger's citation grammar. **What it checks:** every `SecRandomCopyBytes` has `errSecSuccess` on its own line (a window search let an unchecked call inherit a neighbour's guard); every `getrandom` statement propagates or panics (`.ok()`, `let _res =`, and a bare `is_err()` all still zero the buffer); no `kotlin.random`/`java.util.Random`/`Math.random`/`.random()` token in shared Kotlin, matched on the token rather than the receiver shape (matching `"0123..".random()` was bypassed by hoisting the alphabet into a val — the deleted code, one refactor away). **What it does not:** whether a checked call feeds the right value, `core/vendor/`, or intent. `ios/bitchatTests/SecureRandomTests.swift` reads the 24-byte nonce straight out of the NIP-44 wire format across two encryptions and asserts they differ, which fails against a cached or constant nonce. It does **not** pin *this* bug: `SecRandomCopyBytes` cannot be made to fail without a seam, so the old code passes it too, and iOS tests still do not run in CI. The failure branch is guarded only by the shell check. **On the NIP-44 severity specifically:** an earlier draft of this entry claimed a zero nonce meant keystream reuse against a fixed per-peer conversation key. That is wrong for this implementation — `encrypt`'s only callers (`createSeal`, `createGiftWrap`) each pass a per-message *ephemeral* key, so the conversation key already varies per message. The fix is defence in depth against the spec-conformant shape (NIP-17 seals with the sender's long-term key), not a live hole that was being exploited.
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
- **Disabled-control contrast and the claim-field tap target.** `SNPrimaryButton`'s disabled state was an opacity fade over an accent fill, which in dark mode put the near-black `onAccent` ink on a dark capsule and made the label unreadable — live on onboarding `Continue`, the Restore account sheet, and the username Claim button. Now a neutral chip (`disabledFill` / `onDisabled` / `disabledStroke`) on both platforms; the stroke exists because a bare `surface2` chip is indistinguishable from the `surface2` text inputs it sits next to (New group stacked three identical pills). Nothing pins any of it: there are 13 `SNPrimaryButton` call sites across `ios/` and `apps/sonar/`, the two platforms' disabled treatments are kept in lockstep only by the paired token names, and no test on either side renders a disabled control or asserts a contrast ratio. The username field's tap-to-focus (`@FocusState` + `simultaneousGesture` on Apple, `FocusRequester` + `clickable` on Compose) is equally unpinned — SwiftUI/Compose hit-testing needs a UI-test harness neither app has. Verified by hand in the iOS Simulator only; the Compose side has been compiled but never run.

- **Compose connectivity UI must follow the relay latch, not `started`.** The
  home status chip, the Connections sheet and Settings → Connection all read
  `SonarAppState.started` — which only means the local encrypted core booted —
  so a relay outage still rendered "Online · reaches anyone" and "Internet:
  Connected · Nostr relays". The only signal the user ever got that relays were
  down was `startRelayConnection()` toasting the raw core error
  (`relay connect failed: no relay connected within timeout`). Since #354's
  background invalidate every ordinary resume re-runs the attach, and a failed
  attach leaves the previously installed node in place, that toast fired over
  conversations that were visibly sending and receiving — an alarm on the one
  surface that was working, and silence on the one that was not. All four
  surfaces now read `relayOnline` (mirrors `SonarCore.isRelayConnected()`,
  refreshed at every attach outcome, at the background invalidate, at teardown
  and on the heartbeat), matching iOS `SonarAppStore.online`, which is already
  gated on `marmot.relayConnected`; the failure path logs via `sonarLog` like
  iOS does. **Pinned:** only the retry schedule
  (`RelayConnectionPolicyTest.first_connect_failure_retries_fast_in_foreground`
  / `sustained_connect_failure_backs_off` /
  `backgrounded_attach_never_uses_the_fast_retries`, plus
  `RelayConnectionPolicyDesktopTest.unfocused_desktop_window_keeps_the_fast_retries`
  for the half that cannot live in `commonTest` — the schedule takes
  `backgroundSuspendsSockets` rather than reading the platform actual precisely
  so both halves stay assertable, since alt-tab on desktop suspends nothing and
  must not be slowed to the mobile backoff). **Not pinned:** that no UI
  surface reads `started` for internet state again, that the failure path stays
  toast-free, and that `relayConnecting` is cleared on the first failure — all
  three need a constructed `SonarAppState` (same root cause as the gaps above).
  A fifth surface hand-reading `started` is exactly the original bug and nothing
  would catch it. **The `relayConnecting` half is the sharper hole:** self-review
  caught that leaving the flag up for the whole outage made
  `StatusChipPill`'s `else -> "$meshCount nearby on Bluetooth"` branch
  unreachable — the chip's offline copy, dead in exactly the state it exists
  for. That bug lives in the interaction between a Compose flag and a `when`
  branch order, which no test reachable today could see. If the chip's branch
  order is ever rearranged, re-check that a sustained outage can still fall
  through to the mesh count.
- **A failed relay attach must still run the local half of startup.**
  `startRelayConnection()` `continue`d on failure *before* `completeLocalStartup()`,
  despite that function's own contract ("runs on every attach outcome … must not
  wait on a healthy latch"). An offline cold start therefore had no conversation
  listener, no Marmot wake loop, no BLE discovery-policy update and no invite
  drain until relays finally came up — the local-first rule inverted by control
  flow rather than by design. Unpinned for the same reason as above.

- **A wallet backend must not lose its node handle to a failed teardown (PR #456).** `SonarWallet.stopNode()` (`ios/localPackages/SonarWalletKit/Sources/SonarWallet.swift`) has carried a comment since it was written: retain the native owner when `disconnect` throws, because a destructive caller that drops the only handle then deletes or reopens the same SQLite store underneath a node that is still running. The Rust `BreezWallet::disconnect` reintroduced exactly that — `take()` before the await — and it was caught in review rather than by anything mechanical. The failure is quiet: a failed teardown leaves a live node holding the working-dir SQLite lock while `is_connected()` reports `false`, so the next `connect()` opens a *second* node over one store and `wipe_local_storage()` sails past its `is_connected()` guard. Fixed by clearing the handle only after teardown returns `Ok`. **A comment on one platform is not a guard**, which is the whole point of this line existing: the invariant now has three implementations to hold it (Swift, the Rust backend, and whatever backs Cashu/CDK later).

  Two adjacent wallet-lifecycle invariants ride along, both learned from this repo's 0xdead10cc rounds and both now written into the `WalletBackend` trait docs (`core/sonar-wallet/src/traits.rs`) rather than left to memory:
  - **`disconnect` must never park behind an in-flight `connect`.** The first fix attempt used one mutex for both, which makes a suspend-time close wait out a full `LiquidSdk::connect` (esplora + Boltz setup, tens of seconds) — R-016's shape, one layer down. It is now a short critical section plus a generation counter: `disconnect` bumps the generation and returns; a `connect` that raced it discards the handle it produced instead of publishing a node nobody asked for.
  - **Host event callbacks must not run on the backend's own runtime threads.** Breez delivers events on tokio workers and every backend method is a `block_on`, so a listener that reacts by calling back in (`balance()` on `Synced` — which the docs *instruct*) panics with "Cannot start a runtime from within a runtime", and the unwound task stops event delivery for good. Events now cross an `mpsc` channel to a dedicated OS thread, which also keeps a slow host callback from stalling breez's event loop (it awaits listeners sequentially under a read lock).

  **Unpinned, and honestly so.** All three need a live `LiquidSdk` — a connected node, a failed teardown, a real event — none of which the island can fabricate; `BreezWallet` has no injectable SDK seam. What *is* pinned is everything reachable without one: `stable_id`, `net_amount_sats`, `map_status`, the note precedence, and the wipe-path guard (`core/sonar-wallet-breez/src/lib.rs` tests). Writing those found a real id-shadowing bug, so the pure half was worth pinning on its own. Closing the rest means a trait-level fake SDK, and it should land before the iOS notification-extension cutover, where a wallet opened cross-process against the same store is the highest-risk step of the train.
