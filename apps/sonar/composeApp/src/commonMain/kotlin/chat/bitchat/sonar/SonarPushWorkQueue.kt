package chat.bitchat.sonar

import kotlinx.coroutines.Deferred
import kotlinx.coroutines.withTimeoutOrNull

internal data class SonarPushWork(
    val startId: Int,
    val type: String?,
    val notificationType: String,
    val deadlineElapsedMs: Long,
    val admissionGeneration: Long = 0,
    val admissionOwnerId: String = "",
)

internal data class SonarNotificationAdmissionState(
    val ownerId: String = "",
    val generation: Long = 0,
    val surfacedGeneration: Long = 0,
    val fallbackGeneration: Long = 0,
    val completedGeneration: Long = 0,
) {
    fun admit(ownerId: String): SonarNotificationAdmissionState {
        require(ownerId.isNotBlank()) { "notification admission requires an account owner" }
        val owned = if (this.ownerId == ownerId) this else SonarNotificationAdmissionState(
            ownerId = ownerId,
        )
        return owned.copy(generation = owned.generation + 1)
    }

    fun belongsTo(ownerId: String): Boolean =
        ownerId.isNotBlank() && this.ownerId == ownerId

    fun accepts(ownerId: String, admittedGeneration: Long): Boolean =
        belongsTo(ownerId) && admittedGeneration in 1..generation

    fun clearedUnlessOwnedBy(ownerId: String?): SonarNotificationAdmissionState =
        if (ownerId != null && belongsTo(ownerId)) this else SonarNotificationAdmissionState()

    fun markSurfaced(throughGeneration: Long): SonarNotificationAdmissionState = copy(
        surfacedGeneration = maxOf(surfacedGeneration, throughGeneration),
    )

    fun markFallback(throughGeneration: Long): SonarNotificationAdmissionState = copy(
        fallbackGeneration = maxOf(fallbackGeneration, throughGeneration),
    )

    fun markCompleted(throughGeneration: Long): SonarNotificationAdmissionState = copy(
        completedGeneration = maxOf(completedGeneration, throughGeneration),
    )

    fun needsFallback(forGeneration: Long): Boolean =
        forGeneration > surfacedGeneration && forGeneration > fallbackGeneration

    fun needsRecovery(forGeneration: Long = generation): Boolean =
        forGeneration > completedGeneration
}

internal fun markRenderedSnapshotSurfaced(
    state: SonarNotificationAdmissionState,
    renderedGeneration: Long,
): SonarNotificationAdmissionState = state.markSurfaced(renderedGeneration)

internal enum class SonarDurableWorkMode {
    KeepDelayedBackup,
    ReplaceSameGenerationWithImmediate,
}

internal fun sonarDurableWorkMode(upgradeDelayedBackup: Boolean): SonarDurableWorkMode =
    if (upgradeDelayedBackup) {
        SonarDurableWorkMode.ReplaceSameGenerationWithImmediate
    } else {
        SonarDurableWorkMode.KeepDelayedBackup
    }

/** Notification display is an independent user decision from whether the OS
 * may wake a closed process via background push. Live relay delivery in an
 * already-running app must continue to use the display preference alone. */
internal fun sonarNotificationDisplayEnabled(notificationsEnabled: Boolean): Boolean =
    notificationsEnabled

/** Coalesce only adjacent Marmot wakes. This preserves FIFO ordering around
 * wallet work while ensuring a burst cannot start overlapping native syncs. */
internal fun enqueueSonarPushWork(queue: MutableList<SonarPushWork>, work: SonarPushWork) {
    val tail = queue.lastOrNull()
    if (work.type == "marmot" &&
        tail?.type == work.type &&
        tail.admissionOwnerId == work.admissionOwnerId
    ) {
        val merged = tail.copy(
            startId = maxOf(tail.startId, work.startId),
            deadlineElapsedMs = minOf(tail.deadlineElapsedMs, work.deadlineElapsedMs),
            admissionGeneration = maxOf(tail.admissionGeneration, work.admissionGeneration),
        )
        if (tail.admissionGeneration == work.admissionGeneration) {
            // Duplicate delivery for one durable admission can share a single
            // recovery snapshot.
            queue[queue.lastIndex] = merged
        } else {
            val previous = queue.getOrNull(queue.lastIndex - 1)
            if (previous?.type == "marmot" &&
                previous.admissionOwnerId == work.admissionOwnerId
            ) {
                // Keep the oldest generation as its own recovery pass and fold
                // only the remaining burst into one newest-generation follow-up.
                // An old precise outbox row can therefore settle the oldest
                // wake, but it cannot mark the newest admission surfaced or
                // completed without a fresh snapshot. This also bounds every
                // adjacent per-account Marmot burst to two pending entries.
                queue[queue.lastIndex] = merged
            } else {
                queue += work
            }
        }
    } else {
        queue += work
    }
}

internal fun remainingPushBudgetMs(deadlineElapsedMs: Long, nowElapsedMs: Long): Long =
    (deadlineElapsedMs - nowElapsedMs).coerceAtLeast(0)

internal fun notificationSessionMatches(
    expectedGeneration: Long,
    expectedAccountSecret: String,
    currentGeneration: Long,
    currentAccountSecret: String,
): Boolean =
    expectedGeneration == currentGeneration && expectedAccountSecret == currentAccountSecret

/** Await an externally-owned blocking prerequisite without adopting/cancelling
 * it. This is essential for UniFFI connect: structured timeout would still wait
 * for the non-cooperative native call during child cancellation. */
internal suspend fun awaitPushPrerequisite(
    deadlineElapsedMs: Long,
    nowElapsedMs: () -> Long,
    prerequisite: Deferred<Boolean>,
): Boolean {
    val budget = remainingPushBudgetMs(deadlineElapsedMs, nowElapsedMs())
    if (budget == 0L) return false
    return withTimeoutOrNull(budget) { prerequisite.await() } ?: false
}

internal data class SonarCompletedPushWork(
    val work: SonarPushWork,
    val coalescedWhileActive: Boolean,
    val hasPendingMarmot: Boolean,
)

/** Small deterministic state machine behind the Android Service actor. Calls
 * are externally synchronized by the Service because `onStartCommand` and the
 * coroutine consumer run on different threads. */
internal class SonarPushWorkQueue {
    private val pending = mutableListOf<SonarPushWork>()
    private var active: SonarPushWork? = null
    private var coalescedWhileActive = false

    fun enqueue(work: SonarPushWork) {
        val current = active
        if (work.type == "marmot" &&
            current?.type == work.type &&
            current.admissionOwnerId == work.admissionOwnerId &&
            pending.isEmpty()
        ) {
            // The in-flight native snapshot cannot be widened safely. Absorb
            // the Android startId, then require one durable continuation after
            // completion to cover events that arrived behind that snapshot.
            active = current.copy(
                startId = maxOf(current.startId, work.startId),
                admissionGeneration = maxOf(
                    current.admissionGeneration,
                    work.admissionGeneration,
                ),
            )
            coalescedWhileActive = true
            return
        }
        enqueueSonarPushWork(pending, work)
    }

    fun next(): SonarPushWork? {
        check(active == null) { "push work already active" }
        if (pending.isEmpty()) return null
        return pending.removeAt(0).also { active = it }
    }

    fun complete(): SonarCompletedPushWork {
        val work = checkNotNull(active) { "no active push work" }
        return SonarCompletedPushWork(
            work = work,
            coalescedWhileActive = coalescedWhileActive,
            hasPendingMarmot = pending.any { it.type == "marmot" },
        ).also {
            active = null
            coalescedWhileActive = false
        }
    }
}
