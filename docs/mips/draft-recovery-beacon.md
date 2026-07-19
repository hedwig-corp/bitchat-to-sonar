# Draft MIP: Marmot Recovery Beacon

**Status:** EXPERIMENTAL / draft. Sonar-only, opportunistic. Kind number is
provisional (`30447`) until coordinated with Marmot/White Noise. Non-Sonar
clients ignore the kind, so the beacon is wire-safe against interop.

## Problem

When a Marmot participant loses local MLS state but restores from their `nsec`
(account key), the account identity survives but the MLS group state does not.
MDK has **no external-commit / ReInit / external-join** processing
(`NotImplemented` in `mdk-core/src/messages/proposal.rs`), so the restored
client cannot rejoin the existing group. Today the only recovery is manual:
delete the chat on both sides and start over. This heals *connectivity* poorly
and loses the conversation row.

## Goal

After nsec-only restore, the restored client announces recovery; surviving peers
automatically re-invite it into a **fresh** MLS group; the UI folds the new leg
into the same conversation with a "chat was reset" system notice. No manual
delete + restart. Recovery converges eventually and never blocks chat
open/send/paint (local-first).

This heals *connectivity*, not *history*: pre-reset messages stay only on the
survivor's side. Survivor-side history re-send is a tracked follow-up (5B).

## Event

**Recovery Beacon** — addressable event, signed by the account key.

- `kind`: `30447` (provisional, EXPERIMENTAL).
- `content`: empty.
- Tags:
  - `["d", "recovery"]` — addressable slot; republish REPLACES the previous
    beacon, so relays keep only the latest per author.
  - `["t", "state-loss"]` — marker identifying the beacon's purpose.
  - `["k", "<fresh KeyPackage event id>"]` — OPTIONAL pointer to the restored
    client's fresh kind-30443 KeyPackage. Informational: a survivor may prefer
    that KeyPackage, but MAY fetch the author's newest KeyPackage instead.
- `created_at`: restore time (used by peers as the replay/staleness ordinate).

The Nostr signature *is* the authorization proof (3C): only the holder of the
account key can publish a beacon for that npub. A stolen `nsec` is full account
compromise and out of scope.

## Publishing (restored client)

Publish the beacon immediately after the fresh KeyPackage publish on the
**explicit nsec-restore path only**. Fresh onboarding and ordinary reconnect
MUST NOT publish: an empty MLS store alone cannot distinguish those cases, and
the outstanding-beacon flag auto-accepts multi-member group welcomes — which
must not be armed on a brand-new install.

While a locally published beacon is outstanding, the restored client
auto-accepts multi-member group welcomes (they are surviving admins re-inviting
it). The flag clears once at least one conversation heals; the beacon event
stays published (addressable) for late-connecting peers.

## Processing (surviving peer)

On receiving a beacon from `author`:

1. **Member scope.** Ignore unless `author` is a member of ≥1 group we share. A
   beacon only re-establishes an existing relationship; it never starts a new
   one.
2. **Replay guard.** Ignore if `created_at <= last processed beacon` for
   `author` (idempotency; addressable re-fetch is a no-op).
3. **Staleness guard.** Ignore if `created_at < newest decrypted inbound message
   from author` (the peer is clearly still live on the existing group). Note the
   strict `<`: a beacon in the same second as the last inbound still heals.
4. **1:1 DMs.** For each reusable 1:1 group with `author`: fetch `author`'s fresh
   KeyPackage, create a new group + gift-wrapped welcome, retire the old group
   (kept locally as an archived transcript, removed from the live subscription),
   and emit a `ConversationReset` so the UI inserts the system notice and folds
   old + new into one conversation row.
5. **Multi-member groups.** Only members with add permission act. The
   deterministic executor is the lowest-hex member other than `author` (all
   members are admins in Sonar's group model), which dedups concurrent re-adds.
   The executor removes the stale member, then re-adds with the fresh KeyPackage.
6. **Rate limit.** At most one action per `(author, created_at)`.

## Interop and safety

- New kind → non-Sonar Marmot clients (White Noise, etc.) ignore it. Nothing is
  overloaded onto 30443/444/445, so the beacon cannot confuse other clients.
- Auto-resetting a ratchet is an attack surface. Mitigations: nostr signature by
  the account key (inherent), member-scoping, replay guard, staleness guard, and
  the empty-store publish gate.
- Local-first: beacon publish, detection, and re-invite are background relay
  work. The manual delete + restart path remains as a fallback.

## Out of scope / follow-ups

- History transfer to the restored device (5B) — needs storage + protocol
  design; likely rides on an nsec-encrypted conversation-list backup event.
- MLS-native rejoin (external commit / ReInit) — blocked on MDK upstream.
- Hard beacon TTL for late-connecting peers (currently bounded only by the
  staleness guard).
- Multi-device / multi-KeyPackage fan-out.

## Reference implementation

Sonar core: `core/sonar-core/src/recovery.rs` (state + event builder),
`core/sonar-core/src/marmot.rs` (`RECOVERY_BEACON_KIND`), and
`core/sonar-core/src/client.rs` (publish / subscribe / fetch / handle). e2e:
`core/sonar-core/tests/recovery_beacon.rs`. Regression invariant: `R-011` in
`docs/REGRESSIONS.md`.
