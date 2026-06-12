# Persistent Sonar chats across app restarts

Date: 2026-06-12
Status: clarified (brainstorm output, no code changes)

## Context findings

- Today NOTHING persists to disk: `ChatViewModel.messages` (channels) and
  `PrivateChatManager.privateChats` (DMs) are in-memory `@Published` arrays;
  the Marmot Rust core uses `MdkMemoryStorage`. Only nickname, favorites,
  read-receipts, and the wallet seed (Keychain) survive a restart.
- bitchat's own `PRIVACY_POLICY.md` already contemplates opt-in local
  retention ("messages saved locally when retention is enabled; otherwise
  deleted when the app closes") — persistence is consistent with the project
  ethos as long as it's deliberate and panic-wipe still erases everything.
- No Swift SQLite layer exists yet. Reusable patterns: `GeoRelayDirectory`
  (file-on-disk), `FavoritesPersistenceService` (Codable + Keychain — good for
  small blobs, wrong for bulk messages). The Rust core already depends on
  `mdk-sqlite-storage` (uses bundled SQLCipher → the iOS cross-build issue
  recorded in CLAUDE.md must be solved).
- Multi-device differs by chat type: White Noise/Marmot is already Nostr-native
  (kind 445 on relays; multi-device = MLS multi-KeyPackage, MIP-00). Mesh DMs
  travel over BLE with no relay copy → would need an encrypted self-backup to
  Nostr. Geohash channels are already on relays (ephemeral, public).

## Decisions taken (user, 2026-06-12)

- Scope: persist ALL — DM bitchat, White Noise, public/geohash channels, and
  the ⚡PAY ledger.
- Retention: ON by default; panic wipe clears everything.
- Marmot: switch the Rust core to `mdk-sqlite-storage`.
- Encryption: local encryption AND explore using Nostr as a sync layer for
  multi-device (the user explicitly wants the multi-device door open).
- **Mesh (Bluetooth) DMs stay LOCAL-ONLY (decided 2026-06-12):** no Nostr
  self-backup copy of BLE-delivered messages. Persistence for mesh DMs is
  on-device only; they are never republished to relays. (Multi-device sync,
  if built later, applies to White Noise/Marmot only — which is already
  relay-native — not to mesh conversations.) Whether to ever copy mesh DMs to
  Nostr remains explicitly undecided/deferred.

## Clarified Problem Statement

**Goal:** Make Sonar conversations survive app restarts — persisted locally and
encrypted at rest — with an optional Nostr-backed layer enabling the same
identity's chats to sync across devices, while preserving panic-wipe.

**Constraints:**
- Persistence ON by default; panic wipe erases 100% (local DB + keys).
- Encrypted at rest; decryption key in Keychain (device-bound).
- No break to wire compat (BLE Noise, NIP-17, geohash 20000, Marmot 445) or the
  live `SonarAppStore` read paths.
- Marmot group/ratchet (MLS epoch) state must persist with the messages —
  partial persistence corrupts ongoing secure chats.
- Scope: DM bitchat, White Noise, public/geohash channels, ⚡PAY ledger.

**Non-goals:**
- Cloud/account backup (Google Drive etc.).
- A server-side message archive we host.
- Persisting raw BLE packets / mesh routing state.

**Success criteria:**
- Kill + relaunch: DM, White Noise, channel transcripts, payment history intact.
- White Noise chats reopen without re-establishing the MLS group.
- Panic wipe leaves nothing recoverable on disk.
- (Stretch) A second device with the same npub sees White Noise history.

## Approaches Considered

### Approach A: Local-only encrypted store (single device)
- Sketch: Swift persistence layer (encrypted SQLite, key in Keychain) mirroring
  `messages`, `privateChats`, and `SonarPayLedger`; load on launch, write-through
  on append. Swap the Rust core to `mdk-sqlite-storage`. Include the
  optimistic-echo fix for White Noise sends.
- Affected files: new `bitchat/Services/MessageStore.swift`; hooks in
  `PrivateChatManager.swift`, `ChatViewModel` timeline, `SonarPayLedger.swift`;
  `core/sonar-core/src/{client,marmot}.rs` + iOS SQLCipher/OpenSSL cross-build;
  `SonarAppStore.wipe()` clears the DB.
- Tradeoffs: Solves the restart problem completely, fastest to "production feel."
  No multi-device. Main risk = SQLCipher iOS cross-build.
- Effort: M.

### Approach B: Nostr-sync-first (multi-device by design)
- Sketch: Relays as durable backup. White Noise already syncs via MLS. For mesh
  DMs and ⚡PAY, publish NIP-17 gift-wrapped encrypted copies to your own npub
  ("self-backup"); any device fetches+decrypts on launch. Local store = cache.
  Channels re-fetch geohash history.
- Affected files: new `core/sonar-core` self-backup module + a backup event
  kind; `MarmotService`/`SonarClient` multi-KeyPackage device support; Swift
  sync-on-launch; same `mdk-sqlite-storage` swap.
- Tradeoffs: Unlocks multi-device directly. Much bigger lift; leaks
  metadata (encrypted content, but timing/size/that-you-back-up visible);
  dedup/ordering complexity; MLS multi-device is non-trivial; no help for
  offline-only mesh users.
- Effort: L/XL.

### Approach C: Layered — local store now, Nostr sync as an additive layer
- Sketch: Ship A first (fixes restarts in weeks). Then add B's Nostr
  self-backup/multi-device on top, behind a Settings toggle, reusing A's store
  as the local cache and the same key derivation.
- Affected files: A's set first; then B's Nostr backup wired to the same
  `MessageStore`.
- Tradeoffs: Fixes the real pain fast, keeps multi-device open without betting
  the first release on the hard part. Slightly more total work; each ships
  independently.
- Effort: M now, L later.

## Recommendation

**Approach C.** Local persistence is the prerequisite for everything (the app
can't reopen a chat today), so build it first and get restarts working in weeks,
then layer Nostr sync as opt-in multi-device on the same store. Encryption: lean
**SQLCipher** so the Swift store and the Rust `mdk-sqlite-storage` share one
mechanism and one Keychain key — if the iOS cross-build fights us, fall back to
plain SQLite under iOS Data Protection (`NSFileProtectionComplete`) for the Swift
side. Validate the SQLCipher-on-iOS spike before committing (we hit it once).

## Open questions

- White Noise multi-device needs the 2nd device added as an MLS member
  (MIP-00 multi-KeyPackage) — OK to defer real multi-device to phase B and ship
  single-device persistence first?
- ~~Mesh-DM Nostr self-backup~~ — RESOLVED 2026-06-12: mesh DMs stay
  local-only, never copied to relays. Multi-device sync is White Noise only.
- Retention cap: everything forever, or a rolling window (last N / 90 days) to
  bound DB growth?
