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

`scripts/check-regression-ledger.sh` (run in CI) asserts every `Guarded by:` symbol
still exists in the test sources, so entries cannot rot silently when a test is
renamed. It does not check that the test is still *meaningful* — that is on review.

## Hotspot files

Ranked by `fix:` commit count on `main`. The top two are the same conversation
logic written twice; between them they account for ~60 fixes. Changes here have a
measurably high chance of re-breaking something below.

| File | `fix:` commits |
|---|---|
| `apps/sonar/composeApp/src/commonMain/kotlin/chat/bitchat/sonar/SonarAppState.kt` | 32 |
| `ios/bitchat/Views/Sonar/SonarAppStore.swift` | 30 |
| `ios/bitchat/Views/MarmotChatView.swift` | 21 |
| `core/sonar-core/src/client.rs` | 21 |

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

**Guarded by:** `TranscriptDisplayPolicyTest.outOfWindowCanonicalRowFulfillsEchoAndIsAdmitted`

**Also guarded by:** `TranscriptDisplayPolicyTest.windowedCanonicalRowIsNotAdmittedTwice`, `TranscriptDisplayPolicyTest.identicalOutOfWindowRowsConsumeEchoesOneForOne`

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

**History:** #276 deduped by message id -> #288 cleared the dedup state on account wipe (stale state survived a wipe).

**Rejected:** *Dedup on latest-timestamp only.* Drops a genuine second message in the same second.

---

## R-005 — A newer local send must not starve another chat's catch-up

**Invariant:** The missing-message resync floor is derived per conversation from its own local transcript, never from one global latest timestamp.

**Breaks as:** Sending in chat A advances a global watermark past chat B's unfetched messages; B's messages never arrive.

**Call sites:** `core/sonar-core/src/client.rs` (sync watermark / per-group catch-up); consumed by both apps

**Guarded by:** `ConversationRegressionSmokeTest.coldRestartPaintsPersistedOrderThenNewSaraMessageMovesOnlySara`

**History:** #177 (watermark pinning) -> #252 (forced sync skipped the batched fetch). Stated as a rule in `CLAUDE.md` under the Signal-Comparable Performance Rule.

**Rejected:** *One global latest-timestamp floor.* Exactly the starvation above.

---

## Unguarded

Invariants we believe in but that no test currently pins. Each line is a concrete
backlog item; promote it to an `R-` entry when a test exists.

- **iOS-side echo reconciliation.** R-001/R-002 are pinned by Compose tests only. `MarmotChatView.reconciledOptimisticMessages` has no Swift unit test, so an iOS-side regression would not be caught. iOS test infrastructure is thinner (`ios/bitchatTests/`); `SonarConversationRegressionSmokeTests.swift` is the natural home.
- **Account key durability.** `CLAUDE.md`'s Account Key Durability Rule lists five invariants (never delete-before-add, never regenerate on keychain error, etc.). They are blocking correctness rules with no regression test cited here.
- **Duplicate-send.** Nothing pins "one tap produces exactly one canonical row". Worth adding if the duplicate bubble reported in #290 ever proves to be two real rows rather than an echo — that was investigated and left unproven.
