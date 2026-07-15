package chat.bitchat.sonar

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class MarmotSendReconciliationTest {
    @Test
    fun reconciliationFailureAfterSuccessfulSendDoesNotReportSendFailure() = runTest {
        val reconciliationError = IllegalStateException("refresh failed")
        var sendFailures = 0
        var reportedReconciliationError: Throwable? = null

        runMarmotSendWithBestEffortReconciliation(
            send = {},
            reconcile = { throw reconciliationError },
            onSendAccepted = {},
            onSendFailure = { sendFailures += 1 },
            onReconciliationFailure = { reportedReconciliationError = it },
        )

        assertEquals(0, sendFailures)
        assertEquals(reconciliationError, reportedReconciliationError)
    }

    @Test
    fun genuineSendFailureReportsFailureAndSkipsReconciliation() = runTest {
        val sendError = IllegalStateException("publish failed")
        var reconciliationAttempts = 0
        var reportedSendError: Throwable? = null
        var reconciliationFailures = 0

        runMarmotSendWithBestEffortReconciliation(
            send = { throw sendError },
            reconcile = { reconciliationAttempts += 1 },
            onSendAccepted = {},
            onSendFailure = { reportedSendError = it },
            onReconciliationFailure = { reconciliationFailures += 1 },
        )

        assertEquals(sendError, reportedSendError)
        assertEquals(0, reconciliationAttempts)
        assertEquals(0, reconciliationFailures)
    }

    @Test
    fun successfulSendRunsReconciliationWithoutFailureCallbacks() = runTest {
        var reconciliationAttempts = 0
        var sendFailures = 0
        var reconciliationFailures = 0

        runMarmotSendWithBestEffortReconciliation(
            send = {},
            reconcile = { reconciliationAttempts += 1 },
            onSendAccepted = {},
            onSendFailure = { sendFailures += 1 },
            onReconciliationFailure = { reconciliationFailures += 1 },
        )

        assertEquals(1, reconciliationAttempts)
        assertEquals(0, sendFailures)
        assertEquals(0, reconciliationFailures)
    }

    @Test
    fun successfulSendIsAcceptedBeforeReconciliation() = runTest {
        val calls = mutableListOf<String>()

        runMarmotSendWithBestEffortReconciliation(
            send = { calls += "send" },
            reconcile = { calls += "reconcile" },
            onSendAccepted = { calls += "accepted" },
            onSendFailure = { calls += "send failure" },
            onReconciliationFailure = { calls += "reconciliation failure" },
        )

        assertEquals(listOf("send", "accepted", "reconcile"), calls)
    }

    @Test
    fun sendCancellationRemainsStructuredAndDoesNotReportFailure() = runTest {
        var sendFailures = 0
        var accepted = 0
        var reconciliationAttempts = 0

        assertFailsWith<CancellationException> {
            runMarmotSendWithBestEffortReconciliation(
                send = { throw CancellationException("cancelled before acceptance") },
                reconcile = { reconciliationAttempts += 1 },
                onSendAccepted = { accepted += 1 },
                onSendFailure = { sendFailures += 1 },
                onReconciliationFailure = {},
            )
        }

        assertEquals(0, sendFailures)
        assertEquals(0, accepted)
        assertEquals(0, reconciliationAttempts)
    }

    @Test
    fun reconciliationCancellationKeepsAcceptedStateAndRemainsStructured() = runTest {
        var accepted = 0
        var reconciliationFailures = 0

        assertFailsWith<CancellationException> {
            runMarmotSendWithBestEffortReconciliation(
                send = {},
                reconcile = { throw CancellationException("cancelled after acceptance") },
                onSendAccepted = { accepted += 1 },
                onSendFailure = {},
                onReconciliationFailure = { reconciliationFailures += 1 },
            )
        }

        assertEquals(1, accepted)
        assertEquals(0, reconciliationFailures)
    }
}
