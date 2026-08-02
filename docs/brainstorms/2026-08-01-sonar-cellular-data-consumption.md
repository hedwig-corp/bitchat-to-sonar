# Sonar cellular data consumption (66.3 GB / period, iOS)

> **Status: P0 shipped.** See `docs/REGRESSIONS.md` R-032 for the landed
> invariant, its tests, and both platform call sites. Two things changed versus
> the plan below while implementing, both recorded in R-032's `Rejected`:
> the fingerprint must be taken over the **plaintext** (the seal's nonce is
> fresh per run, so sealed bytes never repeat and no server-side dedup can
> help), and the unchanged-refresh window tracks the user's chosen cadence
> rather than a flat 7 days, so a "Daily" user never reads "Last backup: 6 days
> ago" and concludes backup is broken. P1/P2 below remain open.

Reported: iOS Settings → Mobile Data shows **Sonar 66.3 GB** in the current period
(device total 82.4 GB, 81.9 GB of it roaming). Next app on the list is Instagram
at 3.35 GB — Sonar is ~20× the heaviest normal app on the phone.

## Shape of the number

66.3 GB / 30 days ≈ **2.2 GB/day** ≈ 200 kbit/s sustained, 24/7. That rules out
anything bursty and human-scale (chat text, presence beacons, Tor circuit
padding, occasional media). It requires a **large payload re-sent on a
schedule** — and the codebase has exactly one of those.

## Root cause (confirmed in code): auto-backup re-uploads the entire account on a ~30-minute cadence, with no metered-network gate, on both platforms

Every element verified, not inferred:

1. **On by default.** `BackupPolicy::default()` sets `enabled: true`
   ([account_backup.rs:174](core/sonar-core/src/account_backup.rs:174)). Uploads
   start only after the user passes the one-time disclosure
   (`sonar.auto_backup_disclosed`, checked in
   [MarmotChatView.swift:1303](ios/bitchat/Views/MarmotChatView.swift:1303)) —
   so this hits exactly the users who set up backup, like the reporter.

2. **Every upload is a full snapshot, never a delta.**
   `seal_account_backup_files` → `read_account_backup_package` does
   `fs::read(db_path)` of the whole SQLCipher DB **plus** the whole conversation
   index DB, seals both, and `upload_sealed_backup` PUTs the entire blob to
   Blossom ([account_backup.rs:753](core/sonar-core/src/account_backup.rs:753),
   [:1637](core/sonar-core/src/account_backup.rs:1637),
   [:1159](core/sonar-core/src/account_backup.rs:1159)). Cap:
   `MAX_BACKUP_BYTES = 200 MiB`. The AEAD seal uses a **fresh random nonce every
   time** ([account_backup.rs:681](core/sonar-core/src/account_backup.rs:681)),
   so the sealed bytes — and the blob's sha256 — differ on every run even when
   the account has not changed one byte. No server-side content-address dedup
   can ever help; only a client-side skip can.

3. **The real cadence is 30 minutes, not daily.** `backup_is_due`
   ([account_backup.rs:373](core/sonar-core/src/account_backup.rs:373)) fires as
   soon as the policy is `dirty` and `opportunistic_debounce_secs` (default
   **30 min**) has passed since the last attempt. `mark_backup_dirty` runs on
   **every outbound send** ([client.rs:3439](core/sonar-core/src/client.rs:3439))
   and **every incoming message** indexed
   ([client.rs:6977](core/sonar-core/src/client.rs:6977)) — an account in one
   active group is dirty essentially always. The 24 h `daily_interval_secs` is
   only a floor for a *quiet* account; it never throttles an active one.

4. **Executors ask constantly, on both platforms.**
   - iOS: `runOpportunisticBackgroundBackupIfDue()` runs on **every**
     transition to background
     ([AutoBackupBackgroundScheduler.swift:278](ios/bitchat/Services/AutoBackupBackgroundScheduler.swift:278));
     a `BGAppRefresh` re-arms itself 3 min after each backgrounding
     ([:122](ios/bitchat/Services/AutoBackupBackgroundScheduler.swift:122));
     a `BGProcessing` 12 h floor backs those up; and a 15-min in-app loop
     ([MarmotChatView.swift:997](ios/bitchat/Views/MarmotChatView.swift:997))
     covers macOS/foreground. The scheduler's own doc comment contains a
     measurement: **18 `BGAppRefresh` runs in a 53-hour device log**
     ([:88](ios/bitchat/Services/AutoBackupBackgroundScheduler.swift:88)) —
     ~8/day of that path alone, before the every-backgrounding opportunistic runs.
   - Android: `AutoBackupWorker` — 12 h periodic + a one-shot 3 min after every
     backgrounding, `NetworkType.CONNECTED` (metered allowed), `Result.retry()`
     on failure
     ([AutoBackupWorker.kt:109](apps/sonar/composeApp/src/androidMain/kotlin/chat/bitchat/sonar/backup/AutoBackupWorker.kt:109)).

5. **No code anywhere distinguishes cellular from wifi.** The only
   `NWPathMonitor` in the app (`NetworkActivationService`) checks reachability,
   never `isExpensive`; the BGProcessing request asks only
   `requiresNetworkConnectivity = true`
   ([AutoBackupBackgroundScheduler.swift:116](ios/bitchat/Services/AutoBackupBackgroundScheduler.swift:116));
   Android asks `CONNECTED`, not `UNMETERED`. The design comment even says the
   quiet part: *"a backup that only happens while charging is not a backup for
   most people"* — the same reasoning was never applied to metered data.

**Arithmetic.** Dirty-always + 30-min debounce + executors firing on every
backgrounding ⇒ up to 48 uploads/day. 2.2 GB/day ÷ 48 ≈ **46 MB per upload** —
squarely a plausible sealed DB+index size for a months-old account (cap is
200 MiB). At 20 uploads/day it's a 110 MB account; still ordinary. The observed
number is reproduced by this one mechanism with no second cause needed. Roaming
81.9 of 82.4 GB says the phone effectively *lived* on cellular, so the implicit
"it'll mostly happen on wifi" assumption never held for even one upload.

**Failed uploads count too.** A seal → upload that times out
(`TRANSFER_DEADLINE_MAX` = 20 min, min throughput 100 KiB/s) still *sent* those
bytes over the modem; the 30-min debounce then re-seals and re-sends the whole
blob. A large account on a slow roaming link can burn data forever without one
successful backup.

## Ruled out / secondary (each was checked)

- **Media downloads** — view-driven only (`.task` on bubble render →
  `prepareMedia`, images/audio auto, video/docs on demand,
  [SonarComponents.swift:2531](ios/bitchat/Views/Sonar/SonarComponents.swift:2531)),
  cached durably under Application Support (not the OS-purgeable Caches dir), so
  no refetch loop. Bounded by what the user actually views once. Retries are
  3 attempts, 350 ms apart, non-retryable 4xx excluded.
- **Media upload resume** — resumes only in-flight rows; failed rows need an
  explicit tap ([client.rs:4810](core/sonar-core/src/client.rs:4810)). Outbox
  publish retries are attempt-limited with backoff.
- **Relay sync** — event-driven (`waitForMarmotEvent`), watermark-scoped
  `.since` filters, batched `#h` fetch; `sync_force` only on
  foreground/wake/reconnect. Worst case is the retryable-rewind path: a failed
  relay quorum rewinds the watermark to a floor of now − 7 d
  (`GIFTWRAP_LOOKBACK_SECS`, [client.rs:904](core/sonar-core/src/client.rs:904)),
  so a flapping Tor/cellular link can re-pull a 7-day window of wraps + group
  messages on each reconnect. Real, worth a follow-up, but text-scale events —
  MB/day, not GB/day.
- **Tor (Arti)** — persists its directory state; a multiplier (~1.1–1.3×) on the
  above, not an independent source.
- **Sticker prefetch** — pack-install-time, small webp, LRU with evict-on-miss
  fixes from #307. Not a GB source.

## On-device confirmation (do this before/alongside the fix — 1 hour, no code)

1. Pull the app container read-only (`devicectl device copy directory` /
   Finder), read `<db>.sonar-backup-policy.json` next to the Marmot DB:
   `last_size_bytes` = per-upload cost, `last_success_at`/`last_attempt_at` +
   log lines = cadence. `account_storage_bytes` (DB + index) is the unsealed
   size.
2. List the Blossom host's blobs for the account key (BUD-03
   `{base}/list/{pubkey}`, mime `application/vnd.sonar.account-backup-v1`):
   one entry per successful upload with timestamps — a direct server-side count
   for the billing period. (Also shows whether old blobs accumulate host-side.)
3. Cross-check `SecureLogger` `.session` lines: "Auto-backup … running" /
   "Auto account backup uploaded" / "failed".

Expected result: uploads ≈ tens per day × tens of MB ≈ the 66 GB. If the count
comes back tiny, escalate the relay-rewind path (check for
"gift wrap sync" quorum failures in the same logs) before touching anything.

## Proposed solution

### P0 — stop the bleeding (small, shippable immediately, both platforms)

1. **Unmetered gate, host-side.**
   - iOS: monitor `NWPath.isExpensive` (extend `NetworkActivationService`);
     every auto-backup executor entry point (`runAutoBackupIfDue`, the
     opportunistic run, both BGTask handlers) refuses when the path is
     expensive unless the user opted in to cellular backup.
   - Android: `NetworkType.UNMETERED` on both WorkManager requests; same check
     in any in-app executor.
   - New Settings toggle "Back up over cellular" (default **off**), stored
     beside the disclosure flag. Show a "last backup: N days ago" age line so
     the gate can never silently mean *no backups* (Account Key Durability
     Rule: the user must be able to see backup staleness).
2. **Skip unchanged accounts, core-side.** Before sealing, hash the plaintext
   inputs (db bytes + index bytes — or cheaper: `(mtime, size)` of both files
   after checkpoint, upgraded to SHA-256 of the files). Store
   `last_plain_hash` in the policy sidecar; if unchanged since the last
   *successful* upload and the daily floor hasn't passed, record a no-op
   attempt and skip seal + upload entirely. This fixes the random-nonce
   problem at its root: dedup must happen before encryption.
3. **Fix the dirty definition.** `mark_backup_dirty` currently treats *incoming*
   messages as urgent. Received history is recoverable from relays; what is
   irreplaceable is local-only state. Keep the 30-min debounce for genuinely
   new local state, but let incoming-only dirt ride the daily floor. (Cheapest
   version: two dirty bits, `dirty_local` vs `dirty_remote`, only the first
   triggers opportunistic uploads.)

Estimated effect: P0.1 alone removes ~100% of the cellular spend for this user;
P0.2+P0.3 cut wifi spend to ~1 full upload/day worst case.

### P1 — right-size the payload (medium)

4. **Incremental/differential backup.** Signal's pattern (and the reason their
   backups don't eat data): archive-once, then append. Minimal version here:
   keep the full-snapshot format but upload only when the *content* changed
   (P0.2), on a daily cadence, and delete the previous blob (BUD-02 DELETE)
   after a successful upload so host storage doesn't grow unboundedly. Full
   delta encoding of a SQLCipher file is poor ROI vs. moving to an
   export-format backup (Signal's `SignalDatabase` → backup-proto approach) —
   track as a follow-up, don't block P0 on it.
5. **Cap and report.** Track uploaded-bytes-per-period in the policy sidecar;
   surface it in Settings → Backup ("this month: 412 MB"). Refuse the
   opportunistic path (not the manual one) past a sane ceiling.

### P2 — never be blind again (medium/large, separate change)

6. **Byte accounting in core.** One counter per subsystem (backup, media,
   relay, sticker, wallet) at the two HTTP client chokepoints
   (`HTTP_CLIENT`/`BLOSSOM_UPLOAD_HTTP_CLIENT` in client.rs, plus the relay
   pool's transport) + a Diagnostics "Data usage" panel next to the existing
   log export. Turns the next "eating data" report into a number the user can
   screenshot.
7. **Relay-rewind follow-up.** Bound how often a failed quorum may rewind the
   watermark to the 7-day floor (e.g. once per N hours), so a flapping link
   cannot re-pull the window on every reconnect.

### Cross-platform + regression notes

- P0 must land on iOS **and** Android in the same change (Cross-Platform
  Feature Rule); macOS keeps its in-app executor but gets the same unchanged-skip
  from core for free (no cellular concept there).
- Add a `docs/REGRESSIONS.md` entry once fixed, guarded by core tests:
  `backup_is_due`-level tests for the metered flag pass-through and an
  unchanged-hash test that fails if a second seal of identical inputs schedules
  an upload. Pin the *call site* (executor refuses on expensive path), not just
  the helper.
- None of this touches the seal/close/reopen dance — the 0xdead10cc invariants
  (rounds 6–8) stay untouched; the gate runs *before* `backupAccount()` so a
  skipped run never opens the store at all (strictly fewer reopen windows).

## Open questions (non-blocking)

- Reporter's actual `last_size_bytes` and server-side blob count — confirms the
  multiple (46 MB × 48/day vs 110 MB × 20/day etc.).
- Does the Blossom host garbage-collect superseded backup blobs, or is it
  storing every upload this user ever made? (Cost/privacy question for the
  host operator; P1.4 adds the client-side delete.)
- Android reporter data: same bug exists, but Doze batches WorkManager — is the
  observed magnitude platform-skewed to iOS because of the
  every-backgrounding opportunistic path?
