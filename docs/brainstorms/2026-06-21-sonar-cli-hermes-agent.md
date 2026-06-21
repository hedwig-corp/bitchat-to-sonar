# sonar-cli inside Hermes Agent — autonomous agent plan

Date: 2026-06-21
Source: `/brainstorm how to use sonar-cli inside https://hermes-agent.nousresearch.com/docs`

## Decisions (locked)

| Axis | Choice |
| --- | --- |
| Goal | **Autonomous Sonar agent** — Hermes continuously reads inbound messages and auto-replies |
| Runtime | **Co-located on Hermes' host** (same machine), `terminal.backend: local`, persistent `SONAR_CLI_HOME` |
| Effort | **Zero code** — Hermes `terminal` toolset + a committed `SKILL.md`; no new Rust in the hot path |

## Clarified Problem Statement

**Goal:** Stand up an always-on agent where Hermes reads inbound Sonar/Marmot messages and auto-replies, by shelling out to the `sonar-cli` binary co-located on Hermes' host, with no new integration code.

**Constraints:**
- Zero Rust in the integration path. Deliverables are docs + a committed Hermes skill + a built binary (`cargo build -p sonar-cli --release`).
- Hermes `terminal` toolset, `terminal.backend: local`.
- Per-agent identity isolated in its own `SONAR_CLI_HOME` (e.g. `~/.sonar-agent`); nsec loaded via `init --nsec-file`/`--nsec-env`, never `--nsec` (shell-history / process-listing leak — repo **Local Secrets Rule**). The nsec file and `config.json` stay gitignored / outside the repo.
- Inbound loop must use `listen --once` (or `listen --timeout-secs N`), never a bare blocking `listen`, which streams forever and would hang an agent turn.

**Non-goals:** No MCP server, no `serve-mcp` subcommand, no cross-platform bridge, no new app-surface work. (sonar-cli is a headless surface; CLAUDE.md's cross-platform rule covers `ios/` + `apps/sonar/`, not this CLI.)

**Success criteria:**
- A peer DMs the agent → within the poll interval Hermes emits exactly one relevant reply via `sonar-cli send --to <sender-npub>`.
- No duplicate processing across restarts (the `seen.json` cursor persists).
- The agent never replies to its own messages (guaranteed: `listen` filters `mine` before emitting).

## Verified CLI surface (from `core/sonar-cli/src/main.rs`)

Commands: `init`, `identity`, `publish`, `post` (stickers), `send`, `listen`, `groups`, `messages`.

- `init [--nsec-file <p> | --nsec-env <VAR> | --nsec <s>] [--force]` — create/replace identity + db key in `SONAR_CLI_HOME`.
- `identity` — print `{npub, pubkey_hex, home, config_path}`.
- `publish` — publish the Marmot KeyPackage so peers can start DMs.
- `send --to <npub|hex> --text <s> [--group-name <s>]` — **DM only**; finds-or-creates the 2-member DM group for `<to>`.
- `listen [--once] [--timeout-secs <n>] [--poll-secs <n=30>] [--no-publish]` — sync/drain; prints one JSON line per **inbound** message; records `seen.json`.
- `groups` — print known Marmot groups `{id, name, members[]}`.
- `messages [--group <hex>]` — print messages (this path DOES include `mine:true` rows; `listen` does not).
- Global: `--home <dir>` (else `SONAR_CLI_HOME`, else XDG/platform dir), `--relay <url>` (repeatable; defaults: damus, nos.lol, primal).

Inbound NDJSON contract:
```json
{"type":"message","group_id":"...","id":"...","sender":"npub1...","content":"...","created_at_secs":123,"mine":false}
```

**Transport note (corrected):** `SonarClient::connect` takes only Nostr relays — the CLI is **Marmot/MLS over Nostr relays**, not BLE mesh. Co-location buys identity persistence + low local latency, not BLE reach. The agent is reachable by any White Noise / Sonar peer over the shared relays.

## Chosen approach: cron-polled drain loop

1. **Build** `sonar-cli` once: `cargo build -p sonar-cli --release` → `target/release/sonar-cli`.
2. **Provision identity** (one-time): `sonar-cli --home ~/.sonar-agent init --nsec-file ~/.secrets/sonar-agent.nsec` then `sonar-cli --home ~/.sonar-agent publish`.
3. **Enable the terminal toolset** in Hermes (`hermes chat --toolsets "terminal"`, `terminal.backend: local`).
4. **Install the skill**: copy the committed `SKILL.md` into Hermes' skills dir so the agent knows the contract (commands, `--home`, NDJSON shape, `listen --once` not `listen`, reply with `send --to <sender>`).
5. **Cron job** (Hermes natural-language cron): every N seconds run
   `sonar-cli --home ~/.sonar-agent listen --once`, feed each emitted line to a turn, and reply via
   `sonar-cli --home ~/.sonar-agent send --to <sender> --text <reply>`.
   The `seen.json` cursor dedupes across runs; `mine` filtering prevents self-reply.

Latency = poll interval (start ~30s, tune down if needed). Restart-safe and idempotent by construction. `listen --once` was purpose-built for this ("cron-style agents").

## Implementation plan (what `/ship` produces — docs + skill, no hot-path Rust)

1. `core/sonar-cli/hermes/SKILL.md` — agentskills.io-compatible skill teaching the full sonar-cli contract and the cron-poll auto-reply loop. **Primary deliverable.**
2. `docs/HERMES-AGENT.md` — operator runbook: build, isolated identity via `--nsec-file`, `publish`, enable `terminal` toolset, create the cron job, secrets handling, the relay-only transport note, and the group-reply gap.
3. `core/sonar-cli/README.md` — fix the Agent Contract section: document the full command surface (`identity`/`groups`/`messages`, `listen` flags), call out the `listen` (blocking) vs `listen --once` (cron) distinction, and link to `docs/HERMES-AGENT.md`.
4. (Optional) `docs/hermes/config.example.yaml` — example `~/.hermes/config.yaml` snippet (terminal backend + cron entry).

## Tracked gaps / follow-ups

- **Group auto-reply gap:** `send` has no `--group <id>` target, so the agent can only reply to **DMs**, not multi-member groups. v1 is DM-only (Signal-style 1:1). Follow-up: add `send --group <hex>` in `core/sonar-cli/src/main.rs` (small, breaks "zero code" → separate PR). Tracked here per the **Fix What We Break Rule** as a documented gap, not a silent one.
- **Cadence:** poll interval vs acceptable inbound latency — set in the cron entry; default 30s.
- **Upgrade path:** if structured tool schemas are wanted later, wrap sonar-cli in a thin stdio MCP server (`~/.hermes/config.yaml` → `mcp_servers:`), or add a native `serve-mcp` subcommand. Out of scope now.

## Verification

- `cargo build -p sonar-cli --release` succeeds; `cargo test -p sonar-cli` green.
- `sonar-cli --home <tmp> init` + `identity` round-trips an npub.
- Markdown lint / link check on the new docs.
- Manual: two isolated homes, A `send`s to B's npub, B `listen --once` emits the line, B `send`s back, A `listen --once` sees the reply; reruns emit nothing (cursor works).
