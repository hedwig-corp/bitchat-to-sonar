# Plan: MDK 0.9 port + multi-device login (same nsec, used together)

Date: 2026-07-18
Branch: `claude/mdk-multi-device-login-9aa9ac`
Brainstorm: [`docs/brainstorms/2026-07-18-mdk-09-port-and-multi-device.md`](../brainstorms/2026-07-18-mdk-09-port-and-multi-device.md)
Design: [`docs/MULTI-DEVICE.md`](../MULTI-DEVICE.md)

## Why

Two coupled goals:

1. **Protocol port.** `core/Cargo.toml` pins MDK at rev `e8cd584` (0.8-era wire
   format, Marmot `0xf2ee`). Upstream is ~473 commits ahead at v0.9.4 with the
   new Marmot wire format `0xf2f1` — the format White Noise iOS already speaks.
   PR #257 shipped the typed mismatch error; the port is the actual fix. This
   is a **port, not a bump**: upstream deleted the crates we pin
   (`mdk-core` / `mdk-sqlite-storage` / `mdk-memory-storage` /
   `mdk-storage-traits`) and reorganized the workspace into `cgka-engine`,
   `cgka-session`, `storage-sqlite`, `marmot-account`, `marmot-app`,
   `marmot-uniffi`, plus Nostr transport adapter/peeler crates.

2. **Multi-device.** One account (one nsec) running Sonar on more than one
   machine **at the same time** — e.g. macOS desktop and an Android phone, both
   live, both sending and receiving. The new MDK models this natively via
   per-device MLS leaves under one account identity ("account-device session":
   one encrypted SQLite DB per account-device identity), which is why it is a
   clean Stage 2 on top of the port rather than a bespoke pairing protocol
   (contrast the shelved PR #195 "second MLS leaf via link code").

## Constraints (must hold — from CLAUDE.md)

- **Account Key Durability Rule.** nsec is the account. No delete-before-add,
  no silent regeneration on keychain/keystore errors, onboarding flag only set
  after durable persistence. Migration failure surfaces a restore path, never a
  fresh account.
- **MDK-bump rule.** Rerun `cargo run -p sonar-sim --release -- group-scale …`,
  diff the ceiling + welcome-size columns against the committed
  `docs/GROUP-SCALE-SIM.md` baseline. A moved ceiling after the bump means the
  wire format changed → re-verify White Noise interop before merge.
- **Signal-Comparable Performance + XChat startup rules.** Migration and
  device-add must never block chat open, chat-list paint, sending, or
  scrolling. Local transcript first, bounded background repair, DB-invalidation
  drives the UI.
- **SQLCipher invariant.** No system `libsqlite3` shadowing the bundled
  SQLCipher (broke iOS Marmot encryption once — see
  `docs/MARMOT-PERSISTENCE.md` and the regression memory).
- **Regression ledger.** Read `docs/REGRESSIONS.md` before touching
  send/echo/dedup; the four hot files attract the most re-fixes.
- **Cross-Platform Feature Rule.** iOS (`ios/`) and Compose (`apps/sonar/`,
  Android + Desktop JVM) move together; a gap is documented with a follow-up.

## Scope

In: MDK 0.9 port, in-place migration of existing accounts, White Noise interop,
nsec-login multi-device with simultaneous use, device list + revoke, group-scale
baseline refresh. Surfaces: Rust core + Android + Desktop + iOS.

Out (tracked follow-ups): full encrypted history transfer to a new device
(new device backfills only what relays hold + what it is cryptographically
entitled to after its join epoch); multi-account-per-install; BLE mesh
multi-device semantics (mesh identity stays per-device); wn-agent/QUIC surfaces.

## Stage 0 — Port spike (no behavior change, throwaway branch)

Goal: turn "473 commits, renamed crates" into a concrete API-break + DB-schema
delta list before committing to a migration design.

1. Point `core/Cargo.toml` at v0.9.4 crate names (`cgka-session` /
   `storage-sqlite` / … ) and try to compile `core/sonar-core/src/marmot.rs`.
2. Inventory every break: `mdk_core::prelude` → new engine/session API,
   `MdkMemoryStorage` / `MdkSqliteStorage` construction, `MdkStorageProvider`
   `dispatch!` generic, `create_group` / `add_members` / `remove_members` /
   `merge_pending_commit` / message create/read, encrypted-media (`mip04`)
   equivalent feature flag, `create_key_package_for_event`.
3. Determine the migration mechanism: can `storage-sqlite` open/upgrade the old
   `mdk-sqlite-storage` schema in place, or does migration mean "decrypt old DB
   → replay group records into a fresh session DB"? This answer sets Stage 1's
   risk and is the single most important spike output.
4. Write findings back into this plan under "Spike results".

Exit: a written API-break table + a chosen migration mechanism. No commit to
`main`-track code yet.

## Stage 1 — Protocol port (single account-device per account)

Ships White Noise interop + in-place migration. Behavior otherwise identical to
today (one device per account, exactly current UX).

- `core/Cargo.toml`: swap MDK deps to v0.9.4 crates.
- `core/sonar-core/src/marmot.rs` + `client.rs`: adapt to the new
  engine/session API. Keep the `MlsWork` / `requires_commit_merge` /
  publish-before-merge contract shape — the new `cgka-session`
  `SessionEffects` + "confirm or fail pending" contract is the same discipline
  under a new name; map onto it rather than inventing a parallel one.
- Storage/migration: implement the mechanism chosen in Stage 0 behind the
  Account Key Durability Rule — old DB is never deleted before the new session
  DB is durably written; failure surfaces restore, not fresh account.
- `sonar-sim`: rerun `group-scale`, commit the refreshed baseline table to
  `docs/GROUP-SCALE-SIM.md` with a note that the ceiling/welcome-size moved due
  to the `0xf2ee → 0xf2f1` wire-format change.
- Interop test: Sonar ↔ White Noise iOS (0.9) DM + group, both directions.
  Kills the PR #257 mismatch error path (keep the typed error for peers still
  on 0.8).
- Benchmark: `scripts/bench/` cold→synced before/after; migration must run off
  the critical path.
- **Transition interop decision (open):** while some peers run old Sonar (0.8)
  and others 0.9 — do we dual-stack both formats for a release window, or accept
  a per-group flag-day? Resolve during Stage 1; affects how "migrate in place"
  feels to existing users mid-rollout.

Exit: existing installs upgrade in place (same npub, wallet, readable local
history, working groups), WN interop green, baseline committed, no cold-start
regression. Shippable on its own.

## Stage 2 — Multi-device login (simultaneous use)

- **Core:** on nsec login on a machine that has no local MLS state for this
  account, mint a device MLS signing key + publish a KeyPackage (kind 30443) to
  the account's NIP-65 outbox relays, and publish the MIP-06 device identity
  proof (kind 450) signed by the account key binding the device leaf to the
  npub.
- **Add-my-leaf flow:** the already-logged-in device (the natural adder — it is
  in every one of your groups and trusts your account key) commits an add of the
  new leaf into each group and sends the welcome. If it is offline, any peer
  client that sees the new KeyPackage + valid identity proof may add it. The new
  device becomes writable in a group only once that group's add is processed.
- **Concurrency:** two of your devices committing the same group at the same
  epoch is the upstream engine's concurrent-commit path — fork resolution,
  losing-committer invalidation (#702), epoch-gap backfill (#892),
  membership-fork replay (#877). We rely on it; we do not re-implement it. Add a
  `sonar-sim` scenario that exercises two same-account leaves committing
  concurrently and asserts convergence.
- **UX (XChat rule):** login paints profile/wallet/pending conversations
  immediately; conversations flip to writable as welcomes land in the
  background. No pairing ceremony unless MIP-06 requires old-device co-sign
  (open question below).
- **Peer folding:** peers must see one person, not two — fold your leaves by
  npub, mirroring the existing conversation-unification invariant
  (`docs/REGRESSIONS.md`), applied to leaves instead of transports.
- **Surfaces:** login flow in `apps/sonar` (Android + Desktop) and `ios/`
  onboarding; core FFI additions via UniFFI.

Exit: nsec login on a second machine → profile/wallet present, active
conversations become usable, both devices send/receive concurrently without
forking group state; concurrent-commit sim converges.

## Stage 3 — Device management (follow-ups)

- Settings → Devices: list your device leaves, label them, revoke one.
  Revocation rides MIP-06 `IdentityRemove` (remove every leaf of an identity
  atomically) once available; interim uses per-group remove + `sign_out` with
  relay KeyPackage cleanup (#496).
- Relay-backfill window on a new device (bounded; how far back = open question).
- Encrypted history transfer / Blossom backup for true "log in and everything
  is there" (the real fix for the pre-join-epoch history gap).
- Push-token handling per device (owner-authenticated push-token gossip, #725).

## Open questions (carried from brainstorm)

- Old→new DB: in-place schema upgrade vs decrypt-and-replay? (Stage 0 output.)
- Transition window: dual-stack 0.8+0.9 or per-group flag-day? (Stage 1.)
- Does MIP-06 finalize on pure-nsec login, or require an existing-device
  co-sign to add a new device (anti-theft)? Read the MIP-06 PR on
  `marmot-protocol/marmot` before Stage 2 — it decides whether "type your nsec"
  is the whole login UX or a confirm-on-existing-device step is added.
- New-device relay-backfill depth (Stage 3).
- `features = ["mip04"]` media-flag equivalent in the new workspace (stickers /
  encrypted media depend on it).

## Verification checklist

- [ ] `group-scale` baseline refreshed + committed with wire-format note.
- [ ] Sonar ↔ White Noise iOS 0.9 DM + group, both directions.
- [ ] Existing install upgrade: same npub, wallet intact, local history
      readable, groups work without manual re-add.
- [ ] Cold-start `t0→t4` within baseline noise; migration off critical path.
- [ ] nsec login on second machine; both devices concurrent send/receive.
- [ ] Concurrent-commit `sonar-sim` scenario converges.
- [ ] Account Key Durability Rule preserved on every surface (migration failure
      → restore path, never fresh account).
