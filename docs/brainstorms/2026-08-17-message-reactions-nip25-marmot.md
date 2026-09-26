## Clarified Problem Statement

**Goal:** Add Signal-style message reactions across Sonar chat surfaces, using NIP-25 kind-7 *shape* inside each transport’s privacy boundary (Marmot-encrypted for White Noise interop; not public relay likes), matching the UX in `design/handoff/project/sonar/` (long-press context picker + bubble tallies), while allowing one user to hold multiple emojis on the same message.

**Constraints:**
- Marmot path: unsigned kind-7 application rumors inside MLS (Marmot `03.md` / EE), with `e`/`p`/`k` tags targeting the parent kind-9 (or other) rumor — same pattern White Noise Android uses via `reactToMessage`, **not** publicly signed NIP-25 on relays.
- Stay on current MDK pin; implement send/parse/aggregate in `sonar-core` ourselves. Model APIs so a later MDK/`reactToMessage` upgrade is a drop-in behind the same FFI (`send_reaction` / `toggle` / tallies), not a host rewrite.
- Cross-platform: `ios/` + `apps/sonar/` in the same change (Cross-Platform Feature Rule). Track any transport gap explicitly.
- Local-first: open chat paints from local storage; reaction sync must not block first paint/send/scroll (Signal-Comparable Performance Rule). Optimistic tallies + DB invalidation, same class as WN’s `runOptimisticReactionMutation`.
- UI source of truth: design handoff (`design/handoff/project/sonar/components.jsx` — `BC_REACTIONS`, `ReactionRow`, `MsgList` long-press `bc-ctxpicker`; `theme.css` `.bc-react*` / `.bc-ctx*`). Zip: `Sonar - UX design-handoff (4).zip` (already mirrored under `design/handoff/`).
- Multi-emoji per user (product choice): each `(sender, emoji, target)` is independent; tap again on that emoji removes only that emoji. **Diverges** from the prototype’s Signal “one emoji per person” toggle in `app.jsx` `reactMsg` — keep the visual design; change the mutation semantics.
- Reply precedent: follow the NIP-C7 reply shape (core rumor + host UI + tests on both platforms), including not treating reaction events as chat-list body rows.

**Non-goals:**
- Public Nostr timeline reactions / kind-17 external content reactions.
- NIP-30 custom emoji packs in v1.
- Notification quick-react (WN has it; defer unless trivial after core path).
- Full composer emoji keyboard as the reaction entry point (composer keyboard already exists for stickers/GIFs; reaction entry is long-press picker).
- MDK bump in this change.
- Editing/deleting messages, or reaction-as-chat-row history UI.

**Success criteria:**
- White Noise / Marmot peer can see Sonar emoji reactions on a Marmot message and vice versa (kind-7 rumor interop).
- Long-press opens design-faithful quick picker (`❤️ 👍 😂 😮 😢 🔥`); chips render under bubbles with count + mine accent; chip tap toggles that emoji for self without clearing other emojis the same user already set.
- Same UX on iOS + Compose for Marmot DMs/groups; geohash, mesh BLE, and non-Marmot Nostr DMs either work end-to-end or have an explicit tracked platform/transport gap with follow-up.
- Chat open remains local-first; reaction traffic is background DB write → UI invalidate.
- Core unit tests: encode/decode kind-7, aggregate tallies (multi-emoji same sender), ignore kind-7 as transcript body / chat-list preview; host tests for can-react gating (echo/sending rows) mirroring reply gates.
- Upgrade path documented: when MDK exposes reaction helpers, `sonar-core` switches implementation without changing UniFFI / host call sites.

## Approaches Considered

### Approach A: Core reaction engine + per-transport adapters (phased)
- Sketch: Add `ReactionRef` / tallies on messages in `sonar-core` (aggregate kind-7 by target `e` tag). `Client::send_reaction(group, target_id, emoji)` builds unsigned kind-7 and sends via existing `create_message`. On ingest, classify kind-7 → update tallies on parent, never append as `ChatMessage` body. Hosts mirror reply UX: long-press menu + `ReactionRow`. Phase 1: Marmot. Phase 2: geohash (signed public kind-7 on channel relays — still NIP-25 tags, public by nature of geohash), mesh BLE encode, NIP-17 gift-wrapped kind-7 — each behind the same core API.
- Affected files: `core/sonar-core/src/marmot.rs`, `client.rs`, `sonar-ffi`; `ios/.../MarmotChatView.swift`, `SonarAppStore.swift`; `apps/sonar/.../SonarAppState.kt`, message bubble/composables; design tokens from `design/handoff/project/sonar/`.
- Tradeoffs: Matches WN wire for Marmot; upgrade-friendly; scope C is large — must phase transports. Multi-emoji needs clear retract rule (re-send same emoji = remove that kind-7 / mark retracted; no NIP-09 required if WN uses retract-by-engine — verify against WN before locking).
- Effort: L (Marmot+UI medium; all transports large)

### Approach B: Host-only optimistic UI, protocol later
- Sketch: Paint chips and picker from local host state only; no kind-7 on the wire until a follow-up.
- Affected files: iOS/Compose UI only.
- Tradeoffs: Fast demo; zero WN interop; violates “use NIP reaction” intent; throwaway state.
- Effort: S — reject for product goal

### Approach C: Wait for MDK `reactToMessage` then thin-wrap
- Sketch: Bump MDK to WN’s MarmotKit reaction APIs; hosts call through.
- Affected files: MDK pin, ffi, hosts.
- Tradeoffs: Best long-term interop, but user chose stay-on-current-MDK; blocks shipping; doesn’t cover geohash/mesh.
- Effort: M–L depending on MDK gap — defer as upgrade path, not v1

## Recommendation

**Approach A, phased — affirmed by Socratic check (2026-08-17):** ship Marmot kind-7 hydrate+send + design-faithful UI on both hosts first; track geohash/mesh/NIP-17 as explicit gaps (same host API later). Do not ship Approach B. Keep Approach C as MDK upgrade seam.

Multi-emoji (4B) overrides the handoff’s one-per-person `reactMsg` — UI stays; semantics match WN (per-emoji delete).

## Socratic check (resolved)

1. **Is public NIP-25 the goal?** No — Marmot needs unsigned kind-7 *inside* MLS. Public kind-7 would leak reactions. Approach A’s “shape not public event” is correct.
2. **Can we do this without MDK bump?** Yes. MDK already persists non-chat application kinds; `marmot.rs` already documents that reactions from WN peers are stored but filtered out of the transcript (`Incoming::None` / kind-9-only pages). V1 is hydrate tallies from stored kind-7 + emit kind-7 on send — not invent storage.
3. **Is multi-emoji wrong vs Signal/design?** Product chose multi; WN already implements per-emoji retract via `deleteMessage(reactionEventId)` because target-only unreact drops the wrong emoji. Affirms 4B.
4. **Should v1 include geohash/mesh/NIP-17?** “Everything” as success criteria invites an unbounded PR. Right approach: Marmot+UI ships; other transports tracked gaps with one shared `send_reaction` seam — not three half-broken adapters.
5. **Is host-only UI (B) ever right first?** No — WN peers already send kind-7 into our store; UI-only would still miss inbound reactions and create throwaway state.
6. **Must we wait for MDK reactToMessage (C)?** No for v1; yes as later swap behind the same FFI.

## Open questions (remaining)

- Retract on current MDK pin: WN uses `deleteMessage`; confirm Sonar/MDK expose equivalent soft-delete for application rumors, or ship add-only first with remove tracked.
- Geohash/mesh/NIP-17: documented gaps in PR, not silent omissions.
- Chip tap on others’ emoji adds yours — yes (design + Signal).

## Design / WN references

- UX: `design/handoff/project/sonar/components.jsx` (`BC_REACTIONS`, `ReactionRow`, `MsgList` ctx picker), `theme.css` `.bc-react*`, `.bc-ctx*`
- WN Android: `ui/conversation/reactions/Reactions.kt`, `Controllers.toggleReaction` / `reactToMessage`, optimistic tallies in `CanAcceptReactionTest`
- Marmot: application messages = unsigned Nostr kinds inside MLS; reactions = kind 7
- Sonar precedent: NIP-C7 reply (`ChatMessage.reply`, `send_text_with_reply`)
