# Brainstorm: Media sharing in Sonar (Marmot + BLE mesh)

Date: 2026-06-15. Status: clarified, ready for `/ship --plan-only`.

## Clarified Problem Statement

**Goal:** Let Sonar users send and receive **images, files, video and voice
notes** in chats — end-to-end encrypted — over **both** transports: White
Noise / Marmot (MLS over Nostr) and the BLE mesh.

**User decisions (2026-06-15):**
- Media types v1: **full** — images + arbitrary files + video + voice.
- Transports v1: **Marmot (White Noise) + BLE mesh.**
- Blob storage: **mirror White Noise's per-user Blossom server list**
  (kind-10063 / BUD-03) — read+publish our own list, upload to it, fall back
  to a default; recipient fetches from the URL in the imeta tag.
- Design: **extend the handoff tastefully now** (no media UX exists in the
  vendored design → new bubbles designed to Sonar tokens, every deviation
  listed, reviewed on-device).

### How the two transports actually work (grounded in the code)

**Marmot leg = Marmot MIP-04 "Encrypted Media", already implemented by MDK.**
The pinned MDK rev (`e8cd584`) ships `mdk_core::encrypted_media`:
- `EncryptedMediaManager::new(mdk, group_id)` bound to a group.
- `encrypt_for_upload(bytes, filename, mime) -> EncryptedMediaUpload`
  (ciphertext + `original_hash`, `encrypted_hash`, `mime`, `dimensions`,
  `blurhash`, `thumbhash`, `duration_ms`, `waveform`, `nonce`). Key is derived
  from the MLS group **exporter_secret** per epoch → only group members decrypt.
- `create_imeta_tag(upload, uploaded_url) -> NostrTag` (NIP-94-style `imeta`:
  url, m, filename, x=hash, dim, blurhash, thumbhash, duration, waveform).
- `decrypt_from_download(encrypted_data, MediaReference) -> bytes` (parses the
  imeta back into a `MediaReference`; epoch-aware).
- MDK `create_message(group_id, rumor, tags)` **accepts tags** → the imeta tag
  rides on the normal kind-9 chat message → kind-445.

So MDK does crypto + tag; **the app must do the Blossom HTTP upload/download**.
`nostr-blossom 0.44.0` is in our registry (matches our pinned nostr 0.44) — a
Rust client for BUD-01/02 (HTTP PUT/GET + kind-24242 signed auth). Per-user
server list = kind-10063 (BUD-03): publish ours, read peers' if needed.

**Mesh leg = bitchat's fragmented file transfer (separate wire format).** The
bitchat wire spec already has `fragmentStart/Continue/End` + `FileTransferLimits`
(see `bitchat/Utils/FileTransferLimits.swift`, voice in `bitchat/Features/voice/`).
Media over mesh is chunked encrypted packets over the Noise link — NOT Blossom.
The Rust mesh wire foundation is partly in place (packet v1 + fragments). Mesh
media is the **larger, riskier** half (BLE throughput caps practical size;
big video is effectively Marmot-only).

## Approaches Considered

### Approach A: Unified core media API across both transports (big bang)
- Sketch: One core entry `send_media(chat_id, bytes, filename, mime)` that
  routes by transport — Marmot via MDK+`nostr-blossom`, mesh via a Rust port of
  the bitchat fragment file-transfer stack. One FFI surface; shells just pick +
  render.
- Affected: `core/sonar-core/src/media.rs` (new) + `marmot.rs` send path +
  `client.rs` Blossom/server-list + a new mesh-fragment-media module in core +
  `sonar-ffi`; both shells' pickers + bubbles.
- Tradeoffs: cleanest app code; but couples two unrelated transports into one
  release, and porting mesh fragment media to Rust is a big chunk of M3 work.
  Highest risk of a long-lived branch.
- Effort: **XL.**

### Approach B: Phased — Marmot media first, mesh media second (recommended)
- Sketch: Ship **Phase 1 = Marmot/White Noise media** end-to-end (MIP-04 via
  MDK + `nostr-blossom` + kind-10063 server list, all in the shared core; full
  types: image/file/video/voice; new media bubbles). Then **Phase 2 = mesh
  media** (bitchat fragment file-transfer in the core + same bubbles). Same
  final architecture as A, but each phase ships and is demoable on its own.
- Affected: Phase 1 — `core/.../media.rs`, `client.rs` (Blossom + 10063),
  `marmot.rs` (imeta on send / parse on receive), `sonar-ffi` (sendMedia/
  fetchMedia + media message fields + server-list), iOS pickers+bubbles,
  Android pickers+bubbles, on-device encrypted media cache. Phase 2 — core
  mesh-fragment media + reuse the same FFI media shape + bubbles.
- Tradeoffs: interops with the real White Noise on day one (Phase 1), lowest
  risk, lets the design/UX get reviewed before the mesh leg piles on. Slightly
  more glue to keep one media UI over two phases.
- Effort: **L** (Phase 1), **L** (Phase 2).

### Approach C: Crypto-in-core, networking-in-native
- Sketch: Core only exposes encrypt/decrypt + imeta build/parse; each shell
  implements Blossom upload/download + the kind-10063 list + pickers natively.
- Affected: thin `media.rs` (crypto only); heavy iOS + Android networking.
- Tradeoffs: lets each platform use native HTTP/caching, but **duplicates the
  Blossom + BUD-03 protocol twice** and diverges from the thick-core
  architecture (CLAUDE.md Approach B). Rejected unless a Rust Blossom blocker
  appears — `nostr-blossom 0.44` removes that reason.
- Effort: L, but with permanent duplication cost.

## Recommendation

**Approach B (phased), on Approach A's unified architecture.** Build everything
in the shared Rust core (thick-core rule), but ship **Marmot/White Noise media
first** — it's fully supported by MDK + `nostr-blossom`, is cross-platform
through one FFI, and interops with the real White Noise app immediately. Then
add the **mesh** fragment-media leg as Phase 2 behind the same `sendMedia`/
`fetchMedia` FFI and the same bubbles. Design the media bubbles to Sonar tokens
now (image w/ blurhash placeholder, file chip, video thumb + play, voice
waveform) and list every deviation for on-device review.

Suggested split for `/ship`:
- **Phase 1a (core):** `media.rs` — EncryptedMediaManager wrapper, `nostr-blossom`
  upload/download, kind-10063 read/publish, imeta attach on send + parse on
  receive; FFI `sendMedia`/`fetchMedia` + media fields on the message model;
  e2e test (two in-process clients exchange an encrypted image via a mock
  Blossom + the test relay).
- **Phase 1b (iOS):** PHPicker/UIDocumentPicker/camera/voice → core; media
  bubbles in `SonarDMScreen`/`SonarComponents`; download→decrypt→cache→render;
  wipe-aware media cache.
- **Phase 1c (Android):** PickVisualMedia/SAF/CameraX/audio → core; same bubbles
  in Compose; same cache rules.
- **Phase 2 (mesh):** bitchat fragment file-transfer in core + same FFI/bubbles.

## Open questions / risks

- **Design gap is real:** no media UX in the vendored handoff, and the standing
  rule is "reproduce the handoff 1:1." Extending it is a deliberate, listed
  deviation — best to also refresh the design handoff with media screens later.
- **Mesh media is heavy + size-limited:** BLE throughput caps practical size;
  big video should be Marmot-only in practice. Phase 2 needs `FileTransferLimits`
  parity + a clear "too big for mesh" path.
- **Server-list trust:** uploading to a public Blossom server means the
  *ciphertext* is hosted by a third party (fine — only group members hold the
  key), but availability/retention varies. Default server choice + retention is
  a product decision.
- **Caching + wipe:** decrypted media must be cached encrypted-at-rest (iOS
  `NSFileProtectionComplete` / Android FBE) and erased by both "Erase all chats"
  and the panic wipe.
- **Per-message transport color:** media bubbles inherit the same
  current-reachability transport-color approximation as text (no per-message
  transport field).
- **Voice/video capture** is a large native surface on its own; if Phase 1
  feels big, voice+video can be a Phase 1.5 after image+file land.
