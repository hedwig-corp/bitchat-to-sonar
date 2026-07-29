package chat.bitchat.sonar.push

import android.content.Context
import android.util.Log
import chat.bitchat.sonar.RelayConnectionPolicy
import chat.bitchat.sonar.SonarCore
import chat.bitchat.sonar.SonarLifecycle
import chat.bitchat.sonar.wallet.InvoiceRequestPayload
import chat.bitchat.sonar.wallet.JsonLite
import chat.bitchat.sonar.wallet.WalletBridge
import chat.bitchat.sonar.wallet.WalletState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull

/**
 * What a denied foreground-service start falls back to, per wake type (#203).
 *
 * Pure so the routing is pinned by `PushInlineFallbackPlanTest` — the denial
 * path itself only reproduces on a device with the app backgrounded and the
 * FGS allowlist expired, which no CI covers.
 */
internal enum class InlineFallbackPlan {
    /** Bounded local sync + titled notifications from local state. */
    MarmotBoundedSync,

    /** Answer the blocked payer's BOLT12 invoice_request within the FCM
     *  window; settle-wait is skipped (next wake/open reconciles). */
    BreezAnswerInvoiceRequest,

    /** Nothing to answer and nothing to render: reconcile on next open. */
    BreezSilentSkip,
}

internal fun inlineFallbackPlan(pushType: String, notificationType: String): InlineFallbackPlan =
    when {
        pushType == SonarPushProcessingService.TYPE_BREEZ &&
            notificationType == "invoice_request" -> InlineFallbackPlan.BreezAnswerInvoiceRequest
        pushType == SonarPushProcessingService.TYPE_BREEZ -> InlineFallbackPlan.BreezSilentSkip
        else -> InlineFallbackPlan.MarmotBoundedSync
    }

/**
 * Bounded, in-window fallback for a push wake whose foreground-service start
 * Android refused (`ForegroundServiceStartNotAllowedException`: the push was
 * downgraded from high priority, or the app is in a restricted state).
 *
 * We are still inside FCM's `onMessageReceived` execution window (~10s), so
 * instead of dropping the wake — or degrading straight to a generic banner —
 * do the platform-allowed amount of real work here, hard-bounded well under
 * the window:
 *
 * - Marmot: one bounded relay sync into local storage, then the SAME titled
 *   notification rendering the foreground-service path uses
 *   ([SonarWakeNotifications]); generic banner only when nothing landed.
 * - Breez `invoice_request`: a payer is blocked on the NDS's 60s window. A
 *   short answer attempt (connect → create invoice → POST) beats letting them
 *   time out; on any failure an error reply is posted so the payer is
 *   unblocked either way. The 45s settle-wait of the service path is
 *   deliberately NOT attempted here — no execution guarantee exists, and the
 *   next wake or app open reconciles the ledger (banner dedup via the
 *   notified-payment ring makes that safe).
 * - Other Breez wakes (swap fee bumps, refunds): silent by design.
 *
 * Runs synchronously on FCM's background thread — that is the documented way
 * to use the window; returning early would just discard the remaining budget.
 */
internal object SonarPushInlineFallback {

    private const val TAG = "SonarPushFallback"

    /** Total budget: safely inside FCM's ~10s handler window. */
    private const val INLINE_BUDGET_MS = 8_000L

    /** Wallet connect share of the budget (leaves room for invoice + POST). */
    private const val WALLET_SETUP_BUDGET_MS = 4_000L

    /** Orphan scope for blocking UniFFI calls: a timeout child cannot cancel
     *  them, so the await is bounded instead and stragglers finish harmlessly
     *  in the background (same pattern as the service's profile prefetch). */
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    fun run(context: Context, pushType: String, notificationType: String, payload: String) {
        when (inlineFallbackPlan(pushType, notificationType)) {
            InlineFallbackPlan.MarmotBoundedSync -> runBlocking { marmotBoundedSync(context) }
            InlineFallbackPlan.BreezAnswerInvoiceRequest ->
                runBlocking { answerInvoiceRequestInline(payload) }
            InlineFallbackPlan.BreezSilentSkip ->
                Log.d(TAG, "Breez non-invoice wake with no FGS: reconciling on next open")
        }
    }

    private suspend fun marmotBoundedSync(context: Context) {
        val prefs = SonarPushPrefs.notificationPrefs(context)
        val sync = scope.async {
            runCatching {
                SonarCore.start()
                // Doze/freeze can leave the host latch true after sockets die —
                // same policy as the foreground-service wake path.
                if (RelayConnectionPolicy.shouldInvalidateOnPushWake(SonarLifecycle.appVisible)) {
                    SonarCore.invalidateRelayConnection()
                }
                SonarCore.connectRelays()
                SonarCore.syncForce()
            }.isSuccess
        }
        val synced = withTimeoutOrNull(INLINE_BUDGET_MS) { sync.await() } == true
        if (!prefs.enabled) {
            Log.d(TAG, "Inline Marmot fallback done (synced=$synced), notifications disabled")
            return
        }
        // Even a cut-short sync has usually landed the pushed message locally;
        // prefer real titled notifications and degrade only when nothing is
        // unread AND the sync was cut short (same policy as the service).
        val notified = runCatching {
            SonarWakeNotifications.notifyUnreadConversations(
                prefs = prefs,
                scope = scope,
                // The sync may have consumed most of the window; keep the
                // name-resolution slice small.
                profileFetchBudgetMs = 2_000L,
            )
        }.getOrDefault(0)
        when {
            notified > 0 ->
                Log.d(TAG, "Inline Marmot fallback: notified $notified conversation(s) (synced=$synced)")
            synced ->
                Log.d(TAG, "Inline Marmot fallback: synced, nothing unread")
            else -> {
                Log.w(TAG, "Inline Marmot fallback: sync cut short with nothing unread, generic banner")
                SonarWakeNotifications.notifyFallback(prefs)
            }
        }
    }

    /**
     * Answer a BOLT12 invoice_request without a foreground service: the payer
     * is blocked on the NDS reply either way, and a fast answer (or a fast
     * error) strictly beats their 60s timeout. Every exit path that accepted
     * the pinned reply URL posts SOMETHING.
     */
    private suspend fun answerInvoiceRequestInline(payload: String) {
        val req = InvoiceRequestPayload.parse(payload) ?: run {
            Log.w(TAG, "inline invoice_request: unparseable payload")
            return
        }
        // Same pin as the service path: the reply URL is only ever our NDS.
        if (!isAcceptableNdsReplyUrl(req.replyUrl, SonarPushRegistration.expectedNdsHost())) {
            Log.w(TAG, "inline invoice_request: refusing reply URL")
            return
        }
        // Account Key Durability: a push path must never mint an identity.
        val nsec = runCatching { SonarCore.identityNsec() }.getOrDefault("")
        if (nsec.isBlank()) {
            postNdsReply(req.replyUrl, JsonLite.encodeObject("error", "wallet unavailable"))
            return
        }
        val outcome = withTimeoutOrNull(INLINE_BUDGET_MS) {
            val live = withTimeoutOrNull(WALLET_SETUP_BUDGET_MS) {
                WalletBridge.ensureLiveConnection(nsec)
            } ?: false
            if (!live || WalletBridge.state() !is WalletState.Ready) {
                postNdsReply(req.replyUrl, JsonLite.encodeObject("error", "wallet unavailable"))
                return@withTimeoutOrNull false
            }
            val invoice = WalletBridge.createBolt12Invoice(req.offer, req.invoiceRequest)
            val body = invoice.fold(
                onSuccess = { JsonLite.encodeObject("invoice", it) },
                // Generic reason on purpose: the reply is relayed verbatim to a
                // semi-trusted swap server — don't leak SDK internals.
                onFailure = { JsonLite.encodeObject("error", "failed to create invoice") },
            )
            postNdsReply(req.replyUrl, body)
            invoice.isSuccess
        }
        if (outcome == null) {
            // Our bound tripped mid-answer: still owe the payer an answer.
            postNdsReply(req.replyUrl, JsonLite.encodeObject("error", "timed out"))
        }
        Log.d(TAG, "inline invoice_request answered (invoice=${outcome ?: false})")
    }
}
