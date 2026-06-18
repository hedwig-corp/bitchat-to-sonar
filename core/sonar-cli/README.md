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

The Signal `pack_key` is only used locally for decryption and is never included
in the published Nostr event.

## Agent Contract

`listen` emits one JSON object per inbound message:

```json
{"type":"message","group_id":"...","id":"...","sender":"npub1...","content":"...","created_at_secs":123,"mine":false}
```

The command records seen message IDs before exiting, so rerunning `listen` only
emits new messages. `listen --once` performs a single sync/drain cycle, which is
useful in tests and cron-style agents.
