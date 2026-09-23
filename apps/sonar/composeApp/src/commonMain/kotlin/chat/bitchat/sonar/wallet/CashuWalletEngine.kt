package chat.bitchat.sonar.wallet

import chat.bitchat.sonar.ConcurrencyLock
import chat.bitchat.sonar.sonarLog
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
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
 * Sonar's Cashu wallet, host side: lifecycle, caches and the send pipeline
 * around one [CashuNative] per account. [WalletBridge] owns the production
 * instance; tests build their own with a fake native.
 *
 * Threading contract (Signal-Comparable Performance Rule): every [CashuNative]
 * call runs on [io]. Public suspend functions hop there themselves, and the
 * few non-suspend entry points only launch onto [scope]. Nothing here ever
 * blocks the caller's dispatcher — which, for the app, is the main thread.
 *
 * Money rules this class enforces:
 *  - A `Pending` send is reported as pending, never as failed, and is never
 *    re-sent: its outcome arrives as a [WalletPaymentEvent] with the same id.
 *  - Affordability is checked against the mint's REAL fee reserve before
 *    `send`; a shortfall is the typed [SendErrorKind.InsufficientFunds].
 *  - The wallet is not disconnected while a send is in flight.
 */
class CashuWalletEngine(
    private val openNative: (nsec: String, mintUrl: String, workingDir: String) -> CashuNative,
    private val storageRoot: () -> String,
    private val prefs: WalletPrefs,
    private val files: WalletFileOps,
    private val io: CoroutineDispatcher = Dispatchers.IO,
    private val mintUrl: String = CASHU_MINT_URL,
    private val retryDelaysMs: List<Long> = DEFAULT_RETRY_DELAYS_MS,
) {
    private val scope = CoroutineScope(SupervisorJob() + io)

    /** Serializes setup / release / wipe (the native handle swap). */
    private val lifecycle = Mutex()

    /** Serializes native connect()/disconnect() so a background disconnect
     *  waits out a connect already inside the mint round-trip. */
    private val connectOps = Mutex()

    /** Guards [sendsInFlight], [connectJob], [disconnectWhenIdle]. */
    private val counters = ConcurrencyLock()

    @Volatile private var native: CashuNative? = null
    @Volatile private var accountId: String? = null

    /** Bumped on every native swap; late writes from an older native are dropped. */
    @Volatile private var epoch = 0L

    /** Foreground intent. The app starts foregrounded. */
    @Volatile private var wantOnline = true
    private var sendsInFlight = 0
    private var disconnectWhenIdle = false
    private var connectJob: Job? = null

    /** One balance refresh in flight, at most one trailing (event bursts). */
    private val refreshGate = Mutex()
    @Volatile private var refreshPending = false

    private val _state = MutableStateFlow<WalletState>(WalletState.NotConfigured)
    val state: StateFlow<WalletState> get() = _state

    private val _balanceSats = MutableStateFlow(0L)
    /** Confirmed (spendable) sats: the cached value until `balance()` answers. */
    val balanceSats: StateFlow<Long> get() = _balanceSats

    private val _balance = MutableStateFlow<CashuBalance?>(null)
    /** Full breakdown from the last live `balance()`; null until one answered. */
    val balance: StateFlow<CashuBalance?> get() = _balance

    private val _offer = MutableStateFlow<String?>(null)
    /** THE published receive offer for this account, or null while unknown. */
    val offer: StateFlow<String?> get() = _offer

    private val _online = MutableStateFlow(false)
    /** True while connected to the mint. False drives "mint offline — retrying". */
    val online: StateFlow<Boolean> get() = _online

    /** Buffered: the wallet thread `tryEmit`s and never blocks. */
    private val _events = MutableSharedFlow<WalletPaymentEvent>(extraBufferCapacity = 64)
    val paymentEvents: SharedFlow<WalletPaymentEvent> get() = _events

    fun currentAccountId(): String? = accountId

    /** A native wallet exists for the signed-in account (sends may be attempted). */
    fun isOpen(): Boolean = native != null

    /**
     * Construct the wallet for [nsec] and publish what is known locally:
     * the cached balance and the offer (answered from disk once it exists).
     * LOCAL ONLY; the mint connect starts in the background and retries with
     * backoff. Returns once the local state is published. Idempotent per account.
     */
    suspend fun setup(nsec: String) {
        if (nsec.isBlank()) return
        val id = cashuAccountId(nsec)
        val opened = withContext(io) {
            lifecycle.withLock {
                if (native != null && accountId == id) return@withLock false
                native?.let { releaseLocked(it) }
                finishInterruptedWipe()
                accountId = id
                loadCachedBalance(id)?.let {
                    _balanceSats.value = it
                    _state.value = WalletState.Ready(it)
                } ?: run { _state.value = WalletState.SettingUp }
                val dir = cashuWorkingDir(storageRoot(), id)
                val created = runCatching { openNative(nsec, mintUrl, dir) }
                val n = created.getOrElse { e ->
                    sonarLog(TAG, "cashu wallet construct failed: ${e.message}")
                    _state.value = WalletState.Failed(e.message ?: "wallet unavailable")
                    return@withLock false
                }
                epoch += 1
                val myEpoch = epoch
                n.setListener { event -> onNativeEvent(n, myEpoch, event) }
                native = n
                true
            }
        }
        if (!opened) return
        refreshOffer()
        if (wantOnline) startConnectLoop()
    }

    /** App came to the foreground: connect (with retry) and reconcile. */
    fun onForeground() {
        wantOnline = true
        val n = native ?: return
        scope.launch {
            if (n.isConnected()) {
                syncAndRefresh(n)
            } else {
                startConnectLoop()
            }
        }
    }

    /**
     * App went to the background: disconnect — but never under a send in
     * flight; that disconnect is deferred until the last send returns.
     */
    fun onBackground() {
        wantOnline = false
        counters.withLock { connectJob?.cancel(); connectJob = null }
        val n = native ?: return
        scope.launch { disconnectIfIdle(n) }
    }

    /** Live confirmed balance (local store read); the cached value when offline. */
    suspend fun refreshBalance(): Long = withContext(io) {
        val n = native ?: return@withContext _balanceSats.value
        val myEpoch = epoch
        val live = runCatching { n.balance() }.getOrNull() ?: return@withContext _balanceSats.value
        if (myEpoch == epoch && native === n) publishBalance(live)
        live.confirmedSats
    }

    /**
     * The receive offer. Answered from memory, else from the native (from disk
     * once created; the very first one needs a connect). Throws when neither
     * has one — callers treat that as "not payable yet".
     */
    suspend fun receiveOffer(): String {
        _offer.value?.let { return it }
        refreshOffer()
        return _offer.value ?: throw CashuWalletException.NotConnected()
    }

    /** A one-off BOLT11 invoice. */
    suspend fun receiveInvoice(amountSats: Long, description: String?): String = withContext(io) {
        val n = native ?: throw CashuWalletException.NotConnected()
        n.receiveInvoice(amountSats, description)
    }

    suspend fun lookupPayment(id: String): CashuPayment? = withContext(io) {
        val n = native ?: return@withContext null
        if (!n.isConnected()) return@withContext null
        runCatching { n.lookupPayment(id) }.getOrNull()
    }

    /**
     * Pay [destination]. [amountSats] 0 lets an invoice speak for its own
     * amount. [feeFromAmount] is the Cashu `Max`: prepare at [amountSats]
     * (the full balance), subtract the quoted fee reserve, prepare again.
     *
     * The result is one of: ok (Complete, with preimage), pending (in flight —
     * NOT a failure, never retry it), or a typed failure.
     */
    suspend fun send(
        destination: String,
        amountSats: Long,
        note: String,
        feeFromAmount: Boolean = false,
        onQuoted: ((paymentId: String) -> Unit)? = null,
    ): SendResult = withContext(io) {
        val n = native ?: return@withContext SendResult(
            ok = false, error = WALLET_STARTING_MESSAGE, errorKind = SendErrorKind.NotReady,
        )
        val dest = destination.trim()
        if (amountSats < 0 || dest.isEmpty()) return@withContext SendResult(false)
        counters.withLock { sendsInFlight += 1 }
        try {
            if (!n.isConnected()) connectOnce(n)
            // Read before quoting: the balance is what the user can spend.
            val balance = n.balance().confirmedSats
            var prepared = n.prepareSend(dest, amountSats.takeIf { it > 0 })
            var fee = prepared.feesSats ?: 0L
            if (prepared.amountSats + fee > balance) {
                val reduced = amountSats - fee
                if (!feeFromAmount || amountSats <= 0 || reduced <= 0) {
                    return@withContext insufficient(prepared.amountSats, fee, balance)
                }
                prepared = n.prepareSend(dest, reduced)
                fee = prepared.feesSats ?: 0L
                if (prepared.amountSats + fee > balance) {
                    return@withContext insufficient(prepared.amountSats, fee, balance)
                }
            }
            // The payment's id IS the quote id. Hand it out before the one
            // spending call so a caller can link its record first: if the
            // process dies inside `send`, a later lookup still finds it.
            onQuoted?.invoke(prepared.quoteId)
            val payment = n.send(prepared, note)
            requestBalanceRefresh()
            sendResultOf(payment)
        } catch (e: CashuWalletException) {
            if (e.isOffline && wantOnline) startConnectLoop()
            failureOf(e, n)
        } catch (e: Throwable) {
            sonarLog(TAG, "cashu send failed: ${e.message}")
            SendResult(ok = false, error = PAYMENT_FAILED_MESSAGE, errorKind = SendErrorKind.Failed)
        } finally {
            val deferred = counters.withLock {
                sendsInFlight -= 1
                (sendsInFlight == 0 && disconnectWhenIdle).also { if (it) disconnectWhenIdle = false }
            }
            if (deferred && !wantOnline) withContext(NonCancellable) { disconnectIfIdle(n) }
        }
    }

    /**
     * Account replacement: disconnect and forget this account's wallet but
     * KEEP `sonar-cashu/<accountId>/` on disk — it may hold funds. Refuses
     * (throws) while a send is in flight rather than tearing it down.
     */
    suspend fun release() = withContext(io) {
        lifecycle.withLock {
            if (counters.withLock { sendsInFlight } != 0) throw PaymentInFlightException()
            native?.let { releaseLocked(it) }
            accountId = null
            resetPublishedState()
        }
    }

    /**
     * Panic wipe: disconnect, wipe the open store, then delete EVERY account's
     * store under `sonar-cashu/`. Throws when anything remains on disk.
     * Minted proofs stay restorable from the nsec (NUT-13).
     */
    suspend fun wipeAll() = withContext(io) {
        lifecycle.withLock {
            // A panic wipe must proceed, but give an in-flight send a moment to
            // hand off (the FFI forbids disconnect() under a running send).
            withTimeoutOrNull(PANIC_SEND_GRACE_MS) {
                while (counters.withLock { sendsInFlight } > 0) delay(100)
            }
            val id = accountId
            native?.let { n ->
                releaseLocked(n, close = false)
                runCatching { n.wipeLocalStorage() }
                    .onFailure { sonarLog(TAG, "cashu wipeLocalStorage failed: ${it.message}") }
                runCatching { n.close() }
            }
            accountId = null
            id?.let { forgetCaches(it) }
            resetPublishedState()
            // Crash-safe: a wipe interrupted mid-delete finishes before any
            // store is opened again (see finishInterruptedWipe).
            check(files.writeText(wipeMarker(), "1")) { "cashu wipe marker could not be persisted" }
            check(files.deleteTree(cashuRoot())) { "cashu wallet storage could not be removed" }
            check(files.deleteTree(wipeMarker())) { "cashu wipe marker could not be cleared" }
        }
    }

    private fun cashuRoot(): String = "${storageRoot().trimEnd('/')}/$CASHU_ROOT_DIR"

    /** Beside (not inside) the root it guards, so deleting the root keeps it. */
    private fun wipeMarker(): String = "${storageRoot().trimEnd('/')}/$CASHU_ROOT_DIR.wipe-pending"

    private fun finishInterruptedWipe() {
        if (!files.exists(wipeMarker())) return
        if (files.deleteTree(cashuRoot())) files.deleteTree(wipeMarker())
    }

    // ── internals ──

    /**
     * Detach [n]: drop it as the current native first (so the connect loop and
     * late events see it is gone), then disconnect behind any in-flight
     * connect. [close] releases the handle; a wipe closes after wiping.
     */
    private suspend fun releaseLocked(n: CashuNative, close: Boolean = true) {
        epoch += 1
        native = null
        counters.withLock { connectJob?.cancel(); connectJob = null; disconnectWhenIdle = false }
        runCatching { n.clearListener() }
        connectOps.withLock { runCatching { n.disconnect() } }
        if (close) runCatching { n.close() }
        _online.value = false
    }

    private fun resetPublishedState() {
        _state.value = WalletState.NotConfigured
        _balanceSats.value = 0L
        _balance.value = null
        _offer.value = null
        _online.value = false
    }

    private fun startConnectLoop() {
        counters.withLock {
            if (connectJob?.isActive != true) connectJob = scope.launch { connectLoop() }
        }
    }

    private suspend fun connectLoop() {
        var attempt = 0
        while (true) {
            if (!wantOnline) return
            val n = native ?: return
            // The native call is blocking and cannot be cancelled; run it to
            // completion and then look at what we still want.
            val error = withContext(NonCancellable) { connectOnce(n) }
            if (!wantOnline || native !== n) {
                withContext(NonCancellable) { disconnectIfIdle(n) }
                return
            }
            if (error == null) {
                syncAndRefresh(n, syncFirst = false)
                return
            }
            sonarLog(TAG, "cashu connect failed (attempt ${attempt + 1}): ${error.message}")
            delay(retryDelaysMs[attempt.coerceAtMost(retryDelaysMs.lastIndex)])
            attempt += 1
        }
    }

    /** One bounded connect attempt. Null on success. */
    private suspend fun connectOnce(n: CashuNative): Throwable? = connectOps.withLock {
        val result = runCatching { n.connect() }
        _online.value = n.isConnected()
        result.exceptionOrNull()
    }

    private suspend fun disconnectIfIdle(n: CashuNative) {
        val busy = counters.withLock {
            if (sendsInFlight > 0) { disconnectWhenIdle = true; true } else false
        }
        if (busy || wantOnline || native !== n) return
        connectOps.withLock { runCatching { n.disconnect() } }
        _online.value = false
    }

    private suspend fun syncAndRefresh(n: CashuNative, syncFirst: Boolean = true) {
        if (syncFirst) runCatching { n.sync() }
        refreshBalance()
        refreshOffer()
    }

    /** Re-read the offer; publish only on change. Offline falls back to the
     *  last offer this account published. */
    private suspend fun refreshOffer() = withContext(io) {
        val n = native ?: return@withContext
        val id = accountId ?: return@withContext
        val myEpoch = epoch
        val live = runCatching { n.receiveOffer() }
            .onFailure { sonarLog(TAG, "cashu receiveOffer unavailable: ${it.message}") }
            .getOrNull()
            ?.takeIf { it.isNotBlank() }
        if (myEpoch != epoch || native !== n) return@withContext
        val offer = live ?: _offer.value ?: prefs.get(offerKey(id))
        if (live != null && prefs.get(offerKey(id)) != live) prefs.put(offerKey(id), live)
        if (offer != _offer.value) _offer.value = offer
    }

    private fun publishBalance(b: CashuBalance) {
        _balance.value = b
        _balanceSats.value = b.confirmedSats
        _state.value = WalletState.Ready(b.confirmedSats)
        accountId?.let { prefs.put(balanceKey(it), b.confirmedSats.toString()) }
    }

    private fun loadCachedBalance(id: String): Long? = prefs.get(balanceKey(id))?.toLongOrNull()

    private fun forgetCaches(id: String) {
        prefs.remove(balanceKey(id))
        prefs.remove(offerKey(id))
    }

    /** Wallet-thread callback: never block it, hop to [scope]. */
    private fun onNativeEvent(n: CashuNative, myEpoch: Long, event: CashuEvent) {
        if (myEpoch != epoch) return
        when (event) {
            CashuEvent.Connected -> {
                _online.value = true
                scope.launch { refreshOffer() }
                requestBalanceRefresh()
            }
            CashuEvent.Disconnected -> {
                _online.value = false
                if (wantOnline && native === n) startConnectLoop()
            }
            CashuEvent.Synced -> {
                scope.launch { refreshOffer() }
                requestBalanceRefresh()
            }
            // A Cashu receive is final when PaymentReceived fires.
            is CashuEvent.PaymentReceived -> emitPayment(event.payment.copy(status = CashuPaymentStatus.Complete))
            is CashuEvent.PaymentSent -> emitPayment(event.payment)
            is CashuEvent.PaymentFailed -> emitPayment(event.payment)
        }
    }

    private fun emitPayment(p: CashuPayment) {
        _events.tryEmit(p.toEvent())
        requestBalanceRefresh()
    }

    private fun requestBalanceRefresh() {
        scope.launch {
            if (!refreshGate.tryLock()) { refreshPending = true; return@launch }
            try {
                do {
                    refreshPending = false
                    refreshBalance()
                } while (refreshPending)
            } finally {
                refreshGate.unlock()
            }
        }
    }

    private fun insufficient(amount: Long, fee: Long, balance: Long) = SendResult(
        ok = false,
        error = SpendableBalance.insufficientMessage(amount, fee, balance),
        errorKind = SendErrorKind.InsufficientFunds,
    )

    private fun failureOf(e: CashuWalletException, n: CashuNative): SendResult = when (e) {
        is CashuWalletException.InsufficientFunds -> SendResult(
            ok = false,
            error = SpendableBalance.insufficientBalanceMessage(
                runCatching { n.balance().confirmedSats }.getOrDefault(_balanceSats.value),
            ),
            errorKind = SendErrorKind.InsufficientFunds,
        )
        is CashuWalletException.NotConnected,
        is CashuWalletException.Network,
        is CashuWalletException.Timeout ->
            SendResult(ok = false, error = MINT_OFFLINE_MESSAGE, errorKind = SendErrorKind.Offline)
        is CashuWalletException.Busy ->
            SendResult(ok = false, error = WALLET_BUSY_MESSAGE, errorKind = SendErrorKind.Busy)
        is CashuWalletException.InvalidDestination,
        is CashuWalletException.InvalidInput ->
            SendResult(ok = false, error = INVALID_DESTINATION_MESSAGE, errorKind = SendErrorKind.InvalidDestination)
        is CashuWalletException.Unsupported ->
            SendResult(ok = false, error = UNSUPPORTED_MESSAGE, errorKind = SendErrorKind.Unsupported)
        is CashuWalletException.Backend ->
            SendResult(ok = false, error = PAYMENT_FAILED_MESSAGE, errorKind = SendErrorKind.Failed)
    }

    companion object {
        private const val TAG = "SonarWallet"
        val DEFAULT_RETRY_DELAYS_MS = listOf(2_000L, 5_000L, 15_000L, 30_000L, 60_000L)
        private const val PANIC_SEND_GRACE_MS = 5_000L

        fun balanceKey(accountId: String) = "wallet.cashu.balance.$accountId"
        fun offerKey(accountId: String) = "wallet.cashu.offer.$accountId"

        const val MINT_OFFLINE_MESSAGE = "Mint offline — retrying. Nothing was sent."
        const val WALLET_STARTING_MESSAGE = "Your wallet is still starting. Try again in a moment."
        const val WALLET_BUSY_MESSAGE = "Your wallet is busy. Try again in a moment."
        const val INVALID_DESTINATION_MESSAGE = "That payment address can't be paid."
        const val UNSUPPORTED_MESSAGE = "This kind of payment isn't supported yet."
        const val PAYMENT_FAILED_MESSAGE = "Payment failed — you were not charged."
    }
}

/** Map a native payment to the app event (both directions; consumers filter). */
internal fun CashuPayment.toEvent() = WalletPaymentEvent(
    paymentId = id,
    incoming = incoming,
    amountSats = amountSats,
    feesSats = feesSats,
    timestampSecs = timestampSecs,
    preimage = preimage,
    settled = status == CashuPaymentStatus.Complete,
    status = status,
)

/** The send result for a payment `send` returned. Pending is not a failure. */
internal fun sendResultOf(p: CashuPayment): SendResult = when (p.status) {
    CashuPaymentStatus.Complete -> SendResult(
        ok = true,
        preimage = p.preimage,
        paymentId = p.id,
        feesSats = p.feesSats,
        settledAtSecs = p.timestampSecs,
    )
    // Refundable is a Breez-backend state; for Cashu it is not terminal, so it
    // is treated as in flight rather than claimed as failed.
    CashuPaymentStatus.Pending, CashuPaymentStatus.Refundable -> SendResult(
        ok = false,
        pending = true,
        paymentId = p.id,
        feesSats = p.feesSats,
    )
    CashuPaymentStatus.Failed -> SendResult(
        ok = false,
        paymentId = p.id,
        error = CashuWalletEngine.PAYMENT_FAILED_MESSAGE,
        errorKind = SendErrorKind.Failed,
    )
}

/** Account replacement refused: a send is still running on this wallet. */
class PaymentInFlightException : IllegalStateException("a payment is still in flight")
