package chat.bitchat.sonar.push

import android.content.Context
import android.os.SystemClock
import android.util.Log
import chat.bitchat.sonar.Notifier
import chat.bitchat.sonar.SonarCore
import chat.bitchat.sonar.SonarDeltaNotificationAction
import chat.bitchat.sonar.SonarLifecycle
import chat.bitchat.sonar.SonarNotificationKind
import chat.bitchat.sonar.SonarNotificationRouter
import chat.bitchat.sonar.SOCIAL_STATE_BLOB_KEY
import chat.bitchat.sonar.awaitPushPrerequisite
import chat.bitchat.sonar.decodeSonarSocialState
import chat.bitchat.sonar.notificationSessionMatches
import chat.bitchat.sonar.remainingPushBudgetMs
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

internal data class SonarNotificationRecoveryOutcome(
    val completed: Boolean,
    val preciseCount: Int = 0,
)

/** Process-wide serialization shared by FCM's foreground service and
 * WorkManager. Rust also owns its continuation, but this mutex avoids wasting
 * the host deadline waiting on a second blocking UniFFI call. */
internal object SonarNotificationRecovery {
    private const val TAG = "SonarPushRecovery"
    private const val NATIVE_DEADLINE_MS = 12_000L
    private const val RENDER_MARGIN_MS = 2_000L
    private val singleFlight = Mutex()
    private val prerequisiteScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val connectLock = Any()
    private var connectJob: Deferred<Boolean>? = null

    suspend fun run(
        context: Context,
        deadlineElapsedMs: Long,
        admissionGeneration: Long,
        admissionOwnerId: String,
    ): SonarNotificationRecoveryOutcome =
        singleFlight.withLock {
            val currentOwnerId = SonarPushPrefs.accountOwnerId()
            val admission = SonarNotificationAdmission.currentForWork(
                context = context,
                expectedOwnerId = admissionOwnerId,
                currentOwnerId = currentOwnerId,
            )
            if (admission == null || !admission.accepts(admissionOwnerId, admissionGeneration)) {
                Log.i(TAG, "Notification recovery retired before sync after account changed")
                return@withLock SonarNotificationRecoveryOutcome(completed = true)
            }
            // WorkManager can start in a fresh process where the foreground
            // service has never created the channel.
            Notifier.ensureChannel()
            val prefs = SonarPushPrefs.notificationPrefs(context)
            val accountNsec = SonarCore.identityNsec()
            try {
                if (remaining(deadlineElapsedMs) <= RENDER_MARGIN_MS) {
                    showFallbackOnce(
                        context,
                        prefs,
                        admissionGeneration,
                        admissionOwnerId,
                        accountNsec,
                    )
                    return@withLock SonarNotificationRecoveryOutcome(completed = false)
                }

                if (!awaitRelayConnection(deadlineElapsedMs - RENDER_MARGIN_MS)) {
                    showFallbackOnce(
                        context,
                        prefs,
                        admissionGeneration,
                        admissionOwnerId,
                        accountNsec,
                    )
                    return@withLock SonarNotificationRecoveryOutcome(completed = false)
                }
                val sessionGeneration = SonarCore.notificationSessionGeneration()
                if (SonarCore.identityNsec() != accountNsec) {
                    Log.i(TAG, "Notification recovery retired after account identity changed")
                    return@withLock SonarNotificationRecoveryOutcome(completed = true)
                }
                var preciseCount = surfaceAndPersistProgress(
                    context,
                    prefs,
                    admissionGeneration,
                    admissionOwnerId,
                    expectedSessionGeneration = sessionGeneration,
                )
                val nativeBudget = (remaining(deadlineElapsedMs) - RENDER_MARGIN_MS)
                    .coerceAtMost(NATIVE_DEADLINE_MS)
                if (nativeBudget < 250L) {
                    if (preciseCount == 0) {
                        showFallbackOnce(
                            context,
                            prefs,
                            admissionGeneration,
                            admissionOwnerId,
                            accountNsec,
                        )
                    }
                    return@withLock SonarNotificationRecoveryOutcome(
                        completed = false,
                        preciseCount = preciseCount,
                    )
                }

                val result = SonarCore.syncNotifications(nativeBudget)
                if (!notificationSessionMatches(
                        sessionGeneration,
                        accountNsec,
                        SonarCore.notificationSessionGeneration(),
                        SonarCore.identityNsec(),
                    )
                ) {
                    Log.i(TAG, "Notification recovery retired after account generation changed")
                    return@withLock SonarNotificationRecoveryOutcome(completed = true)
                }
                Log.i(
                    TAG,
                    "completed=${result.completed} timedOut=${result.timedOut} " +
                        "truncated=${result.truncated} processed=${result.processedEvents} " +
                        "notifications=${result.notifications.size} elapsedMs=${result.elapsedMs}",
                )
                val pending = SonarCore.pendingNotifications()
                preciseCount += surfaceAndPersistProgress(
                    context,
                    prefs,
                    admissionGeneration,
                    admissionOwnerId,
                    pending,
                    expectedSessionGeneration = sessionGeneration,
                )
                // The data-only push itself is the current-wake correlation.
                // Even a complete empty relay page needs one privacy-safe alert
                // unless this generation was precisely surfaced/foreground-ACKed.
                if (preciseCount == 0 && pending.isEmpty()) {
                    showFallbackOnce(
                        context,
                        prefs,
                        admissionGeneration,
                        admissionOwnerId,
                        accountNsec,
                    )
                }
                SonarNotificationRecoveryOutcome(
                    completed = result.completed && remaining(deadlineElapsedMs) > 0,
                    preciseCount = preciseCount,
                )
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                Log.e(TAG, "Notification recovery failed", error)
                showFallbackOnce(
                    context,
                    prefs,
                    admissionGeneration,
                    admissionOwnerId,
                    accountNsec,
                )
                SonarNotificationRecoveryOutcome(completed = false)
            }
        }

    /** Shared entry point for live delivery and explicit foreground sync. */
    suspend fun surfacePending(context: Context): Int = singleFlight.withLock {
        Notifier.ensureChannel()
        val state = SonarNotificationAdmission.current(context)
        val ownerId = SonarPushPrefs.accountOwnerId()
        val generation = state.generation
        surfaceAndPersistProgress(
            context,
            SonarPushPrefs.notificationPrefs(context),
            generation,
            ownerId?.takeIf { state.belongsTo(it) },
        )
    }

    private suspend fun surfaceAndPersistProgress(
        context: Context,
        prefs: chat.bitchat.sonar.SonarNotificationPrefs,
        admissionGeneration: Long,
        admissionOwnerId: String?,
        pending: List<chat.bitchat.sonar.SonarDrainNotification>? = null,
        expectedSessionGeneration: Long? = null,
    ): Int {
        // The app-owned UI path acknowledges only after repainting its local
        // database snapshot. A remote push racing that foreground path must not
        // display an OS notification or steal its acknowledgment.
        if (SonarLifecycle.isForeground) return 0
        val sessionGeneration = expectedSessionGeneration
            ?: SonarCore.notificationSessionGeneration()
        if (SonarCore.notificationSessionGeneration() != sessionGeneration) return 0
        val surfaced = surfacePendingLocked(
            prefs,
            pending ?: SonarCore.pendingNotifications(),
            sessionGeneration,
        )
        if (surfaced != 0 && admissionOwnerId != null) {
            // The snapshot above belongs only to this admitted wake. A newer
            // wake can arrive while rendering and must retain its own fallback
            // obligation until its later snapshot is actually surfaced.
            SonarNotificationAdmission.markRenderedSnapshotSurfaced(
                context,
                admissionOwnerId,
                admissionGeneration,
            )
            Notifier.cancel(SonarNotificationRouter.notificationId(FALLBACK_ID_KEY))
        }
        return surfaced
    }

    private suspend fun surfacePendingLocked(
        prefs: chat.bitchat.sonar.SonarNotificationPrefs,
        pending: List<chat.bitchat.sonar.SonarDrainNotification>,
        expectedSessionGeneration: Long,
    ): Int {
        val canNotify = Notifier.canNotify()
        val nowSecs = System.currentTimeMillis() / 1_000L
        val socialState = decodeSonarSocialState(SonarCore.loadBlob(SOCIAL_STATE_BLOB_KEY))
        val acknowledged = mutableListOf<String>()
        pending.forEach { delta ->
            val action = SonarNotificationRouter.actionForDelta(
                delta = delta,
                notificationsAllowed = canNotify,
                prefs = prefs,
                nowSecs = nowSecs,
                senderAllowed = socialState.allowsChatMessage(
                    chatId = delta.groupId,
                    senderNpub = delta.senderNpub,
                    mine = false,
                ),
                parseCallControl = SonarCore::callParseControl,
            )
            val handled = SonarCore.runIfNotificationSessionCurrent(expectedSessionGeneration) {
                when (action) {
                    is SonarDeltaNotificationAction.Post -> {
                        val notification = action.notification
                        Notifier.notify(notification.id, notification.title, notification.body)
                    }
                    is SonarDeltaNotificationAction.Cancel -> Notifier.cancel(action.notificationId)
                    SonarDeltaNotificationAction.Acknowledge -> true
                    SonarDeltaNotificationAction.None -> false
                }
            }
            if (handled) acknowledged += delta.messageId
        }
        if (acknowledged.isNotEmpty()) {
            SonarCore.ackNotificationsForSession(acknowledged, expectedSessionGeneration)
        }
        return acknowledged.size
    }

    private suspend fun awaitRelayConnection(deadlineElapsedMs: Long): Boolean {
        if (SonarCore.isRelayConnected()) return true
        val job = synchronized(connectLock) {
            connectJob?.takeIf { it.isActive } ?: prerequisiteScope.async {
                runCatching {
                    // `connectRelays` also creates the node when start() has not
                    // run. Keep the non-cooperative UniFFI call externally owned
                    // so a push deadline never waits for its cancellation.
                    SonarCore.connectRelays()
                    SonarCore.isRelayConnected()
                }.getOrElse {
                    Log.w(TAG, "Relay prerequisite failed", it)
                    false
                }
            }.also { connectJob = it }
        }
        return awaitPushPrerequisite(
            deadlineElapsedMs = deadlineElapsedMs,
            nowElapsedMs = SystemClock::elapsedRealtime,
            prerequisite = job,
        )
    }

    private fun remaining(deadlineElapsedMs: Long): Long =
        remainingPushBudgetMs(deadlineElapsedMs, SystemClock.elapsedRealtime())

    private fun showFallbackOnce(
        context: Context,
        prefs: chat.bitchat.sonar.SonarNotificationPrefs,
        generation: Long,
        ownerId: String,
        expectedIdentityNsec: String? = null,
    ) {
        if (SonarLifecycle.isForeground) return
        if (expectedIdentityNsec != null && SonarCore.identityNsec() != expectedIdentityNsec) return
        val sessionGeneration = SonarCore.notificationSessionGeneration()
        val progress = SonarNotificationAdmission.currentForWork(
            context = context,
            expectedOwnerId = ownerId,
            currentOwnerId = SonarPushPrefs.accountOwnerId(),
        ) ?: return
        if (!progress.accepts(ownerId, generation) ||
            !progress.needsFallback(generation) ||
            !Notifier.canNotify()
        ) return
        val notification = SonarNotificationRouter.build(
            idKey = FALLBACK_ID_KEY,
            kind = SonarNotificationKind.Message,
            unreadCount = 1,
            prefs = prefs.copy(showPreview = false),
        ) ?: return
        val posted = SonarCore.runIfNotificationSessionCurrent(sessionGeneration) {
            (expectedIdentityNsec == null || SonarCore.identityNsec() == expectedIdentityNsec) &&
                SonarPushPrefs.accountOwnerId() == ownerId &&
                Notifier.notify(notification.id, notification.title, notification.body)
        }
        if (posted) SonarNotificationAdmission.markFallback(context, ownerId, generation)
    }

    const val FALLBACK_ID_KEY = "marmot-push"
}
