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
import chat.bitchat.sonar.wallet.NotifiedPaymentIds
import chat.bitchat.sonar.wallet.PaymentActivityStore
import chat.bitchat.sonar.wallet.WalletBridge
import chat.bitchat.sonar.wallet.WalletPaymentEvent
import chat.bitchat.sonar.wallet.WalletState
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
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
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(FOREGROUND_ID, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(FOREGROUND_ID, notification)
        }
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
     * service is the settlement orchestrator: stay alive until the payment
     * reaches COMPLETE (event-first, poll fallback), then post one "Payment
     * received" notification. Intermediate wakes (swap_updated fee bumps,
     * refunds) settle nothing inside the budget and stay silent.
     */
    private suspend fun processBreezWakeup(notificationType: String, payload: String) {
        try {
            val prefs = notificationPrefs()
            if (payload.isNotBlank()) {
                // Swap id / payment hash for correlating against Boltz-side logs.
                Log.d(TAG, "Breez payload: ${payload.take(200)}")
            }
            val deadline = SystemClock.elapsedRealtime() + BREEZ_SETTLE_BUDGET_MS
            // The poll fallback only exists for the seconds-wide race where a
            // payment settles during connect(), before the event listener
            // attaches. A tight floor keeps it from re-surfacing older receives
            // the user already watched arrive in a foreground session.
            val wakeFloorSecs =
                System.currentTimeMillis() / 1000 - BREEZ_SETTLE_LOOKBACK_SECS
            val settled = AtomicInteger(0)

            coroutineScope {
                // Subscribe BEFORE wallet setup so a payment settling right
                // after connect() can't slip past the collector.
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
                }
                if (WalletBridge.state() !is WalletState.Ready) {
                    // Setup failed/timed out: no SDK, so nothing can settle —
                    // don't burn the budget polling a nil wallet.
                    Log.w(TAG, "Breez wakeup: wallet not ready, giving up")
                    events.cancel()
                    return@coroutineScope
                }
                WalletBridge.refreshBalance()

                // Await settlement: each new payment sends its own push, so the
                // first settled receive ends this wake.
                while (settled.get() == 0 &&
                    SystemClock.elapsedRealtime() < deadline
                ) {
                    for (ev in WalletBridge.recentSettledReceives(wakeFloorSecs)) {
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
        // alive; 30s keeps the whole wake inside the FCM high-priority window
        // while giving Boltz round-trips room on slow networks. Setup keeps its
        // own 15s sub-budget so a hung connect() still leaves settle time.
        private const val BREEZ_SETTLE_BUDGET_MS = 30_000L
        private const val WALLET_SETUP_TIMEOUT_MS = 15_000L
        private const val BREEZ_SETTLE_POLL_MS = 2_500L
        // Poll floor: wide enough for the connect()-race and modest clock skew,
        // tight enough not to re-surface receives from an earlier session.
        private const val BREEZ_SETTLE_LOOKBACK_SECS = 120L
        /** Blob key for the persisted notified-payment-ids ring. */
        private const val NOTIFIED_IDS_BLOB = "wallet.notifiedPaymentIds"
    }
}
