# Signal-like Blossom account backup (v1)

## Clarified problem

Delete → reinstall → paste the same `nsec` restored identity + Lightning wallet
but not Marmot chats (fresh SQLCipher DB + random host `db_key`). Users need a
Signal-style encrypted backup so chat history returns with the nsec.

## Recommended approach (shipped)

Encrypt `db_key` + Marmot DB (+ conversation index) with an HKDF key derived
from the account nsec (`sonar-backup` / `sonar-account-backup-v1`), AEAD with
ChaCha20-Poly1305, upload to Blossom as `application/vnd.sonar.account-backup-v1`.

- **Backup now** (Settings): close node → upload → reconnect
- **Restore** (onboarding / Settings nsec paste): wipe → import nsec → try
  download latest backup → persist restored `db_key` → connect
- Soft-fail when no backup / offline: identity + wallet still restore; chats empty
- Default Blossom host: `https://nostr.download` (same media fallback); Hedwig
  dedicated Blossom is a follow-up

## Explicit non-goals (v1)

- Auto backup on every send
- Optional passphrase beyond nsec
- Remote delete on panic wipe
- Mesh/BLE history (local-only by design)
