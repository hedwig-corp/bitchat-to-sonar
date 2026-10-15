# Multi-account switcher (Telegram / White Noise style)

Brainstorm, 2026-10-15. Read-only; no code changed.

## Clarified Problem Statement

**Goal:** Let one install hold several Nostr/Marmot accounts and switch between
them instantly, with only the active account live on relays and the others
reachable through push, so that "personal vs work" and dev/QA flipping no longer
go through nsec paste → wipe → Blossom restore.

**What exists today (the baseline the design has to move)**

- One store at a fixed path: Android `filesDir/sonar-marmot/marmot.sqlite`
  (`SonarCore.android.kt:77-124`), iOS App Group
  `MarmotAppGroupStore.databaseDirectory()/marmot.sqlite` shared with the NSE
  (`MarmotService.databaseConfig()`, `MarmotService.swift:1620-1710`).
- One secret per device: Android `AndroidSecrets "nsec"`, iOS keychain
  `identity_*` items plus `marmot-db-key` (one DB key for the one store).
- One live node: `SonarNode.connect(identity, relays, db_path, db_key_hex,
  latch)` (`core/sonar-ffi/src/lib.rs:1086`). The core already takes the path
  as a parameter and keys every sidecar (conversation index, invite-link state,
  backup policy) off `db_path`, so the core is path-agnostic already.
- "Switch" today is account **replacement**: `shouldReplaceAccount` +
  `setAsideWalletsForAccountReplacement` (`SonarAppState.kt:3401-3412, 4964`),
  `CashuWalletService` "Account replacement / wipe" (iOS). It wipes the Marmot
  store, keeps `sonar-cashu/<accountId>/` on disk, and restores from Blossom.
- Already per-account: Cashu wallet dir (`cashuAccountId(nsec)`), handle-address
  record (`HandleAddressRecord.load(prefs, accountId)`), Breez legacy store.
- White Noise reference: `mdk_storage_path(pubkey, data_dir) =
  data_dir/mls/<pubkey_hex>`, `mdk_db_key_id = "mdk.db.key.<hex>"`, an
  `accounts` table with `last_synced_at`, and on Android an
  `AccountSwitchLocalSnapshot` that paints the target account's first chat-list
  frame from local data before anything loads, plus `AccountUnreadStore` with
  per-account unread counts.

**Decisions taken in this brainstorm (user answers)**

- Background accounts: **active one live, others push-only**. Exactly one
  `SonarNode` at a time. Every added account keeps its push registration so a
  notification can offer "switch to <account>".
- Why: personal vs work identity, and dev/QA convenience.
- Scope: **chat + wallet per account, BLE/Noise identity shared** by the
  device.
- Platform: core-owned registry, iOS and Compose in the same change set.

**Constraints (must hold)**

- Account Key Durability Rule: adding an account never deletes or regenerates
  another account's nsec or DB key. Removing an account is an explicit,
  confirmed action, and must clear every store location for that account only.
- XChat-style switch: switching paints the target account's chat list from its
  local conversation index before any relay connect. No Blossom restore, no
  key-package publish, no profile fetch on the switch path.
- No Performance Regression Rule: a single-account install must not get slower
  (no extra store opens, no registry scan on the hot path). Bound the account
  count (propose 3 to 5); each extra store costs disk, an index, and a cold
  read that the large-account fixture already puts at ~6 s.
- 0xdead10cc: only one store may be open at a time on iOS. Switching is
  close-then-open through the suspend latch, never two live stores.
- Push: the NSE / FCM handler must pick the store by the pubkey the payload
  targets, not by "the" store. Transponder registration becomes
  (device token, pubkey) per account and must survive switches.
- Regression ledger: R-entries on account replacement, echo, and the
  SonarAppState/SonarAppStore mirror pair apply; read `docs/REGRESSIONS.md`.

**Non-goals**

- Two accounts live at once (multi-node, Telegram-style simultaneous sync).
- Per-account BLE Noise key or per-account mesh fingerprint.
- Changing the on-wire Marmot/MLS format or White Noise interop.
- Account-level theming, separate notification sounds, or linked-device
  changes (PR #195 device linking is orthogonal).
- Migrating the Hermes/CLI peers to multi-account.

**Success criteria**

- Add a second account by generating or pasting an nsec without touching the
  first account's store, wallet, or backup policy. Verified by a test that
  pins both stores' paths and DB keys before and after.
- Switch paints the target chat list from local storage in under the single
  account cold-open budget in `docs/PERFORMANCE.md`, offline.
- A push for the non-active account shows the sender name and offers a
  switch; tapping it opens the right account and the right chat.
- Removing an account clears its Marmot store, DB key, nsec, push
  registration, and sidecars, and leaves the other accounts untouched
  (`Wipe` invariant 5, scoped to one account).
- A legacy single-account install migrates in place: the existing store moves
  (or is linked) into the per-account layout with no re-sync and no
  re-publish.
- Same behaviour on iOS and Compose, with QA scenarios added to
  `docs/QA-SCENARIOS.md`.

## Approaches Considered

### Approach A: Core-owned registry, host-owned secrets, one live node (recommended)

- Sketch: `sonar-core` gains an `accounts` module: a small registry file
  (`<data_dir>/accounts.json` or sqlite) listing `{npub, dir, label,
  added_at, last_active_at}` and the active npub, plus
  `account_dir(data_dir, npub) = <data_dir>/accounts/<npub_hex>/`. Secrets
  stay in the host keychain/keystore, keyed per account
  (`nsec.<hex>`, `marmot-db-key.<hex>`), mirroring White Noise's
  `mdk.db.key.<hex>`. Hosts call `SonarNode.connect` exactly as today with the
  per-account path. Switch = suspend-latch close of the current node, open the
  target's node, chat list paints from the target's conversation index.
  Migration: on first launch with the registry absent, register the existing
  store in place (keep the legacy path as that account's `dir`; no file move),
  so the single-account path does zero extra work.
- Affected files: `core/sonar-core/src/accounts.rs` (new),
  `core/sonar-ffi/src/lib.rs` (registry FFI), `SonarCore.android.kt` (path
  and secret keys per npub), `AndroidSecrets`, `MarmotService.swift`
  (`databaseURL`/`databaseConfig` take an account), `MarmotAppGroupStore`,
  `KeychainManager` key naming, NSE store selection, Transponder
  registration (`ios/bitchat/Services/*Push*`, Android
  `MarmotFirebase*`/UnifiedPush), `SonarAppState.kt` and
  `SonarAppStore.swift` (account list + active account state), new
  switcher UI on both apps, `AccountReplacementTest` becomes an add-account
  test.
- Tradeoffs: smallest change to the hot path; core stays path-agnostic and
  keychain-free; the layout is identical to White Noise so a later move of
  more logic into core needs no re-layout. Costs: registry and secrets live in
  two places (core file, host keychain) and must agree; a lost registry with
  surviving keychain items needs the same "recover prefs from key" rule the
  onboarding flag already follows.
- Effort: M (core small, hosts medium, push plumbing is most of it).

### Approach B: Fully core-owned accounts with a foreign SecretStore trait

- Sketch: White Noise shape end to end. Core owns the accounts table, secret
  storage goes through a UniFFI foreign trait the host implements over
  keychain/keystore, and the host asks core for `switch(npub) -> SonarNode`.
- Affected files: same as A plus a `SecretStore` foreign trait in
  `sonar-ffi`, host implementations on both platforms, and every existing
  nsec/DB-key read site moved behind the trait.
- Tradeoffs: one source of truth, no registry/keychain drift, future CLI and
  desktop get it for free. Costs: UniFFI foreign traits plus flat errors are a
  known footgun here (a host throw aborts the call); the NSE and the locked-
  device DB-key path (`.deviceLocked` deferral) would have to round-trip
  through the trait, which puts the most delicate keychain code behind an FFI
  boundary. Touches every secret read site on both platforms.
- Effort: L.

### Approach C: Multiple resident nodes, one subscribed

- Sketch: open every account's store at launch, keep only the active one
  subscribed to relays, swap subscriptions on switch so the switch never
  reopens SQLCipher.
- Affected files: `sonar-ffi` node lifecycle, both hosts' node ownership.
- Tradeoffs: fastest possible switch. Costs: N open SQLCipher stores and N
  conversation indexes resident; directly conflicts with the dead10cc history
  (any open store at suspend is a kill) and with the single-account
  performance budget. Rejected for v1; A's close-then-open is bounded by the
  local open cost, which is what we already measure.
- Effort: L, and risky.

Rejected outright: reuse today's replacement flow (seal backup to Blossom,
restore the other). It is network-bound, violates the XChat rule, and the
memory notes show it already eats cellular data on auto-backup.

## Recommendation

Approach A. The core already accepts a path per node and keys all sidecars by
it, so the only new core surface is the registry and the directory convention.
Keeping secrets host-side avoids the foreign-trait footgun and leaves the
locked-device DB-key logic where it is. Lay the directory and keychain naming
out exactly as White Noise does (`accounts/<hex>/`, `marmot-db-key.<hex>`) so
Approach B remains a refactor, not a redesign.

## Open questions

- Shared Noise key: the "one conversation per person" fold links fingerprint
  to npub. With one fingerprint and two npubs, a mesh peer will see the npub
  flip when the user switches. Decide whether BLE announces carry the active
  npub (peer re-folds) or the mesh stays bound to a primary account only.
- Push-only accounts on iOS: the NSE opens a different App Group store per
  pubkey. Confirm the Transponder payload already carries the target pubkey,
  and whether the NSE can hydrate a non-active store without colliding with
  the main app's store lock (the launch-blocked-by-push-held-lock finding).
- Account cap: 3 or 5? Each account is a full Marmot store plus index.
- Auto-backup: per active account only, or every account on its own timer?
  Default to active only to keep the cellular budget.
- Per-account local-time share, relay lists, kind-0 profile: all already keyed
  by signing key, but each has a "published already" record that must be
  per-account (R-051 class fan-out if it is not).
- Dev/QA: should `SONAR_BENCH_NSEC` and the QA harness get an `--account`
  flag so scenarios can cover the switch?
