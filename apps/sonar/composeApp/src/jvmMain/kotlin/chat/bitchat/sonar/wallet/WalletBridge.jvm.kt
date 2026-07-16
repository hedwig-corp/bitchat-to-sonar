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
import chat.bitchat.sonar.PanicWipeIntent
import chat.bitchat.sonar.crypto.Bech32
import java.io.File
import chat.bitchat.sonar.durablyRetireJvmDirectory
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
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
    private val operationGate = Mutex()
    private val setupGate = Mutex()
    private val cleanupGate = Mutex()
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
    /** Listener-driven native refreshes are serialized off the SDK callback. */
    private val refreshGate = Mutex()
    private data class RefreshRequest(val node: BindingLiquidSdk, val epoch: Int)
    private val refreshRequests = Channel<RefreshRequest>(Channel.CONFLATED)
    private data class SetupResult(val node: BindingLiquidSdk, val balanceSats: Long)
    private class SetupAttempt(
        val epoch: Int,
        val work: Deferred<SetupResult>,
    ) {
        val quiesced = CompletableDeferred<Unit>()
    }
    @Volatile private var setupAttempt: SetupAttempt? = null

    init {
        walletScope.launch {
            for (request in refreshRequests) {
                operationGate.withLock {
                    refreshGate.withLock {
                        if (walletGenerationActive(request.node, request.epoch)) {
                            refreshBalanceFor(request.node, request.epoch)
                        }
                    }
                }
            }
        }
    }

    private val apiKey: String by lazy {
        runCatching {
            javaClass.getResourceAsStream("/breez_api_key.txt")?.bufferedReader()?.use { it.readText() }
        }.getOrNull().orEmpty().trim()
    }

    actual fun isAvailable(): Boolean = apiKey.isNotEmpty()

    actual fun state(): WalletState = current

    actual suspend fun setupIfNeeded(nsec: String): Unit = withContext(Dispatchers.IO) {
        setupGate.withLock {
            if (cleanupPending()) {
                check(wipeLocalData()) { "pending wallet cleanup could not be completed" }
            }
            val key = apiKey
            val secretHex = Bech32.nsecToSecretHex(nsec)
            val attempt = operationGate.withLock {
                lock.withLock {
                    if (PanicWipeIntent.isPending() || cleanupPending()) {
                        current = WalletState.NotConfigured
                        return@withLock null
                    }
                    if (sdk != null || setupAttempt != null) return@withLock null
                    if (key.isEmpty()) {
                        current = WalletState.NotConfigured
                        return@withLock null
                    }
                    if (secretHex == null) {
                        current = WalletState.Failed("no identity")
                        return@withLock null
                    }
                    current = WalletState.SettingUp
                    val epoch = walletEpoch
                    val work = walletScope.async(Dispatchers.IO) {
                        val seed = WalletSeed.breezSeed(WalletSeed.hexToBytes(secretHex))
                        val config = defaultConfig(LiquidNetwork.MAINNET, key).apply {
                            val dir = DesktopEnv.file("sonar-wallet/mainnet").apply { mkdirs() }
                            workingDir = dir.absolutePath
                        }
                        val node = connect(ConnectRequest(config, null, null, seed.map { it.toUByte() }))
                        SetupResult(node, node.getInfo().walletInfo.balanceSat.toLong())
                    }
                    SetupAttempt(epoch, work).also { setupAttempt = it }
                }
            } ?: return@withLock

            val outcome = runCatching {
                withTimeoutOrNull(20_000) { runCatching { attempt.work.await() } }
            }.getOrNull()
            if (outcome == null) {
                lock.withLock {
                    if (setupAttempt === attempt && walletEpoch == attempt.epoch) {
                        current = WalletState.Failed("wallet setup timed out")
                    }
                }
                walletScope.launch { finishTimedOutSetup(attempt) }
                return@withLock
            }

            val result = outcome.getOrNull()
            operationGate.withLock {
                var disconnect: BindingLiquidSdk? = null
                lock.withLock {
                    if (setupAttempt === attempt) setupAttempt = null
                    when {
                        result == null -> current = WalletState.Failed(
                            outcome.exceptionOrNull()?.message ?: "wallet setup failed",
                        )
                        walletEpoch != attempt.epoch || PanicWipeIntent.isPending() || cleanupPending() || sdk != null -> {
                            disconnect = result.node
                            if (sdk == null) current = WalletState.NotConfigured
                        }
                        else -> {
                            sdk = result.node
                            balance.value = result.balanceSats
                            startObservingBalance(result.node)
                            current = WalletState.Ready(result.balanceSats)
                        }
                    }
                }
                disconnect?.let { runCatching { it.disconnect() } }
                attempt.quiesced.complete(Unit)
            }
        }
    }

    private suspend fun finishTimedOutSetup(attempt: SetupAttempt) {
        val result = runCatching { attempt.work.await() }.getOrNull()
        operationGate.withLock {
            result?.node?.let { runCatching { it.disconnect() } }
            lock.withLock { if (setupAttempt === attempt) setupAttempt = null }
            attempt.quiesced.complete(Unit)
        }
    }

    actual suspend fun refreshBalance(): Long = withContext(Dispatchers.IO) {
        operationGate.withLock {
            val node = sdk ?: return@withLock 0L
            refreshBalanceFor(node, walletEpoch)
        }
    }

    private fun refreshBalanceFor(node: BindingLiquidSdk, epoch: Int): Long {
        if (!walletGenerationActive(node, epoch)) return 0L
        try {
            val bal = node.getInfo().walletInfo.balanceSat.toLong()
            // Drop the writes if shutdown/re-setup won the race while the
            // blocking getInfo() ran — never resurrect a torn-down wallet.
            if (walletGenerationActive(node, epoch)) {
                current = WalletState.Ready(bal)
                balance.value = bal
                return bal
            }
            return 0L
        } catch (_: Throwable) {
            return if (walletGenerationActive(node, epoch)) {
                (current as? WalletState.Ready)?.balanceSats ?: 0L
            } else {
                0L
            }
        }
    }

    private fun walletGenerationActive(node: BindingLiquidSdk, epoch: Int): Boolean =
        acceptsWalletCallback(
            listenerEpoch = epoch,
            currentEpoch = walletEpoch,
            ownsSdkNode = sdk === node,
            panicWipePending = PanicWipeIntent.isPending() || cleanupPending(),
        )

    /**
     * iOS parity (`WalletBridgeService.startObservingBalance()`): the Breez
     * event listener drives a background `getInfo()` refresh on payment/sync
     * events, so [balanceFlow] stays live without the UI ever polling. The
     * callback arrives on an SDK thread — never block it; hop to [walletScope].
     */
    private fun startObservingBalance(node: BindingLiquidSdk) {
        val listenerEpoch = walletEpoch
        balanceListenerId = runCatching {
            node.addEventListener(object : EventListener {
                override fun onEvent(e: SdkEvent) {
                    walletScope.launch {
                        var shouldRefresh = false
                        lock.withLock {
                            if (!walletGenerationActive(node, listenerEpoch)) return@withLock
                            when (e) {
                                is SdkEvent.PaymentSucceeded -> {
                                    emitPaymentEvent(e.details)
                                    shouldRefresh = true
                                }
                                is SdkEvent.Synced,
                                is SdkEvent.DataSynced,
                                is SdkEvent.PaymentWaitingConfirmation,
                                is SdkEvent.PaymentPending,
                                is SdkEvent.PaymentRefunded,
                                is SdkEvent.PaymentFailed -> shouldRefresh = true
                                else -> Unit
                            }
                        }
                        if (shouldRefresh) requestBalanceRefresh(node, listenerEpoch)
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

    /** A single conflated worker serializes native `getInfo()` calls. Every
     * request revalidates its SDK node/account generation before execution. */
    private fun requestBalanceRefresh(node: BindingLiquidSdk, epoch: Int) {
        refreshRequests.trySend(RefreshRequest(node, epoch))
    }

    actual suspend fun createOffer(): String = withContext(Dispatchers.IO) {
        operationGate.withLock {
            receiveOffer ?: lock.withLock {
                if (PanicWipeIntent.isPending() || cleanupPending()) error("wallet wipe pending")
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
    }

    actual suspend fun send(destination: String, amountSats: Long, note: String): SendResult =
        withContext(Dispatchers.IO) {
            operationGate.withLock {
                val node = sdk ?: return@withLock SendResult(false)
                val epoch = walletEpoch
                if (amountSats < 0 || !walletGenerationActive(node, epoch)) return@withLock SendResult(false)
                try {
                    val amount: PayAmount? =
                        if (amountSats > 0) PayAmount.Bitcoin(amountSats.toULong()) else null
                    val prepared = node.prepareSendPayment(PrepareSendRequest(destination.trim(), amount))
                    if (!walletGenerationActive(node, epoch)) return@withLock SendResult(false)
                    val resp = node.sendPayment(SendPaymentRequest(prepared, null, note.ifBlank { null }))
                    val payment = resp.payment
                    val lightning = payment.details as? PaymentDetails.Lightning
                    refreshBalanceFor(node, epoch)
                    SendResult(
                        ok = true,
                        preimage = lightning?.preimage,
                        paymentId = payment.txId ?: lightning?.paymentHash ?: payment.destination,
                        feesSats = payment.feesSat.toLong(),
                        settledAtSecs = payment.timestamp.toLong(),
                    )
                } catch (_: Throwable) { SendResult(false) }
            }
        }

    actual suspend fun fetchRates(): List<ExchangeRate> = withContext(Dispatchers.IO) {
        operationGate.withLock {
            val node = sdk ?: return@withLock emptyList()
            try {
                val list = node.fetchFiatRates().map { ExchangeRate(it.coin.uppercase(), it.value) }
                rates = list.associateBy { it.currency }
                list
            } catch (_: Throwable) { rates.values.toList() }
        }
    }

    actual fun cachedRate(currency: FiatCurrency): ExchangeRate? = rates[currency.code]

    actual fun hasLiveRate(): Boolean = Money.isLiveRate(rates[currency().code])

    actual fun showFiat(): Boolean = DesktopEnv.getBoolean("wallet.showFiat", false)
    actual fun setShowFiat(value: Boolean) { DesktopEnv.putBoolean("wallet.showFiat", value) }

    actual fun currency(): FiatCurrency = FiatCurrency.of(DesktopEnv.getString("wallet.currency", "USD"))
    actual fun setCurrency(value: FiatCurrency) { DesktopEnv.putString("wallet.currency", value.code) }

    actual suspend fun registerWebhook(url: String): Unit = withContext(Dispatchers.IO) {
        operationGate.withLock {
            sdk?.takeIf { !PanicWipeIntent.isPending() && !cleanupPending() }?.registerWebhook(url)
        }
    }

    actual suspend fun unregisterWebhook(): Unit = withContext(Dispatchers.IO) {
        operationGate.withLock { sdk?.unregisterWebhook() }
    }

    actual suspend fun shutdown(): Unit = withContext(Dispatchers.IO) {
        operationGate.withLock {
            val (node, listener) = lock.withLock {
                walletEpoch += 1
                val detached = sdk
                val listener = balanceListenerId
                balanceListenerId = null
                sdk = null
                current = WalletState.NotConfigured
                balance.value = 0L
                rates = emptyMap()
                receiveOffer = null
                detached to listener
            }
            listener?.let { id -> runCatching { node?.removeEventListener(id) } }
            val disconnectFailure = runCatching { node?.disconnect() }.exceptionOrNull()
            if (disconnectFailure != null) {
                current = WalletState.Failed("wallet node did not disconnect cleanly")
                throw IllegalStateException("wallet node did not disconnect cleanly", disconnectFailure)
            }
        }
    }

    actual suspend fun wipeLocalStorage() {
        check(wipeLocalData()) { "wallet storage could not be removed" }
    }

    actual suspend fun wipeLocalData(): Boolean = cleanupGate.withLock {
        val markerCommitted = withContext(Dispatchers.IO) {
            operationGate.withLock {
                runCatching { markCleanupPendingLocked(); true }.getOrDefault(false)
            }
        }
        if (!markerCommitted) return@withLock false
        if (runCatching { shutdown() }.isFailure) return@withLock false
        val attempt = setupAttempt
        if (attempt != null && withTimeoutOrNull(5_000) {
                attempt.quiesced.await(); true
            } != true
        ) return@withLock false
        val retired = withContext(Dispatchers.IO) {
            operationGate.withLock {
                if (setupAttempt != null) return@withLock false
                durablyRetireJvmDirectory(
                    DesktopEnv.file("sonar-wallet"),
                    ".sonar-wallet-wipe-",
                )
            }
        }
        if (!retired) return@withLock false
        withContext(Dispatchers.IO) {
            operationGate.withLock {
                runCatching { completeCleanupLocked(); true }.getOrDefault(false)
            }
        }
    }

    private fun cleanupMarker(): File = DesktopEnv.file(CLEANUP_MARKER_NAME)

    private fun cleanupPending(): Boolean = cleanupMarker().exists()

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
}
