# Auto-backup + Signal-parity roadmap (post PR #270)

## Clarified Problem Statement

**Goal:** After shipping manual Blossom account backup (PR #270), add Signal-competitive *automatic* encrypted backups (daily floor + dirty opportunistic), include last-N-days media in the free archive, turn auto-backup on by default after onboarding, and sequence the next Signal-parity lanes without blocking on a recovery-key redesign.

**Decisions locked (2026-07-19):**
1. Cadence: **daily floor + opportunistic when dirty**
2. Wrap key: **keep nsec-derived** (restore stays paste-nsec; no separate recovery key in this tranche)
3. Archive contents: **DB + last N days of media** now; **full media** deferred to pro account (tracked issue)
4. Roadmap: **ranked multi-lane** (backup → chat UX → multi-device)
5. Default: **auto-backup on after onboarding** (opt-out in Settings)

**Constraints:**
- Must preserve Account Key Durability and crash-safe stage→persist→commit from #270
- Must not block chat open / send / scroll on Blossom upload (Signal-Comparable Performance)
- Cross-platform: iOS + macOS + Compose together (Cross-Platform Feature Rule)
- HTTPS Blossom only; default host remains `https://nostr.download` until Hedwig Blossom is productized
- Close live `SonarNode` (or equivalent exclusive access) before WAL checkpoint / seal
- On-by-default must still be user-visible and disableable; panic wipe should eventually delete remote archive (follow-up if not in first auto-backup PR)

**Non-goals (this tranche):**
- Separate Signal-style 64-char recovery key / passphrase beyond nsec
- Paid backup billing UI (only open issue + MIME/size policy hooks for later)
- Multi-device linked sessions as part of the auto-backup PR
- Mesh/BLE history in the cloud archive
- Incremental/delta wire format (full archive replace is OK for v2)

**Success criteria:**
- New accounts: auto-backup enabled after onboarding without a separate “Backup now” step
- Dirty chats: opportunistic backup within a bounded debounce; daily floor still runs if quiet
- Reinstall → paste same nsec restores chats + media from last N days (N documented, default TBD e.g. 45 to match Signal free tier)
- Failed/offline auto-backup never bricks the session (Compose/iOS always recover usable Marmot)
- Settings shows last backup time / failure / disable toggle on all three surfaces
- Pro full-media backup tracked in a GitHub issue (not blocked on shipping free tier)

## Signal-parity ranking (lane D)

| Priority | Lane | Why now |
|----------|------|---------|
| P0 | **Backup completeness** — auto + last-N media + on-by-default | Manual backup alone loses to Signal Secure Backups; this is the gap users feel on reinstall |
| P1 | **Chat UX parity** — reactions, typing indicators, read receipts, disappearing messages (Signal-first design) | Retention / “feels like Signal” once history survives reinstall |
| P2 | **Multi-device / linked desktop** | Harder identity + KeyPackage story; must not block P0/P1 |

## Approaches Considered

### Approach A: Host-scheduled full archive (thinnest)
- **Sketch:** Reuse `backupAccountToBlossom` / `uploadAccountBackup`. Hosts own WorkManager / BGAppRefresh / desktop timer: mark dirty on send/receive, debounce opportunistic runs, schedule daily floor. On-by-default flag in prefs after onboarding.
- **Affected files:** `SonarAppState.kt`, `SonarAppStore.swift` / `MarmotChatView.swift`, Android `WorkManager` worker, iOS background task, Settings UI; media packing added in `account_backup.rs` package format (version bump).
- **Tradeoffs:** Fastest ship; host logic duplicated three ways; easier to drift on debounce/busy rules.
- **Effort:** M

### Approach B: Core-owned dirty + policy, host executor (recommended)
- **Sketch:** Core exposes `backup_policy` state: `enabled`, `dirty`, `last_success_at`, `last_error`, `media_window_secs`. Hosts only *execute* when core says due (opportunistic or daily). Seal path extended for last-N media blobs (file refs + ciphertext already on Blossom or re-upload). Same nsec wrap as v1.
- **Affected files:** `core/sonar-core/src/account_backup.rs` (+ client hooks on message persist), `sonar-ffi`, iOS `MarmotService` / `SonarAppStore`, Compose `SonarCore` / `SonarAppState`, Settings screens all platforms.
- **Tradeoffs:** One policy brain; slightly larger FFI surface; still full-archive replace (not delta).
- **Effort:** M–L

### Approach C: Incremental / chunked backup (Signal-archive shaped)
- **Sketch:** New backup format with snapshots + media chunks, resume, paid size tiers.
- **Affected files:** New core module, Blossom listing/GC, major restore rewrite, pro billing later.
- **Tradeoffs:** Best long-term scale; wrong next step — blocks P0 while rewriting what #270 just made solid.
- **Effort:** L

## Recommendation

**Ship Approach B for auto-backup + last-N media**, with Approach A’s scheduling primitives on hosts as the executor. Keep nsec-derived wrap (decision 2A). Turn auto-backup **on after onboarding** with a clear Settings off-ramp and last-status row. Open (don’t build) pro full-media. Sequence P1 chat UX and P2 multi-device as separate brainstorms/PRs after auto-backup lands.

Default **N = 45 days** of media unless product picks otherwise (aligns with Signal free Secure Backups messaging). Confirm N before implement.

## Open questions

- Exact **N** for free media window (45 vs 30 vs 7) and max archive bytes before skip/fail
- Whether on-by-default shows a one-time explainer sheet or silent enable + Settings discoverability only
- Opportunistic debounce (e.g. 15–60 min) and “don’t backup on constrained network / low power”
- Panic wipe / Emergency wipe: delete remote Blossom archive in the same PR or hard follow-up
- Hedwig Blossom cutover vs staying on `nostr.download` for auto volume

## Suggested ship slices

1. **PR1 — Auto-backup policy + on-by-default (DB-only archive)** — dirty/daily, no media yet; proves scheduling without size blowups
2. **PR2 — Last-N media in archive** — format bump, restore path, size caps
3. **Issue — Pro full media** — opened alongside; no code until pro account exists
4. **Later — P1 chat UX / P2 multi-device** — separate brainstorms

## Next

```
/ship --from-brainstorm docs/brainstorms/2026-07-19-auto-backup-signal-parity.md
```
Or `/ship --plan-only` for PR1 only (auto-backup policy, DB-only).
