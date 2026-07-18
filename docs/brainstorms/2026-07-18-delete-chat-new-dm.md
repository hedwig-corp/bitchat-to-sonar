## Clarified Problem Statement

**Goal:** Make per-chat delete (and group leave) actually clear local MLS state so the same entry points (Search / contact / peer) create a brand-new secure conversation — for both people after an nsec-only restore or other dead-chat case.

**Constraints:**
- Cross-platform: `ios/` + `apps/sonar/` (and core behavior both call).
- Keep Signal-style local-first: delete must not block on relay; new DM setup may use network in background after local pending paint.
- Preserve intentional `start_dm` reuse for *healthy* existing 1:1 groups (don't break "tap peer again opens same chat").
- Delete stays local-only for DMs (peer not notified); multi-member uses leave (MLS membership update) as today.
- Account Key Durability / nsec-restore semantics unchanged — this is conversation repair, not chat backup.

**Non-goals:**
- Blossom / multi-device MLS / recovering old transcript history after wipe.
- Auto-detecting "peer reinstalled / can't decrypt" or soft failure hints (deferred).
- Changing wipe / erase-all-chats product copy beyond what's needed for this fix.

**Success criteria:**
- After Delete chat on a 1:1 Marmot DM, core `groups()` no longer contains that MLS group (or any duplicate 1:1 with same peer), conversation index/folds/UI mappings are gone, and the next `startChat` / `start_dm` for that peer returns a **different** group id and delivers a new welcome using the peer's current KeyPackage.
- Same for mesh-folded rows: deleting the visible chat removes mesh transcript **and** all folded White Noise legs for that peer.
- Multi-member: Leave removes local membership so the user can be re-invited / re-join; admin re-add with fresh KeyPackage works; old left group is not silently reused as a DM.
- Both platforms expose working delete/leave from the home list (and existing profile entry points); errors are not swallowed.
- Guarded by a core test: `delete_group` then `start_dm` → new group id (today only `delete_group_removes…` and `start_dm_reuses…` exist separately). Mirror call-site coverage on iOS + Compose where practical; note platform gap if iOS tests still don't run in CI.
- Regression: healthy "open existing DM" still reuses one group (R-style: don't break reuse).

**Observed failure modes (why "delete doesn't work"):**
- Core `start_dm` reuses via `find_dm_group_with` if MLS group still present (`client.rs`).
- App layers short-circuit before create: iOS `startChatReturningId` / `directGroup(forNpub:)` returns existing id; Compose `startChat` / `marmotGroupForNpub` opens existing.
- iOS `deleteChat` fires `deleteGroup` in a detached `Task` with errors easy to miss; Compose `deleteChat` uses `runCatching` in places.
- No e2e pin that delete → start_dm must mint a new group.
- Duplicate 1:1 groups / fold maps can resurface a "deleted" peer chat after refresh if not all ids are purged.

## Approaches Considered

### Approach A: Fix the delete invariant (recommended)
- Sketch: Treat "delete then start again = new MLS group" as a hard invariant. Harden `SonarClient::delete_group` + app `deleteChat`/`deleteMarmotChat`/`leaveGroup` so MLS state, outbox, conversation index, fold maps, and duplicate peer groups are fully cleared and awaited before list refresh. Add core test `delete_then_start_dm_creates_new_group`. Keep normal reuse when a group still exists. Extend the same completeness to multi-member leave so re-invite/re-join is possible.
- Affected files: `core/sonar-core/src/client.rs`, `core/sonar-core/src/marmot.rs`, `core/sonar-core/tests/e2e.rs`; `ios/.../SonarAppStore.swift`, `MarmotChatView.swift`, `SonarHomeScreen.swift`; `apps/sonar/.../SonarAppState.kt`, `SonarCore*.kt`, contact/home screens.
- Tradeoffs: Fixes root cause without new user-facing verbs; does not add "Restart conversation" copy. Requires careful async/await so UI doesn't reopen a half-deleted group.
- Effort: M

### Approach B: Force-recreate API in core
- Sketch: Add `start_dm_force_new(peer)` (or flag) that deletes any reusable 1:1 with that peer then creates + welcomes. Apps call it from startChat only after an explicit delete, or expose as recreate. Leave/reuse path for happy taps unchanged if apps still call plain `start_dm`.
- Affected files: `client.rs`, `sonar-ffi`, UniFFI bindings, both app `startChat` bridges; tests for force vs reuse.
- Tradeoffs: Clear escape hatch; risks apps calling force too often (chat split / duplicate welcomes) or still calling plain start after a broken delete. Doesn't fix incomplete delete by itself.
- Effort: M

### Approach C: Recovery UX + delete fix
- Sketch: Do Approach A, plus a visible "Start new secure chat" / reset affordance on contact or dead-chat surfaces for DMs, and for groups a leave + "ask admin to re-add" / re-join via invite link path with copy that explains nsec-restore.
- Affected files: same as A, plus `SonarContactProfileScreen` (both), group info screens, strings/i18n.
- Tradeoffs: Better discoverability for both users; larger product/i18n surface; user asked for same entry points (4A), so extra buttons are optional polish on top of A.
- Effort: L

## Recommendation

**Approach A.** The product already has Delete / Leave and the intended recovery path is "delete, then use the same start-chat entry points." Evidence points to incomplete local purge + UI/core reuse short-circuits, not a missing feature. Pin the invariant in core, make both apps await a complete delete (including folds/duplicates), then verify Search/contact/peer start creates a new DM. Pull multi-member leave completeness into the same pass so re-invite works; defer Approach C copy unless delete remains undiscoverable after A.

## Open questions

- Confirm on-device repro: after Delete, does the row vanish but `startChat` still return the old group id (reuse), or does the row reappear after refresh (resurrect)?
- For groups: is "admin re-adds with new KeyPackage" enough for v1, or must invite-link re-join also be verified in the same change?
- Should deleting a DM while the peer still has the old group leave them with one dead chat + one new welcome chat (expected today), and is any cleanup guidance in-scope later?
