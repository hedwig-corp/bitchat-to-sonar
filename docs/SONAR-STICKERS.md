# Sonar Sticker Packs

Status: draft. This document specifies the Sonar sticker-pack metadata format
implemented by `core/sonar-stickers`, `sonar-cli post`, and the `/stickers` web
viewer.

## Goals

- Publish sticker packs as Nostr addressable events.
- Store sticker image bytes outside relays on HTTPS Blossom-compatible servers.
- Let clients render a sticker pack without knowing Signal-specific secrets.
- Keep sent sticker references stable even if an addressable pack is edited.
- Preserve a path for Signal sticker-pack import without publishing Signal
  `pack_key` material.

## Identifiers

- Pack format marker: `sonar-sticker-pack-v1`
- Sticker pack event kind: `30030`
- User installed-pack list kind: `10030`
- Pack address coordinate: `30030:<author-pubkey-hex>:<identifier>`

The `<author-pubkey-hex>` field is the 64-character lowercase Nostr public key
that signed the pack event. The `<identifier>` field is the event `d` tag value
and must be 1 to 80 ASCII characters containing only alphanumeric characters,
dot, underscore, or dash.

Signal imports use:

```text
signal-<signal-pack-id>
```

as the pack identifier, where `<signal-pack-id>` is Signal's 32-character hex
pack id.

## Sticker Assets

Sticker image bytes are uploaded to Blossom-compatible HTTPS storage before the
pack event is published. A valid sticker asset has:

- `url`: an `https://` URL whose path contains the lowercase SHA-256 hash.
- `sha256`: 64 hex characters for the plaintext sticker image bytes.
- `mime`: one of `image/webp`, `image/png`, `image/apng`, or `image/gif`.
- `dim`: optional `WIDTHxHEIGHT`, with both values between `1` and `4096`.

Clients must not render non-HTTPS sticker URLs. Clients should verify that the
URL contains the advertised SHA-256 and may additionally download and hash the
blob before caching it.

## Pack Event

A sticker pack is a Nostr addressable event:

```json
{
  "kind": 30030,
  "content": "",
  "tags": [
    ["d", "<identifier>"],
    ["title", "<pack title>"],
    ["pack_format", "sonar-sticker-pack-v1"],
    ["t", "sonar-sticker-pack-v1"],
    ["description", "<optional description>"],
    ["image", "<cover-url>", "<cover-sha256>", "<optional WIDTHxHEIGHT>"],
    ["license", "<optional license>"],
    ["sticker", "<shortcode>", "<url>", "<sha256>", "<mime>", "<optional WIDTHxHEIGHT>", "<optional alt>", "<optional emoji>"],
    ["emoji", "<shortcode>", "<url>"]
  ]
}
```

Required tags:

- `d`
- `title`
- `pack_format` with value `sonar-sticker-pack-v1`
- at least one `sticker`

Recommended discovery tag:

- `t` with value `sonar-sticker-pack-v1`

Optional tags:

- `description`
- `image`
- `license`
- `emoji`

The `pack_format` tag is the normative client marker. The `t` hashtag is present
for relay-indexable discovery and broad Nostr tooling compatibility.

## Sticker Tag

Sticker tags use this positional schema:

```json
["sticker", "<shortcode>", "<url>", "<sha256>", "<mime>", "<dim>", "<alt>", "<emoji>"]
```

Fields:

- `shortcode`: 1 to 64 ASCII alphanumeric or underscore characters. It is unique
  within the pack.
- `url`: HTTPS Blossom-compatible URL containing `sha256`.
- `sha256`: plaintext sticker image hash.
- `mime`: allowlisted image MIME type.
- `dim`: optional `WIDTHxHEIGHT`; use an empty string when omitted but later
  fields are present.
- `alt`: optional accessibility text, at most 160 characters.
- `emoji`: optional representative emoji string, at most 8 characters.

Pack validation rejects duplicate shortcodes and duplicate sticker hashes.

## Cover Image Tag

The optional cover image tag uses:

```json
["image", "<url>", "<sha256>", "<optional WIDTHxHEIGHT>"]
```

The cover follows the same URL, hash, and dimension validation as stickers. The
current parser treats cover MIME as `image/webp`; publishers should use a WebP
cover or omit the cover and let clients use the first sticker.

## Emoji Compatibility Tag

For compatibility with Nostr clients that understand simple emoji image tags,
publishers also emit:

```json
["emoji", "<shortcode>", "<url>"]
```

Sonar clients must prefer `sticker` tags over `emoji` tags because `sticker`
tags carry the immutable hash and MIME metadata required for safe rendering.

## Installed Pack List

A user can publish the sticker packs installed in their client as kind `10030`.
The event content is empty. Each installed pack is represented by an `a` tag:

```json
{
  "kind": 10030,
  "content": "",
  "tags": [
    ["a", "30030:<author-pubkey-hex>:<identifier>"]
  ]
}
```

Clients should deduplicate repeated pack addresses while preserving the first
seen order.

## Sent Sticker Reference

When a chat message references a sticker, the reference tag must include the
immutable plaintext sticker hash:

```json
["sticker", "30030:<author-pubkey-hex>:<identifier>", "<shortcode>", "<plaintext-sha256>"]
```

The hash prevents an edited addressable pack from silently changing the meaning
of an old chat message. A client resolving a sent sticker must verify that the
current pack still contains a sticker with both the referenced shortcode and the
referenced plaintext hash. If it does not, the client should render a missing or
untrusted sticker state instead of substituting a different image.

## Publishing Flow

`sonar-cli post <signal-link>` implements the current publishing flow:

1. Load the local CLI Nostr identity from `--home` or `SONAR_CLI_HOME`.
2. Parse the Signal link and decrypt the Signal manifest with the Signal
   `pack_key`.
3. Download and decrypt each Signal sticker asset.
4. Compute the plaintext SHA-256 of each sticker.
5. Upload each plaintext sticker to the configured Blossom server.
6. Build a Sonar `StickerPack` with address
   `30030:<publisher-pubkey>:signal-<signal-pack-id>`.
7. Publish the signed kind `30030` pack event to the configured relays.
8. Print JSON containing the pack address, event id, relays, Blossom server,
   website URL, sticker count, and skipped Signal ids if any.

The Signal `pack_key` is only used locally for decryption and must never be
included in a Nostr event, Blossom upload, website URL, log, or shareable pack
address.

## Signal Import

Signal sticker links have the form:

```text
https://signal.art/addstickers/#pack_id=<32-hex>&pack_key=<hex-or-base64>
```

The importer supports `pack_key` encoded as 32-byte hex, standard base64,
URL-safe base64, or unpadded URL-safe base64. Internally it normalizes the key to
hex.

Signal encrypted blobs use:

```text
iv || ciphertext || mac
```

where:

- `iv` is 16 bytes.
- `ciphertext` is AES-256-CBC with PKCS#7 padding.
- `mac` is HMAC-SHA256 over `iv || ciphertext`.
- AES and HMAC keys are derived with HKDF-SHA256 from the 32-byte Signal pack
  key, a 32-byte zero salt, and info string `Sticker Pack`.
- HKDF output is 64 bytes: first 32 bytes AES key, next 32 bytes HMAC key.

The manifest protobuf is:

```proto
message StickerPack {
  message Sticker {
    optional uint32 id    = 1;
    optional string emoji = 2;
  }

  optional string  title    = 1;
  optional string  author   = 2;
  optional Sticker cover    = 3;
  repeated Sticker stickers = 4;
}
```

Importer limits:

- manifest response: 512 KiB
- sticker response: 4 MiB
- stickers per pack: 200

If a local network intercepts TLS with a private CA, the CLI can use
`--accept-invalid-signal-certs`. This flag only affects encrypted Signal CDN
fetches; decrypted bytes are still authenticated by Signal's HMAC before they
are accepted.

If a Signal manifest references an unavailable asset, the CLI can use
`--skip-missing-signal-stickers`. Skipped Signal sticker ids are included in the
JSON output. Without this flag, any failed Signal sticker fetch aborts the
import.

## Web Resolution

The `/stickers` web route accepts:

```text
/stickers?a=30030:<author-pubkey-hex>:<identifier>&relay=wss://relay.example
```

When `a` is present, the route queries the provided relays with a kind `30030`
filter scoped to the author and `d` tag. Without `a`, it queries recent kind
`30030` events tagged with `t=sonar-sticker-pack-v1`.

The web viewer treats relay events as untrusted input. It renders only parsed
pack events that:

- are kind `30030`;
- include `pack_format=sonar-sticker-pack-v1`;
- have a valid 64-character hex publisher key;
- have at least one valid `sticker` tag;
- use HTTPS sticker URLs containing the advertised SHA-256.

The viewer does not evaluate HTML from relay data.

## Security And Privacy

- Nostr signatures define the pack author and update authority.
- Blossom upload auth uses the publisher's Nostr key.
- Sticker bytes are public once uploaded to Blossom.
- Signal `pack_key` material is secret import input and must not be published.
- Clients should never trust relay-provided sticker metadata without validating
  URL scheme, hash shape, MIME, dimensions, and pack format.
- Chat sticker references should include plaintext hash material so old messages
  remain stable after pack edits.

## Current Gaps

- Native app install/picker/send UI must be implemented in both `ios/` and
  `apps/sonar/` before stickers are a complete cross-platform user feature.
- The route styling should be reconciled with the Claude Design file
  `Sonar Stickers.html` when that design is available.
- The current cover tag does not encode MIME; a future version may add MIME while
  preserving backwards compatibility.
