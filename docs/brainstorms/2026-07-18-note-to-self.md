# Clarified Problem Statement — Note to Self

**Goal:** Ship a Signal-style “Note to Self” chat: a normal Sonar Marmot conversation with only you as member, always pinned in the chat list, full chat surface (text/media/stickers/etc.), never notifying, on both iOS and Compose.

**Constraints:**
- Cross-platform (`ios/` + `apps/sonar/`) in the same change, or explicit tracked gap.
- Local-first: pinned row and open/send must not wait on relay connect or KeyPackage fetch (XChat-style pending → reconcile is allowed).
- Must reuse the normal Marmot transcript/send/media pipeline — not a separate notes product.
- `Client::start_dm` already rejects self (`"direct message requires another member"`); cannot be a self-DM via that API.
- Silent: no local/OS notifications for this conversation (sender is always self).
- Preserve chat-type invariants in `docs/CHAT-TYPES.md` — this is a third *kind* or a well-marked pure-Marmot solo group, not mesh-folded.
- Signal-First: study Signal Note to Self for list placement, icon/label, and “no notify when sending to self”; adopt patterns that fit Marmot (solo MLS group + marker), not Signal’s multi-device sync envelope as v1 requirement.

**Non-goals:**
- Linked-device sync product work beyond “solo Marmot group already syncs via relays if/when multiple clients share the same nsec.”
- Disappearing messages, folders, or note-taking UX beyond the normal chat surface.
- Mesh/BLE leg for Note to Self.
- Payments-to-self as a special product (if the composer exposes pay, it can follow normal chat rules or be hidden — defer unless trivial).

**Success criteria:**
- After onboarding, chat list always shows a pinned “Note to Self” row (special label/avatar), even offline / before first open.
- Opening it paints from local storage; typing/sending works with local echoes; background reconcile creates/finds the solo Marmot group.
- Text, images/files, stickers, and other existing composer actions work the same as a normal Marmot chat (or deferred items are listed with platform + follow-up).
- Sending never produces a user-visible notification on the sending device.
- Only one Note to Self conversation per account (idempotent ensure; survives restart).
- Guarded by tests: core ensure/idempotency; app-layer pin + notification suppress (or ledger entry if UI-only hard to unit-test).

## Approaches Considered

### Approach A: Solo Marmot group via `ensure_note_to_self`
- Sketch: Add core API that finds a group marked as Note to Self (dedicated description/marker, analogous to `SONAR_DIRECT_DM_DESCRIPTION`) or creates one with `create_group(..., member_key_packages: [])` so only the local identity is a member. Apps call ensure on session start, pin the row at top of the list, route open/send through existing `openChat` / Marmot transcript paths, and suppress notifications for that group id.
- Affected files: `core/sonar-core/src/client.rs`, `core/sonar-core/src/marmot.rs`, UniFFI; `SonarAppState.kt`, `SonarAppStore.swift`, chat-list UI, notification router; `docs/CHAT-TYPES.md`.
- Tradeoffs: Gains full surface + relay durability with minimal new UI. Costs: need a stable marker + migration if duplicates appear; empty-member MLS create must be verified against MDK. Doesn’t solve “row before group exists” unless ensure is local-fast.
- Effort: M

### Approach B: Lift `start_dm(self)` and treat as 1:1 with own KeyPackage
- Sketch: Allow `start_dm` when peer == self, fetch/publish own KeyPackage, create a “DM” that includes self twice in the member list semantics.
- Affected files: same as A, plus DM dedup (`find_dm_group_with` / `is_reusable_dm_group`).
- Tradeoffs: Looks like “normal DM” in code, but fights existing guard and DM folding logic; awkward MLS welcome-to-self; higher regression risk in chat folding (`docs/CHAT-TYPES.md`). Little product gain over solo group.
- Effort: M–L (risk-heavy)

### Approach C: Local pending Note to Self + background solo-group reconcile (recommended shape of A)
- Sketch: On session ready, apps immediately insert a pending/pinned Note to Self conversation (stable local id), paint and accept sends with echoes/queue; background call `ensure_note_to_self` (Approach A’s core API) and reconcile the pending row to the real group id — same pattern as pending DMs/groups.
- Affected files: Approach A plus pending-conversation paths in `SonarAppState.kt` / `SonarAppStore.swift` (and any core pending helpers already used for instant chat creation).
- Tradeoffs: Best match for pinned-always + XChat/local-first rules; slightly more reconcile edge cases (send before group id exists). Still one conversation kind from the user’s POV.
- Effort: M

## Recommendation

**Approach C** (with Approach A’s core solo-group API underneath). User intent is “a normal Sonar chat with myself,” not a new notes store; `start_dm(self)` is already illegal, so a marked solo Marmot group is the right wire model. Pending-first ensures the always-pinned row and composer never wait on relay. Notifications stay suppressed by group marker/id on both platforms.

## Open questions

- Exact MLS marker: dedicated description string vs. group name “Note to Self” vs. core-owned flag in conversation summary — prefer description/marker like direct DMs so rename can’t fork identity.
- Whether payments/call actions are hidden in the Note to Self composer (likely hide — low value, avoids weird self-pay UX).
- Multi-device: two installs with the same nsec each calling ensure — must converge on one group (find-by-marker across local groups; relay discovery of an existing solo self-group if needed).
- Unread badge on Note to Self: Signal keeps the thread; recommend no unread badge for self-sends (or treat as always-read on send).

## Decisions already made (from brainstorm answers)

1. Job: notepad now + sync-ready later without rewrite → C
2. Transport: real Marmot (normal Sonar chat shape) → B, implemented as solo group not self-DM
3. Entry: always-visible pinned chat-list row → A
4. Surface: full chat surface → C
5. Notifications: never on sending device → A
