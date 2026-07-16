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

## Shipping a probe change to the bot

`publish.sh` rebuilds `sonar-status` from the checkout on every run, so deploying
a probe change is just `git pull` on the Hermes host — the next scheduled run
picks it up. Cargo is a fast no-op when the tree is unchanged.

The one exception is `SONAR_STATUS_BIN`: setting it opts out of the rebuild, and
the bot will keep running whatever binary it points at. That is a silent
staleness trap — probe changes land in git, every publish still reports healthy,
and the document never changes. If you set it, rebuild it yourself on deploy.

Optional post-step: parse `~/.local/state/sonar-status/last.json` and alert if any
`services[].state` is `degraded` or `down`.

## What gets measured

- `relays` — always (Sonar bootstrap + White Noise interop relays)
- `dm` — when `SONAR_STATUS_CHAT_PROBE=1` + probe nsec (KeyPackage publish/fetch)
- `http-*` — when `SONAR_STATUS_HTTP` is set

See [`SONAR-STATUS.md`](SONAR-STATUS.md) for the full contract.

## Groups probe (5-agent MLS)

1. setup: ./scripts/status/groups-probe.sh --setup
2. run: ./scripts/status/groups-probe.sh
3. publish: SONAR_STATUS_GROUPS_RESULT=... ./scripts/status/publish.sh

Removed: push (not possible), calls (too complex).
