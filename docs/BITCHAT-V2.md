# bitchat v2: Marmot over mesh

**Status:** draft spec (implementation staged as a PR train — see the plan at
the end). Android + Rust core first; iOS is a documented follow-up gap, but the
wire format below is platform-neutral and iOS-adoptable without change.

**Origin:** [`/brainstorm bitchat-v2 Marmot over mesh`](brainstorms/2026-07-18-bitchat-v2-marmot-over-mesh.md).

## Why

MDK is transport-agnostic. [`core/sonar-core/src/marmot.rs`](../core/sonar-core/src/marmot.rs)
already produces and consumes Nostr events with zero relay coupling, and the
mesh link engine ([`mesh_engine.rs`](../core/sonar-core/src/mesh_engine.rs),
PR #291) now lives in the same crate. That makes it possible to carry the
Marmot handshake and message events **over the BLE mesh**, so that meeting a
peer over Bluetooth creates a real MLS/Marmot group with no relay round-trip.

Today, starting a Nostr DM from a mesh encounter needs the internet
(KeyPackage fetch, group create, Welcome publish), which forces the
**mesh-folded chat kind** described in [`CHAT-TYPES.md`](CHAT-TYPES.md): the
`mesh:` id namespace, the 16-hex/64-hex identity gap (a BLE chat is unsendable
once out of range if only the short id is known), and double storage
(`MessageStore` vs the SQLCipher DB). bitchat v2 couples mesh contact with
group creation so that a new peer chat is a **pure Marmot chat** — one MLS
group id, one storage plane, transport chosen per message — from first contact.

## Scope (v2.0)

- **In:** peer-to-peer KeyPackage exchange, Welcome delivery, and kind-445 MLS
  message delivery over an authenticated Noise mesh link; capability
  negotiation with v1; convergence of new contacts to pure Marmot chats.
- **Out (tracked follow-ups):** multi-hop store-and-forward of Marmot events
  (mesh-as-relay); MLS group/broadcast channels over mesh; migrating existing
  mesh-folded conversations into groups; device-linking (PR #195) over mesh;
  iOS implementation; binary Nostr-event encoding on the wire.

## Layering

bitchat v2 does **not** replace Noise. The link is still established exactly as
in v1 (`ANNOUNCE` → Noise XX → verified link), the peer id stays
`SHA256(noise static pubkey)[:8]`, and frames are still Noise-encrypted
(`msg_type::NOISE_ENCRYPTED` = 0x11) and fragmented via 0x20. v2 adds a second
crypto plane **inside** the Noise channel: MLS. Noise authenticates and
encrypts the link; MLS is the end-to-end group cipher that is identical on the
mesh leg and the relay leg. Double encryption on the mesh leg is intentional —
it preserves link privacy and lets v1 and v2 coexist on one link.

### New inner payload types

v2 frames are new **`noise_payload` inner-type bytes**, decoded after Noise
decryption alongside the existing `PRIVATE_MESSAGE` (0x01) etc. in
[`mesh.rs`](../core/sonar-core/src/mesh.rs). They are **not** new top-level
packet types, so v1 relays/forwarders pass them through unchanged and only the
addressed recipient (which holds the Noise session) ever sees them.

| Byte | Name | Payload |
|---|---|---|
| `0x20` | `MARMOT_KP_REQUEST` | none — "send me your KeyPackage" |
| `0x21` | `MARMOT_KP_RESPONSE` | serialized kind-30443 KeyPackage event |
| `0x22` | `MARMOT_WELCOME` | serialized kind-444 Welcome rumor (bare; see below) |
| `0x23` | `MARMOT_GROUP_MSG` | serialized kind-445 MLS message event |
| `0x24` | `MARMOT_ACK` | event id being acknowledged (delivery/commit gate) |

(`0x20–0x24` are unused in the `noise_payload` namespace today; the existing
top-level `FRAGMENT` = 0x20 is a different namespace and does not collide.)

Events are serialized as **canonical Nostr JSON** in v2.0 — same bytes the
relay leg carries, so the Nostr event id is identical and mesh+relay
double-delivery deduplicates for free. A `version`/encoding field in the frame
header reserves a future binary encoding (≈30–40% smaller over BLE) without a
new type byte.

Welcome is delivered **bare** (not NIP-59 gift-wrapped): the wrap exists to
hide the recipient on a public relay, which is meaningless over a
point-to-point authenticated Noise link. The relay leg still gift-wraps.

## Capability negotiation

v2 is advertised, never assumed. The `0x53` `SONAR_ANNOUNCE` gains a
capability TLV bit `MARMOT_MESH_V2`. On a verified link:

- Both peers advertise v2 → the v2 plane is used for that peer.
- Either peer lacks it → fall back to v1 Noise `PRIVATE_MESSAGE` DMs, exactly
  today's behavior. Upstream bitchat iOS and pre-v2 Sonar installs keep working.

The engine tracks per-peer v2 capability and emits a `V2LinkReady` event to the
app layer only when both sides qualify.

## Flows

### First contact → group exists

1. Links come up (v1 Noise XX). Both announce `MARMOT_MESH_V2`.
2. The deterministic **initiator** (lower npub, hex compare) sends
   `MARMOT_KP_REQUEST`. The tie-break avoids both sides creating a group at
   once; the non-initiator waits.
3. Responder replies `MARMOT_KP_RESPONSE` (its 30443).
4. Initiator runs `create_group` + `add_members` (MDK), producing a Welcome,
   and sends `MARMOT_WELCOME`. It does **not** `merge_pending_commit` yet.
5. Responder ingests the Welcome and auto-accepts (see below), joining the
   group, and replies `MARMOT_ACK(welcome_event_id)`.
6. On ACK — or on the relay outbox confirming the commit, whichever first —
   the initiator calls `merge_pending_commit`. The group is live on both sides.

The UI never blocks on this. Per the XChat-Style Chat Startup Rule, tapping the
peer opens a **local pending Marmot conversation** immediately; steps 2–6 run on
a background path and the pending row reconciles to the real group id when the
commit merges.

### Messaging in range

`sendDmAuto` gains an MLS-over-mesh leg. For a v2 peer with a live link, a
kind-445 is produced once and sent as `MARMOT_GROUP_MSG` over mesh **and**
queued to the relay outbox. Receipt over either leg ingests through the same
MDK path; the second copy dedups by event id. Out of range, only the outbox
(relay) leg carries it — the same group, no new chat.

### Auto-accept semantics

White Noise requires manual invite acceptance. Over mesh, a Welcome arriving on
an **authenticated Noise link whose peer identity matches the KeyPackage
owner's npub-linked identity** is auto-accepted for Sonar-to-Sonar peers —
physical proximity plus a signed announce is treated as consent. If the
identity does not match, or the peer is not Sonar-verified, fall back to the
normal invite UX. This is the one place v2 relaxes WN behavior and is called
out for review.

## Fragmentation & sizing

KeyPackages are small (~1 KB); Welcomes are 2–12 KB; 445s vary. BLE MTU is
~180–500 B. All v2 frames larger than one fragment ride the existing 0x20
fragmentation with `original_type = NOISE_ENCRYPTED`, unchanged from v1 file
transfer. No new fragmentation logic.

## Invariants (must not regress)

- **MLS discipline:** fresh ephemeral signer per 445; `merge_pending_commit`
  only after the commit is delivered (mesh ACK or outbox-queued for relay,
  per the flow above). The no-lock MDK invariant is unchanged.
- **Wire compatibility with White Noise:** a group created over mesh must be a
  wire-valid WN group on relays (same MDK rev / framing). Any MDK bump
  re-triggers `sonar-sim group-scale` and the WN 0.8/0.9 interop check
  (`whitenoise-ios-mdk09-protocol-split`).
- **One conversation per person:** first-contact-over-mesh and later-over-relay
  are the same MLS group; no `mesh:` id minted for a v2 peer, no `MessageStore`
  rows for a v2 chat. Legacy v1 peers keep the fold path.
- **Peer identity:** peerID stays Noise-key-derived
  (`bitchat-peerid-is-key-derived`). v2 does not touch link identity.
- **Performance:** no UI path blocks on mesh handshake, group create, or
  commit merge (Signal-Comparable + XChat-Style rules).
- **Both-sides-create race:** resolved by the lower-npub tie-break; existing
  `duplicateDirectMarmotChats` folding remains the backstop.

## PR train

1. **Spec** — this doc.
2. **Core wire + engine** — `noise_payload` types `0x20–0x24`, capability TLV
   advertise/parse in the `0x53` announce, engine per-peer v2 tracking +
   `V2LinkReady`. Unit tests including v1 fallback and the tie-break.
   Files: [`mesh.rs`](../core/sonar-core/src/mesh.rs),
   [`mesh_engine.rs`](../core/sonar-core/src/mesh_engine.rs).
3. **Core protocol flow** — KP exchange → `create_group` → Welcome over mesh →
   auto-accept; 445 send/receive over mesh with event-id dedup; pending-chat
   reconcile; commit gate. `sonar-sim group-scale` diff attached.
   Files: [`marmot.rs`](../core/sonar-core/src/marmot.rs),
   [`client.rs`](../core/sonar-core/src/client.rs).
4. **Compose app** — new-contact path creates the pending Marmot chat instead
   of a `mesh:` chat; per-message transport pick; transport badge
   (cyan = mesh, indigo = internet) driven by the delivery leg.
   Files: `apps/sonar/.../SonarAppState.kt` + mesh driver.
5. **Docs/ledger** — [`CHAT-TYPES.md`](CHAT-TYPES.md) third state ("v2 native"),
   [`REGRESSIONS.md`](REGRESSIONS.md) entries where a fix pins a real call site,
   iOS follow-up issue.

## Open questions (resolve in review before step 3)

- Auto-accept rule wording — is "authenticated link + identity match" a
  sufficient consent signal, or is a lightweight one-tap confirm required for
  the first message from a new peer?
- Commit "published" definition — mesh ACK alone, or mesh ACK **and**
  outbox-queued for relay? (Leaning: whichever is first, but never before at
  least one durable path has the commit.)
- Event encoding — JSON in v2.0 (id-identical to the relay copy) vs a binary
  encoding behind the reserved header field. v2.0 = JSON.
- Legacy upgrade — when a known mesh-folded peer advertises v2, opportunistically
  create the group and stop writing `MessageStore` rows? (Deferred; spec must
  not preclude it.)
