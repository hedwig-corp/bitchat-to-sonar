## Clarified Problem Statement

**Goal:** Add Signal-style reply-to-message on every Sonar transcript (Marmot, mesh-folded DMs, geohash channels), using the same NIP White Noise already ships so Marmot replies interoperate.

**Constraints:**

- Cross-platform: `ios/` and `apps/sonar/` in the same change, or an explicit tracked gap.
- Local-first: opening a chat must paint from the local window. Do not fetch the parent from a relay on first paint. `Jump(id)` may page locally; it must not block open.
- Marmot inner rumors are already **kind 9** (`CHAT_RUMOR_KIND` in `core/sonar-core/src/marmot.rs`). That is NIP-C7, not kind 1.
- White Noise interop: stay wire-compatible with Marmot clients (kind 445 envelope, kind 9 rumor, existing `imeta` / `sticker` tags).
- Mesh BLE `PrivateMessage` TLV (`core/sonar-core/src/mesh.rs`) is `message_id` + `content` today; unknown TLV types are ignored (forward-compat). Old bitchat peers must keep working.
- Geohash channels are **kind 20000** ephemeral (`core/sonar-core/src/geohash.rs`), not kind 9. Location notes (kind 1) are a different surface.
- Reply target = any **transcript-visible** row (`MessageClassification::is_transcript_visible`): text, media, stickers, `⚡PAY` receipts. Hidden `PayDone` / `CallControl` stay non-targets.
- Two chat kinds (`docs/CHAT-TYPES.md`): pure Marmot and mesh-folded. A reply in a folded chat must survive BLE → Marmot transport switching.
- Signal-first: quote chip + composer banner + tap-to-jump, not Slack threads. Study Signal-iOS `QuotedReplyModel` / Signal-Android `Quote` before coding.
- `docs/SIGNAL-TRANSCRIPT-PATTERNS.md` already lists `Jump(id)` as a tracked follow-up for search/reply.

**Non-goals:**

- Slack-style thread sidebars or a separate thread view.
- Public social-feed kind-1 threading (NIP-10) on the user's main identity.
- Location-notes (kind 1) reply UI unless it falls out of the geohash path for free.
- Editing / deleting the parent; reactions; reply-all vs reply-one in groups (a reply is just another group message with a parent pointer).
- Changing the kind-9 / kind-445 envelope.

**Success criteria:**

- Swipe or long-press a visible bubble → composer shows a quote banner; send attaches a parent pointer; both apps render a small parent snippet on the new bubble.
- Tap the snippet jumps to the parent when it is in (or can be paged into) the local window; if the parent is missing, the chip still paints from a local snapshot and does not stall open.
- A White Noise client in the same Marmot group sees the reply as a NIP-C7 quote (`q` tag + `nostr:nevent` prefix).
- A Sonar client sees a White Noise NIP-C7 reply as a quote chip (parse `q` + strip the nevent from displayed content).
- Mesh-only and geohash replies work on Sonar↔Sonar; old mesh/geohash clients ignore the extra field and show a normal message.
- Opening an existing chat does not wait on relay sync or parent fetch. Bounded window still applies.
- Tests: round-trip NIP-C7 parse/strip in core; mesh TLV unknown-type ignore; both chat kinds; both apps.

## How White Noise does it (the NIP)

Grok suggested **NIP-10** (kind-1 `e` tags with `root` / `reply` markers). That is the social-note thread NIP. It is the wrong contract for Sonar chat:

- NIP-10 applies to **kind 1**. Sonar/Marmot application messages are **kind 9** rumors inside kind 445.
- NIP-10 itself says do not use kind-1 replies for non-kind-1 events.
- White Noise originally used `e` tags, then **replaced them** with NIP-C7 `q` tags for Marmot-ts / Amethyst interop ([whitenoise#445](https://github.com/marmot-protocol/whitenoise/issues/445), [PR #468](https://github.com/marmot-protocol/whitenoise/pull/468), [whitenoise-rs#581](https://github.com/marmot-protocol/whitenoise-rs/pull/581)).

**The standard for this is NIP-C7** ([nips/C7.md](https://github.com/nostr-protocol/nips/blob/master/C7.md)):

A chat message is kind 9. A reply is another kind 9 that quotes the parent with a `q` tag:

```json
{
  "kind": 9,
  "content": "nostr:nevent1...\nyes",
  "tags": [
    ["q", "<event-id>", "<relay-url>", "<pubkey>"]
  ]
}
```

White Noise:

- Writes **one** `q` tag (event id + pubkey; relay URL often empty inside MLS).
- **Prepends** `nostr:nevent1...` to `content`.
- On receive, **parses and strips** that URI so the user never sees it.
- Other content types MAY be quoted inside a kind 9 following NIP-18; clients that render a chat stream MUST keep fetching kind 9 so context is not lost.

**NIP-22** (kind 1111 comments) is for commenting on arbitrary events from a feed client. Not in-chat replies. Do not use it here.

Mesh and geohash have **no** NIP-C7 (wrong kind / not Nostr rumors). They need a transport shim that still maps to the same core `ReplyRef`.

## Approaches Considered

### Approach A: NIP-C7 on Marmot, pointer-only, shims elsewhere

- Sketch: Core `ReplyRef { parent_id, parent_pubkey }` parsed from rumor `q` tags. Send path: Marmot rumor gets `q` + nevent prefix (exact White Noise). Mesh: new optional TLV (unknown types already ignored). Geohash 20000: same `q` tag shape. UI looks up the parent in the local window to paint the chip.
- Affected files: `core/sonar-core/src/marmot.rs` (`create_text_event_inner` and siblings, `to_chat_message`), `core/sonar-core/src/mesh.rs` (`PrivateMessage`), `core/sonar-core/src/geohash.rs` + `GeoMessage`, `core/sonar-ffi/src/lib.rs` (`MessageInfo`), `ios/bitchat/Views/Sonar/` composer + bubbles, `apps/sonar/.../SonarAppState.kt` + chat composer, `packages/transcript-engine*` Jump(id).
- Tradeoffs: Best WN interop with the smallest rumor change. Chip is empty/generic when the parent sits outside the bounded page (common). Mesh/geohash are Sonar-only extra fields.
- Effort: M

### Approach B: NIP-10 `e` tags (Grok)

- Sketch: Put `e` tags with `root` / `reply` markers on kind-9 rumors, geohash 20000, and (if ever) kind 1 notes. Mesh TLV copies the parent event/message id.
- Affected files: same send/parse sites as A, plus any NIP-10 marker helpers. No White Noise-shaped `q` / nevent path.
- Tradeoffs: Matches the Grok chat and kind-1 mental model. White Noise will **not** thread these (they moved off `e` tags). Amethyst/marmot-ts replies would not round-trip. NIP-10 forbids this for non-kind-1.
- Effort: M

### Approach C: NIP-C7 pointer + Signal quote snapshot

- Sketch: Same wire as A for the pointer (Marmot = White Noise NIP-C7; mesh TLV; geohash `q`). Also persist a **denormalized quote snapshot** on the reply (parent id, pubkey, short text/caption, optional thumb ref) so the chip paints from the reply row itself. That is how Signal avoids loading the parent on bind. Snapshot can ride in a Sonar-specific extra tag WN ignores, or be derived at send time from the local parent and stored only in our DB if we do not want a custom tag. Prefer a snapshot in local storage reconstructed from `q`+lookup when present, and kept on the outbox/transcript row when the parent is known at send. Incoming WN replies: strip nevent, look up parent locally, snapshot what we have; if missing, chip shows a generic “Message” until a later local page finds it.
- Affected files: Approach A plus `ChatMessage` / `MessageInfo` quote fields, local transcript mapping on both apps, Jump(id) in transcript-engine (already a listed follow-up). Send APIs grow `reply_to: Option<parent_id>` on text/media/sticker/pay-visible sends.
- Tradeoffs: Signal-quality chips on a bounded window; WN interop on Marmot; extra model field and send plumbing. Must not put the snapshot in displayed `content` (mesh/bitchat would show it; WN already reserved the nevent prefix).
- Effort: L (M if snapshot is local-DB-only and Jump(id) is a fast follow-up)

## Recommendation

**Approach C**, with the Marmot wire **exactly** matching White Noise NIP-C7 (`q` tag + `nostr:nevent` prefix + strip on display). Do not use NIP-10.

Pointer-only (A) will look broken on Sonar’s bounded transcript windows. NIP-10 (B) breaks the only Marmot client we interop with. C is the Signal data model: quote snapshot on the reply row, Jump(id) when the parent can be paged locally, never block open on a parent fetch.

v1 send: pass `reply_to` into the existing create-message helpers (text, media, sticker, visible pay). v1 UI: composer banner + bubble snippet + tap-to-jump on both apps. Mesh TLV + geohash `q` in the same PR so all-surfaces is real, not a silent gap.

## Open questions

- Snapshot storage: local-DB-only vs an extra rumor tag WN ignores. Local-DB-only is smaller and enough for our send path; incoming WN replies still need a local parent lookup.
- Mesh TLV number: pick the next unused type in `PrivateMessage` (0x04+); confirm iOS Swift mesh encoder is in lockstep with `core/sonar-core/src/mesh.rs`.
- Geohash `q` on kind 20000 is not NIP-C7 (wrong kind). Treat as a Sonar/bitchat convention; do not also emit NIP-10 `e` tags.
- Location notes (kind 1): leave out unless product wants NIP-10 there separately.
- Jump(id) vs v1 “chip only, no scroll”: chip-without-jump is a worse Signal clone; include Jump in the same change if transcript-engine can take it, otherwise ship chip + banner and track Jump as the documented gap.
- Reply to a message that arrived over BLE when the send later goes out over Marmot: resolve the parent to a Marmot event id if one exists; otherwise omit `q` and keep the local snapshot (folded-chat edge).
