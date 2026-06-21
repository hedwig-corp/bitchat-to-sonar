# Running Sonar as a Hermes Agent

Status: draft. This document is the operator runbook for driving `sonar-cli`
(see `core/sonar-cli`) as an autonomous agent from
[Hermes Agent](https://hermes-agent.nousresearch.com/docs) by Nous Research.

The goal is an always-on agent that reads inbound Sonar/Marmot direct messages
and replies, using **zero integration code**: Hermes shells out to the prebuilt
`sonar-cli` binary through its `terminal` toolset, and a `SKILL.md` teaches it
the command contract.

## Architecture

```
Nostr relays  <--Marmot/MLS-->  sonar-cli  <--terminal toolset-->  Hermes Agent
                                    |
                          SONAR_CLI_HOME (identity + seen cursor)
```

- **Transport is relay-only.** `sonar-cli` connects to Nostr relays and speaks
  Marmot (MLS); it does not drive BLE mesh (that lives in the app shells). The
  agent is reachable by any Sonar / White Noise peer over the shared relays,
  whether or not it is co-located with anything.
- **Runtime model is a cron-polled drain loop.** Hermes runs
  `sonar-cli listen --once` on a short interval, feeds each emitted JSON line to
  a turn, and replies with `sonar-cli send`. This is the mode `listen --once`
  was built for, and it is restart-safe via the persisted seen cursor.

## Prerequisites

- Hermes Agent installed, authenticated, with the `terminal` toolset available
  and `terminal.backend: local`.
- A Rust toolchain to build the binary (or a prebuilt `sonar-cli` on `PATH`).

## 1. Build the binary

From the repo's `core/` workspace:

```bash
cd core
cargo build -p sonar-cli --release
# binary at core/target/release/sonar-cli
```

Put it on `PATH` (or reference it by absolute path in the cron command).

## 2. Provision the agent identity (one-time)

Give the agent its own isolated home so it never shares state with a human
client:

```bash
export SONAR_CLI_HOME="$HOME/.sonar-agent"

# Import an existing nsec from a file (preferred), or omit --nsec-file to
# generate a fresh identity.
sonar-cli init --nsec-file "$HOME/.secrets/sonar-agent.nsec"

# Announce the agent's KeyPackage so peers can open a DM with it.
sonar-cli publish

# Confirm and capture the agent npub (share this so people can message it).
sonar-cli identity
```

`init` writes `config.json` (the nsec, the Marmot DB key, and the relay list)
under `SONAR_CLI_HOME`, with `0700` directories and `0600` secret files on Unix.
The encrypted Marmot database and the `seen.json` cursor are created later, on
the first `publish` / `send` / `listen`.

### Secrets handling (Local Secrets Rule)

- Never pass the key as `init --nsec <literal>` — command-line args leak into
  shell history and process listings. Use `--nsec-file <path>` or
  `--nsec-env <VAR>`.
- `SONAR_CLI_HOME` and the `.nsec` file live **outside** the repository. Do not
  commit them. Keep the nsec file in gitignored local storage or a CI/secret
  store, exactly like the Breez key.
- When rebuilding on a new host, recreate or copy the `SONAR_CLI_HOME` directory
  (or re-`init` from the secret store) to preserve the agent's identity — the
  npub is derived from the nsec, so the same nsec restores the same agent.

## 3. Enable the terminal toolset in Hermes

Either start chat with the toolset enabled:

```bash
hermes chat --toolsets "terminal"
```

or configure it in `~/.hermes/config.yaml`. Hermes selects the execution
backend via the `terminal.backend` key — `local`, `docker`, `ssh`,
`singularity`, `modal`, or `daytona`; use `local` for a co-located agent.
Confirm the exact schema against Hermes' config reference; illustratively:

```yaml
terminal:
  backend: local
```

## 4. Install the skill

Copy the committed skill so Hermes knows the `sonar-cli` contract:

```bash
cp core/sonar-cli/hermes/SKILL.md <hermes-skills-dir>/sonar-cli/SKILL.md
```

The skill (`core/sonar-cli/hermes/SKILL.md`) documents the command surface, the
inbound JSON contract, the `listen --once` requirement, and the DM-only /
relay-only limitations.

## 5. Create the auto-reply cron job

Use a Hermes cron job that, every interval, drains new messages and replies.
Expressed as the work each tick performs:

```bash
# every ~30s
SONAR_CLI_HOME="$HOME/.sonar-agent" sonar-cli listen --once
# -> for each emitted {"type":"message", sender, content, ...} line, the agent
#    composes a reply and runs:
SONAR_CLI_HOME="$HOME/.sonar-agent" sonar-cli send --to <sender> --text "<reply>"
```

Tune the interval against acceptable inbound latency: latency is at most one
poll interval. The seen cursor guarantees no message is processed twice, and
`listen` never emits the agent's own messages, so the loop cannot reply to
itself.

## Command reference

All commands accept the global flags `--home <dir>` (defaults to
`SONAR_CLI_HOME`, then an XDG/platform data dir) and `--relay <wss-url>`
(repeatable; overrides the configured relays; defaults: `relay.damus.io`,
`nos.lol`, `relay.primal.net`).

| Command | Output `type` | Purpose |
| --- | --- | --- |
| `init [--nsec-file p \| --nsec-env VAR \| --nsec s] [--force]` | `identity` | Provision/replace the identity. |
| `identity` | `identity` | Print npub, pubkey hex, home, config path. |
| `publish` | `published` | Publish the Marmot KeyPackage. |
| `send --to <npub\|hex> --text <s> [--group-name <s>]` | `sent` | Send a DM (find/create the 1:1 group). |
| `listen [--once] [--timeout-secs n] [--poll-secs n] [--no-publish]` | `message` | Drain inbound messages as JSON lines. |
| `groups` | `group` | List known Marmot groups. |
| `messages [--group <hex>]` | `message` | Print message history (includes `mine:true`). |
| `post <signal-link> [--blossom url] [--site-url url] [--accept-invalid-signal-certs] [--skip-missing-signal-stickers]` | `posted_sticker_pack` | Import + publish a Signal sticker pack. |

Inbound message line:

```json
{"type":"message","group_id":"...","id":"...","sender":"npub1...","content":"...","created_at_secs":123,"mine":false}
```

## Known gaps and follow-ups

- **Group replies are not supported.** `send` only targets an npub and
  finds/creates a 1:1 DM group; there is no `send --group <id>`. The agent can
  read inbound group messages (`listen` emits them) but can only reply to direct
  messages. Follow-up: add a group send target in `core/sonar-cli/src/main.rs`
  (a small change, tracked separately so this integration stays zero-code).
- **No BLE mesh.** Relay-only, as above. Mesh-only nearby peers are out of reach
  for the CLI agent.

## Upgrade path (optional, not required)

If you later want structured tool schemas instead of free-form shell calls,
wrap `sonar-cli` in a thin stdio MCP server and register it in
`~/.hermes/config.yaml`:

```yaml
mcp_servers:
  sonar:
    command: "sonar-mcp"        # a wrapper that shells out to sonar-cli
    args: []
    env:
      SONAR_CLI_HOME: "/home/agent/.sonar-agent"
    tools:
      include: [sonar_send, sonar_poll, sonar_publish]
```

That is strictly more work than the terminal + skill approach above and is not
needed for the autonomous auto-reply loop.

## Smoke test

With two isolated homes on the same machine:

```bash
A=$(mktemp -d); B=$(mktemp -d)
sonar-cli --home "$A" init >/dev/null; sonar-cli --home "$A" publish >/dev/null
sonar-cli --home "$B" init >/dev/null; sonar-cli --home "$B" publish >/dev/null
NPUB_B=$(sonar-cli --home "$B" identity | python3 -c 'import sys,json;print(json.load(sys.stdin)["npub"])')

sonar-cli --home "$A" send --to "$NPUB_B" --text "ping"
sonar-cli --home "$B" listen --once          # emits the "ping" line
sonar-cli --home "$B" listen --once          # emits nothing (cursor works)
```

Relay propagation is not instant; if the first `listen --once` prints nothing,
wait a few seconds and run it again. (The example uses `python3` to read the
npub from the JSON; substitute `jq` or any JSON reader you have.)
