package chat.bitchat.sonar

import chat.bitchat.sonar.push.InlineFallbackPlan
import chat.bitchat.sonar.push.SonarPushProcessingService
import chat.bitchat.sonar.push.inlineFallbackPlan
import kotlin.test.Test
import kotlin.test.assertEquals

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
}
