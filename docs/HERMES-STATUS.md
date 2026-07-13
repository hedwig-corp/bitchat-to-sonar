# Hermes task: Sonar status monitor

How to run `sonar-status` from a Hermes agent / cron without inventing status JSON.

## Roles

| Component | Role |
| --- | --- |
| `sonar-status` | Probe + sign kind `30078` |
| Hermes | Schedule + secrets + alert on failure |
| Website `/status` | Display feed |

Do **not** use the Hermes chat agent nsec as the status publisher or chat probe key.

## One-time setup

```bash
# Publisher (public status document)
openssl rand -hex 32 > ~/.config/sonar/status.hex
chmod 600 ~/.config/sonar/status.hex
cargo run -p sonar-status --manifest-path core/Cargo.toml -- \
  identity --nsec-file ~/.config/sonar/status.hex
# → put pubkey_hex / npub into web/src/lib/status-data.js and deploy

# Chat probe identity (Marmot KeyPackage path)
openssl rand -hex 32 > ~/.config/sonar/status-probe.hex
chmod 600 ~/.config/sonar/status-probe.hex
```

## Scheduled task (every 10 minutes)

```bash
export SONAR_STATUS_NSEC_FILE="$HOME/.config/sonar/status.hex"
export SONAR_STATUS_PROBE_NSEC_FILE="$HOME/.config/sonar/status-probe.hex"
export SONAR_STATUS_CHAT_PROBE=1
# optional: export SONAR_STATUS_HTTP="https://example/health"
/path/to/bitchat-to-sonar/scripts/status/publish.sh
```

On non-zero exit: notify ops (Hermes DM / gateway alert).

Optional post-step: parse `~/.local/state/sonar-status/last.json` and alert if any
`services[].state` is `degraded` or `down`.

## What gets measured

- `relays` — always
- `dm` — when `SONAR_STATUS_CHAT_PROBE=1` + probe nsec (KeyPackage publish/fetch)
- `http-*` — when `SONAR_STATUS_HTTP` is set

See [`SONAR-STATUS.md`](SONAR-STATUS.md) for the full contract.
