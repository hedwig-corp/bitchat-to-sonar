# Vendored `breez-sdk-liquid` (core crate) from breez/breez-sdk-liquid

Source: `https://github.com/breez/breez-sdk-liquid` @
`e11d88c73abf1bf00b3c909e0a238c0abebb5d6a` (MIT — `LICENSE` copied verbatim).
Upstream commit: *"update versions to 0.12.4"*, Roei Erez, 2026-06-17 — what
tag `0.12.4` pointed at when `core/sonar-wallet-breez` pinned it.

## Why vendored: the upstream repository was re-created empty

On 2026-09-23 a cold-cache `cargo fetch --locked` of the Breez island failed:

```
fatal: remote error: upload-pack: not our ref e11d88c73abf1bf00b3c909e0a238c0abebb5d6a
```

`github.com/breez/breez-sdk-liquid` now reports `created_at: 2026-09-20`, a
6 KB repository with no tags: the repo that held the Liquid SDK's history was
deleted and a new one took its name. The GitHub API answers
`No commit found for SHA: e11d88c…`. This follows `breez/breez-sdk` going 404
on 2026-08-15 (see `../breez-sdk/VENDORED.md`); Breez appears to be
consolidating on the Spark SDK.

The other Breez-owned git sources in the island lockfile (`lwk`, `rusqlite`,
`rusqlite_migration`, `rust-esplora-client`, `rust-secp256k1-zkp`,
`sideswap_rust`, `sqlite-wasm-rs`) and `SatoshiPortal/boltz-rust` still serve
their pinned commits as of that date; they are not vendored.

The copy here was taken from a local `~/.cargo/git` checkout made while the
commit was still served. Its `.git` resolves `HEAD` to `e11d88c7…` and
`git diff HEAD -- lib/core LICENSE lib/Cargo.toml` was empty before copying.

## What is vendored

Only what the island links, ~1.6 MB:

- `lib/core` — the `breez-sdk-liquid` crate, verbatim (sources, `build.rs`,
  the `sync.proto` its build compiles, tests).
- `lib/Cargo.toml` — upstream's workspace root, because the crate inherits
  `version.workspace`, `lints.workspace`, and its dependency versions from it.
  Trimmed: `members` to `["core"]`; `[profile.release]` and `[patch.crates-io]`
  dropped (both are root-only and ignored in a non-root workspace — the island
  manifest carries the secp256k1-zkp patch itself). `[workspace.package]`,
  `[workspace.lints]` and `[workspace.dependencies]` are verbatim: vendoring
  must not silently re-resolve versions upstream pinned on a money path.

Not vendored: `lib/bindings`, `lib/wasm`, `lib/plugins`, `cli`, `packages`,
`regtest`.

## How it is wired in

`core/sonar-wallet-breez/Cargo.toml` depends on it by path:

```toml
breez-sdk-liquid = { path = "../vendor/breez-sdk-liquid/lib/core" }
```

and `core/Cargo.toml` excludes `vendor/breez-sdk-liquid` so the main
(SQLCipher) workspace never absorbs it. Its `sdk-common`/`sdk-macros`
dependencies resolve through the island's existing
`[patch."https://github.com/breez/breez-sdk"]` onto `../breez-sdk`.

## Scope: the shipped apps are not affected

Neither app builds this Rust crate. iOS consumes the prebuilt
`breez-sdk-liquid-swift` package (tag `0.12.4` still served) and Android the
Maven `technology.breez.liquid:breez-sdk-liquid-kmp:0.12.4`
(`mvn.breez.technology`, still served). The blast radius is the Rust island
only — `sonar-wallet-cli`, the headless proof of the (now legacy) Breez
backend.

## Do not "clean this up"

Pointing back at the git URL restores a dependency on a commit GitHub no
longer serves. Remove this directory only if the island itself is retired, or
if Breez republishes the crate and a cold-cache build proves it resolves:

```sh
cd core/sonar-wallet-breez
CARGO_HOME="$(mktemp -d)" cargo fetch --locked   # a warm cache hides the problem
```
