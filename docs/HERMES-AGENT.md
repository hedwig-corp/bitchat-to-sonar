# Hermes Agent integration

Status: **stable operator guide** (2026-07). This document explains how to run
[Hermes Agent](https://hermes-agent.nousresearch.com/docs) as an autonomous
assistant over Sonar / Marmot encrypted direct messages, using the headless
**`sonar-cli`** binary from this repository (`core/sonar-cli`).

Hermes is **not** built into Sonar. Integration is a thin contract: Hermes (or
any agent runtime) shells out to `sonar-cli` for transport. The recommended
production setup uses the **Hermes gateway Sonar platform plugin** so Sonar DMs
get the same agent loop as Telegram (tools, memory, skills, MCP).

## What belongs where

| **bitchat-to-sonar (this repo)** | **hermes-agent** |
|----------------------------------|------------------|
| `sonar-cli` binary, Marmot protocol, apps | `plugins/platforms/sonar/` (`SonarAdapter`) |
| `docs/HERMES-AGENT.md` (this page) | Gateway config, cron `deliver=sonar`, skills |
| `core/sonar-cli/hermes/SKILL.md` | Optional community skill `sonar-cli` / `sonar-hermes-bridge` |

Do not fork Sonar protocol logic into Hermes. Do not embed Hermes into
`sonar-cli`. Keep the **CLI JSON contract** stable (see below).

---

## Architecture options

Choose **one** inbound listener per agent identity. Running two modes together
duplicate-processes `sonar-cli listen` and causes **duplicate replies**.

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
                    ┌─────────────────────────────────────┐
  Sonar app ──DM──► │ Nostr relays (Marmot / MLS)         │
                    └─────────────────┬───────────────────┘
                                      │
                    ┌─────────────────▼───────────────────┐
                    │ sonar-cli listen  (JSON lines)      │
                    └─────────────────┬───────────────────┘
          ┌───────────────────────────┼───────────────────────────┐
          │                           │                           │
   ┌──────▼──────┐            ┌───────▼────────┐           ┌──────▼──────┐
   │ A. Gateway  │            │ B. Legacy      │           │ C. Cron     │
   │ SonarAdapter│            │ Python bridge  │           │ listen --once│
   │ (preferred) │            │ hermes chat -q │           │ + terminal  │
   └──────┬──────┘            └───────┬────────┘           └──────┬──────┘
          │                           │                           │
          └───────────────────────────┼───────────────────────────┘
                                      │
                    ┌─────────────────▼───────────────────┐
                    │ Hermes agent (model + tools)        │
                    └─────────────────┬───────────────────┘
                                      │
                    ┌─────────────────▼───────────────────┐
                    │ sonar-cli send --to <npub> …        │
                    └─────────────────────────────────────┘
```

| Mode | When to use | Listen style |
|------|-------------|--------------|
| **A. Native gateway** | Always-on DM agent with sessions, voice, cron delivery | Long-lived `sonar-cli listen` (subprocess of `hermes gateway`) |
| **B. Legacy bridge** | Hermes without gateway plugin; migration | Streaming `listen` in a Python service |
| **C. Cron + terminal** | Minimal setup; higher latency | `listen --once` on a schedule |

Transport is **relay-only**. `sonar-cli` does not drive BLE mesh; peers reach
the agent over Nostr relays when they know the agent `npub`.

---

## Prerequisites

- **Hermes Agent** installed with a working model provider and toolsets (at
  minimum `terminal` for mode C; full toolsets for A/B).
- **Web search backend** configured in Hermes (`web.backend`, e.g. searxng) if
  the agent uses web tools — otherwise subprocesses fail with *"Web tools aren't
  configured"* even when the CLI works.
- Rust toolchain to build `sonar-cli`, or a prebuilt binary on `PATH`.
- **Config safety:** edit `~/.hermes/config.yaml` with `hermes config set` or
  targeted patches — **never overwrite the whole file** with a partial snippet.
  A truncated config (e.g. only `gateway.platforms.sonar.extra`) breaks Sonar
  silently. Keep backups under `~/.hermes/state-snapshots/` before bulk edits.

### Build `sonar-cli`

```bash
cd core
cargo build -p sonar-cli --release
install -m 755 target/release/sonar-cli ~/.local/bin/sonar-cli
```

**Verify you have Sonar CLI, not crates.io `nostr-cli`:**

```bash
sonar-cli --help
# Must include: init, identity, publish, send, listen, groups, messages

sonar-cli send --help | grep -E 'file|kind'   # optional: media / voice builds
```

### Agent identity (one-time)

Use an isolated home directory — never share with a human Sonar client:

```bash
export SONAR_CLI_HOME="$HOME/.sonar-agent"
mkdir -p "$SONAR_CLI_HOME"

# Prefer file or env for nsec — not literal on argv (shell history).
sonar-cli init --nsec-file "$HOME/.secrets/sonar-agent.nsec"
sonar-cli publish
sonar-cli identity    # capture npub — users DM this address
```

`init` writes `config.json` and Marmot state under `SONAR_CLI_HOME` with
restricted permissions on Unix. **Back up** this directory before upgrades;
deleting it creates a new identity.

#### Secrets handling

- Use `init --nsec-file` or `--nsec-env`, not `init --nsec <literal>`.
- Keep `SONAR_CLI_HOME` and key material **outside** git.
- Same nsec → same npub on any host.

---

## Mode A — Native Hermes gateway (recommended)

Hermes ships a platform plugin: `hermes-agent/plugins/platforms/sonar/`. It
spawns `sonar-cli listen`, maps inbound JSON to `MessageEvent`, runs the normal
gateway agent loop, and replies via `sonar-cli send` (and `send --file --kind
voice` when supported).

### Enable Sonar platform

```bash
hermes config set gateway.platforms.sonar.enabled true
```

Example `~/.hermes/config.yaml`:

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
          - npub1YOUR_PEER_HERE
        instant_ack_enabled: false
        typing_indicator_enabled: false
```

### Authorization

The gateway enforces who may DM the agent:

1. **`SONAR_ALLOWED_SENDERS`** — comma-separated npubs in the gateway process
   environment (e.g. `~/.hermes/.env`).
2. **`authorized_senders`** in yaml — mirrored into env by the adapter when env
   is empty.
3. **`hermes pairing approve sonar <npub>`** when using pairing mode.

For systemd, load env into the gateway unit:

```ini
# ~/.config/systemd/user/hermes-gateway.service.d/sonar-env.conf
[Service]
EnvironmentFile=-/home/USER/.hermes/.env
Environment=SONAR_CLI_HOME=/home/USER/.sonar-agent
```

```bash
hermes gateway install   # if not already
systemctl --user daemon-reload
systemctl --user restart hermes-gateway.service
```

### Disable duplicate listeners

If you previously ran a Python bridge or poller:

```bash
systemctl --user stop sonar-bridge.service sonar-poller.service 2>/dev/null || true
systemctl --user disable sonar-bridge.service sonar-poller.service 2>/dev/null || true
```

Confirm a **single** `sonar-cli listen`:

```bash
pgrep -af 'sonar-cli listen'
```

### Verify

```bash
journalctl --user -u hermes-gateway -n 100 --no-pager | grep -i sonar
```

From an authorized npub, send a DM to the agent npub from `sonar-cli identity`.
Expect a full model reply (tools, memory), not a static ping handler.

### Reply UX on Sonar

- **Plain text** in DMs (no markdown tables or `**bold**` — the app is not Telegram).
- Match the user’s language.
- Long answers: split into multiple messages (~3200 chars); optional `[1/N]` prefix.
- **Voice outbound:** build with media-capable CLI; prefer AAC `.m4a` for iOS;
  gateway may transcode via ffmpeg.

### Cron delivery to Sonar

With the gateway enabled, scheduled jobs may use `deliver=sonar` or
`deliver=sonar:<npub>` (set `SONAR_HOME_CHANNEL` for a default npub).

---

## Mode B — Legacy Python bridge

Use when the gateway Sonar plugin is unavailable. Community automation lives in
the Hermes skill **`sonar-hermes-bridge`** (install script, `bridge_config.json`,
systemd unit). The bridge:

1. Runs streaming `sonar-cli listen`
2. Parses JSON (`sender`, `content` — not `from` / `text`)
3. Invokes `hermes chat -q "..." -Q --yolo --resume <session_id> -t "..."`
4. Sends reply with `sonar-cli send --to <sender>`

**Disable gateway Sonar** before enabling the bridge. Load `~/.hermes/.env` into
the bridge subprocess so API keys and web backends match interactive Hermes.

---

## Mode C — Cron-polled `listen --once` (minimal)

Original zero-code pattern: Hermes cron runs `sonar-cli listen --once` every
~30s, agent handles each line via the `terminal` toolset, replies with `send`.

```bash
SONAR_CLI_HOME="$HOME/.sonar-agent" sonar-cli listen --once
# for each {"type":"message", "sender", "content", ...}:
SONAR_CLI_HOME="$HOME/.sonar-agent" sonar-cli send --to <sender> --text "<reply>"
```

Install the skill shipped in this repo:

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

```bash
mkdir -p ~/.hermes/skills/sonar-cli
cp core/sonar-cli/hermes/SKILL.md ~/.hermes/skills/sonar-cli/SKILL.md
```

Tune poll interval vs latency. The seen cursor in `SONAR_CLI_HOME` prevents
double-processing; `listen` does not emit `mine: true` lines.

**Never** run bare `sonar-cli listen` from a one-shot tool call — it blocks
forever. Use `--once` or `--timeout-secs`.

---

## Stable CLI contract (do not break without versioning)

Integrators depend on these shapes. If you change field names or semantics, bump
documented version and coordinate with `hermes-agent` tests
(`tests/gateway/test_sonar_platform.py`).

### Inbound (`listen`)

One JSON object per line:

```json
{
  "type": "message",
  "group_id": "<hex>",
  "id": "<hex>",
  "sender": "npub1...",
  "content": "plain text",
  "created_at_secs": 1718900000,
  "mine": false
}
```

| Field | Notes |
|-------|--------|
| `sender` | Reply with `send --to <sender>` — **not** `from` |
| `content` | Body — **not** `text` |
| `id` | Dedupe key |
| `mine` | Integrators must skip when `true` |
| `media` | Optional on voice/image inbound; text agents may ignore until handled |

### Outbound text

```bash
sonar-cli send --home "$SONAR_CLI_HOME" --to npub1... --text "reply"
```

Do **not** use `send --group` for 1:1 DM replies.

### Outbound media (voice / image / video)

When the binary supports it:

```bash
sonar-cli send --to npub1... --file /path/to/audio.m4a --kind voice
```

Global flags: `--home <dir>` (else `SONAR_CLI_HOME`), `--relay <wss>` (repeatable).

### Command summary

| Command | Output `type` | Purpose |
| --- | --- | --- |
| `init` | `identity` | Provision identity |
| `identity` | `identity` | npub, pubkey hex, paths |
| `publish` | `published` | KeyPackage to relays |
| `send --to … --text …` | `sent` | DM text |
| `send --to … --file … --kind voice` | `sent_media` | DM attachment |
| `listen [--once]` | `message` | Inbound drain |
| `groups` | `group` | List groups |
| `messages` | `message` | History (includes `mine:true`) |

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

---

## Known limitations

- **Group replies:** `send` targets an npub (1:1 DM). No `send --group <id>` for
  multi-member groups; integrators can read group lines from `listen` but only
  reply in DMs unless CLI gains group send.
- **No BLE mesh** for the CLI agent — relay path only.
- **Inbound voice** may require integrator support for `media[]` when `content`
  is empty.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| No reply | Sender not allowlisted | `SONAR_ALLOWED_SENDERS` / yaml list |
| Duplicate replies | Gateway + bridge both listening | Stop legacy bridge service |
| Parser drops messages | Wrong JSON fields | Use `sender` / `content` |
| Wrong binary | `nostr-cli` on PATH | Reinstall from this repo |
| Web tools fail in service | `.env` not loaded | systemd `EnvironmentFile` or bridge `load_hermes_env` |
| Voice fails on iOS | Opus OGG or old CLI | Media build + `.m4a` / AAC |
| `listen` hangs tool | Missing `--once` | Cron/tool calls must use `--once` |
| Truncated / broken Hermes | Partial overwrite of `config.yaml` | Restore from `state-snapshots`; use `hermes config set` only |
| "Too many pairing requests" | Pairing mode + extra traffic | Allowlist via env; disable typing/ack spam |

---

## Smoke test (two temp homes)

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

Relay propagation can take a few seconds; retry `listen --once` if needed.

---

## Relay smoke (Hermes-driven)

The daily relay gate is `scripts/smoke/relay-smoke.sh` (`docs/RELAY-SMOKE.md`),
scheduled on this Hermes host (Mode C: cron + terminal), not CI. The Hermes
agent runs the harness and can then read its metrics for an adaptive triage of
what it flagged.

```bash
# latest gate result (metrics.json written by the last run)
jq '{overall, target_loss_pct: .target.loss_pct, control_loss_pct: .control.loss_pct}' metrics.json

# adaptive probe: ephemeral identities, receiver subscribed BEFORE the send
A=$(mktemp -d); B=$(mktemp -d); R=wss://nostr.relay.hedwig.sh
sonar-cli --home "$A" --relay "$R" init >/dev/null;  sonar-cli --home "$A" --relay "$R" publish >/dev/null
sonar-cli --home "$B" --relay "$R" init >/dev/null;  sonar-cli --home "$B" --relay "$R" publish >/dev/null
NPUB_B=$(sonar-cli --home "$B" --relay "$R" identity | jq -r .npub)
( sonar-cli --home "$B" --relay "$R" listen --timeout-secs 20 --no-publish ) &
sleep 5
sonar-cli --home "$A" --relay "$R" send --to "$NPUB_B" --text "probe-$RANDOM"
wait
```

The receiver must be subscribed before the send (gift-wrap events arrive live);
the gate proves the same flow works on the control relays, so a target-only
failure points at the relay. Report triage to the ops npub with `send --to` and
optionally summarise a hypothesis as a comment on the open `[relay-smoke]` issue.

---

## Optional: MCP wrapper

For structured tools instead of shell, a thin stdio MCP server can wrap
`sonar-cli` and register under `mcp_servers` in Hermes. This is optional; modes
A–C do not require it.

---

## Further reading

- Hermes gateway plugin README: `hermes-agent/plugins/platforms/sonar/README.md`
- Hermes docs: https://hermes-agent.nousresearch.com/docs
- Agent skill (terminal contract): `core/sonar-cli/hermes/SKILL.md`

Relay propagation may need a short retry on the first `listen --once`.

---

## Related docs

- `core/sonar-cli/hermes/SKILL.md` — agent-facing CLI contract
- `core/sonar-cli/README.md` — binary reference
- Hermes plugin README: `hermes-agent/plugins/platforms/sonar/README.md`
- Legacy bridge skill: `sonar-hermes-bridge` (Hermes skill hub / devops)
