# Vendored `sdk-common` + `sdk-macros` from breez/breez-sdk

Source: `https://github.com/breez/breez-sdk` @
`113749fd36dd7a20358dc40526c4a30147f8c1a8` (MIT — `LICENSE` copied verbatim).
Upstream commit: *"nwc: chore: rename `wallet_public_key` to
`wallet_service_public_key`"*, yse <hydra_yse@proton.me>, 2026-01-19.

## Why vendored: the upstream repository no longer exists

On 2026-08-15 `https://github.com/breez/breez-sdk` began returning **404** — the
repository was deleted or made private (no rename redirect; the Breez org still
serves `breez-sdk-liquid`, `lwk`, `rusqlite_migration`, and
`rust-secp256k1-zkp`, so only this one repo went away). Breez appears to be
consolidating on the Spark SDK.

This is not a stale pin on our side. `breez-sdk-liquid` **main** still declares:

```toml
sdk-common = { git = "https://github.com/breez/breez-sdk", rev = "113749fd…", features = ["liquid", "nwc"] }
sdk-macros = { git = "https://github.com/breez/breez-sdk", rev = "113749fd…" }
```

so *every* revision of `breez-sdk-liquid` is currently unbuildable from source
on a cold cargo cache, for anyone. Bumping our `breez-sdk-liquid` rev cannot fix
it. Neither crate was ever published to crates.io, so there is no registry
fallback.

Our CI proved the timing: `core-tests.yml` run 31885040933 (this same branch)
built the island green earlier that day; the next cold-cache run failed with

```
failed to load source for dependency `sdk-common`
  unable to update https://github.com/breez/breez-sdk?rev=113749fd…
  revision 113749fd36dd7a20358dc40526c4a30147f8c1a8 not found
```

The copy here was recovered from a local `~/.cargo/git` clone made while the
repo was still up, and verified against the pinned SHA before copying (the
cached bare repo holds `113749fd…` as a real commit object whose tree matches
the checkout). As far as we can tell this is now the only reachable copy of the
code that our Lightning send path is built on.

## What is vendored

Only the two crates `breez-sdk-liquid` actually depends on, ~390 KB:

- `libs/sdk-common` — LNURL, BOLT11/BOLT12 parsing, fiat rates, the gRPC
  breez proto client, and the `input_parser` used on every payment we send.
- `libs/sdk-macros` — proc macros `sdk-common` needs to compile.

`libs/Cargo.toml` is upstream's workspace root with `members` trimmed to those
two and `[profile.release]` dropped (ignored in a non-root workspace). Both
crates inherit `version.workspace` and their dependency versions from it, so
the `[workspace.package]` / `[workspace.dependencies]` tables are copied
verbatim — vendoring must not silently re-resolve the versions upstream pinned
on a money path.

Nothing else from that repository is vendored: `sdk-core`, `sdk-bindings`,
`sdk-flutter`, and `sdk-react-native` are the Greenlight SDK proper and are
unused here.

## How it is wired in

`core/sonar-wallet-breez/Cargo.toml` redirects the dead git source to these
paths:

```toml
[patch."https://github.com/breez/breez-sdk"]
sdk-common = { path = "../vendor/breez-sdk/libs/sdk-common" }
sdk-macros = { path = "../vendor/breez-sdk/libs/sdk-macros" }
```

The patch lives in the **island** manifest (`core/sonar-wallet-breez` is its
own workspace, excluded from `core/Cargo.toml`) because that island is the only
place in the repo that links breez-rust at all.

## Scope: the shipped apps are not affected

Neither app builds this Rust crate. iOS gets Breez through the prebuilt
`WalletKit` Swift package and Android through the Maven `breez_sdk_liquid`
artifact; both are published binaries and are unaffected by a GitHub repo
disappearing. The blast radius of the deletion is the Rust island only —
`sonar-wallet-cli` and, more importantly, `sonar-migrate-cli`, which is the
headless driver for the Breez→Cashu migration test.

## Do not "clean this up"

The obvious tidy-up — delete the vendor, point back at the git URL — restores a
dependency on a URL that 404s. Remove this directory only if Breez restores the
repository (or publishes the crates), and only after a cold-cache build proves
the upstream source resolves again.

Editing these files is a fork, not a vendor: keep changes out unless there is a
reason recorded here. As of this commit the tree is byte-identical to upstream
apart from the trimmed `libs/Cargo.toml` described above.
