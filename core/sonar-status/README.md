# sonar-status

Probe Sonar-adjacent systems and publish a **replaceable Nostr status document**
that the marketing site (`web/` `/status`) can fetch and render.

## Contract (must match the website)

| Field | Value |
| --- | --- |
| Kind | `30078` (parameterized replaceable) |
| `d` tag | `sonar-status` |
| Content | JSON `{ services, relays, incidents }` |
| Author | ops status key (`STATUS_PUBKEY_HEX` on the site) |

Schema details: [`docs/SONAR-STATUS.md`](../../docs/SONAR-STATUS.md).

## Build

```bash
cargo build -p sonar-status --release --manifest-path core/Cargo.toml
```

Binary: `core/target/release/sonar-status`.

## Commands

```bash
# Probe only (stdout JSON matching the website parser)
cargo run -p sonar-status --manifest-path core/Cargo.toml -- probe --pretty

# Optional HTTP health checks (GET)
cargo run -p sonar-status --manifest-path core/Cargo.toml -- \
  probe --http https://example.com/health --pretty

# Show pubkey for a secret (never commit the nsec)
export SONAR_STATUS_NSEC=nsec1…   # or 64-char hex
cargo run -p sonar-status --manifest-path core/Cargo.toml -- identity

# Sign + publish (or --dry-run)
cargo run -p sonar-status --manifest-path core/Cargo.toml -- \
  publish --nsec-file ~/.config/sonar/status.nsec \
  --out /var/lib/sonar-status/last.json

# Cron-friendly wrapper
./scripts/status/publish.sh
```

## Secrets

- **Never** commit `nsec` / hex secrets.
- Prefer `--nsec-file` (mode `0600`) or `SONAR_STATUS_NSEC` in a secret store / CI.
- After first publish, set on the website:

```js
// web/src/lib/status-data.js
export const STATUS_PUBKEY_HEX = '<identity pubkey_hex>';
export const STATUS_NPUB = '<identity npub>';
```

## What is probed today

1. **Sonar client bootstrap relays** — WebSocket open RTT to the same default
   set iOS/Android use (`damus`, `nos.lol`, `primal`, `offchain.pub`,
   `nostr21.com`, `kaleidoswap`, `nostr.relay.hedwig.sh`). Published as service
   `id: "relays"`.
2. **Optional HTTP URLs** (`--http` / `SONAR_STATUS_HTTP`) — GET health checks
   become extra service rows (`id: "http-<host>"`).

Application rows (DM, groups, media, push, payments, calls) are **not** mocked.
They appear only when a dedicated probe exists — see
[`docs/SONAR-STATUS.md`](../../docs/SONAR-STATUS.md) § "Real service probes".

## Incident continuity

Pass `--previous /path/to/last.json` (the `--out` file from the last run) so
open auto-incidents get Monitoring/Resolved updates instead of a new incident
every poll.
