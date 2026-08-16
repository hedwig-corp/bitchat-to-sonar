package chat.bitchat.sonar

import chat.bitchat.sonar.push.InlineFallbackEffects
import chat.bitchat.sonar.push.InlineFallbackPlan
import chat.bitchat.sonar.push.SonarPushInlineFallback
import chat.bitchat.sonar.push.SonarPushProcessingService
import chat.bitchat.sonar.push.inlineFallbackPlan
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * #203 — when Android denies the foreground-service start
 * (`ForegroundServiceStartNotAllowedException`, backgrounded/locked device),
 * the FCM handler must fall back to bounded in-window work, and the routing
 * of that fallback must never silently drop the payer-blocking case.
 *
 * The denial itself only reproduces on-device (background + expired FGS
 * allowlist), so the routing decision is pure and pinned here.
 */
class PushInlineFallbackPlanTest {

    @Test
    fun marmotWakeFallsBackToBoundedSync() {
        assertEquals(
            InlineFallbackPlan.MarmotBoundedSync,
            inlineFallbackPlan(SonarPushProcessingService.TYPE_MARMOT, ""),
        )
    }

    @Test
    fun breezInvoiceRequestMustAnswerThePayerInline() {
        // A payer is blocked on the NDS 60s window: the denied-FGS path must
        // still answer (or error-reply), never skip.
        assertEquals(
            InlineFallbackPlan.BreezAnswerInvoiceRequest,
            inlineFallbackPlan(SonarPushProcessingService.TYPE_BREEZ, "invoice_request"),
        )
    }

    @Test
    fun otherBreezWakesStaySilent() {
        for (type in listOf("swap_updated", "payment_received", "")) {
            assertEquals(
                InlineFallbackPlan.BreezSilentSkip,
                inlineFallbackPlan(SonarPushProcessingService.TYPE_BREEZ, type),
                "notification_type=$type",
            )
        }
    }

    @Test
    fun unknownTypesDegradeToTheMarmotShape() {
        // Fail toward showing something rather than silently dropping a wake.
        assertEquals(
            InlineFallbackPlan.MarmotBoundedSync,
            inlineFallbackPlan("unknown", ""),
        )
    }

    // ── Dispatch + degrade policy over injected effects ──────────────────
    // The routing table above is only half the invariant: swapping two
    // branches in `run` used to leave every test green (the R-001 shape).

    private class RecordingEffects(
        val syncResult: Boolean = true,
        val unread: Int = 0,
        val enabled: Boolean = true,
        val answerResult: Boolean = true,
    ) : InlineFallbackEffects {
        var syncCalls = 0
        var notifyCalls = 0
        var genericCalls = 0
        var answeredPayloads = mutableListOf<String>()

        override suspend fun syncMarmot(): Boolean {
            syncCalls++
            return syncResult
        }

        override suspend fun notifyUnread(): Int {
            notifyCalls++
            return unread
        }

        override fun notifyGeneric() {
            genericCalls++
        }

        override fun notificationsEnabled() = enabled

        override suspend fun answerInvoiceRequest(payload: String): Boolean {
            answeredPayloads.add(payload)
            return answerResult
        }
    }

    @Test
    fun invoiceRequestPlanAnswersThePayerAndNeverSyncs() {
        val effects = RecordingEffects()
        SonarPushInlineFallback.run(
            InlineFallbackPlan.BreezAnswerInvoiceRequest,
            "the-payload",
            effects,
        )
        assertEquals(listOf("the-payload"), effects.answeredPayloads)
        assertEquals(0, effects.syncCalls)
        assertEquals(0, effects.genericCalls)
    }

    @Test
    fun silentSkipTouchesNothing() {
        val effects = RecordingEffects()
        SonarPushInlineFallback.run(InlineFallbackPlan.BreezSilentSkip, "x", effects)
        assertTrue(effects.answeredPayloads.isEmpty())
        assertEquals(0, effects.syncCalls)
        assertEquals(0, effects.notifyCalls)
        assertEquals(0, effects.genericCalls)
    }

    @Test
    fun marmotPlanSyncsThenNotifiesAndNeverAnswersAPayer() {
        val effects = RecordingEffects(unread = 2)
        SonarPushInlineFallback.run(InlineFallbackPlan.MarmotBoundedSync, "", effects)
        assertEquals(1, effects.syncCalls)
        assertEquals(1, effects.notifyCalls)
        // Titled notifications landed: no generic banner on top of them.
        assertEquals(0, effects.genericCalls)
        assertTrue(effects.answeredPayloads.isEmpty())
    }

    @Test
    fun genericBannerOnlyWhenNothingLandedAndSyncWasCutShort() {
        // Sync completed, nothing unread: a genuinely quiet wake stays quiet.
        val quiet = RecordingEffects(syncResult = true, unread = 0)
        SonarPushInlineFallback.run(InlineFallbackPlan.MarmotBoundedSync, "", quiet)
        assertEquals(0, quiet.genericCalls)

        // Sync cut short AND nothing unread: degrade rather than drop the wake.
        val cutShort = RecordingEffects(syncResult = false, unread = 0)
        SonarPushInlineFallback.run(InlineFallbackPlan.MarmotBoundedSync, "", cutShort)
        assertEquals(1, cutShort.genericCalls)
    }

    @Test
    fun notificationsDisabledStillSyncsButPostsNothing() {
        val effects = RecordingEffects(enabled = false, syncResult = false)
        SonarPushInlineFallback.run(InlineFallbackPlan.MarmotBoundedSync, "", effects)
        assertEquals(1, effects.syncCalls, "local storage must still catch up")
        assertEquals(0, effects.notifyCalls)
        assertEquals(0, effects.genericCalls)
    }

    @Test
    fun budgetSlicesStayInsideTheFcmWindow() {
        // The sync used to be the whole budget with the render running
        // unbounded on top of it, which exceeded the window it was justified
        // against.
        val total = SonarPushInlineFallback.SYNC_BUDGET_MS + SonarPushInlineFallback.NOTIFY_BUDGET_MS
        assertTrue(total <= 10_000, "Marmot slices ($total ms) must fit the FCM handler window")
        assertFalse(SonarPushInlineFallback.INVOICE_BUDGET_MS > 10_000)
    }
}
