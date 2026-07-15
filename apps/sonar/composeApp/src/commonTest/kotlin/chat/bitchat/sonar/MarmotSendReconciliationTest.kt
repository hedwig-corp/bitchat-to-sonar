package chat.bitchat.sonar

import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals

class MarmotSendReconciliationTest {
    @Test
    fun reconciliationFailureAfterSuccessfulSendDoesNotReportSendFailure() = runTest {
        val reconciliationError = IllegalStateException("refresh failed")
        var sendFailures = 0
        var reportedReconciliationError: Throwable? = null

        runMarmotSendWithBestEffortReconciliation(
            send = {},
            reconcile = { throw reconciliationError },
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
            onSendFailure = { sendFailures += 1 },
            onReconciliationFailure = { reconciliationFailures += 1 },
        )

        assertEquals(1, reconciliationAttempts)
        assertEquals(0, sendFailures)
        assertEquals(0, reconciliationFailures)
    }
}
