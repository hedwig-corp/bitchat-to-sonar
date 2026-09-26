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
                                   ← cgka-engine 0.9.14 (git pin 235c8ade) ← sonar-core
libcrux-secrets 0.0.5 ← libcrux-traits 0.0.6 ← libcrux-sha3
```

`hpke-rs 0.6.1` declares `libcrux-sha3 = "0.0.8"`. Cargo treats every `0.0.x`
release as mutually incompatible, so `0.0.10` cannot satisfy that requirement:
upgrading needs a new `hpke-rs`, which needs a new `openmls`, which needs an
**MDK rev bump** — see "MDK 0.9.14 bump notes" below. The libcrux-sha3 0.0.8
pin may still apply if 0.9.14's OpenMLS/hpke-rs chain has not moved; re-check
`cargo tree -i libcrux-sha3` after this bump.

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

## MDK 0.9.14 bump notes

Sonar now pins MDK **v0.9.14** (`cgka-engine` / `cgka-session` / `cgka-traits`
/ `storage-sqlite` / `transport-nostr-peeler` at
`235c8ade2920414679e59d7a5f1a0e78651756a4`). This is a **protocol migration**, not
a lockfile bump:

- **Wire format** `0xf2ee` → `0xf2f1`. New installs speak White Noise's current
  profile. A 0.8 peer and a 0.9.14 peer cannot decrypt each other's MLS traffic.
  Kind-445 `#h` is the 32-byte `nostr_group_id` from the founding routing
  component, not the 16-byte MLS group id hosts use as a conversation id.
- **Existing 0.8 SQLCipher stores cannot be opened in place as MLS state.**
  MDK 0.9 applies the key as a passphrase (`PRAGMA key = '<hex>'`), not the
  0.8 raw-key form `PRAGMA key = "x'HEX'"`, and the Marmot wire format moved
  `0xf2ee` → `0xf2f1`. `MarmotEngine::persistent` must **not** wipe that file.
  It decrypts the 0.8 `messages` table with the raw key, copies plaintext
  chat onto the host transcript sidecar, quarantines the 0.8 file as
  `*.mdk08.bak`, and creates a fresh 0.9 store. Wrong-key opens stay a hard
  error and must not delete or quarantine the store. Only a proven
  unencrypted sqlite file is self-healed. MLS membership is not imported —
  see `docs/plans/2026-09-13-mdk-09-existing-chat-migration.md`.
- **Stage 1 of this port** keeps the host-facing `MarmotEngine` / `SonarClient`
  API (hex group ids, publish-then-`confirm_published`). Multi-device (Stage 2)
  is not in this change.
- **Founding admin Leave.** `create_group` / `add_members` pass empty
  `initial_admins`, so invitees are regular members and MIP-03 Leave works.
  The founding admin still cannot self-remove (`EngineError::AdminCannotSelfRemove`).
  `self_demote` returns `InvalidInput` rather than looping Leave; a real demote
  commit is a follow-up. Do not wipe the store to work around this.
- **MIP-03 commit ingest is buffered.** Kind-445 commits return `Buffered`
  until the host calls `advance_group_convergence` after the ~1s quiescence
  window. Ingest must not wait that window on the receive path (a rival
  commit can still arrive). Tests sleep 1.1s then advance; the live client
  still needs a scheduled drain (same shape as marmot-app's worker).
  `advance_group_convergence` must persist `MessageReceived` events from that
  drain: MDK may decrypt PeelDeferred application messages there, and a later
  relay redelivery of the same ciphertext is a content-id Duplicate.
  Same-epoch fork selection uses committer/digest, not Nostr `created_at`.
- **Group-scale baseline is committed** in [`GROUP-SCALE-SIM.md`](GROUP-SCALE-SIM.md)
  (2026-09-13, MDK v0.9.14 `235c8ade`). Ceiling moved **120 → 50** because
  `0xf2f1` welcomes are larger (N=25 is ~38.7 KB vs 0.8’s 27.8 KB). N=100
  fails wrapping the next welcome (NIP-44). Re-run the sim after any later
  MDK rev; do not invent numbers.

The previously deferred advisories (libcrux incremental SHAKE, secrets
`ct_swap`/`ct_select`, AVX2 SHAKE panic) remain a reachability question on the
new OpenMLS/hpke-rs chain — re-check with `cargo audit` from `core/` after
the bump. They were not the reason for the bump; White Noise interop was.

## Re-check triggers

Re-run this analysis when any of the following changes:

- the MDK rev, `openmls` rev, or `hpke-rs` version
- the `iroh` / `netwatch` / `netdev` chain, which is what drags in `quick-xml`
- `libcrux-aead` becoming reachable, or any of its AEAD features being enabled
- a new advisory against any crate above — the ignore list is per-advisory-ID, so
  new IDs still fail the audit
