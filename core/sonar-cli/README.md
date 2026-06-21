# sonar-cli

`sonar-cli` is a headless Sonar/Marmot command-line client for agents and
automation. It uses the same `sonar-core` engine as the app shells and prints
newline-delimited JSON so another process, such as a Hermes Agent, can consume
messages without linking to Sonar internals.

## Quick Start

```bash
cargo run -p sonar-cli -- init
cargo run -p sonar-cli -- publish
cargo run -p sonar-cli -- send --to npub1... --text "hello"
cargo run -p sonar-cli -- listen
```

Use `--home <dir>` or `SONAR_CLI_HOME` to isolate an agent identity. The CLI
stores `config.json`, the encrypted Marmot database, and the seen-message cursor
under that directory. On Unix, directories are written as `0700` and JSON secret
files as `0600`.

To import an existing agent identity, prefer `init --nsec-file <path>` or
`init --nsec-env <VAR>` over `--nsec`, because command-line arguments are often
captured in shell history and process listings.

## Sticker Packs

`post` imports a Signal sticker pack, uploads the plaintext sticker images to a
Blossom server, publishes a Sonar `kind:30030` sticker-pack event to the
configured relays, and prints JSON with the website URL:

```bash
cargo run -p sonar-cli -- post 'https://signal.art/addstickers/#pack_id=...&pack_key=...'
```

Options:

- `--blossom <https-url>`: Blossom server for uploaded sticker images. Defaults
  to Sonar's media fallback server.
- `--site-url <https-url>`: stickers page used in the returned link. Defaults
  to `SONAR_STICKERS_SITE_URL` or the bundled `/stickers` web route.
- `--accept-invalid-signal-certs`: fetch encrypted Signal CDN blobs even when
  local TLS interception breaks certificate validation. The decrypted sticker
  data is still authenticated by Signal's pack-key HMAC before publishing.
- `--skip-missing-signal-stickers`: publish the pack with the importable
  stickers when the Signal manifest references an unavailable asset. Skipped
  Signal ids are reported in the JSON output.

The Signal `pack_key` is only used locally for decryption and is never included
in the published Nostr event.

## Agent Contract

Every command prints newline-delimited JSON. The `type` field identifies the
record: `identity`, `published`, `sent`, `message`, `group`, or
`posted_sticker_pack`. The full command surface:

| Command | Purpose |
| --- | --- |
| `init [--nsec-file p \| --nsec-env VAR \| --nsec s] [--force]` | Provision/replace the identity. |
| `identity` | Print `{npub, pubkey_hex, home, config_path}`. |
| `publish` | Publish the Marmot KeyPackage so peers can DM the agent. |
| `send --to <npub\|hex> --text <s> [--group-name <s>]` | Send a direct message (find/create the 1:1 group). |
| `listen [--once] [--timeout-secs n] [--poll-secs n] [--no-publish]` | Drain inbound messages as JSON lines. |
| `groups` | List known Marmot groups `{id, name, members[]}`. |
| `messages [--group <hex>]` | Print message history (includes the agent's own `mine:true` rows). |
| `post <signal-link> [...]` | Import + publish a Signal sticker pack. |

`listen` emits one JSON object per inbound message:

```json
{"type":"message","group_id":"...","id":"...","sender":"npub1...","content":"...","created_at_secs":123,"mine":false}
```

The command records seen message IDs before exiting, so rerunning `listen` only
emits new messages, and it never emits the agent's own messages (`mine` is
filtered out). A bare `listen` streams until interrupted; `listen --once`
performs a single sync/drain cycle, which is what cron-style agents and tests
should use. `send` is direct-message only (it targets an npub), and transport is
Nostr-relay only — the CLI does not drive BLE mesh.

To run this as an autonomous Hermes agent (terminal toolset + cron-polled
`listen --once`), see [`docs/HERMES-AGENT.md`](../../docs/HERMES-AGENT.md) and
the bundled skill at [`hermes/SKILL.md`](hermes/SKILL.md).
