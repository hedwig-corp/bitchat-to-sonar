package chat.bitchat.sonar.backup

/** Platform periodic auto-backup (WorkManager on Android; no-op on JVM desktop). */
expect fun schedulePlatformAutoBackupWork()

expect fun cancelPlatformAutoBackupWork()

/** True while the Compose UI owns a live Marmot session (Android worker must skip). */
expect fun setLiveUiSessionForAutoBackup(live: Boolean)

/**
 * One-shot backup attempt shortly after the app leaves the foreground.
 *
 * The fallback half of opportunistic backup: the in-process attempt runs
 * immediately on background, and this survives the process being killed before
 * that attempt lands — a fresh worker process has the session gate down. The
 * worker re-checks `backup_is_due`, so when the in-process run already
 * uploaded, this no-ops.
 */
expect fun enqueueOneShotPlatformAutoBackup()

/**
 * Device UTC offset in seconds, for rendering "Today/Yesterday" boundaries in
 * the user's own day rather than UTC's. Caught on device: a 23:33 local backup
 * rendered as "Today, 21:33" at 01:38 the next morning.
 */
expect fun currentUtcOffsetSecs(): Long

/**
 * True when the active route bills the user for bytes (cellular, hotspot, or a
 * Data Saver restriction).
 *
 * Only bulk transfers consult this. A backup is a FULL-ACCOUNT snapshot and the
 * executors fire on every backgrounding, so before this gate an active roaming
 * account re-uploaded its whole database dozens of times a day — 66.3 GB in one
 * billing period on the report that prompted it.
 *
 * Pessimistic (`true`) when the answer is unknown, matching iOS: skipping a
 * backup is recoverable, an unexpected multi-megabyte cellular upload is not.
 * Desktop has no metered concept and answers `false`.
 */
expect fun isNetworkMetered(): Boolean

/**
 * Whether this platform can actually tell a metered link from an unmetered one.
 *
 * `false` on Compose Desktop: the JVM has no portable metered-network API, so
 * [isNetworkMetered] there is a hard-coded `false` and a "wait for Wi-Fi"
 * preference would be unenforceable. The Backup screen hides the toggle rather
 * than offering a data-saving control that silently does nothing — a UI that
 * promises something it cannot deliver is the same class of defect as the
 * "Backup failed" toast on a healthy account.
 *
 * TRACKED GAP (desktop): a laptop on a phone hotspot still auto-uploads full
 * snapshots. Closing it needs per-OS native probing (Windows exposes a
 * connection-cost API; macOS and Linux need separate paths), which is why it is
 * not in this change. Follow-up: implement `isNetworkMetered()` per desktop OS,
 * then flip this to `true` and the toggle reappears with no other edits.
 */
expect val meteredNetworkPolicySupported: Boolean
