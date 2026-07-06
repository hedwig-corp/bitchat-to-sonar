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
import chat.bitchat.sonar.crypto.Bech32
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

    private val ctx: Context get() = AppContextHolder.ctx
    private fun prefs() = ctx.getSharedPreferences("sonar", Context.MODE_PRIVATE)
    private fun cleanupPrefs() = ctx.getSharedPreferences("sonar.wallet.lifecycle", Context.MODE_PRIVATE)

    private fun apiKey(): String = BuildConfig.BREEZ_API_KEY.trim()

    actual fun isAvailable(): Boolean = apiKey().isNotEmpty()

    actual fun state(): WalletState = current

    actual suspend fun setupIfNeeded(nsec: String): Unit = withContext(Dispatchers.IO) {
        lock.withLock {
            recoverPendingCleanupLocked()
            if (sdk != null) return@withContext
            val key = apiKey()
            if (key.isEmpty()) { current = WalletState.NotConfigured; return@withContext }
            val secretHex = Bech32.nsecToSecretHex(nsec)
            if (secretHex == null) { current = WalletState.Failed("no identity"); return@withContext }
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
                runCatching { withTimeoutOrNull(20_000) { work.await() } }
                    .also { if (it.getOrNull() == null) work.cancel() }
            }
            current = when {
                outcome.isFailure -> WalletState.Failed(outcome.exceptionOrNull()?.message ?: "wallet setup failed")
                outcome.getOrNull() == null -> WalletState.Failed("wallet setup timed out")
                else -> outcome.getOrThrow()!!.let { (node, bal) ->
                    sdk = node
                    balance.value = bal
                    startObservingBalance(node)
                    WalletState.Ready(bal)
                }
            }
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
        val id = p.txId ?: lightning?.paymentHash ?: p.destination ?: return null
        return WalletPaymentEvent(
            paymentId = id,
            incoming = p.paymentType == PaymentType.RECEIVE,
            amountSats = p.amountSat.toLong(),
            feesSats = p.feesSat.toLong(),
            timestampSecs = p.timestamp.toLong(),
            preimage = lightning?.preimage,
        )
    }

    /** Surface a settled payment to [paymentEvents]. */
    private fun emitPaymentEvent(p: Payment) {
        val ev = paymentEventOf(p) ?: return
        // Record to the persistent ledger AT THE SOURCE so an incoming payment
        // during a headless/background FCM wakeup (no UI collector on the
        // replay-0 flow) is still captured. Idempotent by wallet payment id.
        PaymentActivityStore.recordIncomingWalletPayment(ev)
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
            val node = sdk ?: return@withContext emptyList()
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

    /**
     * Answer a BOLT12 invoice_request: produce the signed invoice for [offer]
     * so the payer can pay it. The exact call iOS's `InvoiceRequestTask` makes
     * in the NSE (`liquidSDK.createBolt12Invoice`); on Android the push service
     * calls this headlessly and POSTs the result to the NDS reply URL itself,
     * because the KMP bindings ship no notification plugin.
     */
    suspend fun createBolt12Invoice(offer: String, invoiceRequest: String): Result<String> =
        withContext(Dispatchers.IO) {
            val node = sdk
                ?: return@withContext Result.failure(IllegalStateException("wallet not ready"))
            runCatching {
                node.createBolt12Invoice(CreateBolt12InvoiceRequest(offer, invoiceRequest)).invoice
            }
        }

    /**
     * Liveness probe for a reused connection: a wake may find `state()` Ready
     * from a prior wake whose websocket has since died in Doze. `getInfo()`
     * round-trips the SDK; false means the handle is stale and the caller
     * should `shutdown()` + `setupIfNeeded()` rather than silently poll a dead
     * node (which returns empty → "nothing arrived" → missed payment).
     */
    suspend fun isConnectionLive(): Boolean = withContext(Dispatchers.IO) {
        val node = sdk ?: return@withContext false
        runCatching { node.getInfo() }.isSuccess
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
            val node = sdk ?: return@withContext SendResult(false)
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
