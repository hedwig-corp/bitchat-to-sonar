package chat.bitchat.sonar.push

import android.content.Context
import android.os.SystemClock
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import chat.bitchat.sonar.SonarDurableWorkMode
import chat.bitchat.sonar.Notifier
import chat.bitchat.sonar.SonarNotificationRouter
import chat.bitchat.sonar.sonarDurableWorkMode
import java.util.concurrent.TimeUnit

class SonarNotificationSyncWorker(
    appContext: Context,
    workerParams: WorkerParameters,
) : CoroutineWorker(appContext, workerParams) {
    override suspend fun doWork(): Result {
        val ownerId = inputData.getString(SonarNotificationWorkScheduler.INPUT_OWNER_ID).orEmpty()
        val generation = inputData.getLong(
            SonarNotificationWorkScheduler.INPUT_GENERATION,
            0,
        )
        val admission = SonarNotificationAdmission.currentForWork(
            context = applicationContext,
            expectedOwnerId = ownerId,
            currentOwnerId = SonarPushPrefs.accountOwnerId(),
        ) ?: return Result.success()
        if (!admission.accepts(ownerId, generation) || !admission.needsRecovery(generation)) {
            return Result.success()
        }
        if (!SonarPushPrefs.effectivePushEnabled(applicationContext)) {
            SonarNotificationAdmission.markCompleted(applicationContext, ownerId, generation)
            return Result.success()
        }
        val outcome = SonarNotificationRecovery.run(
            context = applicationContext,
            deadlineElapsedMs = SystemClock.elapsedRealtime() + WORK_DEADLINE_MS,
            admissionGeneration = generation,
            admissionOwnerId = ownerId,
        )
        val terminal = outcome.completed || runAttemptCount >= MAX_ATTEMPTS - 1
        return if (terminal) {
            SonarNotificationAdmission.markCompleted(applicationContext, ownerId, generation)
            Result.success()
        } else {
            Result.retry()
        }
    }

    companion object {
        private const val WORK_DEADLINE_MS = 22_000L
        private const val MAX_ATTEMPTS = 5
    }
}

internal object SonarNotificationWorkScheduler {
    private const val UNIQUE_WORK = "sonar-notification-catch-up"
    private const val WORK_TAG = "sonar-notification-catch-up"
    private const val BACKUP_DELAY_SECONDS = 30L

    /** Persist a backup before starting a foreground service. If the process is
     * killed mid-sync, WorkManager still owns this obligation. */
    fun scheduleBackup(context: Context): chat.bitchat.sonar.SonarNotificationAdmissionState {
        val ownerId = requireNotNull(SonarPushPrefs.accountOwnerId()) {
            "Cannot admit notification work without an account"
        }
        val admission = SonarNotificationAdmission.admit(context, ownerId)
        enqueue(
            context,
            admission.ownerId,
            admission.generation,
            BACKUP_DELAY_SECONDS,
            awaitPersistence = true,
            upgradeDelayedBackup = false,
        )
        return admission
    }

    fun scheduleDeletedMessages(context: Context) {
        val ownerId = SonarPushPrefs.accountOwnerId() ?: return
        val admission = SonarNotificationAdmission.admit(context, ownerId)
        enqueue(
            context,
            admission.ownerId,
            admission.generation,
            0,
            awaitPersistence = true,
            upgradeDelayedBackup = false,
        )
    }

    fun scheduleContinuation(context: Context) {
        val currentOwnerId = SonarPushPrefs.accountOwnerId()
        val state = SonarNotificationAdmission.current(context)
        val current = SonarNotificationAdmission.currentForWork(
            context,
            expectedOwnerId = state.ownerId,
            currentOwnerId = currentOwnerId,
        ) ?: return
        enqueue(
            context,
            current.ownerId,
            current.generation,
            0,
            awaitPersistence = false,
            upgradeDelayedBackup = true,
        )
    }

    fun ensureAdmittedWork(context: Context) {
        val persisted = SonarNotificationAdmission.current(context)
        val state = SonarNotificationAdmission.currentForWork(
            context,
            expectedOwnerId = persisted.ownerId,
            currentOwnerId = SonarPushPrefs.accountOwnerId(),
        ) ?: return
        if (state.needsRecovery()) {
            enqueue(
                context,
                state.ownerId,
                state.generation,
                0,
                awaitPersistence = false,
                upgradeDelayedBackup = false,
            )
        }
    }

    private fun enqueue(
        context: Context,
        ownerId: String,
        generation: Long,
        delaySeconds: Long,
        awaitPersistence: Boolean,
        upgradeDelayedBackup: Boolean,
    ) {
        val request = OneTimeWorkRequestBuilder<SonarNotificationSyncWorker>()
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .setInitialDelay(delaySeconds, TimeUnit.SECONDS)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .setInputData(
                workDataOf(
                    INPUT_OWNER_ID to ownerId,
                    INPUT_GENERATION to generation,
                ),
            )
            .addTag(WORK_TAG)
            .build()
        val operation = WorkManager.getInstance(context).enqueueUniqueWork(
            "$UNIQUE_WORK-$ownerId-$generation",
            // REPLACE upgrades this generation's still-delayed 30-second
            // backup to immediate work after FGS rejection/incomplete recovery.
            // The FGS budget is 22 seconds, so its continuation runs before the
            // backup can start. The generation remains in the unique name, so
            // a newer wake is never replaced or cancelled.
            when (sonarDurableWorkMode(upgradeDelayedBackup)) {
                SonarDurableWorkMode.KeepDelayedBackup -> ExistingWorkPolicy.KEEP
                SonarDurableWorkMode.ReplaceSameGenerationWithImmediate ->
                    ExistingWorkPolicy.REPLACE
            },
            request,
        )
        if (awaitPersistence) {
            // Do not enter the foreground-service path until WorkManager has
            // durably accepted the backup. Bound the FCM callback wait.
            operation.result.get(1, TimeUnit.SECONDS)
        }
    }

    /** Account replacement boundary: synchronously retire admission/progress,
     * then cancel both the exact legacy request and every owner-tagged request.
     * A running worker still self-rejects from its owner input. */
    fun invalidateAll(context: Context) {
        val state = SonarNotificationAdmission.current(context)
        SonarNotificationAdmission.clear(context)
        val workManager = WorkManager.getInstance(context)
        if (state.generation > 0) {
            workManager.cancelUniqueWork("$UNIQUE_WORK-${state.generation}")
            if (state.ownerId.isNotEmpty()) {
                workManager.cancelUniqueWork("$UNIQUE_WORK-${state.ownerId}-${state.generation}")
            }
        }
        workManager.cancelAllWorkByTag(WORK_TAG)
        Notifier.cancel(SonarNotificationRouter.notificationId(SonarNotificationRecovery.FALLBACK_ID_KEY))
    }

    const val INPUT_GENERATION = "notification_generation"
    const val INPUT_OWNER_ID = "notification_owner_id"
}
