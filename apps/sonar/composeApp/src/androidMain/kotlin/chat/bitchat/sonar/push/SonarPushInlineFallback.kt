package chat.bitchat.sonar.push

import android.content.Context
import android.util.Log
import chat.bitchat.sonar.SonarCore
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
 * The side effects the fallback performs, injectable so the dispatch and the
 * degrade policy are testable without an Android `Service` or a live SDK.
 */
internal interface InlineFallbackEffects {
    /** Bounded reconnect + gap-recovery fetch. Returns whether it completed. */
    suspend fun syncMarmot(): Boolean

    /** Titled notifications from local state. Returns how many were posted. */
    suspend fun notifyUnread(): Int

    /** Generic "you have a message" banner. */
    fun notifyGeneric()

    /** Whether notifications are enabled at all. */
    fun notificationsEnabled(): Boolean

    /** Produce + POST the BOLT12 answer. Returns true when a reply (invoice
     *  OR error) was actually POSTed, so the caller never double-answers. */
    suspend fun answerInvoiceRequest(payload: String): Boolean
}

/**
 * Bounded, in-window fallback for a push wake whose foreground-service start
 * Android refused (`ForegroundServiceStartNotAllowedException`: the push was
 * downgraded from high priority, or the app is in a restricted state).
 *
 * We are still inside FCM's `onMessageReceived` execution window, so instead
 * of dropping the wake — or degrading straight to a generic banner — do the
 * platform-allowed amount of real work here, hard-bounded:
 *
 * - Marmot: one budgeted sync through the SHARED single-flight
 *   ([SonarMarmotWakeSync]) so an inline wake and a service wake cannot
 *   invalidate the relay node underneath each other, then the SAME titled
 *   notification rendering the service path uses; generic banner only when
 *   nothing landed. Sync and render each get their own slice, so the total
 *   stays inside the window instead of the render running unbounded after it.
 * - Breez `invoice_request`: a payer is blocked on the NDS's 60s window. A
 *   short answer attempt beats letting them time out, and every accepted-URL
 *   failure path posts an error so the payer is unblocked either way. The
 *   whole attempt runs on an ORPHAN job: `WalletBridge.ensureLiveConnection`
 *   bounds its blocking native connect with a `coroutineScope` child, which
 *   cancellation cannot preempt — awaiting an orphan is the only bound that
 *   actually returns (the repo's "coroutineScope cannot bound a blocking
 *   UniFFI call" lesson). Expect an error reply more often than an invoice:
 *   a denied-FGS wake means a cold wallet. A fast error still beats a 60s
 *   payer timeout.
 * - Other Breez wakes (swap fee bumps, refunds): silent by design.
 *
 * Post-window work is best-effort: without a foreground service the process
 * can be frozen or killed once the handler returns, which is why the 45s
 * settle wait of the service path is deliberately not attempted here.
 */
internal object SonarPushInlineFallback {

    private const val TAG = "SonarPushFallback"

    /** Sync slice of the window. */
    const val SYNC_BUDGET_MS = 5_000L

    /** Render slice, reserved so the total stays inside the FCM window. */
    const val NOTIFY_BUDGET_MS = 3_000L

    /** Whole-answer bound for the Breez path (orphan-awaited, so it holds). */
    const val INVOICE_BUDGET_MS = 8_000L

    /** Orphan scope for blocking UniFFI/SDK calls: a timeout child cannot
     *  cancel them, so the AWAIT is bounded instead and stragglers finish
     *  harmlessly in the background. */
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    fun run(context: Context, pushType: String, notificationType: String, payload: String) {
        run(inlineFallbackPlan(pushType, notificationType), payload, realEffects(context))
    }

    /** Testable core: dispatch + degrade policy over injected effects. */
    internal fun run(plan: InlineFallbackPlan, payload: String, effects: InlineFallbackEffects) {
        when (plan) {
            InlineFallbackPlan.MarmotBoundedSync -> runBlocking { marmotBoundedSync(effects) }
            InlineFallbackPlan.BreezAnswerInvoiceRequest -> runBlocking {
                val answered = effects.answerInvoiceRequest(payload)
                Log.d(TAG, "inline invoice_request answered=$answered")
            }
            InlineFallbackPlan.BreezSilentSkip ->
                Log.d(TAG, "Breez non-invoice wake with no FGS: reconciling on next open")
        }
    }

    internal suspend fun marmotBoundedSync(effects: InlineFallbackEffects) {
        val synced = effects.syncMarmot()
        if (!effects.notificationsEnabled()) {
            Log.d(TAG, "Inline Marmot fallback done (synced=$synced), notifications disabled")
            return
        }
        // Even a cut-short sync has usually landed the pushed message locally;
        // prefer real titled notifications and degrade only when nothing is
        // unread AND the sync was cut short (same policy as the service).
        val notified = effects.notifyUnread()
        when {
            notified > 0 ->
                Log.d(TAG, "Inline Marmot fallback: notified $notified conversation(s) (synced=$synced)")
            synced ->
                Log.d(TAG, "Inline Marmot fallback: synced, nothing unread")
            else -> {
                Log.w(TAG, "Inline Marmot fallback: sync cut short with nothing unread, generic banner")
                effects.notifyGeneric()
            }
        }
    }

    private fun realEffects(context: Context) = object : InlineFallbackEffects {
        override suspend fun syncMarmot(): Boolean {
            // Shared single-flight: a service wake and this inline wake must
            // never invalidate the relay node underneath each other.
            val job = scope.async {
                runCatching { SonarMarmotWakeSync.syncForWake(scope, SYNC_BUDGET_MS) }
                    .getOrDefault(false)
            }
            return withTimeoutOrNull(SYNC_BUDGET_MS) { job.await() } == true
        }

        override suspend fun notifyUnread(): Int {
            // Bounded by an orphan await: conversationSummaries() is a blocking
            // UniFFI call, so a child timeout could not cut it short.
            val job = scope.async {
                runCatching {
                    SonarWakeNotifications.notifyUnreadConversations(
                        prefs = SonarPushPrefs.notificationPrefs(context),
                        scope = scope,
                        profileFetchBudgetMs = NOTIFY_BUDGET_MS / 2,
                    )
                }.getOrDefault(0)
            }
            return withTimeoutOrNull(NOTIFY_BUDGET_MS) { job.await() } ?: 0
        }

        override fun notifyGeneric() =
            SonarWakeNotifications.notifyFallback(SonarPushPrefs.notificationPrefs(context))

        override fun notificationsEnabled(): Boolean =
            SonarPushPrefs.notificationPrefs(context).enabled

        override suspend fun answerInvoiceRequest(payload: String): Boolean {
            val req = InvoiceRequestPayload.parse(payload) ?: run {
                Log.w(TAG, "inline invoice_request: unparseable payload")
                return false
            }
            // Same pin as the service path: the reply URL is only ever our NDS.
            if (!isAcceptableNdsReplyUrl(req.replyUrl, SonarPushRegistration.expectedNdsHost())) {
                Log.w(TAG, "inline invoice_request: refusing reply URL")
                return false
            }
            // The orphan job OWNS the reply: the request id is a one-shot slot,
            // so a bail-out error from us must never race (and overwrite) an
            // invoice the job is about to POST. Every path inside posts exactly
            // one reply; we only bound how long we WAIT for it.
            val job = scope.async {
                val nsec = runCatching { SonarCore.identityNsec() }.getOrDefault("")
                if (nsec.isBlank()) {
                    // Account Key Durability: never mint an identity here.
                    return@async postNdsReply(
                        req.replyUrl,
                        JsonLite.encodeObject("error", "wallet unavailable"),
                    )
                }
                val live = runCatching { WalletBridge.ensureLiveConnection(nsec) }
                    .getOrDefault(false)
                if (!live || WalletBridge.state() !is WalletState.Ready) {
                    return@async postNdsReply(
                        req.replyUrl,
                        JsonLite.encodeObject("error", "wallet unavailable"),
                    )
                }
                val invoice = WalletBridge.createBolt12Invoice(req.offer, req.invoiceRequest)
                val body = invoice.fold(
                    onSuccess = { JsonLite.encodeObject("invoice", it) },
                    // Generic reason on purpose: the reply is relayed verbatim
                    // to a semi-trusted swap server — don't leak SDK internals.
                    onFailure = { JsonLite.encodeObject("error", "failed to create invoice") },
                )
                postNdsReply(req.replyUrl, body)
            }
            val posted = withTimeoutOrNull(INVOICE_BUDGET_MS) { job.await() }
            if (posted == null) {
                Log.w(TAG, "inline invoice_request: still answering past our budget; leaving it to finish")
                return false
            }
            return posted
        }
    }
}
