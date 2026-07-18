package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.test.runTest

@OptIn(ExperimentalCoroutinesApi::class)
class SonarPushWorkQueueTest {
    @Test
    fun adjacentMarmotWakesCoalesceWithoutCrossingWalletWork() {
        val queue = mutableListOf<SonarPushWork>()
        enqueueSonarPushWork(queue, work(1, "marmot", 1_000))
        enqueueSonarPushWork(queue, work(2, "marmot", 900))
        enqueueSonarPushWork(queue, work(3, "breez", 1_200))
        enqueueSonarPushWork(queue, work(4, "marmot", 1_100))

        assertEquals(listOf(2, 3, 4), queue.map { it.startId })
        assertEquals(900, queue.first().deadlineElapsedMs)
    }

    @Test
    fun deadlineBudgetIncludesAdmissionDelayAndNeverGoesNegative() {
        assertEquals(750, remainingPushBudgetMs(1_000, 250))
        assertEquals(0, remainingPushBudgetMs(1_000, 1_001))
    }

    @Test
    fun secondMarmotStartDuringActiveLaneIsAbsorbedAndRequestsContinuation() {
        val queue = SonarPushWorkQueue()
        queue.enqueue(work(41, "marmot", 22_000))
        assertEquals(41, queue.next()?.startId)

        queue.enqueue(work(42, "marmot", 34_000))
        val completed = queue.complete()

        assertEquals(42, completed.work.startId)
        assertEquals(true, completed.coalescedWhileActive)
        assertEquals(false, completed.hasPendingMarmot)
        assertEquals(null, queue.next())
    }

    @Test
    fun activeMarmotNeverCoalescesAcrossPendingWalletWork() {
        val queue = SonarPushWorkQueue()
        queue.enqueue(work(41, "marmot", 22_000))
        assertEquals(41, queue.next()?.startId)
        queue.enqueue(work(42, "breez", 23_000))
        queue.enqueue(work(43, "marmot", 24_000))

        val first = queue.complete()
        assertEquals(41, first.work.startId)
        assertEquals(false, first.coalescedWhileActive)
        assertEquals(true, first.hasPendingMarmot)
        assertEquals(42, queue.next()?.startId)
        queue.complete()
        assertEquals(43, queue.next()?.startId)
    }

    @Test
    fun blockingExternalConnectCannotHoldCompletionPastAbsoluteBudget() = runTest {
        val neverCompletes = backgroundScope.async { awaitCancellation() }
        val connected = awaitPushPrerequisite(
            deadlineElapsedMs = 22_000,
            nowElapsedMs = { testScheduler.currentTime },
            prerequisite = neverCompletes,
        )

        assertEquals(false, connected)
        assertEquals(22_000, testScheduler.currentTime)
        assertEquals(true, neverCompletes.isActive)
    }

    @Test
    fun alreadyCompletedPrerequisiteReturnsWithoutConsumingBudget() = runTest {
        val connected = awaitPushPrerequisite(
            deadlineElapsedMs = 22_000,
            nowElapsedMs = { testScheduler.currentTime },
            prerequisite = CompletableDeferred(true),
        )
        assertEquals(true, connected)
        assertEquals(0, testScheduler.currentTime)
    }

    @Test
    fun surfacedProgressPreventsLaterEmptyContinuationFallback() {
        val admitted = SonarNotificationAdmissionState().admit("account-a")
        assertEquals(true, admitted.needsFallback(admitted.generation))

        val surfaced = admitted.markSurfaced(admitted.generation)
        assertEquals(false, surfaced.needsFallback(admitted.generation))
        assertEquals(true, surfaced.needsRecovery())
        assertEquals(false, surfaced.markCompleted(admitted.generation).needsRecovery())
        assertEquals(
            false,
            surfaced.markFallback(admitted.generation).needsFallback(admitted.generation),
        )
    }

    @Test
    fun olderSurfaceCannotSuppressNewerWakeFallback() {
        val first = SonarNotificationAdmissionState().admit("account-a")
        val second = first.admit("account-a")
        val olderSurface = markRenderedSnapshotSurfaced(second, first.generation)

        assertEquals(false, olderSurface.needsFallback(first.generation))
        assertEquals(true, olderSurface.needsFallback(second.generation))
    }

    @Test
    fun immediateContinuationUpgradesSameGenerationDelayedBackup() {
        assertEquals(
            SonarDurableWorkMode.KeepDelayedBackup,
            sonarDurableWorkMode(upgradeDelayedBackup = false),
        )
        assertEquals(
            SonarDurableWorkMode.ReplaceSameGenerationWithImmediate,
            sonarDurableWorkMode(upgradeDelayedBackup = true),
        )
    }

    @Test
    fun coalescingPreservesNewestAdmissionGeneration() {
        val queue = mutableListOf<SonarPushWork>()
        enqueueSonarPushWork(queue, work(1, "marmot", 1_000, generation = 4))
        enqueueSonarPushWork(queue, work(2, "marmot", 900, generation = 7))

        assertEquals(listOf(4L, 7L), queue.map { it.admissionGeneration })
    }

    @Test
    fun olderPreciseSnapshotCannotCompleteNewerQueuedWake() {
        val firstAdmission = SonarNotificationAdmissionState().admit("account-a")
        val secondAdmission = firstAdmission.admit("account-a")
        val queue = mutableListOf<SonarPushWork>()
        enqueueSonarPushWork(
            queue,
            work(1, "marmot", 1_000, generation = firstAdmission.generation),
        )
        enqueueSonarPushWork(
            queue,
            work(2, "marmot", 1_100, generation = secondAdmission.generation),
        )

        val olderSnapshot = queue.removeAt(0)
        val afterOlderPrecise = secondAdmission
            .markSurfaced(olderSnapshot.admissionGeneration)
            .markCompleted(olderSnapshot.admissionGeneration)

        assertEquals(firstAdmission.generation, olderSnapshot.admissionGeneration)
        assertEquals(secondAdmission.generation, queue.single().admissionGeneration)
        // The newer relay event was absent from the older snapshot. Its own
        // queued recovery/fallback obligation must therefore remain live.
        assertEquals(true, afterOlderPrecise.needsRecovery(secondAdmission.generation))
        assertEquals(true, afterOlderPrecise.needsFallback(secondAdmission.generation))
    }

    @Test
    fun queuedMarmotBurstKeepsOldestAndNewestGenerationOnly() {
        val queue = mutableListOf<SonarPushWork>()
        repeat(100) { index ->
            enqueueSonarPushWork(
                queue,
                work(
                    startId = index + 1,
                    type = "marmot",
                    deadline = 1_000L + index,
                    generation = (index + 1).toLong(),
                ),
            )
        }

        assertEquals(2, queue.size)
        assertEquals(listOf(1L, 100L), queue.map { it.admissionGeneration })
        assertEquals(100, queue.last().startId)
    }

    @Test
    fun timedOutNativeResultCannotCrossWipeOrAccountReplacement() {
        assertEquals(true, notificationSessionMatches(7, "account-a", 7, "account-a"))
        assertEquals(false, notificationSessionMatches(7, "account-a", 8, "account-a"))
        assertEquals(false, notificationSessionMatches(7, "account-a", 7, "account-b"))
    }

    @Test
    fun delayedWakeFromReplacedAccountCannotMatchReplacementAdmission() {
        val accountA = SonarNotificationAdmissionState().admit("account-a")
        val delayedGeneration = accountA.generation
        val accountB = accountA.admit("account-b")

        // Generations deliberately collide after owner replacement. The stable
        // non-secret owner is what prevents A's delayed worker from touching B.
        assertEquals(delayedGeneration, accountB.generation)
        assertEquals(false, accountB.accepts("account-a", delayedGeneration))
        assertEquals(true, accountB.accepts("account-b", accountB.generation))
        assertEquals(
            SonarNotificationAdmissionState(),
            accountA.clearedUnlessOwnedBy("account-b"),
        )
    }

    @Test
    fun marmotWorkNeverCoalescesAcrossAccountReplacement() {
        val queue = mutableListOf<SonarPushWork>()
        enqueueSonarPushWork(queue, work(1, "marmot", 1_000, ownerId = "account-a"))
        enqueueSonarPushWork(queue, work(2, "marmot", 900, ownerId = "account-b"))

        assertEquals(listOf("account-a", "account-b"), queue.map { it.admissionOwnerId })
    }

    @Test
    fun liveDeliveryPolicyDoesNotDependOnBackgroundPushWakePreference() {
        val backgroundPushEnabled = false

        assertEquals(false, backgroundPushEnabled)
        assertEquals(true, sonarNotificationDisplayEnabled(notificationsEnabled = true))
        assertEquals(false, sonarNotificationDisplayEnabled(notificationsEnabled = false))
    }

    private fun work(
        startId: Int,
        type: String,
        deadline: Long,
        generation: Long = 0,
        ownerId: String = "account-a",
    ) = SonarPushWork(
        startId = startId,
        type = type,
        notificationType = "",
        deadlineElapsedMs = deadline,
        admissionGeneration = generation,
        admissionOwnerId = ownerId,
    )
}
