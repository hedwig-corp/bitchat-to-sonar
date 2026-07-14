# Delete app → reinstall → restore same nsec (same phone)

Date: 2026-07-15
Status: clarified (brainstorm; no code changes)
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

## Clarified Problem Statement

**Goal:** Tell the truth about delete→reinstall→same-nsec restore on iOS and Android, then close the gap so Marmot chat list + decryptable history return without relying on Keychain surviving uninstall.

**Constraints:**
- Explicit nsec paste on onboarding is the restore trigger (3A); no silent Keychain resurrection as the product path.
- Cross-platform parity (`ios/` + `apps/sonar/`).
- Local-first: restore must not block first paint on full relay history; background repair only.
- Panic wipe and “erase all chats” must still be able to destroy local material; a backup path must be user-driven or clearly gated.
- Mesh/BLE DMs stay local-only (prior decision).
- Do not commit secrets; never log nsec.

**Non-goals:**
- Automatic Keychain/Keystore survival across uninstall as the primary story.
- Recovering mesh/BLE transcripts after delete.
- Full Signal-style multi-device fan-out in the first ship (can be a later approach).
- Cloud vendor backup (iCloud/Drive) as the only mechanism.

**Success criteria:**
- TestFlight / docs state clearly: nsec restore → same identity + wallet; Marmot history **today** does not (gap called out).
- Personal wipe+restore with nsec: after the chosen fix, Home shows prior Marmot conversations and opens transcripts from local storage (rehydrated), wallet balance matches.
- Fresh install without paste still starts a **new** account (no accidental reuse).
- Panic wipe still leaves nothing useful on device; optional backup is explicit.

## Approaches Considered

### Approach A: Honesty layer only (docs + onboarding copy + test plan)
- Sketch: Document the table above in TestFlight notes / restore UI: “Same key restores your account and wallet; chat history on this phone is wiped with the app until we ship backup.” No protocol change.
- Affected: `ios/TestFlight/WhatToTest.md`, `SonarOnboardingScreen` (iOS + Compose), maybe `WHITEPAPER.md` / help if present.
- Tradeoffs: Unblocks TestFlight expectations immediately; does **not** meet 4B.
- Effort: S

### Approach B: User-exported encrypted Marmot backup (file / QR chunk), restore with nsec
- Sketch: Before delete (or from Settings), export SQLCipher DB + db_key (or a single blob wrapped with a key derived from nsec). On restore after paste, import blob → reopen same MLS state → chats + history paint local-first; relay sync is catch-up only.
- Affected: `MarmotService` / `SonarCore` wipe+import paths, new export FFI, Settings + onboarding restore UI both apps, docs.
- Tradeoffs: Meets 4B for deliberate personal restore; user must export before delete (easy to forget). No automatic multi-device.
- Effort: M

### Approach C: Encrypted Nostr self-backup of MLS/conversation state (identity-keyed)
- Sketch: Periodically (or on background) publish encrypted snapshots of Marmot durable state to relays (or a bounded event stream), decryptable only with nsec. Fresh DB after restore pulls snapshot then catches up. Aligns with earlier “multi-device door” in `2026-06-12-persistent-chats-across-restarts.md`.
- Affected: `core/sonar-core` backup module, FFI, both hosts’ restore connect path, relay bandwidth/retention assumptions.
- Tradeoffs: Best “delete phone app, paste nsec, chats return” UX; largest design surface (retention, size, conflict, wipe semantics, privacy).
- Effort: L

### Approach D: Treat reinstall as new MLS device (multi-KeyPackage / MIP-00)
- Sketch: After restore, publish a new KeyPackage; somehow merge into existing groups as an additional device. Needs White Noise/Marmot multi-device semantics and peer/group cooperation; history still needs a device that still holds old epochs or a backup.
- Affected: core MLS membership, KeyPackage lifecycle, both apps; docs parity matrix already notes multi-device KeyPackage fan-out as out of iOS v1.
- Tradeoffs: Right long-term multi-device shape; **does not alone** recover history after the only device’s DB was wiped.
- Effort: L (and insufficient alone for 4B)

## Recommendation

Ship **Approach A immediately** for TestFlight (5A): stop implying update durability = uninstall durability.

For 4B (personal restore + product bar), prefer **Approach B first** (explicit encrypted backup/restore), then evolve toward **Approach C** if “forgot to export” becomes the real failure mode. Do not sell Approach D as the reinstall fix—without a state backup, a wiped sole device cannot decrypt old epochs.

## Open questions

- Backup UX: Settings-only export, or prompt before “dangerous” flows / periodic reminder?
- Should panic wipe also destroy any Nostr self-backups (C), or only local?
- Wallet: confirm current Breez path still re-derives from nsec on both platforms after restore (regression test in CI).
- Nickname / favorites: restore from profile kind-0 vs. leave blank?
- How long do relays retain kind 445 / giftwraps needed for catch-up after B/C restore?
