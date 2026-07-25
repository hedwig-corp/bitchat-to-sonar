# Plan: delete-chat-new-dm

**Goal:** After Delete chat (DM) or Leave (group), the same start-chat entry points mint a new MLS conversation instead of reusing a dead local group.

**Affected files:**
- `core/sonar-core/tests/e2e.rs` — add `delete_then_start_dm_creates_new_group`; keep reuse test green
- `core/sonar-core/src/client.rs` — only if delete/leave leaves a reusable corpse (audit `leave_group` + `find_dm_group_with`)
- `ios/bitchat/Views/Sonar/SonarAppStore.swift` — await full delete/leave purge; cancel pending DM setup; surface errors; purge duplicate/fold legs
- `ios/bitchat/Views/MarmotChatView.swift` — stop swallowing `deleteGroup` errors (`try?` → propagate)
- `apps/sonar/composeApp/.../SonarAppState.kt` — same await/cancel/error semantics for `deleteMarmotChat` / `deleteMeshDm`
- `apps/sonar/composeApp/.../SonarCore.android.kt` (+ jvm) — `deleteChat` must propagate failures (not `runCatching` → Unit)
- `docs/brainstorms/2026-07-18-delete-chat-new-dm.md` — ship with the change (already written)
- Optional: `docs/REGRESSIONS.md` — new R-entry if we add a real failing-without-fix guard

**Approach:** Approach A from the brainstorm. Core already deletes MLS state correctly when called; the bug is incomplete/raced app purge + swallowed errors so `start_dm` / UI short-circuits still see the old group. Fix: (1) pin core invariant with combined e2e, (2) make both apps await durable delete of all duplicate 1:1 ids + folds before refresh, (3) cancel in-flight pending DM setup for that peer, (4) surface delete/leave failures instead of optimistic-only UI clear that resurrects on refresh. Preserve healthy `start_dm` reuse when the group was not deleted.

**Edge cases:**
- Race: UI clears mappings then user immediately startChat while MLS delete still in flight → reuse old id
- Duplicate 1:1 groups / mesh-folded legs leave one id behind → `find_dm_group_with` or `marmotGroupForNpub` reopens corpse
- `leave_group` publish fails → group may remain in MLS storage; must not look like a reusable DM after leave attempt, or surface failure and restore UI
- Pending `directChatSetupTasks` / `pendingMarmotSetupJobs` completing after delete
- Peer still holds old group (expected dual-chat) — out of scope to clean peer side
- Snapshot/fold blob resurrection after half-failed delete

**Test plan:**
- Core: `delete_then_start_dm_creates_new_group` — start_dm, delete_group, start_dm again → different GroupId; second welcome path still works
- Core: existing `start_dm_reuses_existing_direct_group` still passes
- Core: existing `delete_group_removes_a_single_chat_locally` still passes
- Manual / follow-up: iOS + Compose delete from home → start from Search → new empty chat (iOS tests not in CI)

**Conventions to follow:**
- Cross-platform Feature Rule — ios + apps/sonar together
- Signal-Comparable / local-first — await local MLS purge, do not block delete UI on unrelated relay sync; leave may need membership publish (existing)
- Regression ledger honesty — prefer core call-site test; don't overclaim app coverage
- Do not swallow delete errors
- Do not include unrelated `MarmotService` drain-queue WIP

**Open questions / risks:**
- Leave publish failure: prefer fail-visible + keep row vs force local delete anyway (lean: surface error, do not claim leave succeeded)
- Whether to add REGRESSIONS.md R-entry in same PR (yes if test is the real call site)

**Estimated size:** M (50–200 LOC)

**From brainstorm:** `docs/brainstorms/2026-07-18-delete-chat-new-dm.md` — Recommendation A
