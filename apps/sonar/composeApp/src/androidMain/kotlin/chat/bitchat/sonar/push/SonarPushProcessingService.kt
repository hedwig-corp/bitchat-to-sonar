package chat.bitchat.sonar.push

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import chat.bitchat.sonar.Notifier
import chat.bitchat.sonar.SonarCore
import chat.bitchat.sonar.SonarNotificationKind
import chat.bitchat.sonar.SonarNotificationPrefs
import chat.bitchat.sonar.SonarNotificationRouter
import chat.bitchat.sonar.shortNpubLabel
import chat.bitchat.sonar.wallet.WalletBridge
import chat.bitchat.sonar.wallet.WalletState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Short-lived foreground service that processes push wakeups.
 *
 * Marmot pushes (transponder): sync messages → render user-visible notification.
 * Breez pushes (NDS): settle wallet event → NO user-visible notification.
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
                    intent?.getStringExtra(EXTRA_NOTIFICATION_TYPE) ?: ""
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
        SonarNotificationPrefs(
            enabled = prefBool("notifs", true),
            showNames = prefBool("notifNames", true),
            showPreview = prefBool("notifPreview", false),
            showPaymentAmount = true,
        )

    private fun prefBool(key: String, default: Boolean): Boolean {
        val value = getSharedPreferences("sonar", Context.MODE_PRIVATE)
            .getString("blob.pref.$key", "")
            .orEmpty()
        return if (value.isEmpty()) default else value == "1"
    }

    private fun notifyFallback(prefs: SonarNotificationPrefs) {
        val notif = SonarNotificationRouter.build(
            idKey = "marmot-push",
            kind = SonarNotificationKind.Message,
            unreadCount = 1,
            prefs = prefs.copy(showPreview = false),
        ) ?: return
        Notifier.notify(notif.id, notif.title, notif.body)
    }

    private suspend fun processBreezWakeup(notificationType: String) {
        // Silent -- no user-visible notification. The payment amount
        // notification fires later through the transponder/chat path when the
        // ⚡PAY control line arrives.
        try {
            if (WalletBridge.state() !is WalletState.Ready) {
                val nsec = SonarCore.identityNsec()
                if (nsec.isNotBlank()) {
                    withTimeoutOrNull(15_000) { WalletBridge.setupIfNeeded(nsec) }
                }
            }
            WalletBridge.refreshBalance()
            Log.d(TAG, "Breez wakeup processed (type=$notificationType, silent)")
        } catch (e: Exception) {
            Log.w(TAG, "Breez wakeup failed (silent)", e)
        }
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
    }
}
