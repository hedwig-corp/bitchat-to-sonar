package chat.bitchat.sonar.wallet

import android.content.Context
import breez_sdk_liquid.BindingLiquidSdk
import breez_sdk_liquid.ConnectRequest
import breez_sdk_liquid.CreateBolt12InvoiceRequest
import breez_sdk_liquid.EventListener
import breez_sdk_liquid.LiquidNetwork
import breez_sdk_liquid.ListPaymentsRequest
import breez_sdk_liquid.PayAmount
import breez_sdk_liquid.Payment
import breez_sdk_liquid.PaymentMethod
import breez_sdk_liquid.PaymentState
import breez_sdk_liquid.PaymentType
import breez_sdk_liquid.PrepareReceiveRequest
import breez_sdk_liquid.PrepareSendRequest
import breez_sdk_liquid.ReceivePaymentRequest
import breez_sdk_liquid.PaymentDetails
import breez_sdk_liquid.SdkEvent
import breez_sdk_liquid.SendPaymentRequest
import breez_sdk_liquid.connect
import breez_sdk_liquid.defaultConfig
import chat.bitchat.sonar.AppContextHolder
import chat.bitchat.sonar.BuildConfig
import chat.bitchat.sonar.SonarLifecycle
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File

/**
 * Android `actual`: on-device Breez SDK Liquid wallet. Mainnet. Seed derived
 * deterministically from the Nostr identity via [WalletSeed] (HKDF), connected
 * with the same raw seed bytes used by iOS so an imported nsec restores the same
 * wallet across both platforms. API key from the gitignored BuildConfig field.
 */
actual object WalletBridge {

    private const val CLEANUP_PENDING_KEY = "cleanup.pending"

    private val lock = Mutex()
    @Volatile private var sdk: BindingLiquidSdk? = null
    @Volatile private var current: WalletState = WalletState.NotConfigured
    @Volatile private var rates: Map<String, ExchangeRate> = emptyMap()
    @Volatile private var receiveOffer: String? = null

    /** Background home for listener-triggered balance refreshes — never the UI. */
    private val walletScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val balance = MutableStateFlow(0L)
    actual val balanceFlow: StateFlow<Long> get() = balance
    /** Buffered so the SDK callback thread can `tryEmit` without ever blocking. */
    private val payments = MutableSharedFlow<WalletPaymentEvent>(extraBufferCapacity = 16)
    actual val paymentEvents: SharedFlow<WalletPaymentEvent> get() = payments
    @Volatile private var balanceListenerId: String? = null
    /** Bumped in [shutdown] (inside [lock]); [refreshBalance] drops its writes
     *  if the epoch moved while `getInfo()` ran, so a listener-triggered
     *  refresh can never resurrect a torn-down wallet's balance. */
    @Volatile private var walletEpoch = 0
    /** One refresh in flight, at most one trailing — conflates event bursts. */
    private val refreshGate = Mutex()
    @Volatile private var refreshPending = false

    /** Upper bound on the [ensureLiveConnection] liveness probe so a hung
     *  native `getInfo()` can't hold [lock] indefinitely. Public because the
     *  push service derives its own outer bound from it — see
     *  `SonarPushProcessingService.WALLET_SETUP_TIMEOUT_MS`. */
    const val CONNECTION_PROBE_TIMEOUT_MS = 10_000L

    /** Backstop on the [createBolt12Invoice] native call. The push service's own
     *  answer-window bound is usually tighter; this only catches a wedged SDK. */
    private const val CREATE_INVOICE_TIMEOUT_MS = 20_000L

    /**
     * Bound on the blocking `connect()` in [connectLocked]. Named rather than
     * inline so the relationship to the caller's bound is checkable: the worst
     * case through [ensureLiveConnection] is [CONNECTION_PROBE_TIMEOUT_MS] +
     * this, and `SonarPushProcessingService.WALLET_SETUP_TIMEOUT_MS` must be at
     * least that sum or our own outer bound abandons a connect the SDK would
     * have completed.
     */
    const val CONNECT_TIMEOUT_MS = 20_000L

    private val ctx: Context get() = AppContextHolder.ctx
    private fun prefs() = ctx.getSharedPreferences("sonar", Context.MODE_PRIVATE)
    private fun cleanupPrefs() = ctx.getSharedPreferences("sonar.wallet.lifecycle", Context.MODE_PRIVATE)

    private fun apiKey(): String = BuildConfig.BREEZ_API_KEY.trim()

    actual fun isAvailable(): Boolean = apiKey().isNotEmpty()

    actual fun state(): WalletState = current

    actual suspend fun setupIfNeeded(walletSecretHex: String): Unit = withContext(Dispatchers.IO) {
        lock.withLock {
            recoverPendingCleanupLocked()
            if (sdk != null) return@withContext
            connectLocked(walletSecretHex)
        }
    }

    /**
     * Connect + store the SDK. **Assumes [lock] is held and [sdk] is null.**
     * Factored out of [setupIfNeeded] so [ensureLiveConnection] can reuse it
     * inside the same lock acquisition (kotlinx `Mutex` is non-reentrant).
     */
    private suspend fun connectLocked(walletSecretHex: String) {
        val key = apiKey()
        if (key.isEmpty()) { current = WalletState.NotConfigured; return }
        val secretHex = walletSecretHex.takeIf { it.matches(Regex("^[0-9a-fA-F]{64}$")) }
        if (secretHex == null) { current = WalletState.Failed("no identity"); return }
        current = WalletState.SettingUp
        // The Breez connect()/getInfo() are blocking native calls — a plain
        // withTimeoutOrNull can't preempt them (cancellation is cooperative).
        // Run them in a child coroutine and bound the await: on timeout the UI
        // gets Failed instead of hanging on SettingUp forever (the abandoned
        // call finishes on its IO thread but its result is discarded).
        val outcome = coroutineScope {
            val work = async(Dispatchers.IO) {
                val seed = WalletSeed.breezSeed(WalletSeed.hexToBytes(secretHex))
                val config = defaultConfig(LiquidNetwork.MAINNET, key).apply {
                    val dir = File(ctx.filesDir, "sonar-wallet/mainnet").apply { mkdirs() }
                    workingDir = dir.absolutePath
                }
                var node: BindingLiquidSdk? = null
                var handedOff = false
                try {
                    val connected = connect(ConnectRequest(config, null, null, seed.map { it.toUByte() }))
                    node = connected
                    currentCoroutineContext().ensureActive()
                    val balanceSats = connected.getInfo().walletInfo.balanceSat.toLong()
                    currentCoroutineContext().ensureActive()
                    handedOff = true
                    connected to balanceSats
                } finally {
                    // Timeout/cancellation is cooperative only after the native
                    // call returns. Never leak that late node or let it retain a
                    // database handle that a subsequent account restore deletes.
                    if (!handedOff) runCatching { node?.disconnect() }
                }
            }
            runCatching { withTimeoutOrNull(CONNECT_TIMEOUT_MS) { work.await() } }
                .also { if (it.getOrNull() == null) work.cancel() }
        }
        current = when {
            // Zero the balance on failure: a reconnect via ensureLiveConnection
            // may have disconnected a prior node, and only the success branch
            // below writes balance — without this, balanceFlow would keep
            // emitting the dead wallet's last balance alongside Failed state.
            outcome.isFailure -> {
                balance.value = 0L
                WalletState.Failed(outcome.exceptionOrNull()?.message ?: "wallet setup failed")
            }
            outcome.getOrNull() == null -> {
                balance.value = 0L
                WalletState.Failed("wallet setup timed out")
            }
            else -> outcome.getOrThrow()!!.let { (node, bal) ->
                sdk = node
                balance.value = bal
                startObservingBalance(node)
                WalletState.Ready(bal)
            }
        }
    }

    /**
     * Bring the wallet to a live, connected state for a headless wake, atomically
     * under [lock]: connect if there is no SDK, or probe a reused handle and
     * reconnect it if its websocket died in Doze. Returns true when [sdk] is
     * usable afterward.
     *
     * Replaces the caller-side `isConnectionLive() → shutdown() → setupIfNeeded()`
     * dance, which was check-then-act across three separate lock acquisitions —
     * two near-simultaneous Breez wakes could interleave it and tear down each
     * other's freshly-built node. Doing the whole probe+reconnect in one lock
     * acquisition serializes overlapping wakes onto a single connection.
     */
    suspend fun ensureLiveConnection(walletSecretHex: String): Boolean = withContext(Dispatchers.IO) {
        lock.withLock {
            // Same guard setupIfNeeded runs, for the same reason: an interrupted
            // wipeLocalStorage() must finish before ANY seed is opened. Without
            // it a headless wake reached connectLocked directly and could open
            // the half-deleted working directory with the replacement identity's
            // seed.
            recoverPendingCleanupLocked()
            val existing = sdk
            // Mirror of RelayConnectionPolicy.shouldInvalidateOnPushWake: a push
            // landing while the UI is up reaches a node the user may have an
            // in-flight send on, and the probe can time out simply because that
            // node is busy or the radio just thawed. Tearing it down then tells
            // the user their payment failed while its swap state is ambiguous.
            // A visible app is already driving its own connection health, so
            // trust the existing handle and skip probe+reconnect entirely.
            if (existing != null && SonarLifecycle.appVisible) return@withLock true
            if (existing != null) {
                // Bound the probe: getInfo() is a blocking native call, and a
                // half-dead websocket could hang it for the SDK's internal
                // timeout while we hold `lock`. It runs on walletScope, NOT as a
                // child of this coroutine — `coroutineScope` awaits its children,
                // so a child would hold `lock` for the full native call anyway
                // and the timeout would buy nothing (cancelling a blocking UniFFI
                // call is cooperative, i.e. a no-op here). Awaiting an orphan is
                // what actually releases `lock` on time; the abandoned probe
                // finishes and its result is discarded.
                val probe = walletScope.async { runCatching { existing.getInfo() }.isSuccess }
                val liveProbe = withTimeoutOrNull(CONNECTION_PROBE_TIMEOUT_MS) { probe.await() }
                    ?: false.also { probe.cancel() }
                if (liveProbe) return@withLock true
                // Stale/hung handle — disconnect it inline (can't call shutdown();
                // it re-locks). Bump the epoch so any in-flight refreshBalance
                // write is dropped, and detach the listener before disconnect.
                walletEpoch += 1
                balanceListenerId?.let { id -> runCatching { existing.removeEventListener(id) } }
                balanceListenerId = null
                runCatching { existing.disconnect() }
                sdk = null
            }
            connectLocked(walletSecretHex)
            sdk != null
        }
    }

    actual suspend fun refreshBalance(): Long = withContext(Dispatchers.IO) {
        val node = sdk ?: return@withContext 0L
        val epoch = walletEpoch
        try {
            val bal = node.getInfo().walletInfo.balanceSat.toLong()
            // Drop the writes if shutdown/re-setup won the race while the
            // blocking getInfo() ran — never resurrect a torn-down wallet.
            if (epoch == walletEpoch && sdk === node) {
                current = WalletState.Ready(bal)
                balance.value = bal
            }
            bal
        } catch (t: Throwable) { (current as? WalletState.Ready)?.balanceSats ?: 0L }
    }

    /**
     * iOS parity (`WalletBridgeService.startObservingBalance()`): the Breez
     * event listener drives a background `getInfo()` refresh on payment/sync
     * events, so [balanceFlow] stays live without the UI ever polling. The
     * callback arrives on an SDK thread — never block it; hop to [walletScope].
     */
    private fun startObservingBalance(node: BindingLiquidSdk) {
        balanceListenerId = runCatching {
            node.addEventListener(object : EventListener {
                override fun onEvent(e: SdkEvent) {
                    when (e) {
                        is SdkEvent.PaymentSucceeded -> {
                            emitPaymentEvent(e.details)
                            requestBalanceRefresh()
                        }
                        is SdkEvent.Synced,
                        is SdkEvent.DataSynced,
                        is SdkEvent.PaymentWaitingConfirmation,
                        is SdkEvent.PaymentPending,
                        is SdkEvent.PaymentRefunded,
                        is SdkEvent.PaymentFailed -> requestBalanceRefresh()
                        else -> Unit
                    }
                }
            })
        }.getOrNull()
    }

    /** Map an SDK [Payment] to the app event. A stable wallet payment id keeps
     *  `walletIncoming` recording idempotent across event replays (iOS
     *  `SonarWallet.map`: txId ?? destination); with nothing stable we skip the
     *  payment rather than mint a random id that could duplicate ledger rows. */
    private fun paymentEventOf(p: Payment): WalletPaymentEvent? {
        val lightning = p.details as? PaymentDetails.Lightning
        // Prefer the STABLE Lightning id (`paymentHash`) first: a Lightning
        // receive is PENDING with a null `txId` when the poll path accepts it,
        // then COMPLETE with a `txId` set — so keying on `txId` first flips the
        // id across states and double-ledgers / double-notifies the same
        // payment. `paymentHash` is constant across the receive's lifecycle.
        // Chain (Liquid) receives have no Lightning details, so they fall back
        // to `txId`; `destination` remains the last-resort both-null fallback.
        val id = lightning?.paymentHash ?: p.txId ?: p.destination ?: return null
        return WalletPaymentEvent(
            paymentId = id,
            incoming = p.paymentType == PaymentType.RECEIVE,
            amountSats = p.amountSat.toLong(),
            feesSats = p.feesSat.toLong(),
            timestampSecs = p.timestamp.toLong(),
            preimage = lightning?.preimage,
            // Only COMPLETE is money that has actually arrived. recentIncoming-
            // Receives also returns PENDING so a wake can stop waiting once the
            // claim is in flight; that state must not notify or write `Paid`.
            settled = p.status == PaymentState.COMPLETE,
        )
    }

    /** Surface a settled payment to [paymentEvents]. */
    private fun emitPaymentEvent(p: Payment) {
        val ev = paymentEventOf(p) ?: return
        // Record to the persistent ledger AT THE SOURCE so an incoming payment
        // during a headless/background FCM wakeup (no UI collector on the
        // replay-0 flow) is still captured. Idempotent by wallet payment id.
        PaymentActivityStore.recordIncomingWalletPayment(ev)
        // A receive that settles while the UI is up has already been seen by the
        // user, so claim the notify slot now. Otherwise the next Breez wake
        // within BREEZ_SETTLE_LOOKBACK_SECS polls it back out of
        // recentIncomingReceives, finds it unclaimed, and posts a stale
        // "Payment received" banner for a payment the user watched land.
        // A headless wake has appVisible=false, so this never steals the claim
        // from the push service.
        // `settled` guard matters even though PaymentSucceeded should always be
        // COMPLETE: claiming for a payment that has not actually arrived would
        // suppress the real banner when it does.
        if (ev.incoming && ev.settled && SonarLifecycle.appVisible) {
            claimNotifiedPaymentId(ev.paymentId)
        }
        payments.tryEmit(ev)
    }

    /**
     * Headless-wake support: incoming receives at/after [sinceSecs], newest
     * first. The push service polls this to detect a receive that the event
     * listener missed — one that landed during `connect()`, before
     * [startObservingBalance] attached the listener, which would otherwise
     * never reach [paymentEvents].
     *
     * Includes BOTH `COMPLETE` and `PENDING`: a BOLT12/swap receive sits in
     * `PENDING` (lockup seen, claim in flight) for most of the wake — the funds
     * are already arriving — so waiting only for `COMPLETE` would burn the whole
     * budget before the OS foreground-service window closes. Treating a claimed
     * receive as wake-ending lets the SDK finish the confirm in the background.
     * `sortAscending = false` guarantees the just-arrived payment is in the
     * returned page even with many historical receives past the floor.
     * Failures (and a torn-down wallet) surface as an empty list: the wake path
     * treats "can't know" the same as "nothing arrived".
     */
    suspend fun recentIncomingReceives(sinceSecs: Long): List<WalletPaymentEvent> =
        withContext(Dispatchers.IO) {
            // Under [lock] so a concurrent shutdown()/ensureLiveConnection() can't
            // disconnect the handle mid-`listPayments` (a native call on a freed
            // BindingLiquidSdk could abort). The wake calls this sequentially
            // after ensureLiveConnection releases the lock, so no reentrancy.
            lock.withLock {
                val node = sdk ?: return@withLock emptyList()
                runCatching {
                    node.listPayments(
                        ListPaymentsRequest(
                            filters = listOf(PaymentType.RECEIVE),
                            states = listOf(PaymentState.COMPLETE, PaymentState.PENDING),
                            fromTimestamp = sinceSecs,
                            sortAscending = false,
                            limit = 20u,
                        )
                    )
                }.getOrDefault(emptyList()).mapNotNull(::paymentEventOf)
            }
        }

    /**
     * Answer a BOLT12 invoice_request: produce the signed invoice for [offer]
     * so the payer can pay it. The exact call iOS's `InvoiceRequestTask` makes
     * in the NSE (`liquidSDK.createBolt12Invoice`); on Android the push service
     * calls this headlessly and POSTs the result to the NDS reply URL itself,
     * because the KMP bindings ship no notification plugin.
     *
     * [lock] is held while we WAIT on the call, so a concurrent shutdown or
     * reconnect cannot swap the handle out between reading `sdk` and using it.
     * It deliberately does NOT cover the whole native call: on timeout we
     * release the lock and abandon the work, so an orphaned call can still be
     * in flight against `node` while [ensureLiveConnection] disconnects it.
     * That is an errored call, not a use-after-free — `disconnect()` on the Rust
     * side is a graceful shutdown-signal plus task-join, never a free.
     *
     * The native call runs on [walletScope], NOT as a child of this coroutine.
     * The caller wraps this in `withTimeoutOrNull`, and a blocking UniFFI call
     * cannot be preempted by cancellation — a child would make the timeout wait
     * for the call anyway AND keep [lock] held while it did, so the wake's next
     * [recentIncomingReceives] would block behind it. Awaiting an orphan makes
     * the await genuinely cancellable and releases [lock] on time; the abandoned
     * call finishes harmlessly and its result is discarded. (Same reasoning as
     * `prefetchSenderProfiles` in the push service.)
     */
    suspend fun createBolt12Invoice(offer: String, invoiceRequest: String): Result<String> =
        withContext(Dispatchers.IO) {
            lock.withLock {
                val node = sdk
                    ?: return@withLock Result.failure(IllegalStateException("wallet not ready"))
                val work = walletScope.async {
                    runCatching {
                        node.createBolt12Invoice(
                            CreateBolt12InvoiceRequest(offer, invoiceRequest)
                        ).invoice
                    }
                }
                withTimeoutOrNull(CREATE_INVOICE_TIMEOUT_MS) { work.await() }
                    ?: run {
                        work.cancel()
                        Result.failure(IllegalStateException("createBolt12Invoice timed out"))
                    }
            }
        }

    /** Conflates SDK event bursts (initial sync, payment storms) into at most
     *  one in-flight `getInfo()` plus one trailing refresh, instead of one
     *  concurrent refresh per event. */
    private fun requestBalanceRefresh() {
        walletScope.launch {
            if (!refreshGate.tryLock()) { refreshPending = true; return@launch }
            try {
                do {
                    refreshPending = false
                    refreshBalance()
                } while (refreshPending)
            } finally { refreshGate.unlock() }
        }
    }

    actual suspend fun createOffer(): String = withContext(Dispatchers.IO) {
        receiveOffer ?: lock.withLock {
            receiveOffer ?: run {
                val node = sdk ?: error("wallet not ready")
                // Amountless reusable BOLT12 offer. Keep it stable across descriptor
                // refreshes so peers do not race a rotated receive path.
                val prepared = node.prepareReceivePayment(
                    PrepareReceiveRequest(PaymentMethod.BOLT12_OFFER, null)
                )
                node.receivePayment(ReceivePaymentRequest(prepared, "Sonar", null, null))
                    .destination
                    .also { receiveOffer = it }
            }
        }
    }

    actual suspend fun send(destination: String, amountSats: Long, note: String): SendResult =
        withContext(Dispatchers.IO) {
            // Capture the handle under [lock] so a concurrent Breez wake cannot
            // swap it between this read and the calls below. The lock is NOT
            // held for the whole send: a send is multi-second network work, and
            // holding it would block a concurrent wake's invoice_request answer
            // — trading a send hazard for a payer timeout. The real protection
            // against a mid-send teardown is the appVisible guard in
            // [ensureLiveConnection]: a user-initiated send implies a visible
            // UI, and that path no longer probes or reconnects at all.
            val node = lock.withLock { sdk } ?: return@withContext SendResult(false)
            if (amountSats < 0) return@withContext SendResult(false)
            try {
                val amount: PayAmount? =
                    if (amountSats > 0) PayAmount.Bitcoin(amountSats.toULong()) else null
                val prepared = node.prepareSendPayment(PrepareSendRequest(destination.trim(), amount))
                val resp = node.sendPayment(SendPaymentRequest(prepared, null, note.ifBlank { null }))
                val payment = resp.payment
                val lightning = payment.details as? PaymentDetails.Lightning
                refreshBalance()
                SendResult(
                    ok = true,
                    preimage = lightning?.preimage,
                    paymentId = payment.txId ?: lightning?.paymentHash ?: payment.destination,
                    feesSats = payment.feesSat.toLong(),
                    settledAtSecs = payment.timestamp.toLong(),
                )
            } catch (t: Throwable) { SendResult(false) }
        }

    actual suspend fun fetchRates(): List<ExchangeRate> = withContext(Dispatchers.IO) {
        val node = sdk ?: return@withContext emptyList()
        try {
            val list = node.fetchFiatRates().map { ExchangeRate(it.coin.uppercase(), it.value) }
            rates = list.associateBy { it.currency }
            list
        } catch (t: Throwable) { rates.values.toList() }
    }

    actual fun cachedRate(currency: FiatCurrency): ExchangeRate? = rates[currency.code]

    actual fun hasLiveRate(): Boolean = Money.isLiveRate(rates[currency().code])

    actual fun showFiat(): Boolean = prefs().getBoolean("wallet.showFiat", false)
    actual fun setShowFiat(value: Boolean) { prefs().edit().putBoolean("wallet.showFiat", value).apply() }

    actual fun currency(): FiatCurrency = FiatCurrency.of(prefs().getString("wallet.currency", "USD"))
    actual fun setCurrency(value: FiatCurrency) { prefs().edit().putString("wallet.currency", value.code).apply() }

    actual suspend fun registerWebhook(url: String): Unit = withContext(Dispatchers.IO) {
        sdk?.registerWebhook(url)
    }

    actual suspend fun unregisterWebhook(): Unit = withContext(Dispatchers.IO) {
        sdk?.unregisterWebhook()
    }

    actual suspend fun shutdown(): Unit = withContext(Dispatchers.IO) {
        lock.withLock {
            disconnectLocked()
        }
    }

    actual suspend fun wipeLocalStorage(): Unit = withContext(Dispatchers.IO) {
        lock.withLock {
            markCleanupPendingLocked()
            disconnectLocked()
            deleteStorageLocked()
            completeCleanupLocked()
        }
    }

    /** Complete an interrupted destructive wipe before any seed can be opened. */
    private fun recoverPendingCleanupLocked() {
        if (!cleanupPrefs().getBoolean(CLEANUP_PENDING_KEY, false)) return
        disconnectLocked()
        deleteStorageLocked()
        completeCleanupLocked()
    }

    private fun markCleanupPendingLocked() {
        check(cleanupPrefs().edit().putBoolean(CLEANUP_PENDING_KEY, true).commit()) {
            "wallet cleanup marker could not be persisted"
        }
    }

    private fun completeCleanupLocked() {
        check(cleanupPrefs().edit().remove(CLEANUP_PENDING_KEY).commit()) {
            "wallet cleanup marker could not be cleared"
        }
    }

    private fun disconnectLocked() {
        walletEpoch += 1 // invalidate in-flight refreshBalance() writes
        val node = sdk
        balanceListenerId?.let { id -> runCatching { node?.removeEventListener(id) } }
        balanceListenerId = null
        val disconnectFailure = runCatching { node?.disconnect() }.exceptionOrNull()
        if (disconnectFailure != null) {
            current = WalletState.Failed("wallet node did not disconnect cleanly")
            throw IllegalStateException("wallet node did not disconnect cleanly", disconnectFailure)
        }
        sdk = null
        current = WalletState.NotConfigured
        balance.value = 0L
        rates = emptyMap()
        receiveOffer = null
    }

    private fun deleteStorageLocked() {
        val root = File(ctx.filesDir, "sonar-wallet")
        if (root.exists() && (!root.deleteRecursively() || root.exists())) {
            throw IllegalStateException("wallet storage could not be removed")
        }
    }
}
