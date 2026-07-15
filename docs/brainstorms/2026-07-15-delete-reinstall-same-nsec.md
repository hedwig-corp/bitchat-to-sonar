# Delete app → reinstall → same nsec (Signal-like Blossom backup)

Date: 2026-07-15
Status: clarified (brainstorm; no code changes)
Updated: 2026-07-15 — product direction: **Signal-style encrypted backup on Blossom**, with a **Hedwig-operated Blossom** in scope
Answers: 1C (truth + fix plan), 2C (iOS + Android), 3A (explicit nsec paste), 4B (identity + wallet + Marmot history), 5A+B (TestFlight honesty + personal restore)

## Context (what the code does today)

### Survives app delete?
| Asset | Location | After uninstall |
| --- | --- | --- |
| Account `nsec` | iOS Keychain / Android Keystore-backed secrets | **Do not rely on it.** Treat as gone; restore requires paste (3A). |
| SQLCipher DB key (`marmot-db-key`) | Keychain / host secrets | Gone with uninstall |
| Marmot DB + index + sticker cache | App sandbox (`Application Support/sonar-marmot`, Android `filesDir`) | **Deleted** |
| Onboarding / nickname prefs | UserDefaults / SharedPreferences | **Deleted** |
| Mesh / BLE-only DMs | Local only (by design) | **Permanently lost** |

### After reinstall + “Restore account” with same `nsec1…`
Path: iOS `MarmotChatModel.restoreIdentity` / `SonarAppStore.restoreAccount`; Compose `SonarAppState.restoreAccount` → `SonarCore.importIdentity`.

1. Validate nsec → wipe any local Marmot store → persist nsec → open a **new** encrypted DB (fresh random `db_key`).
2. Identity (`npub`) matches the old account.
3. Wallet is designed to **re-derive from nsec** → same Lightning wallet / balance (see `docs/brainstorms/2026-06-12-wallet-derived-from-identity.md`).
4. App republishes KeyPackage + profile on relay connect.
5. **Local Marmot chat list + MLS secrets are empty.** Kind 445 history on relays stays ciphertext for the **old** MLS epochs you no longer hold. Forced sync / resync floors cannot decrypt what you cannot open. Existing groups do not magically reappear; peers may need to start new DMs / re-invite after your new KeyPackage is live.
6. Mesh/BLE history does not come back (non-goal / local-only decision from 2026-06-12).

Account Key Durability (CLAUDE.md) covers **update / prefs loss with key still present**, not uninstall. TestFlight `WhatToTest.md` §8 is the same class (update), not delete→reinstall.

### Blossom already in Sonar
- Media (MIP-04) already encrypts then uploads via BUD-02 (`SonarClient::blossom_upload`); user server list is kind-10063 (BUD-03).
- Fallback today: `DEFAULT_BLOSSOM_SERVER = "https://nostr.download"` (`core/sonar-core/src/client.rs`) — third-party, media-oriented, **not** a retention/quota contract for account backups.
- Stickers/status also probe Blossom; there is **no** account-backup blob path yet.

### Signal analogy (what we want to match)
Signal’s cloud backup is roughly: **encrypt local conversation state → upload to operator-controlled storage → restore on new install with account/backup key**. For Sonar: encrypt Marmot durable state (MLS + transcripts + db key material as needed) → upload ciphertext to **Blossom** → on restore after nsec paste, fetch + decrypt → open local DB first (Signal-Comparable / local-first), then background relay catch-up. The Blossom host must **not** be able to read plaintext (client-side encryption; nsec or a domain-separated backup key).

## Clarified Problem Statement

**Goal:** After delete→reinstall→paste same `nsec`, restore Marmot chat list + decryptable history via a **Signal-like encrypted backup stored on Blossom**, with Hedwig able to run (and prefer) its own Blossom for reliable retention — without making Keychain survival the product path.

**Constraints:**
- Explicit nsec paste on onboarding is the restore trigger (3A).
- Cross-platform parity (`ios/` + `apps/sonar/`).
- Local-first: restore paints from the decrypted local backup first; relay sync is background catch-up only.
- Ciphertext only on Blossom; server never sees plaintext chats or `db_key` / nsec.
- Panic wipe must cover local state; remote backup deletion (or tombstone) must be an explicit product decision.
- Mesh/BLE DMs stay local-only (prior decision) unless later opted into the backup payload.
- Do not commit secrets; never log nsec.
- Reuse existing Blossom client/auth paths where possible; do not overload media CDN semantics without quotas.

**Non-goals (v1):**
- Keychain/Keystore surviving uninstall as the primary story.
- Recovering mesh/BLE transcripts (unless explicitly added to the backup blob later).
- Full Signal multi-device live sync (MIP-00 multi-KeyPackage) as a substitute for backup.
- Relying on `nostr.download` alone for durable account backups without an SLA.

**Success criteria:**
- TestFlight honesty: today, nsec restore ≠ chat history (Approach A).
- With backup enabled: wipe phone → reinstall → paste nsec → Home shows prior Marmot conversations from local restore; wallet still matches.
- Hedwig Blossom (or staged equivalent) accepts authenticated BUD-02 uploads, retains backup blobs per published policy, and supports delete-on-wipe when we choose that semantics.
- User can point kind-10063 at a self-hosted Blossom; Hedwig default is documented.

## Approaches Considered

### Approach A: Honesty layer only (docs + onboarding copy + test plan)
- Sketch: TestFlight / restore UI: “Same key restores account + wallet; chat history needs backup (coming).”
- Affected: `ios/TestFlight/WhatToTest.md`, `SonarOnboardingScreen` (iOS + Compose), `WHITEPAPER.md` if needed.
- Tradeoffs: Immediate; does not meet 4B.
- Effort: S

### Approach B: User-exported encrypted file (no Blossom)
- Sketch: Settings export of encrypted Marmot blob; user saves to Files / AirDrop; import after restore.
- Tradeoffs: Works offline; easy to forget before delete; no “Signal cloud” feel.
- Effort: M

### Approach C (superseded shape): Encrypted events on relays
- Sketch: Put MLS snapshots in Nostr events. Rejected as primary: size/retention poor vs blobs; Blossom already exists for large ciphertext.

### Approach D: Multi-KeyPackage / new MLS device only
- Sketch: Reinstall = new device. Insufficient alone when the sole device’s MLS state was wiped.
- Effort: L (complementary later, not the reinstall fix)

### Approach E: Signal-like encrypted backup on Blossom (**chosen product direction**)
- Sketch:
  1. **Client:** Periodically and/or on “Backup now”, build an encrypted backup package (Marmot SQLCipher DB + db_key, or a portable MLS+transcript format). Outer encryption keyed via domain-separated KDF from nsec (and/or optional user passphrase like Signal’s backup key). Upload ciphertext with existing BUD-02 auth. Publish a small **replaceable backup manifest** (Nostr event pointing at blob hash/URL + version + created_at) so restore can find the latest backup without scanning Blossom.
  2. **Restore:** After nsec paste, fetch manifest → download blob → decrypt → replace/open local store → local-first Home paint → background relay catch-up.
  3. **Server:** Run a **Hedwig Blossom** (dedicated or clearly quota’d for backups) so retention, auth, delete, and abuse controls are ours. Keep kind-10063 override for power users. Do **not** treat `https://nostr.download` as the backup SLA.
- Affected (client): `core/sonar-core` backup module + FFI; `MarmotService` / `SonarCore` restore path; Settings + onboarding UI both apps; kind-10063 / default server selection.
- Affected (server): new Hedwig Blossom deploy (BUD-01/02/03), retention policy, per-pubkey quota, delete API for panic-wipe, monitoring (can extend `sonar-status` Blossom probe).
- Tradeoffs: Matches Signal mental model and 4B; needs infra + careful wipe/privacy semantics; backup size grows with history; must not block chat open on backup upload/download.
- Effort: L (client M–L + server M)

## Recommendation

1. **Approach A now** (TestFlight / restore copy) so users are not surprised.
2. **Approach E as the feature**: Signal-like encrypted backup on Blossom, with **Hedwig-operated Blossom** as the default/reliable target and self-hosted override via kind-10063.
3. Keep **Approach B** as a power-user offline escape hatch (optional v1.1), not the primary path.
4. **Approach D** remains a separate multi-device track; it does not replace backup.

## Infrastructure note (own Blossom)

Today media falls back to a third-party host. Account backup needs:
- Predictable **retention** (weeks/months; documented)
- **Per-npub quota** and auth (BUD-02 signed uploads)
- **Delete** on panic-wipe / disable-backup
- Ops: uptime probe (extend status `media` / new `backup` check), backups-of-backups if we care about durability

Prefer a **dedicated backup Blossom** (or path/quota class) separate from chat media CDN so a viral video upload cannot evict someone’s only reinstall lifeline. Happy to revisit if one hardened cluster with strict namespaces is enough.

## Open questions

- Auto backup cadence: on-by-default periodic (Signal-like) vs manual-first v1?
- Backup encryption: nsec-only KDF vs additional user passphrase (Signal AEP-style)?
- Panic wipe: delete remote Blossom backup automatically, or leave remote until explicit “delete backup”?
- Include media ciphertext references only, or re-embed attachments in the backup blob?
- Manifest event kind: new parameterized replaceable kind vs reuse an existing Sonar kind namespace?
- Hostname: e.g. `blossom.sonar.hedwig.sh` / `backup.sonar.hedwig.sh` — confirm with ops.
- Wallet: regression-test Breez re-derive from nsec after restore on both platforms.
