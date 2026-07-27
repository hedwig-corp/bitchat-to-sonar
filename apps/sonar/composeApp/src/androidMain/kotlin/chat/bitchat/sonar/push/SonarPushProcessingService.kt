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
import chat.bitchat.sonar.MUTE_BLOB_KEY
import chat.bitchat.sonar.Notifier
import chat.bitchat.sonar.PROFILE_CACHE_BLOB_KEY
import chat.bitchat.sonar.RelayConnectionPolicy
import chat.bitchat.sonar.SonarConversationSummary
import chat.bitchat.sonar.SonarCore
import chat.bitchat.sonar.SonarLifecycle
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
import chat.bitchat.sonar.shortNpubLabel
import chat.bitchat.sonar.wallet.InvoiceRequestPayload
import chat.bitchat.sonar.wallet.JsonLite
import chat.bitchat.sonar.BuildConfig
import chat.bitchat.sonar.wallet.claimNotifiedPaymentId
import chat.bitchat.sonar.wallet.settleWakeOutcome
import chat.bitchat.sonar.wallet.wasPaymentNotified
import chat.bitchat.sonar.wallet.PaymentActivityStore
import chat.bitchat.sonar.wallet.WalletBridge
import chat.bitchat.sonar.wallet.WalletPaymentEvent
import chat.bitchat.sonar.wallet.WalletState
import java.net.URL
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Short-lived foreground service that processes push wakeups.
 *
 * Marmot pushes (transponder): sync messages → render user-visible notification.
 * Breez pushes (NDS): answer a BOLT12 `invoice_request` first — a payer is
 * blocked on it — then stay alive until an incoming receive arrives. A claimed
 * (PENDING) receive ends the wake, but only a COMPLETE one posts "Payment
 * received" and writes the ledger; nothing arriving stays silent.
 */
class SonarPushProcessingService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** Set only after `startForeground` actually succeeds. If the background-FGS
     *  allowlist expired before we reached `startForeground`, we must NOT run the
     *  wake work (Breez connect / invoice create / POST) — without a legal
     *  foreground service the process can be killed mid-answer or ANR. */
    @Volatile private var fgsReady = false

    /**
     * Wakes currently running on [scope].
     *
     * A per-wake `stopSelf(startId)` is wrong here: Android's contract is "stop
     * the service if [startId] is the most recent start id", NOT "release my own
     * reference". So whichever wake finishes FIRST stops the service for
     * everyone, and `onDestroy` → `scope.cancel()` kills the rest mid-flight.
     * Observed on device: a Marmot sync (later push, higher id) completed and
     * 24ms later the in-flight Breez settle wake died with
     * JobCancellationException — on the money path, that is an unanswered
     * invoice_request and a payer timeout. The 45s Breez budget makes a Marmot
     * push landing inside that window routine, not rare.
     */
    private val inFlightWakes = AtomicInteger(0)

    /** Newest delivered start id. The last wake to finish stops the service with
     *  THIS id, not its own, so a start delivered meanwhile is not discarded —
     *  `stopSelf` with a stale id is a no-op and would strand the service. */
    @Volatile private var lastStartId = 0

    /**
     * Reply URL of an invoice_request we have accepted but not yet answered.
     * Set once the URL passes the pin, cleared as soon as any reply is POSTed,
     * so [stopWakeWork] can send a bail-out error for exactly the window where
     * a payer is blocked on us.
     *
     * Single-slot on purpose, and best-effort: two overlapping invoice_request
     * wakes are last-writer-wins, so the earlier one loses its bail-out. Not
     * worth a collection — the NDS sends one request at a time per device, and
     * the fallback is the pre-existing behaviour (the payer waits out the 60s
     * window) rather than anything worse.
     */
    @Volatile private var pendingReplyUrl: String? = null

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
        fgsReady = enterForeground()
        if (!fgsReady) {
            // e.g. the background-start allowlist expired before we reached
            // startForeground. Nothing can run without the FGS; stop cleanly
            // rather than risk a crash loop.
            Log.w(TAG, "startForeground(shortService) refused; stopping")
            stopSelf()
        }
    }

    /**
     * Enter — or RE-enter — the foreground as a SHORT_SERVICE.
     *
     * SHORT_SERVICE (API 34+), not DATA_SYNC: a push-triggered settlement/sync
     * wake is exactly the "short critical task" shortService exists for, and —
     * unlike dataSync — it is NOT subject to Android 15's ~6h/24h cumulative
     * dataSync cap (observed force-stopping a sibling app on-device with
     * ForegroundServiceStartNotAllowedException). It needs only
     * FOREGROUND_SERVICE, no type permission.
     *
     * Called again per delivery from [onStartCommand]: the shortService clock
     * starts at the FIRST `startForeground()` an instance makes and does not
     * restart per delivery, so calling it again is how the ~3-minute window is
     * extended. Returns false instead of throwing so the caller can decide
     * whether that is fatal (first arm) or merely not-extended (re-arm).
     */
    private fun enterForeground(): Boolean = try {
        val notification = Notification.Builder(this, SYNC_CHANNEL)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle("Sonar")
            .setContentText("Syncing...")
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(FOREGROUND_ID, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SHORT_SERVICE)
        } else {
            startForeground(FOREGROUND_ID, notification)
        }
        true
    } catch (t: Throwable) {
        Log.w(TAG, "startForeground(shortService) refused: ${t.message}")
        false
    }

    /** API 34 short-service timeout backstop → stop before the ANR. */
    override fun onTimeout(startId: Int) {
        Log.w(TAG, "shortService onTimeout(startId=$startId) — stopping")
        stopWakeWork()
    }

    /** API 35 short-service timeout backstop (typed overload). */
    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.w(TAG, "shortService onTimeout(startId=$startId type=$fgsType) — stopping")
        stopWakeWork()
    }

    /**
     * Cancel in-flight wake work and close the gate.
     *
     * Clearing [fgsReady] is the point: [scope] is cancelled for good, but the
     * service instance outlives it until `onDestroy`. A push delivered in that
     * window would reach `onStartCommand` on this still-alive instance, pass the
     * gate, and `scope.launch { ... }` into a no-op on the cancelled
     * `SupervisorJob` — dropping the wake AND never running the `stopSelf(startId)`
     * inside the lambda. With the gate closed it takes the existing early-return
     * path instead.
     */
    private fun stopWakeWork() {
        fgsReady = false
        // A payer may be blocked on an invoice_request we accepted and are
        // about to abandon. Tell them now: a fast {"error": ...} beats the NDS
        // holding its 60s window for a reply that is never coming. Sent from
        // bailoutScope because [scope] is cancelled on the next line.
        pendingReplyUrl?.let { url ->
            pendingReplyUrl = null
            Log.w(TAG, "wake cancelled with an unanswered invoice_request; sending error reply")
            bailoutScope.launch { postNdsReply(url, JsonLite.encodeObject("error", "wake cancelled")) }
        }
        scope.cancel()
        stopSelf()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // startForeground refused in onCreate (background-FGS allowlist expired):
        // don't launch money-path work without a legal foreground service — the
        // process could be killed mid-answer. Stop cleanly; the app reconciles
        // on next open / next high-priority wake.
        if (!fgsReady) {
            Log.w(TAG, "onStartCommand: no foreground service, skipping wake work")
            stopSelf(startId)
            return START_NOT_STICKY
        }
        val type = intent?.getStringExtra(EXTRA_PUSH_TYPE)
        Log.d(TAG, "Processing push type=$type")

        // Re-arm the shortService window. Its timeout runs from the FIRST
        // startForeground() this instance made and is NOT restarted per
        // delivery, so on a reused instance a later push inherits whatever is
        // left of the original ~3 minutes: a burst of chat wakes can leave an
        // invoice_request with seconds before onTimeout cancels it mid-answer,
        // which is the payer-timeout bug this service exists to remove. A
        // high-priority FCM delivery is an exemption, so the extension is
        // available on exactly the path that needs it.
        // Best effort: a refused extension still leaves the FGS armed by
        // onCreate, so run the work rather than drop a payment wake.
        if (!enterForeground()) {
            Log.w(TAG, "shortService window not re-armed; running on the original one")
        }

        lastStartId = startId
        inFlightWakes.incrementAndGet()
        scope.launch {
            try {
                when (type) {
                    TYPE_MARMOT -> processMarmotWakeup()
                    TYPE_BREEZ -> processBreezWakeup(
                        intent?.getStringExtra(EXTRA_NOTIFICATION_TYPE) ?: "",
                        intent?.getStringExtra(EXTRA_NOTIFICATION_PAYLOAD) ?: "",
                    )
                    else -> Log.w(TAG, "Unknown push type: $type")
                }
            } finally {
                // Stop only when nothing is left running — see [inFlightWakes].
                // `finally` (not the happy path) so a cancelled or throwing wake
                // still releases its slot; stopSelf does not suspend, so it runs
                // even from a cancelled coroutine.
                if (inFlightWakes.decrementAndGet() == 0) stopSelf(lastStartId)
            }
        }

        return START_NOT_STICKY
    }

    private suspend fun processMarmotWakeup() {
        try {
            val prefs = notificationPrefs()
            val synced = syncMarmotForWake()

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

    /**
     * Single-flight relay reconnect + gap-recovery sync for a Marmot wake
     * (mirrors iOS `marmotWakeInFlight` / `marmotWakeNeedsRerun` in
     * `SonarPushProcessor`).
     *
     * Two FCM deliveries arrive as two independent coroutines. Left concurrent,
     * the second wake's [SonarCore.invalidateRelayConnection] supersedes the
     * first wake's in-flight attach and then replaces and closes its node while
     * it is inside [SonarCore.syncForce] — and syncForce swallows node failures,
     * so the first wake is recorded as synced without ever fetching its message.
     * Followers join the owner instead of starting their own reconnect, and a
     * push observed while the owner is already draining sets the rerun flag so
     * its own row is still fetched before the owner completes.
     */
    private suspend fun syncMarmotForWake(): Boolean {
        val owner = marmotWakeLock.withLock {
            // Only an in-flight owner can be joined: a leftover completed (or
            // cancelled-with-the-service) Deferred must not swallow this wake.
            // An owner that already closed its rerun gate has cleared the slot,
            // so a late delivery becomes a new owner instead of setting a flag
            // nobody will read.
            marmotWakeInFlight?.takeIf { it.isActive }?.also { marmotWakeNeedsRerun = true }
                ?: run {
                    val generation = ++marmotWakeOwnerGeneration
                    scope.async { runMarmotWakeSync(generation) }
                        .also { marmotWakeInFlight = it }
                }
        }
        return owner.await()
    }

    /** Owner body: reconnect + force the batched fetch, repeating while another
     *  push landed mid-drain. Failures surface through [Deferred.await] to every
     *  joined wake, which each fall back to the generic notification. */
    private suspend fun runMarmotWakeSync(generation: Long): Boolean {
        try {
            while (true) {
                marmotWakeLock.withLock { marmotWakeNeedsRerun = false }
                val synced = withTimeoutOrNull(MARMOT_PUSH_SYNC_TIMEOUT_MS) {
                    SonarCore.start()
                    // Doze/freeze can leave the host latch true after sockets die.
                    // Without this, connectRelays() no-ops and syncForce talks to a
                    // dead node — the killed-app path works only because a fresh
                    // process starts with relayConnected=false. A push that lands
                    // while the UI is visible reaches a healthy node, so leave it
                    // alone: rebuilding would close a node in-flight sends hold.
                    if (RelayConnectionPolicy.shouldInvalidateOnPushWake(SonarLifecycle.appVisible)) {
                        SonarCore.invalidateRelayConnection()
                    }
                    SonarCore.connectRelays()
                    // Push wake: force the batched gap-recovery fetch. A routine
                    // sync() would short-circuit while live subscriptions are marked
                    // active even though the socket was torn down while backgrounded,
                    // leaving the pushed message unfetched.
                    SonarCore.syncForce()
                } != null
                // Close the rerun gate and retire this owner in ONE locked
                // section. Checking the flag, releasing, then clearing the slot
                // leaves a window where a delivery still sees an active owner and
                // sets a flag that owner will never read — its message goes
                // unfetched while it inherits synced=true and skips the fallback
                // notification.
                val retired = marmotWakeLock.withLock {
                    if (marmotWakeNeedsRerun) {
                        false
                    } else {
                        retireWake(generation)
                        true
                    }
                }
                if (retired) return synced
            }
        } finally {
            // Must run even when the service scope is cancelled mid-wake, or the
            // stale owner would be joined by the next process-alive wake. No-op
            // once the loop retired us, so it cannot clear a newer owner.
            withContext(NonCancellable) {
                marmotWakeLock.withLock { retireWake(generation) }
            }
        }
    }

    /** Clear the owner slot iff [generation] is still the installed owner, so a
     *  retired wake's cleanup cannot evict the owner that replaced it. Caller
     *  must hold [marmotWakeLock]. */
    private fun retireWake(generation: Long) {
        if (marmotWakeOwnerGeneration != generation) return
        marmotWakeInFlight = null
        marmotWakeNeedsRerun = false
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
                // NEVER log the raw payload in release. `reply_url` is a one-shot
                // bearer capability — whoever POSTs an invoice to
                // /api/v1/response/{reqId} first decides where that payment goes
                // — and the payload also carries the payer's signing pubkey and
                // any payer_note. Logcat is app-private, but ADB, bug reports and
                // device-admin log collectors all read it, and this build has
                // isMinifyEnabled=false so there is no R8 Log stripping to lean
                // on. Release keeps only what is useful for debugging the pin.
                if (BuildConfig.DEBUG) {
                    Log.d(TAG, "Breez payload: ${payload.take(200)}")
                } else {
                    val host = InvoiceRequestPayload.parse(payload)
                        ?.let { runCatching { URL(it.replyUrl).host }.getOrNull() }
                    Log.d(TAG, "Breez payload received (replyHost=${host ?: "<none>"})")
                }
            }
            val deadline = SystemClock.elapsedRealtime() + BREEZ_SETTLE_BUDGET_MS
            // A generous floor: covers connect() latency, swap-claim time, and
            // realistic device clock skew vs the swap server, while still
            // excluding genuinely old receives so a first-ever wake (empty
            // notified-ids ring) doesn't surface historical payments. Cross-wake
            // dedup is [NotifiedPaymentIds], not this floor.
            val wakeFloorSecs =
                System.currentTimeMillis() / 1000 - BREEZ_SETTLE_LOOKBACK_SECS
            val arrivals = AtomicInteger(0)
            // Per-wake dedup, separate from the cross-wake notified ring — see
            // handleSettledReceive.
            val seenThisWake = HashSet<String>()

            coroutineScope {
                // Subscribe BEFORE wallet setup so a receive claimed right after
                // connect() can't slip past the collector.
                val events = launch {
                    WalletBridge.paymentEvents.collect { ev ->
                        if (ev.incoming &&
                            handleSettledReceive(ev, prefs, seenThisWake, liveEvent = true)
                        ) {
                            arrivals.incrementAndGet()
                        }
                    }
                }

                // Account Key Durability: a push path must never mint an
                // identity — bail silently when none exists yet.
                val nsec = SonarCore.identityNsec()
                if (nsec.isBlank()) {
                    Log.d(TAG, "Breez wakeup skipped: no identity")
                    // Should be unreachable — no identity means no wallet, no
                    // offer and no NDS registration, so no invoice_request for
                    // us can exist. Answer anyway if one somehow does: every
                    // other abandon path replies, and an unreachable branch that
                    // silently hangs a payer is exactly the asymmetry that made
                    // the original bug hard to see.
                    if (notificationType == NOTIF_TYPE_INVOICE_REQUEST) {
                        replyInvoiceRequestError(payload, "wallet unavailable")
                    }
                    events.cancel()
                    return@coroutineScope
                }
                // One atomic probe+connect+reconnect under the wallet lock —
                // handles cold-start (no SDK) and a Doze-stale reused handle,
                // and serializes overlapping wakes onto one connection.
                val live = withTimeoutOrNull(WALLET_SETUP_TIMEOUT_MS) {
                    WalletBridge.ensureLiveConnection(nsec)
                } ?: false
                if (!live || WalletBridge.state() !is WalletState.Ready) {
                    // No usable SDK — nothing can settle; don't burn the budget.
                    // But a payer blocked on an invoice_request must not be left
                    // to the NDS's 60s timeout just because our wallet is cold
                    // or flaky: that is the original bug wearing a new hat. Send
                    // a fast error instead. The pin means this can only ever be
                    // aimed at the real NDS.
                    Log.w(TAG, "Breez wakeup: wallet not ready, giving up")
                    if (notificationType == NOTIF_TYPE_INVOICE_REQUEST) {
                        replyInvoiceRequestError(payload, "wallet unavailable")
                    }
                    events.cancel()
                    return@coroutineScope
                }

                // BOLT12 invoice_request: the payer is blocked until we produce
                // the invoice and POST it to the NDS reply URL (60s server
                // window) — the step iOS's NSE does via InvoiceRequestTask and
                // Android must do itself (no notification plugin in the KMP
                // bindings). This is the ONLY work here with a hard external
                // deadline, so it runs before anything else; refreshBalance()
                // in particular is unbounded and would happily eat the window.
                // (breez/notify's lnurlpay_* callback types are intentionally
                // unhandled: Sonar publishes no LNURL-pay endpoint, only BOLT12
                // offers — extend here if LNURL receive ever ships.)
                if (notificationType == NOTIF_TYPE_INVOICE_REQUEST) {
                    answerInvoiceRequest(payload, deadline)
                }

                // Redundant on the connect path (connectLocked already did a
                // getInfo) but needed for a reused live handle. Sequenced after
                // the answer precisely because it is unbounded.
                WalletBridge.refreshBalance()

                // Await a claimed receive: the first one ends this wake (each new
                // payment gets its own push, so we don't need to drain many).
                while (arrivals.get() == 0 &&
                    SystemClock.elapsedRealtime() < deadline
                ) {
                    for (ev in WalletBridge.recentIncomingReceives(wakeFloorSecs)) {
                        if (handleSettledReceive(ev, prefs, seenThisWake, liveEvent = false)) {
                            arrivals.incrementAndGet()
                        }
                    }
                    if (arrivals.get() > 0) break
                    delay(BREEZ_SETTLE_POLL_MS)
                }
                events.cancel()
            }
            if (arrivals.get() > 0) WalletBridge.refreshBalance()
            Log.d(TAG, "Breez wakeup done (type=$notificationType arrivals=${arrivals.get()})")
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
        // The reply URL is server-injected by OUR NDS; pin it there so a forged
        // push cannot redirect a freshly signed invoice. Pure and pinned by
        // NdsReplyUrlTest — see isAcceptableNdsReplyUrl for the axes checked.
        if (!isAcceptableNdsReplyUrl(req.replyUrl, SonarPushRegistration.expectedNdsHost())) {
            Log.w(TAG, "invoice_request: refusing reply URL (scheme/host/port/path)")
            return
        }
        // The NDS blocks its caller ~60s from the webhook; past our own wake
        // deadline the answer would land on an expired request id — don't
        // bother producing (and leaking wall-clock on) a stale invoice.
        val remainingMs = deadlineElapsedMs - SystemClock.elapsedRealtime()
        if (remainingMs < 2_000) {
            Log.w(TAG, "invoice_request: answer window already spent, sending error")
            postNdsReply(req.replyUrl, JsonLite.encodeObject("error", "answer window expired"))
            return
        }
        // From here a payer is blocked on us, so a cancelled wake owes them an
        // error reply — see stopWakeWork. Cleared on every exit path below.
        pendingReplyUrl = req.replyUrl
        val answered = withTimeoutOrNull(remainingMs) {
            val invoice = WalletBridge.createBolt12Invoice(req.offer, req.invoiceRequest)
            val body = invoice.fold(
                onSuccess = { JsonLite.encodeObject("invoice", it) },
                onFailure = {
                    // Keep the detailed SDK message local; the reply is relayed
                    // verbatim to the swap server, so send a generic reason and
                    // don't leak Breez internals to a semi-trusted counterparty.
                    Log.w(TAG, "invoice_request: createBolt12Invoice failed", it)
                    JsonLite.encodeObject("error", "failed to create invoice")
                },
            )
            postNdsReply(req.replyUrl, body) to invoice.isSuccess
        }
        pendingReplyUrl = null
        if (answered == null) {
            // Our own bound tripped before the SDK produced anything. Still owe
            // the payer an answer rather than the NDS's 60s expiry.
            Log.w(TAG, "invoice_request: timed out producing the invoice, sending error")
            postNdsReply(req.replyUrl, JsonLite.encodeObject("error", "timed out"))
        }
        // `posted` is only the HTTP 2xx — BOTH an invoice and an {"error": ...}
        // reply post successfully, so log the outcome separately. Without this
        // the one line you actually grep in the field cannot tell "we answered
        // the payer" from "we politely told the payer we failed".
        Log.d(TAG, "invoice_request answered (posted=${answered?.first ?: false} " +
            "invoice=${answered?.second ?: false})")
    }

    /**
     * Tell a blocked payer we cannot answer, instead of letting the NDS's 60s
     * window expire. Same pin as the success path — a forged push can never
     * aim even an error reply anywhere but the real NDS.
     */
    private suspend fun replyInvoiceRequestError(payload: String, reason: String) {
        val req = InvoiceRequestPayload.parse(payload) ?: return
        if (!isAcceptableNdsReplyUrl(req.replyUrl, SonarPushRegistration.expectedNdsHost())) {
            Log.w(TAG, "invoice_request: refusing reply URL for error reply")
            return
        }
        val posted = postNdsReply(req.replyUrl, JsonLite.encodeObject("error", reason))
        Log.d(TAG, "invoice_request error reply sent (reason=$reason posted=$posted)")
    }

    /**
     * Handle an incoming wallet payment observed during this wake. Returns true
     * when this observation should end the settle loop — and that is a
     * path-dependent question, NOT the same one as "should we post a banner":
     *
     * - [liveEvent] (the `paymentEvents` collector): the payment is settling
     *   NOW, while we are connected — first sight ends the wake whether or not
     *   the ring already owns it (the foreground listener may have claimed a
     *   receive the user watched land; the wake must still end, just without a
     *   second banner).
     * - Poll (`recentIncomingReceives`): the feed reaches 600s back, so it
     *   returns HISTORY — a payment notified by an earlier wake would otherwise
     *   end this wake seconds after connect, before the pushed payment's lockup
     *   is even visible, and would do so again on every wake until it ages out
     *   of the floor. Only a NEWLY CLAIMED receive ends the wake here; an
     *   already-claimed one keeps the loop polling. The cost — a redundant wake
     *   (fee-bump `swap_updated`, or a push for a foreground-settled payment)
     *   burns the bounded 45s budget — is the lesser evil vs. delaying money.
     *
     * The banner itself is gated on claiming alone (not prefs), so enabling
     * notifications later must not back-notify an old payment.
     *
     * Synchronized: the event collector and the poll loop race on both
     * [seenThisWake] and the persisted ring.
     */
    @Synchronized
    private fun handleSettledReceive(
        ev: WalletPaymentEvent,
        prefs: SonarNotificationPrefs,
        seenThisWake: MutableSet<String>,
        liveEvent: Boolean,
    ): Boolean {
        // The decision itself is a pure function so it can be pinned — see
        // settleWakeOutcome / SettleWakeOutcomeTest. Keeping it inline here is
        // what let it regress once with every test still green.
        val outcome = settleWakeOutcome(
            settled = ev.settled,
            liveEvent = liveEvent,
            firstThisWake = seenThisWake.add(ev.paymentId),
            alreadyNotified = wasPaymentNotified(ev.paymentId),
        )
        if (outcome.notifies) {
            // Ledger capture (idempotent) — normally already recorded at the
            // event source; this covers poll payments the listener never saw.
            PaymentActivityStore.recordIncomingWalletPayment(ev)
            // Re-check by claiming: `alreadyNotified` above is a read, and the
            // SDK callback thread can claim between the two. The claim is the
            // authority on who owns the banner.
            if (claimNotifiedPaymentId(ev.paymentId)) {
                SonarNotificationRouter.buildWalletReceive(
                    idKey = "wallet-${ev.paymentId}",
                    sats = ev.amountSats,
                    prefs = prefs,
                )?.let { Notifier.notify(it.id, it.title, it.body) }
            }
        }
        return outcome.endsWake
    }

    override fun onDestroy() {
        // Close the gate before cancelling, same ordering as stopWakeWork: a
        // wake launched onto an already-cancelled scope never runs its body, so
        // its `finally` never releases the [inFlightWakes] slot it took.
        fgsReady = false
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

        /** Guards the single-flight wake state below. Process-wide, because
         *  overlapping FCM deliveries each get their own service start and
         *  coroutine. */
        /**
         * Scope for the bail-out error reply only.
         *
         * Deliberately process-scoped rather than per-instance: [stopWakeWork]
         * cancels the wake [scope] and then stops the service, so a reply
         * launched on either would be cancelled or die with onDestroy before
         * the POST completes — and the whole point is that the payer hears
         * something instead of waiting out the NDS's 60s window.
         */
        private val bailoutScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

        private val marmotWakeLock = Mutex()

        /** The wake currently reconnecting + draining. Later deliveries join it
         *  instead of invalidating and replacing the node underneath it. */
        private var marmotWakeInFlight: Deferred<Boolean>? = null

        /** Set when a delivery joins an owner that may already be past the
         *  drain, so the owner runs one more fetch before completing — otherwise
         *  the joining push's own message can be missed. */
        private var marmotWakeNeedsRerun = false

        /** Identifies the installed owner so a retiring wake only clears its own
         *  slot. Without it, the `finally` cleanup of a wake that already retired
         *  normally could null out the owner a later delivery installed, and two
         *  owners would reconnect concurrently again. */
        private var marmotWakeOwnerGeneration = 0L

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
        /** Path prefix breez/notify injects into every reply_url
         *  (`{NOTIFY_EXTERNAL_URL}/api/v1/response/{reqId}`). */
        private const val NDS_RESPONSE_PATH_PREFIX = "/api/v1/response/"
    }
}
