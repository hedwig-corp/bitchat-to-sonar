# Sonar Stickers Ship Plan

Date: 2026-06-18. Status: blocked on design import.

## Goal

Build a production-ready Sonar Stickers surface backed by a reusable Rust crate:

- a standalone `sonar-stickers` crate for Nostr sticker pack modeling,
  validation, event conversion, and future Signal import support;
- a `/stickers` web experience that follows the Claude Design handoff file
  `Sonar Stickers.html`;
- a documented path for later native app integration in both `ios/` and
  `apps/sonar/`, per the cross-platform feature rule.

## Current Blocker

The requested Claude Design connector is not available in this Codex session,
and the file `Sonar Stickers.html` is not present under `design/handoff/`.
Direct access to the Claude Design URL also did not yield the file contents.

Implementation of the visual page must wait until one of these is true:

- the Claude Design connector is enabled and exposes the project file;
- `Sonar Stickers.html` is exported into `design/handoff/project/`;
- the design file is attached directly to the thread.

Until then, do not infer the production UI from Signalstickers screenshots.

## Scope

### In Scope

- Add `core/sonar-stickers` to the Rust workspace.
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
  - NIP-19 `naddr` pack links where supported by the pinned `nostr` crate
- Add fixture-based unit tests.
- Add `/stickers` SvelteKit route only after the design file is available.
- Keep the existing landing page behavior and styling intact.

### Out of Scope For First Ship

- Sending stickers inside Sonar chats.
- Native sticker picker in `ios/` or `apps/sonar/`.
- Browser-side publishing to Blossom.
- Full Signal CDN import/decryption unless explicitly added behind a
  `signal-import` feature.
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

## Web Implementation Plan

After the design file is available:

1. Import `design/handoff/project/Sonar Stickers.html`.
2. Extract layout tokens, spacing, components, and interaction states.
3. Add route files under `web/src/routes/stickers/`.
4. Add route-local components under `web/src/lib/stickers/`.
5. Add static fixture data under `web/src/lib/stickers/fixtures.js` or a JSON
   equivalent generated from Rust fixtures.
6. Implement:
   - gallery/search page;
   - pack card;
   - pack detail view;
   - sticker grid;
   - install/share/copy actions;
   - loading, empty, and invalid-pack states.
7. Keep CSS scoped to the sticker route/components unless the design handoff
   explicitly updates global tokens.

## Verification

Rust:

```sh
cd core
cargo fmt --all --check
cargo test -p sonar-stickers
cargo test --workspace
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
2. Import and implement the design once available.
3. Run local verification.
4. Run a production-safety self-review using the `review-pr` criteria.
5. Commit only the sticker-related files.
6. Push and open a draft PR.
7. Monitor CI.
8. Use `review-feedback` only after the PR has reviewer comments.

