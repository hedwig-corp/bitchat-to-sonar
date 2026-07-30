# Dependency Advisory Triage

`cargo audit` reports advisories against the whole lockfile, including crates
that are never compiled and APIs that are never called. This file records the
reachability analysis behind every advisory we do not fix, so the decision is
reviewable rather than implicit.

```sh
cd core && cargo audit    # must run from core/ — that is where audit.toml lives
```

cargo-audit looks for `.cargo/audit.toml` relative to the working directory, so
the committed ignore list in `core/.cargo/audit.toml` is picked up only when the
audit runs from `core/`. Run from the repo root it will report every advisory
below as unignored.

A clean run means: the advisories still exist, and each has been shown not to
reach a shipped binary. It does not mean the lockfile is advisory-free.

## Summary

After the lockfile bumps in this PR (`nostr`, `quinn-proto`, `crossbeam-epoch`),
eight advisories remain. **None of them reach a shipped mobile binary.**

| Advisory | Crate | Severity | Compiled in? | Reachable? | Verdict |
|---|---|---|---|---|---|
| RUSTSEC-2026-0124 | libcrux-chacha20poly1305 | 8.2 High | **No** | — | Not in any shipped binary |
| RUSTSEC-2026-0209 | libcrux-aesgcm | 6.3 Med | **No** | — | Not in any shipped binary |
| RUSTSEC-2026-0211 | libcrux-aesgcm | 6.3 Med | **No** | — | Not in any shipped binary |
| RUSTSEC-2026-0194 | quick-xml | 7.5 High | **No** | — | Not in any shipped binary |
| RUSTSEC-2026-0195 | quick-xml | 7.5 High | **No** | — | Not in any shipped binary |
| RUSTSEC-2026-0207 | libcrux-sha3 | 8.2 High | Yes | **No** | Vulnerable API never called |
| RUSTSEC-2026-0212 | libcrux-secrets | 8.2 High | Yes | **No** | Vulnerable API never called |
| RUSTSEC-2026-0208 | libcrux-sha3 | — | Yes | x86_64 only | N/A on mobile; residual on desktop |

## libcrux

All six enter through the MLS stack and are pinned transitively:

```
libcrux-sha3 0.0.8 ← hpke-rs 0.6.1 ← openmls_rust_crypto 0.5.1 (git pin)
                                   ← mdk-core 0.8.0 (git pin) ← sonar-core
libcrux-secrets 0.0.5 ← libcrux-traits 0.0.6 ← libcrux-sha3
```

`hpke-rs 0.6.1` declares `libcrux-sha3 = "0.0.8"`. Cargo treats every `0.0.x`
release as mutually incompatible, so `0.0.10` cannot satisfy that requirement:
upgrading needs a new `hpke-rs`, which needs a new `openmls`, which needs an
**MDK rev bump** — see "Why we are not bumping MDK" below.

**Not compiled (0124, 0209, 0211).** `libcrux-aead` is unreachable from every
workspace member — `cargo tree -i libcrux-aead` prints nothing, for the host and
for `--target all`. Its `libcrux-aesgcm` and `libcrux-chacha20poly1305`
dependencies sit behind the disabled optional features `aesgcm128`/`aesgcm256`/
`chacha20poly1305`/`xchacha20poly1305`, so they appear in `Cargo.lock` without
ever being built. Confirmed against the real artifact, not the manifest:

```sh
cd core && cargo build -p sonar-ffi --release
ls target/release/deps | grep -oE '^liblibcrux_[a-z0-9_]+' | sort -u
# liblibcrux_intrinsics, liblibcrux_platform, liblibcrux_secrets,
# liblibcrux_sha3, liblibcrux_traits  ← no aesgcm, no chacha20poly1305
```

**Not reachable (0207).** The advisory is specific to the *incremental* portable
SHAKE API across **multiple squeeze calls**. `hpke-rs` only uses the one-shot
form, at two call sites in `src/kem.rs`:

```rust
let seed = libcrux_sha3::shake256::<32>(ikm);
let seed = libcrux_sha3::shake256::<64>(ikm);
```

There is no incremental state and no second squeeze, so the faulty path cannot
be entered.

**Not reachable (0212).** This one affects constant-time `swap`/`select` in
`libcrux-secrets` on **aarch64** — our primary shipping architecture, so it was
checked closely. Our only consumer of `libcrux-secrets` is `libcrux-traits`,
pulled in by `libcrux-sha3`, and `libcrux-sha3` never calls `ct_swap` or
`ct_select` (SHA-3/SHAKE is a permutation over public state with no
secret-dependent branch to protect). The functions are compiled but never
invoked on any Sonar path.

**Residual (0208).** A potential panic in **AVX2** SHAKE-256. AVX2 is x86_64
only; iOS ships arm64 and Android ships arm64-v8a/armeabi-v7a, so no mobile
artifact can dispatch to it. The x86_64 desktop build can, giving a theoretical
remote panic (availability only — no key or plaintext exposure) reachable
through HPKE seed derivation. This is the one item the MDK bump would close.

## quick-xml (0194, 0195)

Patched in `>= 0.41.0`, but it is a lockfile-only entry. It enters through
`plist`, itself reached only via `netdev ← netwatch ← iroh`, and resolves for
no shipped target:

```sh
cd core
cargo tree -i quick-xml --target aarch64-apple-ios     # no match
cargo tree -i quick-xml --target aarch64-linux-android # no match
cargo tree -i quick-xml --target aarch64-apple-darwin  # no match
ls target/release/deps | grep -cE '^libquick_xml|^libplist'   # 0
```

`cargo update -p quick-xml --precise 0.41.0` is additionally rejected by the
`netdev`/`netwatch`/`iroh` requirement chain, so the bump is not available to us
without moving `iroh` — not worth it for a crate that is never built.

## Why we are not bumping MDK for this release

Sonar is on `mdk-core 0.8.0`. The native White Noise iOS client moved to MDK 0.9,
which is wire-incompatible in both directions (`0xf2f1` vs `0xf2ee` proof), so an
MDK bump is a protocol migration, not a dependency update — it would break Marmot
interop for every existing Sonar install. Per the Performance Analysis Rule in
`CLAUDE.md`, any MDK rev bump must also re-run the device-independent group-scale
simulation and diff the ceiling and welcome-size columns against the committed
baseline:

```sh
cargo run -p sonar-sim --release -- group-scale
```

Trading a confirmed interop break plus a protocol re-baseline against three
unreachable advisories and one x86_64-desktop-only panic is the wrong call for a
point release. The bump is tracked separately and should carry the migration and
the sim diff together.

## Re-check triggers

Re-run this analysis when any of the following changes:

- the MDK rev, `openmls` rev, or `hpke-rs` version
- the `iroh` / `netwatch` / `netdev` chain, which is what drags in `quick-xml`
- `libcrux-aead` becoming reachable, or any of its AEAD features being enabled
- a new advisory against any crate above — the ignore list is per-advisory-ID, so
  new IDs still fail the audit
