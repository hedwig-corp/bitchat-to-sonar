package chat.bitchat.sonar.wallet

import breez_sdk_liquid.BindingLiquidSdk
import breez_sdk_liquid.ConnectRequest
import breez_sdk_liquid.EventListener
import breez_sdk_liquid.LiquidNetwork
import breez_sdk_liquid.PayAmount
import breez_sdk_liquid.Payment
import breez_sdk_liquid.PaymentMethod
import breez_sdk_liquid.PaymentType
import breez_sdk_liquid.PrepareReceiveRequest
import breez_sdk_liquid.PrepareSendRequest
import breez_sdk_liquid.ReceivePaymentRequest
import breez_sdk_liquid.PaymentDetails
import breez_sdk_liquid.SdkEvent
import breez_sdk_liquid.SendPaymentRequest
import breez_sdk_liquid.connect
import breez_sdk_liquid.defaultConfig
import chat.bitchat.sonar.DesktopEnv
import chat.bitchat.sonar.crypto.Bech32
import java.io.File
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

/**
 * Desktop (JVM) `actual`: the SAME on-device Breez SDK Liquid wallet as Android,
 * via the KMP package's `jvm` variant (a UniFFI/JNA binding) loading the host
 * `libbreez_sdk_liquid_bindings.dylib` off the classpath. Mainnet. The seed is
 * derived deterministically from the Nostr identity via [WalletSeed] (HKDF) and
 * connected with the same raw seed bytes as Android and iOS, so the desktop
 * reconstructs the SAME wallet for the same identity (no key export/import step:
 * same nsec ⇒ same wallet).
 *
 * The API key is read from the gitignored generated resource `/breez_api_key.txt`
 * (build.gradle's `generateBreezKeyResource`), the desktop twin of Android's
 * BuildConfig field. With no key the wallet reports NotConfigured and the ⚡PAY UI
 * degrades exactly like a keyless build.
 */
actual object WalletBridge {

    private const val CLEANUP_MARKER_NAME = "wallet-cleanup.pending"

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

    private val apiKey: String by lazy {
        runCatching {
            javaClass.getResourceAsStream("/breez_api_key.txt")?.bufferedReader()?.use { it.readText() }
        }.getOrNull().orEmpty().trim()
    }

    actual fun isAvailable(): Boolean = apiKey.isNotEmpty()

    actual fun state(): WalletState = current

    actual suspend fun setupIfNeeded(nsec: String): Unit = withContext(Dispatchers.IO) {
        lock.withLock {
            recoverPendingCleanupLocked()
            if (sdk != null) return@withContext
            val key = apiKey
            if (key.isEmpty()) { current = WalletState.NotConfigured; return@withContext }
            val secretHex = Bech32.nsecToSecretHex(nsec)
            if (secretHex == null) { current = WalletState.Failed("no identity"); return@withContext }
            current = WalletState.SettingUp
            // Breez connect()/getInfo() are blocking native calls — a plain
            // withTimeoutOrNull can't preempt them (cancellation is cooperative).
            // Run them in a child coroutine and bound the await: on timeout the UI
            // gets Failed instead of hanging on SettingUp forever (the abandoned
            // call finishes on its IO thread but its result is discarded).
            val outcome = coroutineScope {
                val work = async(Dispatchers.IO) {
                    val seed = WalletSeed.breezSeed(WalletSeed.hexToBytes(secretHex))
                    val config = defaultConfig(LiquidNetwork.MAINNET, key).apply {
                        val dir = DesktopEnv.file("sonar-wallet/mainnet").apply { mkdirs() }
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

    /** Surface a settled payment to [paymentEvents]. A stable wallet payment id
     *  keeps `walletIncoming` recording idempotent across event replays (iOS
     *  `SonarWallet.map`: txId ?? destination); with nothing stable we skip the
     *  event rather than mint a random id that could duplicate ledger rows. */
    private fun emitPaymentEvent(p: Payment) {
        val lightning = p.details as? PaymentDetails.Lightning
        val id = p.txId ?: lightning?.paymentHash ?: p.destination ?: return
        val ev = WalletPaymentEvent(
            paymentId = id,
            incoming = p.paymentType == PaymentType.RECEIVE,
            amountSats = p.amountSat.toLong(),
            feesSats = p.feesSat.toLong(),
            timestampSecs = p.timestamp.toLong(),
            preimage = lightning?.preimage,
        )
        // Record at the source (headless-safe, idempotent) — see the android actual.
        PaymentActivityStore.recordIncomingWalletPayment(ev)
        payments.tryEmit(ev)
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

    actual fun showFiat(): Boolean = DesktopEnv.getBoolean("wallet.showFiat", false)
    actual fun setShowFiat(value: Boolean) { DesktopEnv.putBoolean("wallet.showFiat", value) }

    actual fun currency(): FiatCurrency = FiatCurrency.of(DesktopEnv.getString("wallet.currency", "USD"))
    actual fun setCurrency(value: FiatCurrency) { DesktopEnv.putString("wallet.currency", value.code) }

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

    private fun cleanupMarker(): File = DesktopEnv.file(CLEANUP_MARKER_NAME)

    /** Complete an interrupted destructive wipe before any seed can be opened. */
    private fun recoverPendingCleanupLocked() {
        if (!cleanupMarker().exists()) return
        disconnectLocked()
        deleteStorageLocked()
        completeCleanupLocked()
    }

    private fun markCleanupPendingLocked() {
        val marker = cleanupMarker()
        marker.parentFile?.mkdirs()
        check(marker.exists() || marker.createNewFile()) {
            "wallet cleanup marker could not be persisted"
        }
    }

    private fun completeCleanupLocked() {
        val marker = cleanupMarker()
        check(!marker.exists() || marker.delete()) {
            "wallet cleanup marker could not be cleared"
        }
    }

    private fun disconnectLocked() {
        walletEpoch += 1
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
        val root = DesktopEnv.file("sonar-wallet")
        if (root.exists() && (!root.deleteRecursively() || root.exists())) {
            throw IllegalStateException("wallet storage could not be removed")
        }
    }
}
