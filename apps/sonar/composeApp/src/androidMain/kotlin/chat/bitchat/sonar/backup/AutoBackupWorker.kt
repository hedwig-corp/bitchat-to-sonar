package chat.bitchat.sonar.backup

import android.content.Context
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import chat.bitchat.sonar.AppContextHolder
import chat.bitchat.sonar.NdkContext
import chat.bitchat.sonar.SonarCore
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException

/**
 * Process-wide gate: when the Compose UI owns (or is booting) a Marmot session,
 * the OS worker must not seal (that would close the node under the UI's feet).
 *
 * Headless wakes count too. A push-started process has no UI session, so the
 * boolean alone would let a WorkManager seal call `closeNode()` in the middle
 * of a push drain — silently undoing the killed-app receive path. Those wakes
 * are re-entrant and can overlap, so they hold a counter rather than the flag:
 * releasing one must not clear a hold the UI (or another wake) still owns.
 */
object MarmotSessionGate {
    private val lock = Any()

    private var liveUiSession: Boolean = false
    private var headlessSessions: Int = 0

    fun setLiveUiSession(live: Boolean) {
        synchronized(lock) {
            liveUiSession = live
        }
    }

    /** Claim the node for a headless wake (push drain, wallet answer). */
    fun acquireHeadlessSession() {
        synchronized(lock) {
            headlessSessions += 1
        }
    }

    fun releaseHeadlessSession() {
        synchronized(lock) {
            if (headlessSessions > 0) headlessSessions -= 1
        }
    }

    /** True while anything in this process owns the node. */
    fun isLiveUiSession(): Boolean = synchronized(lock) {
        liveUiSession || headlessSessions > 0
    }
}

/** Run [body] with the node claimed against background seals. */
suspend fun <T> withMarmotSessionClaim(body: suspend () -> T): T {
    MarmotSessionGate.acquireHeadlessSession()
    return try {
        body()
    } finally {
        MarmotSessionGate.releaseHeadlessSession()
    }
}

/**
 * OS-scheduled auto-backup when the UI session is not live. Honors disclosure
 * pref + core `backup_is_due`.
 */
class AutoBackupWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result {
        NdkContext.install(applicationContext)
        if (MarmotSessionGate.isLiveUiSession()) return Result.success()
        if (SonarCore.loadBlob(DISCLOSED_PREF) != "1") return Result.success()
        if (!SonarCore.onboardingComplete()) return Result.success()
        // The route can change between dispatch and here, and a constraint that
        // held when the job was enqueued does not bind the upload that starts
        // now. Result.success(), not retry(): the periodic job and the next
        // backgrounding both come back, and retrying would just burn slots
        // while the user is still on cellular.
        if (!AutoBackupNetworkPolicy.allowsUpload(
                metered = runCatching { isNetworkMetered() }.getOrDefault(true),
                cellularOptIn = runCatching {
                    SonarCore.loadBlob(AutoBackupNetworkPolicy.CELLULAR_OPT_IN_PREF) == "1"
                }.getOrDefault(false),
            )
        ) {
            android.util.Log.i("AutoBackupWorker", "skipped: metered link, cellular backup off")
            return Result.success()
        }
        if (!SonarCore.backupIsDue()) return Result.success()
        return try {
            // Final check is inside sealAccountBackup under the Marmot lock
            // (boot raises liveUiSession before SonarCore.start).
            SonarCore.backupAccountToBlossom(requireNoLiveUiSession = true)
            Result.success()
        } catch (_: LiveUiSessionActiveException) {
            Result.success()
        } catch (e: CancellationException) {
            // Structured concurrency cancel must not become Result.retry().
            throw e
        } catch (e: Exception) {
            if (AutoBackupNetworkPolicy.isUnchangedAccount(e)) {
                // Core refused to re-seal a byte-identical account. Nothing to
                // upload and nothing wrong — `backupAccountToBlossom` surfaces
                // the refusal as a thrown error, so without this the worker
                // would burn its backoff slots re-discovering the same no-op
                // and log a scary warning for a healthy account.
                android.util.Log.i("AutoBackupWorker", "skipped: unchanged since the last upload")
                return Result.success()
            }
            // Do not swallow Error (OOM / LinkageError) as retry. Log before
            // retrying: a silent retry made the on-device worker test
            // undiagnosable — the job "ran" and nothing said why nothing
            // happened.
            android.util.Log.w("AutoBackupWorker", "background backup failed; will retry", e)
            Result.retry()
        }
    }

    companion object {
        const val UNIQUE_NAME = "sonar-auto-backup"
        const val ONE_SHOT_NAME = "sonar-auto-backup-oneshot"
        const val DISCLOSED_PREF = "pref.auto_backup_disclosed"

        /**
         * `UNMETERED` unless the user opted into cellular backups.
         *
         * Belt and braces with the in-worker [isNetworkMetered] check below:
         * the constraint keeps WorkManager from waking us at all on a metered
         * link, and the runtime check catches the route changing between the
         * job being dispatched and the upload starting.
         */
        private fun networkType(): NetworkType {
            // Enqueue can run before the core is initialised (startup schedules
            // the periodic job). A failed read means "not opted in", which is
            // the safe direction: worst case a backup waits for Wi-Fi.
            val optedIn = runCatching {
                SonarCore.loadBlob(AutoBackupNetworkPolicy.CELLULAR_OPT_IN_PREF) == "1"
            }.getOrDefault(false)
            return if (optedIn) NetworkType.CONNECTED else NetworkType.UNMETERED
        }

        fun enqueue(context: Context) {
            val constraints = Constraints.Builder()
                .setRequiredNetworkType(networkType())
                .setRequiresBatteryNotLow(true)
                .build()
            val request = PeriodicWorkRequestBuilder<AutoBackupWorker>(12, TimeUnit.HOURS)
                .setConstraints(constraints)
                .build()
            // UPDATE so app upgrades pick new interval/constraints (KEEP would
            // leave a pre-install schedule forever).
            WorkManager.getInstance(context.applicationContext).enqueueUniquePeriodicWork(
                UNIQUE_NAME,
                ExistingPeriodicWorkPolicy.UPDATE,
                request,
            )
        }

        /**
         * One-shot attempt ~3 minutes after the app backgrounds. REPLACE so a
         * quick app switch just resets the timer instead of stacking jobs; the
         * worker re-checks `backup_is_due` and the session gate, so a run that
         * races the user reopening the app degrades to a no-op, never a seal
         * under a live session.
         */
        fun enqueueOneShot(context: Context) {
            val constraints = Constraints.Builder()
                .setRequiredNetworkType(networkType())
                .build()
            val request = OneTimeWorkRequestBuilder<AutoBackupWorker>()
                .setInitialDelay(3, TimeUnit.MINUTES)
                .setConstraints(constraints)
                .build()
            WorkManager.getInstance(context.applicationContext).enqueueUniqueWork(
                ONE_SHOT_NAME,
                ExistingWorkPolicy.REPLACE,
                request,
            )
        }

        fun cancel(context: Context) {
            val wm = WorkManager.getInstance(context.applicationContext)
            wm.cancelUniqueWork(UNIQUE_NAME)
            wm.cancelUniqueWork(ONE_SHOT_NAME)
        }
    }
}

/** Thrown when a background seal aborts because the UI owns Marmot. */
class LiveUiSessionActiveException : IllegalStateException("ui marmot session is live")

fun scheduleAndroidAutoBackupWork() {
    val ctx = try {
        AppContextHolder.ctx
    } catch (_: UninitializedPropertyAccessException) {
        return
    }
    AutoBackupWorker.enqueue(ctx)
}

fun cancelAndroidAutoBackupWork() {
    val ctx = try {
        AppContextHolder.ctx
    } catch (_: UninitializedPropertyAccessException) {
        return
    }
    AutoBackupWorker.cancel(ctx)
}

fun enqueueOneShotAndroidAutoBackup() {
    val ctx = try {
        AppContextHolder.ctx
    } catch (_: UninitializedPropertyAccessException) {
        return
    }
    AutoBackupWorker.enqueueOneShot(ctx)
}
