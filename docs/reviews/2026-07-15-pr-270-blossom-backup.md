# Review package — PR #270 Signal-like Blossom account backup

**PR:** https://github.com/hedwig-corp/bitchat-to-sonar/pull/270  
**Branch:** `feat/signal-blossom-account-backup`  
**Status when left:** production-safety fixes applied after specialist review; ready for human review / merge after CI.

## What this does

1. **Settings → Backup chats** (iOS + Compose): close Marmot node → WAL-checkpoint SQLCipher → AEAD-seal `db_key` + DB (+ conversation index) with nsec-derived key → upload to Blossom → reconnect.
2. **Restore account (nsec paste):** wipe old account → import nsec → stage Blossom backup → persist `db_key` → commit files → connect. Missing backup is soft (identity + wallet only).

## Decision log

| Decision | Choice | Why |
|----------|--------|-----|
| Where to store backup | Blossom (BUD-02), MIME `application/vnd.sonar.account-backup-v1` | Signal-like cloud ciphertext; matches existing media upload path |
| Wrapping key | HKDF-SHA256(nsec, salt=`sonar-backup`, info=`sonar-account-backup-v1`) + ChaCha20-Poly1305 | Domain-separated from other nsec uses; AEAD |
| Live `db_key` | Still random host-owned; sealed inside package | Unchanged connect model |
| Restore ordering | Stage → persist key → commit (abort on fail) | Avoids restored ciphertext + freshly minted key |
| Backup consistency | `PRAGMA wal_checkpoint(TRUNCATE)` before `fs::read` | WAL not packaged; Drop alone is insufficient |
| Default server | `https://nostr.download` | Same media fallback; Hedwig Blossom later |
| Auto-backup / passphrase / remote wipe | Deferred | v1 is manual Settings backup |

## Fixes applied after review (before you returned)

From parallel security + concurrency review:

1. **Staged restore** — `restore` writes `*.sonar-restore-staging`; host persists key then `commitAccountRestore` / `abortAccountRestore` on failure.
2. **WAL checkpoint** before packaging; real SQLCipher unit test.
3. **iOS connect fence** — `closeNode(keepClosed:)` during backup/restore FFI; `connectRelaysIfNeeded` respects `busy`.
4. **Exact MIME** match for listing backups.
5. **Compose toast** mirrors iOS (chats recovered vs empty).

## Known follow-ups (non-blocking for v1)

- Dedicated Hedwig Blossom (`backup.sonar.hedwig.sh`)
- Auto / periodic backup
- Optional passphrase beyond nsec
- Panic-wipe remote blob delete
- Package sync/outbox sidecars (messages recover; pending outbox may not)
- Shorten Compose lock hold during upload (availability only)

## How to review / test

1. Read `docs/brainstorms/2026-07-15-signal-blossom-account-backup.md`
2. Skim `core/sonar-core/src/account_backup.rs` + host Settings/restore wiring
3. Manual: Backup chats → toast → delete app / wipe → Restore with same nsec → chats return
4. Manual: Restore without prior backup → identity+wallet, empty chats
5. `cargo test -p sonar-core --lib account_backup` (5 tests)

## Related

- Includes / stacks with #268 nsec restore discoverability + wallet rebuild
- Brainstorm delete/reinstall: #267 / `docs/brainstorms/2026-07-15-delete-reinstall-same-nsec.md` (if present on that branch)
