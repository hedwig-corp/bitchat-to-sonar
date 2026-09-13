# MDK 0.9 Port + Multi-Device Login (macOS + Android simultaneously)

Date: 2026-07-18

## Clarified Problem Statement

**Goal:** Port Sonar's Marmot layer from the pinned MDK `e8cd584` (0.8-era wire
format `0xf2ee`) to upstream MDK v0.9.4 (new Marmot protocol, `0xf2f1` — the
format White Noise iOS already speaks), migrating existing accounts in place,
and then let one account (nsec) run the app on multiple machines **at the same
time** (e.g. macOS desktop + Android phone), following the multi-device model
the new MDK blesses natively.

**Ground truth found during scoping:**

- `core/Cargo.toml:35-38` pins `mdk-core`/`mdk-storage-traits`/
  `mdk-memory-storage`/`mdk-sqlite-storage` at rev `e8cd584` — **473 commits
  behind** upstream master (v0.9.4).
- Upstream is not the same codebase anymore: those crates are **gone**. The
  workspace is now `cgka-engine` (OpenMLS CGKA engine), `cgka-session`
  ("account-device wrapper over `Engine<SqliteAccountStorage>` — one encrypted
  SQLite DB per Marmot **account-device identity**"), `storage-sqlite`
  (SQLCipher), `marmot-account`, `marmot-app` (multi-account runtime),
  `marmot-uniffi`, plus Nostr transport adapter/peeler crates. This is a
  **port, not a bump**.
- The account-device identity concept + upstream concurrent-commit machinery
  (commit-loss fixes #825, epoch-gap backfill #892, membership-fork replay
  #877, losing-committer invalidation #702, `sign_out` with relay key-package
  cleanup #496) is precisely the substrate needed for two devices of one
  account committing concurrently.
- PR #257 (open) already ships the typed `0xf2f1` protocol-mismatch error;
  migration was its tracked gap. PR #195 (open, unmerged) prototyped a
  pre-0.9 "second MLS leaf via link code" design — superseded in spirit by the
  native account-device model, but its invariants (seal-signer auth,
  pending-commit recovery) remain relevant review material.

**Decisions taken (user):**

- **Migrate in place** — existing accounts keep identity, wallet, and local
  chat history; groups carried/re-established onto 0.9 automatically.
- **Follow MDK 0.9's native multi-device model** — do not revive the bespoke
  PR #195 flow if upstream blesses account-device sessions; interop with
  White Noise is the point.
- **Simultaneous use is the requirement** — macOS and Android both live,
  both sending/receiving. Not a one-shot transfer, not a cold-standby device.
- **All surfaces in scope, including iOS** — the "Android/Rust-core only"
  pause is lifted for this effort because protocol compatibility affects every
  surface.

**Constraints (must-hold):**

- Account Key Durability Rule: nsec is the account; no silent regeneration,
  migration failure must surface a restore path, onboarding flag rules apply
  on every surface.
- Signal-Comparable Performance + XChat startup rules: migration and
  device-sync must never block chat-open/first-paint; bounded background
  repair only.
- CLAUDE.md MDK-bump rule: rerun `sonar-sim group-scale`, diff ceiling +
  welcome-size columns against the committed baseline (`docs/GROUP-SCALE-SIM.md`);
  a moved ceiling means wire-format change → re-verify White Noise interop.
- Regression ledger (`docs/REGRESSIONS.md`) before touching send/echo/dedup
  paths; the four hot files attract most re-fixes.
- SQLCipher invariant: no system libsqlite3 shadowing (see memory of the iOS
  encryption break).
- Cold-start benchmark (`scripts/bench/`) before/after: the Marmot layer sits
  on the startup critical path.

**Non-goals (this effort):**

- Full multi-account support in one app install (marmot-app supports it;
  Sonar stays one account per install for now).
- Device-to-device full history transfer / Blossom encrypted backup (new
  device backfills what relays hold; older history absent on the new machine —
  tracked follow-up).
- BLE mesh multi-device semantics (mesh identity stays per-device; only the
  Marmot/White Noise leg becomes multi-device).
- wn-agent/QUIC agent surfaces of the new MDK.

**Success criteria:**

- Sonar ↔ White Noise iOS (0.9) DM + group chat works both directions (kills
  the PR #257 mismatch error).
- Existing install upgrades: same npub, wallet intact, local history readable,
  active groups functional on 0.9 without manual re-adds.
- Log in with nsec on a second machine → profile appears, active conversations
  become usable, and **both devices can send/receive concurrently** without
  forking group state (survives the concurrent-commit chaos scenarios).
- `sonar-sim group-scale` baseline re-established for 0.9 and committed.
- Cold-start `t0→t4` within baseline noise; migration runs off the critical
  path.

## Approaches Considered

### Approach A: Big-bang port onto the new engine crates

- Sketch: One branch that swaps `mdk-core`+`mdk-sqlite-storage` for
  `cgka-engine`+`cgka-session`+`storage-sqlite` inside `core/sonar-core`,
  writes an on-disk migration from the old mdk schema, and lands multi-device
  in the same change since the account-device identity is the new API's
  native shape.
- Affected: `core/sonar-core/src/{client,marmot*,storage}*.rs`, `core/Cargo.toml`,
  UniFFI surface, both apps' onboarding/login, `sonar-sim`.
- Tradeoffs: no dual-stack transition code; but an enormous, hard-to-review,
  hard-to-bisect change; interop + migration + concurrency risks all land at
  once; violates the repo's habit of guarded incremental regressions.
- Effort: XL (multi-week single PR).

### Approach B: Staged — protocol port first, multi-device second (recommended)

- Sketch: **Stage 1**: port sonar-core to the 0.9 engine/session crates with a
  single account-device per account (exactly today's behavior), in-place DB
  migration, White Noise interop verified, group-scale baseline re-committed.
  Ship it. **Stage 2**: expose "log in on another machine" — new install with
  same nsec mints a second account-device session, publishes its KeyPackage,
  peers/own-devices add its leaf; upstream fork-resolution handles concurrent
  commits. UX: plain nsec login (no pairing ceremony) per the user's mental
  model. **Stage 3** (follow-ups): device list + revocation via `sign_out`,
  relay backfill window on the new device, history-transfer gap.
- Affected: same core files as A but split; Stage 2 adds device-session
  bootstrap in `core/sonar-core`, login flows in `apps/sonar` (Android +
  Desktop) and `ios/` onboarding, device-list settings UI.
- Tradeoffs: two migration moments for testers, and Stage 1 alone delivers no
  user-visible feature beyond WN interop; but each stage is reviewable,
  benchmarkable, and revertable, and Stage 1 unblocks the 0xf2f1 error users
  already hit.
- Effort: L + L (two large but bounded PRs plus follow-ups).

### Approach C: Adopt upstream `marmot-app`/`marmot-uniffi` runtime wholesale

- Sketch: Delete Sonar's bespoke Marmot integration and embed the same
  app-runtime stack White Noise ships (`marmot-app` + `marmot-uniffi` +
  transport adapter), keeping Sonar's mesh/BLE, wallet, and UI around it.
  Multi-device, interop, and future protocol bumps come "for free" from
  upstream.
- Affected: most of `core/sonar-core` (client.rs's Marmot half), the entire
  UniFFI boundary, both apps' event plumbing.
- Tradeoffs: maximum long-term interop and least protocol code to own; but
  discards Sonar's tuned local-first machinery (watermark pinning #177,
  live-tail/sync_force #252, echo reconcile #290, conversation folding) that
  the performance rules and regression ledger encode — re-validating all of
  that inside an upstream runtime is a bigger risk than the protocol port
  itself, and Sonar-specific needs (mesh folding, bench markers) would need
  upstream hooks.
- Effort: XL, high uncertainty.

## Recommendation

**Approach B.** The port is unavoidable (upstream deleted the crates we pin),
in-place migration demands a carefully reviewed storage step, and the
account-device model gives multi-device as a natural second stage instead of a
bespoke pairing protocol. Approach C is worth a written evaluation *after*
Stage 1, when the team has real contact with the new APIs — not as the first
move. Stage 1 should start with a **spike**: build sonar-core against
`cgka-session` in a branch and inventory every API break + the old→new DB
schema delta before committing to the migration design.

## Open questions

- Can `storage-sqlite` (new) read/import the old `mdk-sqlite-storage` schema,
  or does migration mean "decrypt old DB → replay into new session DB"? (Spike
  output; determines migration risk.)
- Transition interop: while some peers run old Sonar (0.8) and others 0.9, do
  we dual-stack both formats for a release window or accept a flag-day per
  group? (Affects how "migrate in place" feels in practice.)
- Does the new device see *any* relay-backfilled history in Stage 2, and how
  far back? (Bounded window proposal needed; full transfer is a non-goal.)
- Device naming/labels + revocation UX (Settings → Devices) — Stage 3 scope.
- MIP-04 media feature flag parity: `features = ["mip04"]` equivalent in the
  new workspace (stickers/media rely on it).
- Does Marmot 0.9's account-device model require the *same* nsec signing key
  on every device leaf (pure nsec login) or per-device subkeys blessed by the
  account key? Determines whether "type your nsec" is the whole login UX.
