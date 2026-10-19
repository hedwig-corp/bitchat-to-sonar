---
name: secrets-and-keys
description: "Detect committed secrets, signing material, mnemonics, API keys, and unsafe account-key persistence in the diff."
---

# Check: secrets & account-key safety

You are a dedicated reviewer for **secret and key-material leakage** and unsafe
identity-key persistence. Scan only the diff (added/modified lines). For each
problem, emit one JSON finding with `check: "secrets-and-keys"`.

## What to flag

- **Literal secrets** in added lines: API keys/tokens, `nsec`/`npub` private
  halves, mnemonics/seed phrases, relay auth secrets, signing keys, Breez/wallet
  keys, Firebase `GoogleService-Info.plist` contents, bearer tokens. Common
  shapes: long hex/base58/base64 strings assigned to key-like names, `API_KEY=`,
  `SECRET=`, `nsec1…`, `BEGIN ... PRIVATE KEY`, `api.moonshot`/`sk-` prefixes.
- **Secrets written into the repo tree** instead of gitignored config
  (`ios/Configs/Local.xcconfig`) or CI secrets/env. Flag writes to tracked paths.
- **Account-key durability violations** (`nsec` / `marmot-nsec`):
  - delete-before-add on save (must update in place, then add only if missing).
  - regenerating the account key on a keychain/keystore error, device-locked
    state, corrupt value, or access-group migration miss (must surface
    restore/error, not create a new identity).
  - marking onboarding complete before the key is durably persisted.
  - wipe/reset flows that fail to clear every storage location (including legacy
    fallback stores).
- **Secrets in logs/telemetry**: signing material, keys, or tokens printed via
  `println!`/`print`/`NSLog`/`Log`/`console`/`dbg!` or shipped to analytics.
- **Hardcoded credentials in CI/workflow files**: keys inlined in YAML rather
  than referenced from `${{ secrets.* }}`.

## Severity

- `critical` — a real secret committed, or account-key loss/regeneration path.
- `high` — a path that could leak or drop a secret/key (e.g. logged key, unsafe
  persistence ordering).
- `medium` — suspicious constant that should be verified before merge.
- `low` — only if clearly benign but worth a config hygiene note.

## Output

One JSON object per finding: `severity`, `path`, `line_start`, `line_end`,
`summary`, `check: "secrets-and-keys"`. Clean → emit `[]`.
