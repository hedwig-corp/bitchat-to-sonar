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

---

## Smoke test (two temp homes)

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

## Optional: MCP wrapper

For structured tools instead of shell, a thin stdio MCP server can wrap
`sonar-cli` and register under `mcp_servers` in Hermes. This is optional; modes
A–C do not require it.

---

## Further reading

- Hermes gateway plugin README: `hermes-agent/plugins/platforms/sonar/README.md`
- Hermes docs: https://hermes-agent.nousresearch.com/docs
- Agent skill (terminal contract): `core/sonar-cli/hermes/SKILL.md`