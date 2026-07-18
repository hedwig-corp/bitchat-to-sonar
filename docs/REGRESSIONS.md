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

**Call sites:** iOS production (Phase 3 cutover) `SNTranscriptCollectionHost.swift::SNTranscriptCollectionViewController` (`TranscriptTailPinLatch` via `TranscriptEngine` + `captureWasAtTail` in `updateOwnedInsetsFromChrome` + contentSize-growth re-pin); iOS fallback `SonarComponents.swift::SNMsgList` (`SNTailPinLatch` + `SNUserScrollObserver` + sentinel/count/viewport events); Compose production `packages/transcript-engine-compose` (`TranscriptHostScrollEffects` / Sonar shim `TranscriptPolicyHostScaffold.kt`) (`TranscriptTailPinSession` + `decideInsetChange` Pin/Lockstep); Compose fallback `App.kt::TranscriptTailPinning` (`TranscriptTailPinner` → `TranscriptTailPinSession` / `packages/transcript-engine-policy`).

**Guarded by:** `SNTailPinLatchTests.shrinkKeepsPinningWhileSentinelIsCovered`

**Also guarded by:** `SNCollectionHostInsetTests.ownedInsetUsesViewportSpaceNotContentSpace`, `SNCollectionHostInsetTests.ownedInsetStableAcrossScrollPositions`, `SNCollectionHostInsetTests.mediaHeightFingerprintChangesWhenDimsArrive`, `SNCollectionHostInsetTests.floatingComposerGapRequiresSingleKeyboardOwner`, `SNTailPinLatchTests.keyboardFrameChangeCapturesVisibleTailBeforeShrink`, `SNTailPinLatchTests.expandKeepsPinningAfterPhantomKeyboardInsetClears`, `SNTailPinLatchTests.preLayoutKeyboardClampIsNotUserScroll`, `SNTailPinLatchTests.tailRevisionTracksOnlyCountAndLiveEdge`, `SNTailPinLatchTests.tailSnapBurstCoalescesUntilDelivery`, `SNTailPinLatchTests.appendedOutgoingRowAtTailFollows`, `SNTailPinLatchTests.replacedTailAtCapacityStillFollows`, `SNTailPinLatchTests.nonKeyboardLayoutTheftSnapsBack`, `SNTailPinLatchTests.keyboardShowWithoutShrinkDoesNotLeaveStickyPin`, `SNTailPinLatchTests.userScrollAwayIsRespectedAfterTailReturns`, `SNTailPinLatchTests.nonTouchScrollTowardTopCountsAsUserScroll`, `SNTailPinLatchTests.programmaticTailFollowIsNotUserScroll`, `SNTailPinLatchTests.downwardDecelerationAtVisibleTailIsIgnored`, `SNTailPinLatchTests.layoutDrivenUpwardOffsetIsNotUserScroll`, `SNTailPinLatchTests.nonTouchHistoryScrollAfterResizeStillCounts`, `SNTailPinLatchTests.anchoredOpenNeverPins`, `SNTailPinLatchTests.keyboardDismissOvershootIsClampedToContentBounds`, `SNTailPinLatchTests.transcriptOpenUsesBottomAnchorOnlyWhenFullyRead`, `SNTailPinLatchTests.fullyReadOpenResnapsUntilLiveEdgeLands`, `SNTranscriptScrollPolicyTests.insetFollowPinsWhenWasAtTail`, `SNTranscriptScrollPolicyTests.insetFollowLockstepsWhenAwayFromTail`, `SNTranscriptScrollPolicyTests.insetFollowIgnoresWhileDraggingOrPrepending`, `SNTranscriptScrollPolicyTests.captureWasAtTailBeforeInsetChangeMatchesSignal`, `SNTranscriptScrollPolicyTests.openActionFullyReadIsLiveEdge`, `SNTranscriptScrollPolicyTests.openActionPendingUnreadIsUnreadDividerEvenWithoutResolvedId`, `SNTranscriptScrollPolicyTests.openActionUnsetCaptureIsProvisionalLiveEdge`, `SNTranscriptScrollPolicyTests.openActionSettledZeroIsLiveEdge`, `SNTranscriptScrollPolicyTests.openActionSettledNonZeroIsUnreadDivider`, `TranscriptScrollPolicyTest.openAction_unsetCapture_isProvisionalLiveEdge`, `TranscriptScrollPolicyTest.openAction_settledZero_isLiveEdge`, `TranscriptTailPinnerTest`, `TranscriptTailPinningUiTest` (Compose, real `LazyListState` wiring), `TranscriptScrollPolicyTest.session_keyboardShrink_atTail_pinsSnap`, `TranscriptScrollPolicyTest.insetChange_atTail_pins`, `TranscriptScrollPolicyTest.insetChange_userScrolling_ignores`, `TranscriptScrollPolicyTest.insetChange_prepending_ignores`.

**Coverage (honest):** Production iOS is the Phase 3 collection host: owned bottom inset from composer occlusion in **viewport** coordinates (`snCollectionHostOwnedBottomContentInset`, `.never` adjustment — converting into the scroll view's content space collapses the inset at the tail of a long chat; guarded by `SNCollectionHostInsetTests`), pre-measured cells (`SNTranscriptRowHeightCache` + `sizeForItemAt`), and `SNTailPinLatch` + 10 ms coalescer on inset Δ / contentSize growth. The representable must `.ignoresSafeArea(.keyboard)` so SwiftUI does not shrink the host while `keyboardLayoutGuide` also lifts the composer — otherwise the bar floats ~one IME height above the keyboard (`snCollectionHostFloatingComposerGap`; helper-level only — device smoke still confirms the modifier). Kill-switch fallback remains `SNMsgList` (sibling composer ⇒ `snOwnedTranscriptBottomContentInset` = 0; still wants SwiftUI keyboard avoidance). Compose production is `TranscriptHostScrollEffects` in `transcript-engine-compose` (real Pin/Lockstep; Sonar shim `TranscriptPhase2ScrollEffects`); legacy `TranscriptTailPinning` is kill-switch only. The Swift tests pin latch/open-policy helpers and inset coordinate math — not that `scrollTo` lands (iOS tests still do not run in CI). The Compose UI test is the stronger guard for pin. Device smoke remains the merge gate for keyboard pin, unread open, and mesh-image remeasure.

**History:** #283 (Compose) -> #303 (iOS, notification + fixed delays; incomplete) -> this fix (previous-frame pinner + explicit user-scroll observation, Signal `wasScrolledToBottom` shape) -> phantom empty band (viewport expand ignored) -> rejected LazyVStack spacer / `contentSize` top-inset experiments that yanked GIAN / Ocean LCI Alert or opened DMs mid-history -> conditional `defaultScrollAnchor` for fully-read opens only -> alpha.11 still opened mid-DM (one `scrollTo` vs under-measure; latch unpinned until sentinel) -> `needsLiveEdgeOpen` re-snap until live edge lands -> unset unread capture treated as `0` chased the tail then jumped to the divider (fixed: optional settle + hold).

**Rejected:**
- *Fixed-delay double pin after `keyboardWillShow` (#303).* The 0.35s timer races the safe-area animation and anything that settles later (late transport-leg merge, sticker/media decode); one lost race also strands `isNearBottom` at false, disabling every later keyboard open.
- *Unconditional `defaultScrollAnchor(.bottom)`.* Fights unread-anchor opens. Conditional (fully-read only) is what shipped.
- *Dynamic top spacer inside LazyVStack.* `contentSize` includes the spacer ⇒ feedback loop yanked chats (GIAN / Ocean LCI Alert).
- *`contentInset.top = max(0, viewport − contentSize)` from LazyVStack metrics.* `contentSize` under-measures on open ⇒ DMs started away from the last message. Rejected.
- *`.frame(minHeight:alignment:.bottom)` on LazyVStack.* Ignored by LazyVStack.
- *Flipping the ScrollView 180°.* Structurally bottom-anchored, but inverts every gesture/accessibility behaviour and would rewrite the whole transcript surface.
- *Keeping SwiftUI keyboard avoidance alongside `keyboardLayoutGuide`.* Double IME ownership floats the composer ~one keyboard height above the IME and inflates the owned bottom inset so the live edge is clipped under the bar.

**Platform gap:** Compose `LazyColumn` is still top-anchored for short feeds (no `reverseLayout` / fill-height bottom arrangement). Same empty-band class of bug may exist there; follow-up is a Compose short-transcript bottom align that keeps unread-anchor opens intact.

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

## R-012 — An offline send is durable before route setup starts

**Invariant:** A user send accepted before a White Noise route/group exists is written to the encrypted shared-core journal before either host mirrors it in memory. The journal is bounded, idempotent by stable message id, shared by overlapping local/relay nodes for the same database path, checkpointed to the concrete MLS group before replay, and removed only after the normal local send/outbox accepts it. Creator-side group setup also writes a zero-content operation sentinel before setup starts, so restart can reach the operation even when no message was queued. Idempotent group creation records intent before MDK mutation and all signed Welcome events before the first relay publish; restart can therefore discard a provably unpublished group or replay an identical partially-published Welcome set by stable event id. Direct-message setup uses the same recovery path with a deterministic private marker derived from the peer key, so Android, desktop, and iOS cannot reuse a creator-only local route whose Welcome was lost at process death. Explicit deletion is serialized with group creation and persists a cancellation marker before deleting MLS state; the marker survives until the marker group, sentinel, and recovery checkpoint are all cleared, so a crash at any cleanup boundary resumes cancellation rather than recreating the group. Cancelling an in-flight invite accept waits for its setup task, then declines the still-pending Welcome or deletes the already-accepted group before removing the durable host route, preventing a declined row from resurfacing after refresh or restart.

**Breaks as:** Killing Android or iOS while connectivity is scarce loses the send, retry says the media/message is no longer available, or restart creates a duplicate group.

**Call sites:** core `pre_route_outbox.rs::PreRouteOutbox` / `SonarClient.discard_pre_route_group_operation`; iOS `SonarAppStore.restorePreRouteMessages` / `MessageRouter.sendPrivate`; Compose `SonarAppState.restorePreRouteMessages` / `SonarOutbox.restore`

**Guarded by:** `pre_route_outbox.rs::encrypted_journal_survives_restart_and_removal`

**Also guarded by:** `pre_route_outbox.rs::resolved_route_survives_restart_and_is_idempotent`, `pre_route_outbox.rs::enqueue_is_idempotent_but_rejects_id_reuse`, `pre_route_outbox.rs::shared_instance_serializes_overlapping_nodes_without_lost_updates`, `pre_route_outbox.rs::encrypted_journal_replaces_existing_file_on_update`, `pre_route_outbox.rs::pending_group_creation_rejects_aggregate_recovery_material_before_save`, `pre_route_outbox.rs::discard_group_operation_removes_sentinel_and_recovery_together`, `pre_route_outbox.rs::group_cancellation_marker_survives_restart_until_cleanup`, `client.rs::durable_group_operation_finds_the_existing_local_route`, `client.rs::durable_group_operation_discards_group_left_at_intent_checkpoint`, `client.rs::durable_group_operation_replays_partial_welcomes_after_restart`, `client.rs::durable_direct_operation_replays_unpublished_welcome_after_restart`, `client.rs::direct_message_operation_description_is_stable_and_private`, `client.rs::discarding_durable_group_operation_removes_local_group_and_checkpoint`, `client.rs::cancelled_group_operation_finishes_cleanup_after_group_delete_crash`, `client.rs::client_wipe_removes_pre_route_sidecar_and_temporary_file`, `client.rs::durable_group_start_and_discard_share_one_operation_gate`, `marmot.rs::merge_pending_commit_is_idempotent_after_group_creation`, `marmot.rs::wipe_removes_encrypted_pre_route_journal_and_temporary_file`, `SonarOutboxTest.restoreIsIdempotentAndReestablishesTimestampOrder`, `SonarOutboxTest.preRouteContextRoundTripsDelimitersAndUnicode`, `SonarOutboxTest.groupOperationSentinelRestoresRouteWithoutCreatingAnEmptyMessage`, `SonarOutboxTest.resolvedGroupCheckpointUsesConcreteGroupInsteadOfEncodedSetupContext`, `SonarOutboxTest.pendingInviteCancellationDeclinesWelcomeBeforeItCanResurface`, `SonarOutboxTest.recoveredGroupCancellationIsRetiredInsteadOfShownAsFailed`, `SonarConversationRegressionSmokeTests.preRouteRowsUseAndRecognizeThePlaintextRetryIdentity`, `SonarConversationRegressionSmokeTests.recoveredGroupCancellationIsRetiredInsteadOfShownAsFailed`, `SonarConversationRegressionSmokeTests.pendingInviteCancellationDeclinesWelcomeBeforeItCanResurface`, `MessageRouterTests.sendPrivate_queuesThenFlushesWhenReachable`, `MessageRouterTests.sendPrivate_rejectsWhenDurableJournalFails`, `MessageRouterTests.sendPrivate_preservesQueuedOrderWhenTransportReturns`, `ChatViewModelDeliveryStatusTests.offlineRoutingOnlyFailsWhenDurableQueueRejectsTheMessage`

**Partly guarded:** Rust pins encrypted persistence, idempotence, shared-path serialization, route checkpointing, partial-Welcome replay, operation deletion, and panic-wipe cleanup. Compose pins rebuilding a metadata-only group operation without creating an empty echo and maps a resolved group checkpoint to the concrete group instead of its encoded setup context. iOS pins that a fully-offline private send is queued rather than failed, durable persistence rejection is the only rejection branch, and restored setup rows use the platform-local plaintext retry identity. Group creation stores the already-signed Welcomes before publishing and merges the creator's pending commit only after every Welcome reaches a relay; repeating that merge after a cleanup crash is idempotent once OpenMLS is operational. Neither app state can be constructed in tests, so the actual startup scheduling and host per-chat delete/leave calls remain review-guarded. Recovery is deliberately split: local restore runs at the local-Home boundary; relay/group replay starts later and never delays first paint.

**Rejected:** *Host-only arrays/dictionaries.* They disappear on process death, which is common during prolonged offline/background operation.

---

## R-013 — Prolonged offline delivery never exhausts a durable send

**Invariant:** Retry attempts may control bounded backoff/observability but must never make an accepted durable send permanently ineligible. There is no fixed attempt cap and no silent wall-clock TTL expiry. A later relay or peer recovery always gets another send attempt; if the device clock moves backward, a persisted future retry timestamp is rebased to the current clock so only the bounded backoff remains.

**Breaks as:** After enough hours offline, reconnecting does nothing, a message silently disappears after 24 hours, or a device time correction postpones delivery for days or months.

**Call sites:** shared core `outbox.rs::OutboxState.retryable_events`; iOS `MessageRouter.flushOutbox`; Compose `SonarAppState.flushOutboxNow` / `SonarOutbox.remainingAfterFailure`

**Guarded by:** `outbox.rs::automatic_retry_does_not_exhaust_during_prolonged_outage`, `outbox.rs::automatic_retry_rebases_future_timestamp_after_clock_correction`, `SonarOutboxTest.failureKeepsEveryLaterMessageQueuedRegardlessOfAge`

**Rejected:** *A fixed attempt cap or age-based deletion.* Either turns a temporary network outage into permanent message loss without a user-visible recovery path. Per-peer queue caps remain explicit bounded-storage eviction.

---

## R-014 — Subscription repair must replace unchanged cached filters

**Invariant:** Foreground/heartbeat repair force-reissues the stable welcome and group subscriptions after disconnect even when the desired group-id set equals the cached set. Initial subscription failure must also remain retryable.

**Breaks as:** The relay indicator reconnects, but incoming messages/welcomes stay frozen until the process restarts or group membership changes.

**Call sites:** shared core `client.rs::subscribe_marmot` / `subscribe_group_messages(force:)` / `ensure_subscriptions`; iOS and Compose invoke the same core repair after local paint

**Guarded by:** `client.rs::forced_subscription_repair_replaces_unchanged_group_filter`

**Rejected:** *Treating an equal filter as proof of a live REQ.* The cache describes desired state, not the relay socket's current subscription state.

---

## Unguarded

Gaps we know about. Each line is a concrete backlog item; fold it into its `R-`
entry once a test exists. Listing a gap is the point — an entry that overclaims
its coverage is worse than an honest hole, because it stops people looking.

- **R-003, the one-transcript half.** Cited tests pin chat-list dedup and identity routing, not "duplicate groups' messages merge into a single transcript". The merge lives in `SonarAppState.duplicateDirectMarmotChats` (private, needs an instance); `dedupeDirectMarmotChats` — the pure seam the tests use — only covers the chat-list half. Closing it means extracting the transcript-source selection into a pure function, or an injectable `SonarCore`.
- **R-004, account wipe, both platforms.** Now implemented on iOS and Compose, but pinned by no test. The Compose path needs an injectable `SonarCore`; the iOS path needs a constructible `SonarAppStore`, and no iOS test builds one today (`MarmotOptimisticEchoTests` only exercises static functions).
- **Anything needing a `SonarAppState` / `SonarAppStore` instance.** The three gaps above share one root cause: neither app object can be constructed in a test, so only pure helpers are reachable. This is the single highest-leverage testing investment in the repo — see the injectable-core note in the Signal architecture notes. Until then, prefer removing a hazard (as R-001 does with a mandatory parameter) over testing for it.
- **R-012 host scheduling and per-chat cleanup.** The encrypted core journal, metadata-only operation restore, and core atomic discard are pinned, but neither host instance is constructible in tests. A regression that removed `restorePreRouteMessages`, moved replay ahead of local Home paint, or stopped invoking the core discard/delete operation from a host delete/leave path would not fail the cited tests.
- **R-012 authenticated-delivery gap.** This change keeps accepted rows durable across restart and prolonged outages, but does not yet close the final weak-BLE acknowledgement gap. iOS `MessageRouter.flushOutbox` completes the durable row immediately after the void `Transport.sendPrivateMessage` call, and BLE UI paths can mark a message `.sent` after local broadcast. Compose mesh can likewise accept a send into process-memory pending state, while `SonarAppState` currently ignores incoming `DELIVERED` / `READ` payloads. A disconnect or process death after local acceptance but before peer receipt can therefore lose the durable row and show a misleading sent state. The Signal-parity follow-up is a stable-message-id `awaitingAck` durable state retained until an authenticated `DELIVERED`, retried on reconnect, and deduplicated by message id at the recipient, with existing queue caps and explicit user cancellation as the only deletion paths.
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
