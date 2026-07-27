package chat.bitchat.sonar.backup

import android.content.Context
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
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
        } catch (_: Exception) {
            // Do not swallow Error (OOM / LinkageError) as retry.
            Result.retry()
        }
    }

    companion object {
        const val UNIQUE_NAME = "sonar-auto-backup"
        const val DISCLOSED_PREF = "pref.auto_backup_disclosed"

        fun enqueue(context: Context) {
            val constraints = Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
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

        fun cancel(context: Context) {
            WorkManager.getInstance(context.applicationContext).cancelUniqueWork(UNIQUE_NAME)
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
