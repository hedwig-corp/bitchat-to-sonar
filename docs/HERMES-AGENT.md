# Running Sonar as a Hermes Agent

Status: operator runbook for driving `sonar-cli` (see `core/sonar-cli`) as an
autonomous agent from
[Hermes Agent](https://hermes-agent.nousresearch.com/docs) by Nous Research.

**Choose an integration path:**

| Path | Best for | Agent loop | Transport |
|------|----------|------------|-----------|
| **A. Native gateway (recommended)** | Production DMs with full tool/MCP/memory parity (same as Telegram) | `hermes gateway` + `SonarAdapter` | Long-running `sonar-cli listen` child process |
| **B. Cron + skill (minimal)** | No gateway plugin; smallest moving parts | Hermes cron + `terminal` toolset | `sonar-cli listen --once` on an interval |

Both paths use the same `sonar-cli` JSON contract and `SONAR_CLI_HOME` identity.
**Never run two listeners** (gateway + legacy bridge, or gateway + cron drain) on
the same identity — duplicate replies and pairing pressure.

---

## Shared prerequisites

- Hermes Agent installed and authenticated.
- **Correct binary:** crates.io `nostr-cli` is **not** Sonar. Verify:

  ```bash
  sonar-cli --help
  # Must list: init, identity, publish, send, listen, groups, messages, post
  ```

- **Web tools:** set `web.backend` (e.g. `searxng`) in `~/.hermes/config.yaml` or
  gateway/bridge subprocesses may fail with *"Web tools aren't configured"*.
- **Config safety:** edit `~/.hermes/config.yaml` with `hermes config set` or
  targeted patches — **never overwrite the whole file** with a partial snippet.
  A truncated config (only `gateway.platforms.sonar.extra`) breaks Sonar silently.
  Keep backups under `~/.hermes/state-snapshots/` before bulk edits.

### Build `sonar-cli`

From this repo's `core/` workspace:

```bash
cd core
cargo build -p sonar-cli --release
install -m 755 target/release/sonar-cli ~/.local/bin/sonar-cli
```

Media/voice builds expose `send --file` and `--kind voice` on `send --help`.

### Provision the agent identity (one-time)

```bash
export SONAR_CLI_HOME="$HOME/.sonar-agent"
sonar-cli init --nsec-file "$HOME/.secrets/sonar-agent.nsec"   # or generate fresh
sonar-cli publish
sonar-cli identity    # share this npub so peers can DM the agent
```

`SONAR_CLI_HOME` is stateful (`config.json`, Marmot DB, `seen.json`). Back it up
before upgrades; do not commit secrets to git.

### Secrets handling (Local Secrets Rule)

- Prefer `init --nsec-file` or `--nsec-env`, not `init --nsec <literal>`.
- Keep nsec and `SONAR_CLI_HOME` outside the repository.

---

## Path A — Native Hermes gateway (recommended)

**Goal:** 1:1 parity with Telegram — same model, tools, memory, skills, MCP — on
encrypted Sonar/Marmot DMs.

**Upstream plugin:** `plugins/platforms/sonar/` in
[NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) (or your
local `~/.hermes/hermes-agent` tree). Optional legacy installer skill:
`sonar-hermes-bridge` on the Hermes skill hub.

### Architecture

```
Sonar app → Nostr relays → sonar-cli listen (gateway child)
         → SonarAdapter → gateway agent loop → sonar-cli send [--file --kind voice]
         → Sonar app
```

### 1. Enable the platform

```bash
hermes config set gateway.platforms.sonar.enabled true
hermes config set gateway.platforms.sonar.extra.sonar_cli_home "$HOME/.sonar-agent"
hermes config set gateway.platforms.sonar.extra.sonar_cli_path "$HOME/.local/bin/sonar-cli"
```

Illustrative `~/.hermes/config.yaml` fragment:

```yaml
gateway:
  platforms:
    sonar:
      enabled: true
      extra:
        sonar_cli_home: ~/.sonar-agent
        sonar_cli_path: ~/.local/bin/sonar-cli
        display_name: "Hermes Agent · Sonar"
        max_chunk_chars: 3200
        authorized_senders:
          - npub1...
        instant_ack_enabled: false
        typing_indicator_enabled: false
web:
  backend: searxng
  searxng_url: https://searx.be   # example
```

After **any** change to `sonar_cli_path`, allowlist, or gateway Sonar keys,
restart the gateway from an SSH shell (not from inside the gateway session):

```bash
systemctl --user daemon-reload
systemctl --user restart hermes-gateway.service
journalctl --user -u hermes-gateway -n 30 --no-pager | grep -i sonar
```

Expect: `[Sonar] listening as npub1...`

### 2. Authorization

The gateway reads **`SONAR_ALLOWED_SENDERS`** (comma-separated npubs) from the
**process environment**. Use at least one of:

1. `~/.hermes/.env`: `SONAR_ALLOWED_SENDERS=npub1...,npub2...`
2. Yaml `authorized_senders` under `gateway.platforms.sonar.extra`
3. `hermes pairing approve sonar <npub>` when pairing mode is active

Systemd must load env (user unit example):

`~/.config/systemd/user/hermes-gateway.service.d/sonar-env.conf`:

```ini
[Service]
EnvironmentFile=-/home/USER/.hermes/.env
Environment=SONAR_CLI_HOME=/home/USER/.sonar-agent
```

Install/start gateway: `hermes gateway install` then enable the user service.

### 3. Disable duplicate listeners

```bash
systemctl --user stop sonar-bridge.service sonar-poller.service 2>/dev/null || true
systemctl --user disable sonar-bridge.service sonar-poller.service 2>/dev/null || true
pgrep -af 'sonar-cli listen'   # should show exactly one, owned by gateway
```

### 4. Verify

From an **authorized** npub, DM the agent npub from `sonar-cli identity`. You
should get a full agent reply (tools/MCP), not a static ping handler.

Cron outbound: `deliver=sonar` or `deliver=sonar:<npub>` with `SONAR_HOME_CHANNEL`
set in env.

### Reply conventions on Sonar

- Plain text DMs (no markdown tables/`**bold**`/headers).
- Match the user's language.
- Signature line, e.g. `— Hermes Agent · Sonar`.
- Long answers: split ~3200 chars per DM; do not hard-truncate at ~2000.
- Voice: `sonar-cli send --file audio.m4a --kind voice` (AAC `.m4a` preferred on iOS).

---

## Path B — Cron-polled drain (minimal, zero gateway code)

**Goal:** always-on auto-reply using **only** the `terminal` toolset and the
committed skill — no Hermes gateway Sonar plugin.

### Architecture

```
Nostr relays  <--Marmot/MLS-->  sonar-cli  <--terminal toolset-->  Hermes Agent
                                    |
                          SONAR_CLI_HOME (identity + seen cursor)
```

- **Relay-only** transport (no BLE mesh from CLI).
- **Runtime:** Hermes runs `sonar-cli listen --once` on a short interval, feeds
  each JSON line to a turn, replies with `sonar-cli send`. Restart-safe via the
  persisted seen cursor.

### Enable terminal + skill

```bash
hermes chat --toolsets "terminal"
# or in ~/.hermes/config.yaml:
# terminal:
#   backend: local

cp core/sonar-cli/hermes/SKILL.md <hermes-skills-dir>/sonar-cli/SKILL.md
```

The skill documents inbound JSON, `listen --once` for polling, and DM-only limits.

### Cron auto-reply loop

Each tick:

```bash
SONAR_CLI_HOME="$HOME/.sonar-agent" sonar-cli listen --once
# for each {"type":"message", "sender", "content", ...} line:
SONAR_CLI_HOME="$HOME/.sonar-agent" sonar-cli send --to <sender> --text "<reply>"
```

Tune interval vs latency. The seen cursor prevents double-processing; `mine:true`
messages are not emitted to the loop.

**Do not use bare `listen` in cron** — it blocks forever. Use `listen --once` or
the gateway path (Path A) for streaming.

---

## Path C — Legacy Python bridge (migration / fallback)

When the gateway plugin is unavailable, use the Hermes skill `sonar-hermes-bridge`
(`install-sonar-bridge.sh`, `~/.sonar-agent/sonar_bridge_hermes.py`). That script
streams `listen`, parses `sender`/`content`, and spawns `hermes chat -q` per
message with `--resume` per `group_id`.

**Disable `gateway.platforms.sonar` before enabling the bridge.** Same single-listener
rule applies.

---

## Command reference

Global flags: `--home <dir>` (defaults to `SONAR_CLI_HOME`), `--relay <wss-url>`
(repeatable).

| Command | Output `type` | Purpose |
| --- | --- | --- |
| `init [--nsec-file p \| --nsec-env VAR \| --nsec s] [--force]` | `identity` | Provision/replace identity. |
| `identity` | `identity` | npub, pubkey hex, home, config path. |
| `publish` | `published` | Publish Marmot KeyPackage. |
| `send --to <npub\|hex> --text <s> [--file path --kind voice]` | `sent` | DM (find/create 1:1 group). |
| `listen [--once] [--timeout-secs n] [--poll-secs n] [--no-publish]` | `message` | Inbound messages as JSON lines. |
| `groups` | `group` | List Marmot groups. |
| `messages [--group <hex>]` | `message` | History (includes `mine:true`). |
| `post <signal-link> [...]` | `posted_sticker_pack` | Sticker pack import. |

Inbound message line:

```json
{"type":"message","group_id":"...","id":"...","sender":"npub1...","content":"...","created_at_secs":123,"mine":false}
```

| Rule | Detail |
|------|--------|
| Reply target | `send --to <sender>` (npub from inbound line) |
| Field names | Use `sender` and `content`, not `from` / `text` |
| DMs | Do not use `send --group` for 1:1 replies |
| Polling | `listen --once` only in scripts/cron |
| Streaming | bare `listen` for gateway/bridge only |

---

## Pitfall checklist

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| No replies / silent drop | `SONAR_ALLOWED_SENDERS` missing or fewer npubs than yaml | Align `.env`, yaml, `bridge_config.json`; restart gateway |
| `[Sonar] send failed` / wrong binary | Stale `sonar_cli_path` or gateway not restarted | Set path to real binary; `systemctl --user restart hermes-gateway` |
| Truncated / broken Hermes | Partial overwrite of `config.yaml` | Restore from `state-snapshots`; use `hermes config set` only |
| Duplicate replies | Gateway + bridge/cron both listening | Stop legacy bridge/poller; one `listen` only |
| Web tools fail in service only | `.env` not loaded | `EnvironmentFile` in systemd drop-in |
| Wrong CLI on PATH | `nostr-cli` impostor | Remove; verify subcommands on `sonar-cli --help` |
| “Too many pairing requests” | Pairing mode + extra traffic | Allowlist env; disable typing spam; see `sonar-hermes-bridge` skill |
| Voice fails on iOS | Wrong container/codec | AAC `.m4a`; media-capable `sonar-cli` build |

---

## Known gaps

- **Group replies:** `send` targets npubs (1:1 DM groups only); no `send --group`.
- **No BLE mesh** from CLI (relay-only).

Optional future: stdio MCP wrapper around `sonar-cli` in `mcp_servers` — more
work than Path A or B; not required for auto-reply.

---

## Smoke test (two isolated homes)

```bash
A=$(mktemp -d); B=$(mktemp -d)
sonar-cli --home "$A" init >/dev/null; sonar-cli --home "$A" publish >/dev/null
sonar-cli --home "$B" init >/dev/null; sonar-cli --home "$B" publish >/dev/null
NPUB_B=$(sonar-cli --home "$B" identity | python3 -c 'import sys,json;print(json.load(sys.stdin)["npub"])')

sonar-cli --home "$A" send --to "$NPUB_B" --text "ping"
sonar-cli --home "$B" listen --once
sonar-cli --home "$B" listen --once   # should emit nothing (cursor)
```

Relay propagation may need a short retry on the first `listen --once`.

---

## Related docs

- `core/sonar-cli/hermes/SKILL.md` — agent-facing CLI contract
- `core/sonar-cli/README.md` — binary reference
- Hermes plugin README: `hermes-agent/plugins/platforms/sonar/README.md`
- Legacy bridge skill: `sonar-hermes-bridge` (Hermes skill hub / devops)