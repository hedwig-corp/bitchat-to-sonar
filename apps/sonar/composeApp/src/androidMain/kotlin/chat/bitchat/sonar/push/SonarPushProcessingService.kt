package chat.bitchat.sonar.push

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import android.util.Log
import chat.bitchat.sonar.Notifier
import chat.bitchat.sonar.SonarCore
import chat.bitchat.sonar.SonarPushWork
import chat.bitchat.sonar.SonarPushWorkQueue
import chat.bitchat.sonar.awaitPushPrerequisite
import chat.bitchat.sonar.wallet.WalletBridge
import chat.bitchat.sonar.wallet.WalletState
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch

/**
 * Short-lived foreground service that processes push wakeups.
 *
 * Marmot pushes (transponder): sync messages → render user-visible notification.
 * Breez pushes (NDS): settle wallet event → NO user-visible notification.
 */
class SonarPushProcessingService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val queueLock = Any()
    private val workQueue = SonarPushWorkQueue()
    private val workSignal = Channel<Unit>(Channel.CONFLATED)

    override fun onCreate() {
        super.onCreate()
        Notifier.ensureChannel()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(SYNC_CHANNEL) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(SYNC_CHANNEL, "Sync", NotificationManager.IMPORTANCE_LOW)
                )
            }
        }
        val notification = Notification.Builder(this, SYNC_CHANNEL)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle("Sonar")
            .setContentText("Syncing...")
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(FOREGROUND_ID, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(FOREGROUND_ID, notification)
        }
        scope.launch { processQueue() }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val work = SonarPushWork(
            startId = startId,
            type = intent?.getStringExtra(EXTRA_PUSH_TYPE),
            notificationType = intent?.getStringExtra(EXTRA_NOTIFICATION_TYPE) ?: "",
            deadlineElapsedMs = intent?.getLongExtra(EXTRA_DEADLINE_ELAPSED_MS, 0L)
                ?.takeIf { it > 0 }
                ?: (SystemClock.elapsedRealtime() + TOTAL_PUSH_DEADLINE_MS),
            admissionGeneration = intent?.getLongExtra(EXTRA_ADMISSION_GENERATION, 0L) ?: 0L,
            admissionOwnerId = intent?.getStringExtra(EXTRA_ADMISSION_OWNER_ID).orEmpty(),
        )
        synchronized(queueLock) { workQueue.enqueue(work) }
        if (workSignal.trySend(Unit).isFailure) {
            Log.w(TAG, "Push actor unavailable for startId=$startId")
        }
        return START_NOT_STICKY
    }

    private suspend fun processQueue() {
        for (ignored in workSignal) {
            while (true) {
                val work = synchronized(queueLock) {
                    workQueue.next()
                } ?: break
                var marmotCompleted = false
                try {
                    when (work.type) {
                        TYPE_MARMOT -> marmotCompleted = processMarmotWakeup(
                            work.deadlineElapsedMs,
                            work.admissionGeneration,
                            work.admissionOwnerId,
                        )
                        TYPE_BREEZ -> processBreezWakeup(work.notificationType, work.deadlineElapsedMs)
                        else -> Log.w(TAG, "Unknown push type=${work.type}")
                    }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Exception) {
                    Log.e(TAG, "Push work failed type=${work.type}", error)
                }
                val completed = synchronized(queueLock) { workQueue.complete() }
                if (work.type == TYPE_MARMOT) {
                    // The pre-enqueued backup is deliberately not cancelled on
                    // success: cancellation can race a newly admitted push and
                    // erase its durable obligation. Its bounded, idempotent
                    // verification run completes the unique WorkManager job.
                    if (!marmotCompleted ||
                        completed.coalescedWhileActive ||
                        completed.hasPendingMarmot
                    ) {
                        SonarNotificationWorkScheduler.scheduleContinuation(this)
                    }
                }
                stopSelfResult(completed.work.startId)
            }
        }
    }

    private suspend fun processMarmotWakeup(
        deadlineElapsedMs: Long,
        admissionGeneration: Long,
        admissionOwnerId: String,
    ): Boolean {
        val outcome = SonarNotificationRecovery.run(
            this,
            deadlineElapsedMs,
            admissionGeneration,
            admissionOwnerId,
        )
        if (outcome.completed) {
            SonarNotificationAdmission.markCompleted(
                this,
                admissionOwnerId,
                admissionGeneration,
            )
        }
        return outcome.completed
    }

    private suspend fun processBreezWakeup(notificationType: String, deadlineElapsedMs: Long) {
        // Silent -- no user-visible notification. The payment amount
        // notification fires later through the transponder/chat path when the
        // ⚡PAY control line arrives.
        BreezPushRecovery.run(notificationType, deadlineElapsedMs)
    }

    override fun onDestroy() {
        workSignal.close()
        scope.cancel()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        private const val TAG = "SonarPushService"
        private const val SYNC_CHANNEL = "push_sync"
        const val FOREGROUND_ID = 9001
        const val EXTRA_PUSH_TYPE = "push_type"
        const val EXTRA_NOTIFICATION_TYPE = "notification_type"
        const val EXTRA_DEADLINE_ELAPSED_MS = "deadline_elapsed_ms"
        const val EXTRA_ADMISSION_GENERATION = "admission_generation"
        const val EXTRA_ADMISSION_OWNER_ID = "admission_owner_id"
        const val TYPE_MARMOT = "marmot"
        const val TYPE_BREEZ = "breez"

        const val TOTAL_PUSH_DEADLINE_MS = 22_000L
    }
}

/** Breez setup/refresh also crosses blocking native APIs. Own that work in a
 * process scope and only bound the Service's await, so wallet latency can never
 * starve a later Marmot wake or extend the foreground-service deadline. */
private object BreezPushRecovery {
    private const val TAG = "SonarBreezPush"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val jobLock = Any()
    private var activeJob: Deferred<Boolean>? = null

    suspend fun run(notificationType: String, deadlineElapsedMs: Long) {
        val job = synchronized(jobLock) {
            activeJob?.takeIf { it.isActive } ?: scope.async {
                runCatching {
                    if (WalletBridge.state() !is WalletState.Ready) {
                        val nsec = SonarCore.identityNsec()
                        if (nsec.isNotBlank()) WalletBridge.setupIfNeeded(nsec)
                    }
                    WalletBridge.refreshBalance()
                    true
                }.getOrElse {
                    Log.w(TAG, "Breez wakeup failed (silent)", it)
                    false
                }
            }.also { activeJob = it }
        }
        val completed = awaitPushPrerequisite(
            deadlineElapsedMs = deadlineElapsedMs,
            nowElapsedMs = SystemClock::elapsedRealtime,
            prerequisite = job,
        )
        if (completed) {
            Log.d(TAG, "Breez wakeup processed (type=$notificationType, silent)")
        } else {
            Log.w(TAG, "Breez wakeup exceeded its host deadline (type=$notificationType)")
        }
    }
}
