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
import chat.bitchat.sonar.SonarNotificationKind
import chat.bitchat.sonar.SonarNotificationPrefs
import chat.bitchat.sonar.SonarNotificationRouter
import chat.bitchat.sonar.shortNpubLabel
import chat.bitchat.sonar.wallet.InvoiceRequestPayload
import chat.bitchat.sonar.wallet.JsonLite
import chat.bitchat.sonar.wallet.NotifiedPaymentIds
import chat.bitchat.sonar.wallet.PaymentActivityStore
import chat.bitchat.sonar.wallet.WalletBridge
import chat.bitchat.sonar.wallet.WalletPaymentEvent
import chat.bitchat.sonar.wallet.WalletState
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Short-lived foreground service that processes push wakeups.
 *
 * Marmot pushes (transponder): sync messages → render user-visible notification.
 * Breez pushes (NDS): stay alive until the SDK settles the incoming payment,
 * then post one "Payment received" notification (nothing settled → silent).
 */
class SonarPushProcessingService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

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
        // SHORT_SERVICE (API 34+), not DATA_SYNC: a push-triggered settlement/
        // sync wake is exactly the "short critical task" shortService exists for,
        // and — unlike dataSync — it is NOT subject to Android 15's ~6h/24h
        // cumulative dataSync cap (which was observed force-stopping a sibling
        // app on-device with ForegroundServiceStartNotAllowedException). It needs
        // only FOREGROUND_SERVICE (no type permission). onTimeout() below is the
        // required backstop for its ~3-minute ceiling.
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(FOREGROUND_ID, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SHORT_SERVICE)
            } else {
                startForeground(FOREGROUND_ID, notification)
            }
        } catch (t: Throwable) {
            // e.g. the background-start allowlist expired before we reached
            // startForeground. Nothing can run without the FGS; stop cleanly
            // rather than risk a crash loop.
            Log.w(TAG, "startForeground(shortService) refused; stopping", t)
            stopSelf()
        }
    }

    /** API 34 short-service timeout backstop → stop before the ANR. */
    override fun onTimeout(startId: Int) {
        Log.w(TAG, "shortService onTimeout(startId=$startId) — stopping")
        scope.cancel()
        stopSelf()
    }

    /** API 35 short-service timeout backstop (typed overload). */
    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.w(TAG, "shortService onTimeout(startId=$startId type=$fgsType) — stopping")
        scope.cancel()
        stopSelf()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val type = intent?.getStringExtra(EXTRA_PUSH_TYPE)
        Log.d(TAG, "Processing push type=$type")

        scope.launch {
            when (type) {
                TYPE_MARMOT -> processMarmotWakeup()
                TYPE_BREEZ -> processBreezWakeup(
                    intent?.getStringExtra(EXTRA_NOTIFICATION_TYPE) ?: "",
                    intent?.getStringExtra(EXTRA_NOTIFICATION_PAYLOAD) ?: "",
                )
                else -> Log.w(TAG, "Unknown push type: $type")
            }
            stopSelf(startId)
        }

        return START_NOT_STICKY
    }

    private suspend fun processMarmotWakeup() {
        try {
            val prefs = notificationPrefs()
            withTimeoutOrNull(MARMOT_PUSH_SYNC_TIMEOUT_MS) {
                SonarCore.start()
                SonarCore.sync()
            } ?: run {
                Log.w(TAG, "Marmot sync timed out, showing fallback")
                notifyFallback(prefs)
                return
            }

            if (!prefs.enabled) {
                Log.d(TAG, "Marmot sync complete, notifications disabled")
                return
            }

            val summaries = SonarCore.conversationSummaries()
            val unread = summaries.filter { it.unreadCount > 0 }

            if (unread.isEmpty()) {
                Log.d(TAG, "Marmot sync complete, no unread messages")
                return
            }

            for (summary in unread) {
                val kind = SonarNotificationRouter.classifyContent(
                    summary.latestContent,
                    isCallControl = { SonarCore.callParseControl(it) != null },
                )
                if (kind == SonarNotificationKind.Call) continue

                val notif = SonarNotificationRouter.build(
                    idKey = summary.groupIdHex,
                    kind = kind,
                    conversationTitle = summary.name.ifBlank { null },
                    senderName = summary.latestSenderNpub
                        .takeIf { it.isNotBlank() }
                        ?.let(::shortNpubLabel),
                    preview = summary.latestContent,
                    unreadCount = summary.unreadCount,
                    prefs = prefs,
                )
                if (notif != null) {
                    Notifier.notify(notif.id, notif.title, notif.body)
                }
            }
            Log.d(TAG, "Marmot wakeup: notified for ${unread.size} conversation(s)")
        } catch (e: Exception) {
            Log.e(TAG, "Marmot wakeup failed, showing fallback", e)
            notifyFallback(notificationPrefs())
        }
    }

    private fun notificationPrefs(): SonarNotificationPrefs =
        SonarPushPrefs.notificationPrefs(this)

    private fun notifyFallback(prefs: SonarNotificationPrefs) {
        val notif = SonarNotificationRouter.build(
            idKey = "marmot-push",
            kind = SonarNotificationKind.Message,
            unreadCount = 1,
            prefs = prefs.copy(showPreview = false),
        ) ?: return
        Notifier.notify(notif.id, notif.title, notif.body)
    }

    /**
     * A Breez offline receive is a swap the SDK claims only while connected —
     * the Android bindings ship no notification plugin (unlike iOS, whose NSE
     * extends `SDKNotificationService` and runs settlement jobs), so this
     * service is the settlement orchestrator: connect, then stay alive until an
     * incoming receive is claimed (event-first, poll fallback that accepts a
     * PENDING/claimed receive so we don't burn the whole window waiting for full
     * confirmation), then post one "Payment received" notification. Intermediate
     * wakes (swap_updated fee bumps, refunds) claim nothing and stay silent.
     */
    private suspend fun processBreezWakeup(notificationType: String, payload: String) {
        try {
            val prefs = notificationPrefs()
            if (payload.isNotBlank()) {
                // Swap id / payment hash for correlating against Boltz-side logs.
                Log.d(TAG, "Breez payload: ${payload.take(200)}")
            }
            val deadline = SystemClock.elapsedRealtime() + BREEZ_SETTLE_BUDGET_MS
            // A generous floor: covers connect() latency, swap-claim time, and
            // realistic device clock skew vs the swap server, while still
            // excluding genuinely old receives so a first-ever wake (empty
            // notified-ids ring) doesn't surface historical payments. Cross-wake
            // dedup is [NotifiedPaymentIds], not this floor.
            val wakeFloorSecs =
                System.currentTimeMillis() / 1000 - BREEZ_SETTLE_LOOKBACK_SECS
            val settled = AtomicInteger(0)

            coroutineScope {
                // Subscribe BEFORE wallet setup so a receive claimed right after
                // connect() can't slip past the collector.
                val events = launch {
                    WalletBridge.paymentEvents.collect { ev ->
                        if (ev.incoming && handleSettledReceive(ev, prefs)) {
                            settled.incrementAndGet()
                        }
                    }
                }

                if (WalletBridge.state() !is WalletState.Ready) {
                    // Account Key Durability: a push path must never mint an
                    // identity — bail silently when none exists yet.
                    val nsec = SonarCore.identityNsec()
                    if (nsec.isBlank()) {
                        Log.d(TAG, "Breez wakeup skipped: no identity")
                        events.cancel()
                        return@coroutineScope
                    }
                    withTimeoutOrNull(WALLET_SETUP_TIMEOUT_MS) {
                        WalletBridge.setupIfNeeded(nsec)
                    }
                } else if (!WalletBridge.isConnectionLive()) {
                    // Ready but the reused websocket died in Doze — reconnect
                    // rather than silently poll a dead node (empty → missed pay).
                    Log.d(TAG, "Breez wakeup: stale connection, reconnecting")
                    WalletBridge.shutdown()
                    val nsec = SonarCore.identityNsec()
                    if (nsec.isNotBlank()) {
                        withTimeoutOrNull(WALLET_SETUP_TIMEOUT_MS) {
                            WalletBridge.setupIfNeeded(nsec)
                        }
                    }
                }
                if (WalletBridge.state() !is WalletState.Ready) {
                    // Setup failed/timed out: no SDK, so nothing can settle —
                    // don't burn the budget polling a nil wallet.
                    Log.w(TAG, "Breez wakeup: wallet not ready, giving up")
                    events.cancel()
                    return@coroutineScope
                }
                WalletBridge.refreshBalance()

                // BOLT12 invoice_request: the payer is blocked until we produce
                // the invoice and POST it to the NDS reply URL (60s server
                // window) — the step iOS's NSE does via InvoiceRequestTask and
                // Android must do itself (no notification plugin in the KMP
                // bindings). Answer FIRST, then await the resulting payment.
                // (breez/notify's lnurlpay_* callback types are intentionally
                // unhandled: Sonar publishes no LNURL-pay endpoint, only BOLT12
                // offers — extend here if LNURL receive ever ships.)
                if (notificationType == NOTIF_TYPE_INVOICE_REQUEST) {
                    answerInvoiceRequest(payload, deadline)
                }

                // Await a claimed receive: the first one ends this wake (each new
                // payment gets its own push, so we don't need to drain many).
                while (settled.get() == 0 &&
                    SystemClock.elapsedRealtime() < deadline
                ) {
                    for (ev in WalletBridge.recentIncomingReceives(wakeFloorSecs)) {
                        if (handleSettledReceive(ev, prefs)) settled.incrementAndGet()
                    }
                    if (settled.get() > 0) break
                    delay(BREEZ_SETTLE_POLL_MS)
                }
                events.cancel()
            }
            if (settled.get() > 0) WalletBridge.refreshBalance()
            Log.d(TAG, "Breez wakeup done (type=$notificationType settled=${settled.get()})")
        } catch (e: Exception) {
            Log.w(TAG, "Breez wakeup failed (silent)", e)
        }
    }

    /**
     * Produce the BOLT12 invoice for an invoice_request push and POST it to
     * the NDS reply URL — the Android analog of iOS `InvoiceRequestTask`:
     * success → `{"invoice": ...}`, failure → `{"error": ...}` so the payer
     * gets a real error instead of the NDS's 60s timeout. The NDS relays the
     * body verbatim to the swap server.
     */
    private suspend fun answerInvoiceRequest(payload: String, deadlineElapsedMs: Long) {
        val req = InvoiceRequestPayload.parse(payload) ?: run {
            Log.w(TAG, "invoice_request: unparseable payload")
            return
        }
        // The reply URL is server-injected by OUR NDS; pin it there. Comparing
        // the PARSED host (https, no userinfo) rejects both plain-http and
        // `https://user@evil/` tricks — a forged push must not redirect the
        // invoice elsewhere.
        val replyHost = runCatching { URL(req.replyUrl) }.getOrNull()
            ?.takeIf { it.protocol == "https" && it.userInfo == null }
            ?.host
        if (replyHost == null ||
            !replyHost.equals(SonarPushRegistration.expectedNdsHost(), ignoreCase = true)
        ) {
            Log.w(TAG, "invoice_request: refusing reply URL (host/scheme mismatch)")
            return
        }
        // The NDS blocks its caller ~60s from the webhook; past our own wake
        // deadline the answer would land on an expired request id — don't
        // bother producing (and leaking wall-clock on) a stale invoice.
        val remainingMs = deadlineElapsedMs - SystemClock.elapsedRealtime()
        if (remainingMs < 2_000) {
            Log.w(TAG, "invoice_request: answer window already spent, skipping")
            return
        }
        val answered = withTimeoutOrNull(remainingMs) {
            val body = WalletBridge.createBolt12Invoice(req.offer, req.invoiceRequest).fold(
                onSuccess = { JsonLite.encodeObject("invoice", it) },
                onFailure = {
                    Log.w(TAG, "invoice_request: createBolt12Invoice failed", it)
                    JsonLite.encodeObject("error", it.message ?: "failed to create invoice")
                },
            )
            postReply(req.replyUrl, body)
        }
        Log.d(TAG, "invoice_request answered (posted=${answered ?: false})")
    }

    /** POST [body] as JSON to [url]; true on 2xx. Bounded timeouts — the whole
     *  answer must beat the NDS's 60s callback window. */
    private suspend fun postReply(url: String, body: String): Boolean =
        withContext(Dispatchers.IO) {
            runCatching {
                val conn = URL(url).openConnection() as HttpURLConnection
                try {
                    conn.requestMethod = "POST"
                    conn.connectTimeout = 10_000
                    conn.readTimeout = 10_000
                    conn.doOutput = true
                    conn.setRequestProperty("Content-Type", "application/json")
                    conn.outputStream.use { it.write(body.encodeToByteArray()) }
                    conn.responseCode in 200..299
                } finally {
                    conn.disconnect()
                }
            }.getOrElse {
                Log.w(TAG, "invoice_request reply POST failed", it)
                false
            }
        }

    /**
     * Notify-exactly-once gate for a settled incoming wallet payment. Returns
     * true when this call newly handled the payment (whether or not prefs let
     * the banner show — enabling notifications later must not back-notify).
     * Synchronized: the event collector and the poll loop race on the
     * persisted [NotifiedPaymentIds] read-modify-write.
     */
    @Synchronized
    private fun handleSettledReceive(
        ev: WalletPaymentEvent,
        prefs: SonarNotificationPrefs,
    ): Boolean {
        // Ledger capture (idempotent) — normally already recorded at the event
        // source; this covers poll-fallback payments the listener never saw.
        PaymentActivityStore.recordIncomingWalletPayment(ev)
        val notifiedIds = NotifiedPaymentIds(SonarCore.loadBlob(NOTIFIED_IDS_BLOB))
        if (!notifiedIds.markNotified(ev.paymentId)) return false
        SonarCore.saveBlob(NOTIFIED_IDS_BLOB, notifiedIds.encode())
        SonarNotificationRouter.buildWalletReceive(
            idKey = "wallet-${ev.paymentId}",
            sats = ev.amountSats,
            prefs = prefs,
        )?.let { Notifier.notify(it.id, it.title, it.body) }
        return true
    }

    override fun onDestroy() {
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
        const val EXTRA_NOTIFICATION_PAYLOAD = "notification_payload"
        const val TYPE_MARMOT = "marmot"
        const val TYPE_BREEZ = "breez"
        /** NDS notification_type for a BOLT12 invoice_request (breez/notify
         *  `NOTIFICATION_INVOICE_REQUEST`). */
        private const val NOTIF_TYPE_INVOICE_REQUEST = "invoice_request"

        // Marmot push-triggered background sync budget.
        // On a cold wake the core must start, connect relays, and reach EOSE
        // inside this window before we render the local notification (otherwise
        // the user gets the generic "New Sonar message" fallback). 20s was too
        // tight on real devices; 25s uses more of the wakeup window while leaving
        // headroom to render the notif. Kept in parity with iOS
        // TransportConfig.marmotPushSyncTimeoutSeconds (PR #123 / F10 of #122).
        // (Android has no Tor; if a bootstrap step is ever added, its latency
        // must also fit inside this budget.)
        private const val MARMOT_PUSH_SYNC_TIMEOUT_MS = 25_000L

        // Breez settlement budget: the SDK claims the swap only while we stay
        // alive. shortService gives ~3 min (no dataSync cap), so this is a
        // battery/latency choice, not an OS-imposed ceiling: 45s covers a cold
        // connect (~10-15s) plus a claimed receive (~18s observed on device)
        // with headroom, then we stop. Accepting a PENDING/claimed receive (see
        // recentIncomingReceives) usually ends the wake well before this.
        private const val BREEZ_SETTLE_BUDGET_MS = 45_000L
        // Outer bound on connect(); the SDK's own connect timeout is ~20s, so
        // 20s here avoids abandoning a connect the SDK would have completed.
        private const val WALLET_SETUP_TIMEOUT_MS = 20_000L
        private const val BREEZ_SETTLE_POLL_MS = 2_500L
        // Poll floor: generous enough for connect()-latency, swap-claim time and
        // realistic clock skew vs the swap server, while excluding genuinely old
        // receives so a first-ever wake (empty notified-ids ring) doesn't surface
        // history. Cross-wake dedup is [NotifiedPaymentIds], not this floor.
        private const val BREEZ_SETTLE_LOOKBACK_SECS = 600L
        /** Blob key for the persisted notified-payment-ids ring. */
        private const val NOTIFIED_IDS_BLOB = "wallet.notifiedPaymentIds"
    }
}
