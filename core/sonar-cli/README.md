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

## Media (voice, image, video)

`send` can transmit encrypted media — voice notes, images, and video — over the
same E2E Marmot 1:1 group path used for text. Media is encrypted in-process
(MIP-04 `imeta`), uploaded to a Blossom server as a ciphertext blob, and the
`imeta` rides inside the encrypted message, so the Sonar app (and any peer using
`sonar-core`) can decrypt it. This is the same core code path the iOS/Android
apps use, so a CLI-sent image renders in the app without any extra plumbing.

```bash
# voice note (defaults to audio/mp4 / AAC)
sonar-cli send --to npub1... --file ./voice.ogg --kind voice --caption "transcript below"

# image
sonar-cli send --to npub1... --file ./diagram.png --kind image

# video
sonar-cli send --to npub1... --file ./clip.mp4 --kind video --caption "demo"

# pipe bytes from another tool (mime required for a pipe)
ffmpeg -f lavfi -i sine=frequency=440:duration=2 -f mp3 - 2>/dev/null \
  | sonar-cli send --to npub1... --stdin --mime audio/mpeg --kind voice
```

`--text` and `--file`/`--stdin` are mutually exclusive: pass exactly one. MIME is
resolved as explicit `--mime` > file extension > the `--kind` default.

| `--kind` | Default MIME | Common extensions |
| --- | --- | --- |
| `voice` | `audio/mp4` (AAC) | `.m4a`, `.mp4` |
| `audio` | `audio/mpeg` | `.mp3`, `.m4a`, `.aac`, `.wav`, `.flac` |
| `image` | `image/png` | `.png`, `.jpg`/`.jpeg`, `.webp`, `.gif` |
| `video` | `video/mp4` | `.mp4`, `.m4v`, `.webm`, `.mov` |

A successful send prints a `sent_media` record:

```json
{"type":"sent_media","to":"npub1...","group_id":"...","kind":"voice","mime":"audio/mp4","filename":"voice.m4a","size_bytes":45678,"blossom_server":"https://blossom.primal.net"}
```

### Receiving media

`listen` and `messages` now include a `media[]` array on each message (omitted
for plain text, so existing parsers keep working). Each entry carries the
encrypted blob `url`, `mime`, a derived `kind`, `filename`, and optional
`width`/`height`/`duration_ms`:

```json
{
  "type": "message",
  "id": "...",
  "sender": "npub1...",
  "content": "see attached",
  "created_at_secs": 123,
  "mine": false,
  "media": [
    {"url":"https://blossom.x/abc.m4a","mime":"audio/mp4","kind":"voice","filename":"voice.m4a","duration_ms":12000}
  ]
}
```

Download and decrypt a blob with `fetch` (local-first: it uses the group's stored
message key, no relay round-trip beyond fetching the ciphertext):

```bash
# to a file (name derived from the URL; prefer --out for a correct extension)
sonar-cli fetch --group <hex> --url https://blossom.x/abc.ogg

# explicit path
sonar-cli fetch --group <hex> --url https://blossom.x/abc.ogg --out ./voice.ogg

# pipe straight into another tool (bytes to stdout, JSON summary to stderr)
sonar-cli fetch --group <hex> --url https://blossom.x/abc.ogg --stdout | ffplay -
```

### Limits and errors

Blossom servers enforce their own maximum blob size (which varies by operator).
Keep voice/image sends modest; for large video, prefer a compressed `video/mp4`.
Clear
errors are raised for: an unsupported/unknown MIME with `--stdin` (use `--mime`),
an empty payload, a missing `--kind` on a media send, and a decryption failure
(no stored `imeta` for the requested URL — run `listen --once` first so the
message is persisted locally).

**iOS playback:** the default voice MIME is AAC (`audio/mp4`) so notes play in the
Sonar app's `AVAudioPlayer`. OGG/Opus (`.ogg`/`.opus`) is not decoded by iOS —
send those only if the receiver has an Opus decoder. An app-side Opus decoder
is a tracked follow-up.

**Tracked gap:** outbound `duration_ms`/dimensions are not yet attached by the
core send path, so a CLI-sent voice clip arrives without a duration field (apps
that send media do attach it, and `listen` surfaces it when present). Extending
`sonar-core::send_media` to accept optional metadata is a follow-up.

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
record: `identity`, `published`, `sent`, `sent_media`, `fetched`, `message`,
`group`, or `posted_sticker_pack`. The full command surface:

| Command | Purpose |
| --- | --- |
| `init [--nsec-file p \| --nsec-env VAR \| --nsec s] [--force]` | Provision/replace the identity. |
| `identity` | Print `{npub, pubkey_hex, home, config_path}`. |
| `publish` | Publish the Marmot KeyPackage so peers can DM the agent. |
| `send --to <npub\|hex> --text <s> [--group-name <s>]` | Send a direct message (find/create the 1:1 group). |
| `send --to <npub\|hex> --file <p> --kind {voice\|audio\|image\|video} [--caption s] [--mime m] [--blossom url]` | Send encrypted media (MIP-04). |
| `fetch --group <hex> --url <url> [--out <p> \| --stdout]` | Download + decrypt an inbound media blob. |
| `listen [--once] [--timeout-secs n] [--poll-secs n] [--no-publish]` | Drain inbound messages (text + media) as JSON lines. |
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

To run this as an autonomous Hermes agent, see
[`docs/HERMES-AGENT.md`](../../docs/HERMES-AGENT.md): **Path A** (native
`hermes gateway` + Sonar platform plugin, recommended) or **Path B** (terminal
toolset + cron-polled `listen --once`). Skill: [`hermes/SKILL.md`](hermes/SKILL.md).
