# Sonar Stickers Ship Plan

Date: 2026-06-18. Status: implementation in progress; design import still pending.

## Goal

Build a production-ready Sonar Stickers surface backed by a reusable Rust crate
and CLI publishing path:

- a standalone `sonar-stickers` crate for Nostr sticker pack modeling,
  validation, event conversion, and Signal import support;
- `sonar-cli post <signal link>` to import a Signal pack, upload assets to
  Blossom, publish a Nostr pack event, and return the website URL;
- a `/stickers` web experience that can resolve published pack events from
  relays and render safe Blossom-hosted sticker images;
- a documented path for later native app integration in both `ios/` and
  `apps/sonar/`, per the cross-platform feature rule.

## Current Design Import Gap

The requested Claude Design connector is not available in this Codex session,
and the file `Sonar Stickers.html` is not present under `design/handoff/`.
Direct access to the Claude Design URL also did not yield the file contents.

The current web route uses the existing Sonar site tokens and layout language.
Replace or refine route-local styling once one of these is true:

- the Claude Design connector is enabled and exposes the project file;
- `Sonar Stickers.html` is exported into `design/handoff/project/`;
- the design file is attached directly to the thread.

Until then, do not claim visual parity with the Claude Design project.

## Cross-Platform Follow-Up Gap

Per `AGENTS.md`, user-facing sticker send/install flows must land in both
supported app surfaces. This change only adds the reusable Rust crate, CLI
publisher, and web viewer. Native app follow-up:

- `ios/`: sticker pack discovery/install UI, sticker picker, and sticker-send
  rendering.
- `apps/sonar/`: Compose Multiplatform parity for discovery/install, picker,
  and rendering.
- Shared contract: apps should consume the same `sonar-stickers` pack/ref
  models and kind `30030`/`10030` event shapes.

## Scope

### In Scope

- Add `core/sonar-stickers` to the Rust workspace.
- Add `sonar-cli post <signal link>`.
- Add `web/src/routes/stickers/`.
- Define canonical data models:
  - `StickerPack`
  - `Sticker`
  - `PackAddress`
  - `StickerRef`
  - `InstalledPackList`
- Implement strict validation:
  - shortcode shape
  - MIME allowlist
  - dimensions
  - SHA-256 shape
  - HTTPS Blossom URL shape
  - duplicate shortcode/hash rejection
- Implement Nostr conversion for:
  - `kind:30030` pack definitions
  - `kind:10030` installed pack lists
  - `sticker` reference tags for future chat messages
- Implement Signal import/decryption behind the `signal-import` feature.
- Add unit tests for pack conversion, Signal link parsing, HMAC rejection, and
  AES-CBC decrypt round trips.
- Keep the existing landing page behavior and styling intact.

### Out of Scope For First Ship

- Sending stickers inside Sonar chats.
- Native sticker picker in `ios/` or `apps/sonar/`.
- Browser-side publishing to Blossom.
- Browser-side Signal import/decryption.
- Moderation/reporting UI beyond displaying curated pack metadata.

## Protocol Decisions To Encode

- Discovery must use relay-indexable tags. Do not rely on `#pack_format` because
  generic Nostr relay filtering is only reliable for single-letter tag names.
  Use `["t", "sonar-sticker-pack-v1"]` plus a `pack_format` marker for clients.
- Sent sticker references must include immutable plaintext hash material, not
  only `(pack address, shortcode)`, because addressable `kind:30030` packs can
  be edited.
- Public pack events may include public Signal provenance, but Signal `pack_key`
  must not be published by default.
- Pack event parsing must prefer `sticker` tags and treat parallel `emoji` tags
  as fallback metadata only.

## Proposed Crate Layout

```text
core/sonar-stickers/
├── Cargo.toml
└── src/
    ├── lib.rs
    ├── model.rs
    ├── nostr.rs
    ├── validation.rs
    ├── blossom.rs
    ├── signal.rs        # feature = "signal-import"
    └── wasm.rs          # feature = "wasm"
```

Feature flags:

- `default = ["nostr"]`
- `nostr`: event parsing/building through the workspace-pinned `nostr` crate.
- `signal-import`: Signal URL/provenance mapping, no publishing by default.
- `wasm`: browser bindings for the sticker website.

## Web Implementation

The `/stickers` route:

- reads `?a=30030:<pubkey>:<identifier>&relay=wss://...` links returned by the
  CLI;
- queries relays directly with a NIP-01 websocket subscription;
- falls back to recent `sonar-sticker-pack-v1` tagged packs when no address is
  provided;
- defensively parses untrusted events and only renders HTTPS sticker URLs that
  include the advertised SHA-256;
- shows relay status, pack list, pack detail, sticker grid, and copy-link
  action.

When the design file is available, import it and reconcile route-local spacing,
states, and visual hierarchy with `Sonar Stickers.html`.

## Verification

Rust:

```sh
cd core
cargo fmt --all --check
cargo test -p sonar-stickers --features signal-import
cargo test -p sonar-cli
cargo clippy -p sonar-stickers --features signal-import -- -D warnings
cargo clippy -p sonar-cli -- -D warnings
```

Web:

```sh
cd web
npm run check
npm run build
```

Visual QA after the design lands:

- run the SvelteKit dev server;
- open `/stickers` in the in-app browser;
- verify desktop and mobile widths;
- compare against `Sonar Stickers.html`;
- check there is no text overflow and no incoherent overlap.

## Production Review Checklist

- No unsafe external URL fetching from untrusted sticker tags.
- No public Signal `pack_key` leakage.
- No global restyle of the existing landing page.
- No native app feature claim unless `ios/` and `apps/sonar/` are implemented
  or an explicit tracked gap exists.
- Pack parsing rejects malformed or ambiguous metadata instead of silently
  rendering unsafe data.
- Web route can render from local fixtures without relay/network availability.

## Shipping Workflow

1. Implement crate and tests.
2. Implement CLI publishing and web viewer.
3. Run local verification.
4. Run a production-safety self-review using the `review-pr` criteria.
5. Commit only the sticker-related files.
6. Push and open a draft PR.
7. Monitor CI.
8. Use `review-feedback` only after the PR has reviewer comments.
