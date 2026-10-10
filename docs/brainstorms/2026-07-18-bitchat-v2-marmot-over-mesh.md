# bitchat v2: Marmot over mesh

## Clarified Problem Statement

**Goal:** Define and implement "bitchat v2" — carry the Marmot protocol
(KeyPackage, Welcome, kind-445 MLS ciphertexts) over the BLE mesh so that
meeting a peer over Bluetooth creates a *real* Marmot/MLS group with no relay
round-trip, and that group is the one conversation for the peer across both
transports (mesh in range, Nostr relays otherwise).

**Why now:** MDK is transport-agnostic — [`core/sonar-core/src/marmot.rs`](../../core/sonar-core/src/marmot.rs)
already produces/consumes Nostr events with zero relay coupling ("never talks
to a relay — publishing and subscribing belong to `client`"). The mesh link
engine also now lives in the Rust core ([`mesh_engine.rs`](../../core/sonar-core/src/mesh_engine.rs),
PR #291). Both halves of the bridge are in the same crate for the first time.

**What it fixes structurally:**
- *Starting a Nostr DM from mesh* today requires internet: KeyPackage fetch
  from relays, group create, Welcome publish. Over mesh it becomes a local
  exchange.
- The **mesh-folded chat kind** (`docs/CHAT-TYPES.md`) — the `mesh:` id
  namespace, the 16hex/64hex identity gap (a BLE chat is unsendable once out
  of range if we only hold the short id), `MessageStore` vs SQLCipher double
  storage, `transcriptGroupIds` folding — exists *because* mesh contact and
  Marmot group creation are decoupled. v2 couples them: first contact ⇒ group
  exists ⇒ every new peer chat is a pure Marmot chat keyed by MLS group id.

**Decisions taken (user-confirmed):**
- **Scope:** bootstrap + messaging. KeyPackage/Welcome exchange over mesh AND
  445 ciphertexts over mesh frames while in range. MLS is the one crypto
  plane; Noise remains as link encryption only.
- **Compat:** v1 interop stays, capability-negotiated. v2 is advertised (new
  TLV in the 0x53 `SONAR_ANNOUNCE`); peers without it fall back to v1 Noise
  DMs. Upstream bitchat iOS and old Sonar installs keep working.
- **Data model:** converge. New v2 contacts are pure Marmot chats from first
  contact; the mesh-folded kind survives only for legacy v1 peers and
  historical `MessageStore` rows.
- **Deliverable:** spec doc + core implementation land together as one PR
  train (spec first in the stack).

**Constraints:**
- Android + Rust core only for now; iOS is a documented follow-up gap
  (standing 2026-07-17 instruction), but the *wire format* must be designed so
  iOS can adopt it without changes — it goes in the spec.
- Byte-compat with bitchat v1 framing: v2 rides as new `msg_type` values
  inside the existing packet format (`mesh.rs`), inside `NOISE_ENCRYPTED`
  payloads, reusing 0x20 fragmentation (Welcomes are 2–12 KB; BLE MTU ~180–500 B).
- MLS discipline unchanged: fresh ephemeral signer per 445,
  `merge_pending_commit` only after the commit is *delivered* (mesh delivery
  ack now counts as "published" — spec must define this precisely).
- Groups created over mesh must be wire-valid White Noise groups on relays
  (same MDK rev / framing — note the MDK 0.8 vs 0.9 interop split already
  tracked for WN iOS).
- Run `sonar-sim group-scale` after any change touching welcome/create_group
  (CLAUDE.md rule); mesh transport must not fork the wire format.
- Signal-comparable performance rules apply: no UI path blocks on mesh
  handshakes or group creation; local pending conversation first, reconcile
  later (XChat-Style Chat Startup Rule).

**Non-goals (v2.0):**
- Multi-hop store-and-forward of Marmot events (mesh-as-relay). Direct
  (single-hop, addressed-recipient) delivery only; TTL forwarding of 445s is a
  tracked follow-up.
- Broadcast/geo channels over MLS. Public mesh broadcast stays v1.
- Replacing Noise at the link layer. Noise XX still authenticates the link and
  encrypts frames; peerID stays `SHA256(noise static pubkey)[:8]`.
- Migrating *existing* mesh-folded conversations into groups (legacy peers
  keep the fold path; opportunistic upgrade is a follow-up).
- Device-linking second-leaf interaction over mesh (PR #195 flows stay
  relay-only for now).

**Success criteria:**
- Two Sonar devices with airplane-mode-except-BLE meet, chat, and the
  conversation is a Marmot group (MLS group id) with messages in the SQLCipher
  DB — no `mesh:` id, no `MessageStore` rows for the new chat.
- Same two devices later gain internet with BLE off: the *same* conversation
  continues over relays with no new chat row and no history loss; relay copies
  of mesh-delivered 445s dedup by event id.
- A v2 device chatting with a v1-only peer (upstream bitchat) falls back to
  Noise DMs with today's behavior, proven by an engine unit test.
- `sonar-sim` structural outputs unchanged (welcome bytes, ceiling).
- Spec doc reviewed and committed alongside the code
  (`docs/BITCHAT-V2.md` or MIP-style under `docs/`).

## Approaches Considered

### Approach A: Marmot event frames over the v1 Noise link (chosen shape)
- Sketch: keep v1 link establishment untouched (announce → Noise XX →
  verified link). Add a v2 plane on top: new `msg_type` values, e.g.
  `0x30 MARMOT_KP_REQUEST`, `0x31 MARMOT_KP_RESPONSE` (serialized 30443),
  `0x32 MARMOT_WELCOME` (the 444 rumor — gift-wrap is pointless
  point-to-point over an authenticated Noise link; spec decides wrapped vs
  bare), `0x33 MARMOT_GROUP_MSG` (serialized 445). All ride inside
  `NOISE_ENCRYPTED`, fragmented via 0x20. Receiver feeds them into the same
  MDK ingestion path the relay drain uses; dedup by Nostr event id makes
  mesh+relay double-delivery free. Sender publishes 445s to the relay outbox
  *and* over the live link — the relay copy doubles as history/offline sync.
- Affected: `core/sonar-core/src/mesh.rs` (frame types + TLVs),
  `mesh_engine.rs` (capability tracking, v2 hand-off events/commands),
  `marmot.rs` (event (de)serialization entry points, mesh-delivery commit
  rule), `client.rs` (unified ingestion, transport pick per send, pending-chat
  reconcile), Compose driver + `SonarAppState.kt` (new-contact path creates
  pending Marmot chat instead of `mesh:` chat), `docs/BITCHAT-V2.md`.
- Tradeoffs: + smallest wire delta, full v1 fallback for free, one ingestion
  path, double encryption (Noise+MLS) is a cost we accept for link privacy
  and v1 coexistence; − event serialization (JSON) is chatty over BLE (can
  move to a binary event encoding later behind the same frame type).
- Effort: L (core + Compose driver + tests + spec), but cleanly stageable.

### Approach B: Mesh-as-local-relay (Nostr REQ/EVENT subset over the link)
- Sketch: implement a tiny binary relay protocol over the Noise link —
  subscribe/event/eose frames scoped to Marmot kinds, per-peer sync
  watermarks, store-and-forward. The mesh peer literally *is* a relay to the
  existing sync pipeline.
- Tradeoffs: + reuses the whole relay-sync semantic (watermarks, completeness),
  natural path to multi-hop forwarding; − much bigger surface, drags the
  watermark/completeness machinery (source of PR #177/#252 bug class) into a
  lossy transport, overkill for the DM-bootstrap goal.
- Effort: XL.

### Approach C: MLS-native link (v2 replaces Noise)
- Sketch: v2 peers skip Noise; the link itself is authenticated by MLS group
  membership and frames are raw 445 ciphertexts.
- Tradeoffs: + single crypto layer, most elegant end state; − breaks peer
  identity (peerID is Noise-key-derived everywhere, see
  `bitchat-peerid-is-key-derived`), kills v1 fallback symmetry, MLS handshake
  round-trips are wrong for a flaky BLE link, no privacy for pre-group
  traffic (KP request would go cleartext).
- Effort: XL, high risk.

## Recommendation

Approach A. It matches all three confirmed decisions (negotiated v1 compat,
one crypto plane on top of Noise link encryption, convergence to pure-Marmot
chats) with the smallest wire delta, and B's store-and-forward can be added
later behind the same frame types. C contradicts the compat decision and the
peer-identity model.

Suggested PR train:
1. Spec: `docs/BITCHAT-V2.md` (frames, capability TLV, fragmentation sizing,
   welcome auto-accept semantics, commit/"published" rule for mesh delivery,
   dedup, fork/duplicate-group handling).
2. Core wire + engine: frame types, capability advertise/parse, engine events
   for "v2 peer link ready"; unit tests incl. v1-fallback.
3. Core protocol flow: KP exchange → group create → Welcome over mesh →
   auto-accept; 445 send/receive over mesh with event-id dedup; pending-chat
   reconcile. `sonar-sim` diff.
4. Compose app: new-contact path creates the Marmot chat, transport pick per
   message, UI transport badge (cyan/indigo) driven by delivery leg.
5. Ledger/docs: CHAT-TYPES.md update (third state: "v2 native"), REGRESSIONS
   entries where applicable, iOS follow-up issue.

## Open questions

- **Welcome auto-accept over mesh:** White Noise requires manual invite
  acceptance; physical proximity + signed announce arguably implies consent
  for Sonar-to-Sonar. Proposal: auto-accept when the Welcome arrives over an
  authenticated link whose Noise identity matches the KeyPackage owner's
  npub-linked identity; otherwise fall back to the invite UX. Needs a
  decision in the spec.
- **Both-sides-create race:** two peers in range may simultaneously create a
  group for each other (today's duplicate-direct-groups problem, now faster).
  Deterministic tie-break (e.g. lower npub creates; other side waits T ms) or
  lean on existing duplicate folding?
- **Event encoding on the wire:** canonical JSON (simple, matches relay copy,
  same id hash) vs a binary encoding (saves ~30–40% over BLE). v2.0 likely
  JSON; frame version field reserves the upgrade.
- **Commit rule wording:** what counts as "published" for
  `merge_pending_commit` when the commit went over mesh only — link-level
  delivery ack, or also queued-to-outbox for relay? (Leaning: outbox-queued
  AND mesh-acked.)
- **Legacy upgrade:** when a known mesh-folded peer advertises v2, do we
  opportunistically create the group and stop writing `MessageStore` rows?
  (Deferred to follow-up, but the spec should not preclude it.)
- **MDK rev risk:** any MDK bump mid-train re-triggers the group-scale sim
  and the WN 0.8/0.9 interop question.
