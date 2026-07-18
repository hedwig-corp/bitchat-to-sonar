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

Optional **chat probe** adds `id: "dm"` via KeyPackage publish+fetch. Other rows (groups, media, …) appear only when their probes exist — see
[`docs/SONAR-STATUS.md`](../../docs/SONAR-STATUS.md) § "Real service probes".

## Incident continuity

Pass `--previous /path/to/last.json` (the `--out` file from the last run) so
open auto-incidents get Monitoring/Resolved updates instead of a new incident
every poll.

### Chat probe (Marmot KeyPackage)

Uses a **dedicated** probe identity (not the status publisher nsec):

```bash
openssl rand -hex 32 > ~/.config/sonar/status-probe.hex
chmod 600 ~/.config/sonar/status-probe.hex

cargo run -p sonar-status --manifest-path core/Cargo.toml -- \
  probe --pretty --chat-probe --probe-nsec-file ~/.config/sonar/status-probe.hex

export SONAR_STATUS_NSEC_FILE=~/.config/sonar/status.hex
export SONAR_STATUS_PROBE_NSEC_FILE=~/.config/sonar/status-probe.hex
export SONAR_STATUS_CHAT_PROBE=1
./scripts/status/publish.sh
```

Publishes service `id: "dm"` when the KeyPackage publish+fetch succeeds.

### Sticker pack directory probe

REQs kind 30031 on bootstrap relays, counts visible sticker packs. No nsec needed.

### Blossom media probe

Compares the app default Blossom server (`DEFAULT_BLOSSOM_SERVER`, today
`https://push.sonar.hedwig.sh`) against the previous public host (default
`https://nostr.download`) and publishes the timings on the `media` status row.

- With a probe nsec: BUD-02 upload + GET + best-effort delete of a ~4 KiB canary
  (this is the latency that matters for media send).
- Without a probe nsec: HTTP HEAD/GET reachability only.

```bash
export SONAR_STATUS_STICKER_PROBE=1
export SONAR_STATUS_MEDIA_PROBE=1
export SONAR_STATUS_PROBE_NSEC_FILE=~/.config/sonar/status-probe.hex
# optional override:
# export SONAR_STATUS_BLOSSOM_SERVER=https://push.sonar.hedwig.sh
# export SONAR_STATUS_BLOSSOM_COMPARE=https://nostr.download
./scripts/status/publish.sh
```

The service description looks like:

```text
primary push.sonar.hedwig.sh upload 116 ms · get 35 ms · candidate nostr.download upload 135 ms · get 37 ms
```

Service state follows the **primary** (app default) only — a slower or failing
compare host is shown in the description without marking Media Messages down.
