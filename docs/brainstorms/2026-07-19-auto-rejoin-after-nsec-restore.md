## Clarified Problem Statement

**Goal:** When a party loses local MLS state but restores from nsec, the chat heals automatically on top of MDK: the restored client announces recovery, surviving peers re-invite it into fresh MLS groups, and the UI folds the new leg into the existing conversation — no manual delete + restart (R-011 flow) required.

**Decisions (from question round):**
- Interop: **1C** — ship Sonar-only opportunistic, but design the events/semantics as a draft MIP so it can be upstreamed to Marmot/White Noise later.
- Driver: **2D** — restored party publishes a **recovery beacon**; the surviving peer detects it and executes the re-invite.
- Trigger: **3C** — only an explicit beacon signed by the peer's account key triggers auto re-invite; the transcript shows a Signal-style "chat was reset" system notice. No heuristic (KeyPackage-rotation + silence) auto-reset.
- Scope: **4B** — 1:1 DMs and multi-member groups (admin re-adds).
- Transcript: **5A** — new MLS group folds into the same conversation row; pre-reset history stays only on the survivor's side. **Track 5B (survivor re-sends history) as an explicit follow-up.**

**Constraints:**
- Pure application layer on top of MDK as it is today: **MDK has no external-commit / ReInit / external-join processing** (`NotImplemented` in `mdk-core/src/messages/proposal.rs`), so recovery = *new group + welcome via fresh KeyPackage*, never "rejoin old group".
- Wire compatibility: nothing we publish may confuse White Noise/other Marmot clients. Beacon must be a new event kind (ignored by non-Sonar clients), not overloaded tags on 30443/444/445.
- Local-first (CLAUDE.md): beacon publish, detection, and re-invite all run as background relay work; never gate chat open/send/paint. Recovery converges eventually; the manual R-011 path stays as fallback.
- Account Key Durability: beacon publishing must never touch identity persistence; restore flow semantics unchanged.
- Cross-platform: core owns the protocol; iOS + Compose both surface the reset notice and auto-accept behavior.
- Anti-abuse: auto-resetting a ratchet is an attack surface. Beacon is nostr-signed by the account key (inherent), replay-guarded, and rate-limited; a stolen nsec is full account compromise and out of scope.

**Non-goals:**
- History transfer to the restored device (5B — tracked follow-up, needs storage + protocol design).
- MLS external commit / ReInit rejoin (blocked on MDK upstream).
- Multi-device / multi-KeyPackage fan-out.
- Chat database backup (Blossom) — separate effort; this heals *connectivity*, not *history*.

**Success criteria:**
- e2e (mock relay): alice⇄bob DM → bob wipes + restores from nsec → bob's client publishes beacon → alice auto-creates new group + welcome → bob auto-accepts → text flows both ways; alice's transcript shows one folded conversation with a reset notice; old group retired from live subscription.
- e2e group: {alice admin, bob, carol} → carol restores → beacon → exactly one admin re-adds carol with her fresh KeyPackage (dedup of concurrent re-adds asserted); carol auto-accepts because the welcome matches her own outstanding beacon.
- Replay/idempotency test: same beacon delivered twice / out of order causes exactly one reset; a beacon older than the last decrypted inbound message from that peer is ignored.
- Healthy-path regression: no beacon ⇒ behavior identical to today (`start_dm_reuses_existing_direct_group` stays green; no spurious resets from ordinary KeyPackage republish).
- Sonar-sim: group-scale run with one member recovering mid-session converges (ties into `docs/GROUP-SCALE-SIM.md` fork/convergence assertions).

## Protocol Sketch (Approach A — recommended)

**New addressable event, "Marmot Recovery Beacon" (draft MIP; e.g. kind 30447, `d` = "recovery"):**
- Signed by the account key (normal nostr signature = the 3C proof).
- Tags: `["k", "<new keypackage d-tag or event id>"]` pointer to the fresh 30443, `["t", "state-loss"]`, created_at = restore time. Addressable ⇒ republish replaces; relays keep only the latest.
- Published automatically by the restored client right after `restoreIdentity` → first relay connect, immediately after the fresh KeyPackage publish (`publish_key_package_background` already runs there). Publishing on fresh onboarding is harmless (no peers are watching that npub).

**Survivor side (core `SonarClient`):**
1. Maintain a live subscription for kind-30447 authored by the member set of all active groups (piggyback on the existing group/KeyPackage relay subscriptions).
2. On beacon: verify author is a member of ≥1 group; check replay guard (`beacon.created_at` > last processed beacon for that npub AND > last decrypted inbound message timestamp from that member).
3. For each 1:1 group with that member: mark old group `reset` (retire from live 445 subscription, keep local transcript), fetch the fresh KeyPackage, `start_dm`-style create new group + gift-wrapped welcome, emit a `ConversationReset` notification so the apps insert the system notice. Existing duplicate-1:1 fold machinery presents old + new as one row (5A).
4. For multi-member groups: only members with add permission act. Dedup: deterministic executor = lowest-npub admin currently in the group; others hold off for a grace window, then retry if the restored member still isn't back (covers offline executor). Concurrent-commit forks stay bounded by MDK's existing fork behavior (assert in sim).
5. Rate-limit: at most one auto-reset per (npub, beacon.created_at).

**Restored side:** 1:1 welcomes are already auto-accepted (member_count ≤ 2). Group re-add welcomes normally go to invite UI — auto-accept when we have an outstanding beacon newer than the welcome's group's last known epoch (we asked for this). Clear the outstanding-beacon flag once ≥1 group heals; keep the beacon event published (addressable) for late peers.

## Approaches Considered

### Approach A: Recovery beacon + survivor auto re-invite (recommended)
- Pure app-layer on MDK; new event kind; survivor drives; works for DMs + groups.
- Affected: `core/sonar-core/src/marmot.rs` + `client.rs` (beacon build/publish/subscribe/handle, reset notification), `sonar-ffi`, `MarmotChatView.swift`/`SonarAppStore.swift`, `SonarAppState.kt`/`SonarCore*.kt` (reset notice UI, auto-accept), `core/sonar-core/tests/`, sim.
- Tradeoffs: no history for restored side (accepted, 5A); new kind to shepherd through MIP later; group re-add needs executor dedup.
- Effort: L (core M-L, apps M)

### Approach B: nsec-encrypted conversation-list backup + restored-party-driven re-invites
- Restored client restores an encrypted peer/group list (NIP-44 self-encrypted addressable event), then walks it re-inviting peers itself.
- Tradeoffs: restores *who* without waiting for peers to come online, and is the natural seed for 5B history work; but writes conversation metadata to relays (privacy surface), and the restored party creating groups inverts today's welcome flow for groups (it can't re-add itself). Rejected as the v1 driver (2D chose beacon), kept as the likely vehicle for the 5B follow-up.

### Approach C: MLS-native rejoin (external commit / ReInit via MDK upstream)
- Cryptographically the "right" answer (rejoin the same group, PCS story clean), no new Nostr kinds.
- Blocked: MDK explicitly `NotImplemented` for external proposals/commits; needs upstream design + audit; White Noise interop risk until spec'd. Long-term track, not v1.

## Recommendation

**Approach A.** It composes entirely from primitives that exist today (addressable signed events, fresh KeyPackage, welcome flow, duplicate-1:1 folding, R-011 delete semantics), satisfies 3C's signed-trigger requirement for free via nostr signatures, and degrades gracefully — peers that don't understand the beacon just ignore it and the manual R-011 path still works. Design the beacon kind + semantics as a one-page draft MIP alongside the implementation (1C).

## Open questions

- Kind number + MIP text: coordinate with Marmot before burning a kind; use an experimental kind behind a feature flag until then.
- Group executor election: lowest-npub-admin + grace window is simple; is that robust enough offline-heavy, or do we need re-add receipts?
- Should the survivor's old 1:1 group be locally deleted after N days (storage) or kept forever as archived transcript?
- Beacon TTL: how long do late-connecting peers honor an old beacon (7-day gift-wrap lookback symmetry?) before requiring a fresh one?
- 5B follow-up (tracked): survivor-side history re-send into the new group — needs sender-side pagination, rate limits, and dedup against the recipient's empty store; likely rides on Approach B's backup event.
