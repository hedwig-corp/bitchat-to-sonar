package chat.bitchat.sonar.push

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import chat.bitchat.sonar.MUTE_BLOB_KEY
import chat.bitchat.sonar.Notifier
import chat.bitchat.sonar.PROFILE_CACHE_BLOB_KEY
import chat.bitchat.sonar.SonarConversationSummary
import chat.bitchat.sonar.SonarCore
import chat.bitchat.sonar.SonarNotificationKind
import chat.bitchat.sonar.SonarNotificationPrefs
import chat.bitchat.sonar.SonarNotificationRouter
import chat.bitchat.sonar.SonarNotificationSound
import chat.bitchat.sonar.SonarProfile
import chat.bitchat.sonar.canonicalProfileKey
import chat.bitchat.sonar.decodeMuteMap
import chat.bitchat.sonar.decodeProfileCache
import chat.bitchat.sonar.isMutedAt
import chat.bitchat.sonar.resolvePushSenderName
import chat.bitchat.sonar.wallet.WalletBridge
import chat.bitchat.sonar.wallet.WalletState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
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
            val synced = withTimeoutOrNull(MARMOT_PUSH_SYNC_TIMEOUT_MS) {
                SonarCore.start()
                SonarCore.connectRelays()
                // Push wake: force the batched gap-recovery fetch. A routine
                // sync() would short-circuit while live subscriptions are marked
                // active even though the socket was torn down while backgrounded,
                // leaving the pushed message unfetched.
                SonarCore.syncForce()
            } != null

            if (!prefs.enabled) {
                Log.d(TAG, "Marmot sync done (synced=$synced), notifications disabled")
                return
            }

            // Even when syncForce overran its budget, the partial drain has
            // usually already written the pushed message into local storage
            // (relays EOSE well inside the window; the tail is engine work).
            // So always try to render real titled notifications from local
            // state, and only degrade to the generic fallback when nothing
            // unread actually landed AND the sync was cut short.
            val notified = notifyUnreadConversations(prefs)

            when {
                notified > 0 ->
                    Log.d(TAG, "Marmot wakeup: notified for $notified conversation(s) (synced=$synced)")
                synced ->
                    Log.d(TAG, "Marmot sync complete, no unread messages")
                else -> {
                    Log.w(TAG, "Marmot sync timed out with nothing unread, showing fallback")
                    notifyFallback(prefs)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Marmot wakeup failed, showing fallback", e)
            notifyFallback(notificationPrefs())
        }
    }

    /** Render titled notifications for every unread conversation from local
     *  storage. Returns how many conversations were notified. */
    private suspend fun notifyUnreadConversations(prefs: SonarNotificationPrefs): Int {
        val summaries = SonarCore.conversationSummaries()
        val unread = summaries.filter { it.unreadCount > 0 }
        if (unread.isEmpty()) return 0

        // The drain runs while the UI may be dead, so resolve nicknames the
        // same way the foreground path does: persisted kind-0 cache first,
        // then a bounded relay fetch (relays are already connected here).
        // Never title a notification with the raw npub when a name exists.
        // Skip the network entirely when names are hidden -- the router
        // discards senderName in that case, so the fetches would be wasted.
        val cachedProfiles = decodeProfileCache(SonarCore.loadBlob(PROFILE_CACHE_BLOB_KEY))
        val fetchedProfiles =
            if (prefs.showNames) prefetchSenderProfiles(unread, cachedProfiles)
            else emptyMap()

        // Per-chat mute is honored on the killed-app drain too: rows and unread
        // counts still accrued in local storage — only the banner is skipped.
        // muteChat persists the whole folded-id set, so a direct group-id
        // lookup is sufficient here.
        val mutes = decodeMuteMap(SonarCore.loadBlob(MUTE_BLOB_KEY))
        val nowSecs = System.currentTimeMillis() / 1000

        var notified = 0
        for (summary in unread) {
            if (isMutedAt(mutes[summary.groupIdHex], nowSecs)) continue
            val kind = SonarNotificationRouter.classifyContent(
                summary.latestContent,
                isCallControl = { SonarCore.callParseControl(it) != null },
            )
            if (kind == SonarNotificationKind.Call) continue

            val notif = SonarNotificationRouter.build(
                idKey = summary.groupIdHex,
                kind = kind,
                conversationTitle = summary.name.ifBlank { null },
                senderName = if (!prefs.showNames) null else summary.latestSenderNpub
                    .takeIf { it.isNotBlank() }
                    ?.let { npub ->
                        // Everything is prefetched above under one budget, so
                        // the fetch lambda is a pure map read (no network).
                        resolvePushSenderName(npub, cachedProfiles) { missing ->
                            fetchedProfiles[canonicalProfileKey(missing)]
                        }
                    },
                preview = summary.latestContent,
                unreadCount = summary.unreadCount,
                prefs = prefs,
            )
            if (notif != null) {
                Notifier.notify(
                    id = notif.id,
                    title = notif.title,
                    body = notif.body,
                    // A trill rings its distinct bell on background drains too.
                    sound = if (kind == SonarNotificationKind.Trill) {
                        SonarNotificationSound.Trill
                    } else {
                        SonarNotificationSound.Default
                    },
                    conversationId = summary.groupIdHex,
                )
                notified++
            }
        }
        return notified
    }

    /**
     * Resolve every uncached sender's kind-0 profile for this wakeup under ONE
     * total budget, keyed by [canonicalProfileKey].
     *
     * Fetches run in parallel and, crucially, are launched on the service's own
     * [scope] rather than as children of the timeout block: [SonarCore.fetchProfile]
     * hops to `Dispatchers.IO` and makes a blocking UniFFI call (with its own
     * ~10s core-internal timeout), so a `withTimeoutOrNull` wrapped directly
     * around it could not actually cancel the blocking child and would wait the
     * full core timeout anyway. By awaiting orphaned [scope] jobs inside the
     * budget, the await is genuinely cancellable -- when the budget expires we
     * fall back to the npub label immediately while the stragglers finish
     * harmlessly in the background. A single budget also bounds total wall time
     * regardless of how many distinct uncached senders are unread (otherwise it
     * would grow as senderCount x timeout, delaying later notifications and
     * stopSelf).
     */
    private suspend fun prefetchSenderProfiles(
        unread: List<SonarConversationSummary>,
        cachedProfiles: Map<String, SonarProfile>,
    ): Map<String, SonarProfile?> {
        // canonicalKey -> npub, de-duplicated and skipping cache hits.
        val missing = LinkedHashMap<String, String>()
        for (summary in unread) {
            val npub = summary.latestSenderNpub.takeIf { it.isNotBlank() } ?: continue
            val key = canonicalProfileKey(npub)
            if (cachedProfiles[key]?.bestName != null) continue
            missing.putIfAbsent(key, npub)
        }
        if (missing.isEmpty()) return emptyMap()

        val jobs = missing.map { (key, npub) ->
            scope.async { key to runCatching { SonarCore.fetchProfile(npub) }.getOrNull() }
        }
        val resolved = HashMap<String, SonarProfile?>()
        withTimeoutOrNull(PROFILE_FETCH_BUDGET_MS) {
            jobs.forEach { job ->
                val (key, profile) = job.await()
                resolved[key] = profile
            }
        }
        return resolved
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

        // Total kind-0 lookup budget for the WHOLE wakeup (not per sender) when
        // the persisted profile cache misses. All uncached senders are fetched
        // in parallel under this single budget after the sync above, so the
        // relay pool is already connected; whatever has not resolved when it
        // expires falls back to the npub label.
        private const val PROFILE_FETCH_BUDGET_MS = 5_000L
    }
}
