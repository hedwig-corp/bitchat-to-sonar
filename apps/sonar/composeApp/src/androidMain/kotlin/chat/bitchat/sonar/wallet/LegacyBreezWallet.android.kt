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
import breez_sdk_liquid.PaymentDetails
import breez_sdk_liquid.PaymentMethod
import breez_sdk_liquid.PaymentState
import breez_sdk_liquid.PaymentType
import breez_sdk_liquid.PrepareReceiveRequest
import breez_sdk_liquid.PrepareSendRequest
import breez_sdk_liquid.ReceivePaymentRequest
import breez_sdk_liquid.SdkEvent
import breez_sdk_liquid.SendPaymentRequest
import breez_sdk_liquid.connect
import breez_sdk_liquid.defaultConfig
import chat.bitchat.sonar.AppContextHolder
import chat.bitchat.sonar.BuildConfig
import chat.bitchat.sonar.SonarLifecycle
import chat.bitchat.sonar.crypto.Bech32
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
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
 * Android `actual`: the on-device Breez SDK Liquid wallet, now LEGACY (see the
 * common [LegacyBreezWallet] contract). Mainnet. Seed derived from the Nostr
 * identity via [WalletSeed] (HKDF), byte-identical to iOS. API key from the
 * gitignored BuildConfig field.
 *
 * Opened ONLY when its store already exists ([LegacyBreezStore]); nothing on
 * the normal path creates `sonar-wallet/`. The one exception is the explicit
 * post-restore check, which marks what it creates and removes it unless the
 * derived wallet turns out to hold funds or history.
 */
actual object LegacyBreezWallet {

    private const val CLEANUP_PENDING_KEY = "cleanup.pending"
    /** Set with [CLEANUP_PENDING_KEY] when the interrupted cleanup was a panic
     *  wipe, so recovery also removes every archive. */
    private const val CLEANUP_ALL_KEY = "cleanup.all"

    private val lock = Mutex()
    @Volatile private var sdk: BindingLiquidSdk? = null
    @Volatile private var current: WalletState = WalletState.NotConfigured
    @Volatile private var receiveOffer: String? = null
    /** A `sync()` completed after the current connect (delete-gate input). */
    @Volatile private var syncedSinceConnect = false

    /** Background home for listener-triggered balance refreshes — never the UI. */
    private val walletScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val balance = MutableStateFlow(0L)
    actual val balanceFlow: StateFlow<Long> get() = balance
    /** Buffered so the SDK callback thread can `tryEmit` without ever blocking. */
    private val payments = MutableSharedFlow<WalletPaymentEvent>(extraBufferCapacity = 16)
    actual val paymentEvents: SharedFlow<WalletPaymentEvent> get() = payments
    private val snapshotState = MutableStateFlow(LegacyWalletSnapshot())
    actual val snapshot: StateFlow<LegacyWalletSnapshot> get() = snapshotState
    @Volatile private var balanceListenerId: String? = null
    /** Bumped on disconnect (inside [lock]); [refreshBalance] drops its writes
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

    /** Non-terminal payment states: any of these blocks a delete. */
    private val UNSETTLED_STATES = listOf(
        PaymentState.CREATED,
        PaymentState.PENDING,
        PaymentState.REFUNDABLE,
        PaymentState.REFUND_PENDING,
        PaymentState.WAITING_FEE_ACCEPTANCE,
    )

    private val ctx: Context get() = AppContextHolder.ctx
    private fun cleanupPrefs() = ctx.getSharedPreferences("sonar.wallet.lifecycle", Context.MODE_PRIVATE)
    private val store = LegacyBreezStore({ ctx.filesDir.absolutePath }, platformWalletFiles())

    private fun apiKey(): String = BuildConfig.BREEZ_API_KEY.trim()

    actual fun hasApiKey(): Boolean = apiKey().isNotEmpty()

    actual fun isPresent(accountId: String): Boolean =
        runCatching { store.resolvePresent(accountId) }.getOrDefault(false)

    actual fun state(): WalletState = current

    actual suspend fun openIfPresent(nsec: String): Boolean = withContext(Dispatchers.IO) {
        lock.withLock {
            recoverPendingCleanupLocked()
            if (sdk != null) return@withLock true
            openExistingLocked(nsec)
        }
    }

    /**
     * Connect the legacy store for [nsec]'s account IF it exists. Assumes
     * [lock] is held and [sdk] is null. The presence check runs BEFORE any
     * directory is created, so a fresh install never grows `sonar-wallet/`.
     */
    private suspend fun openExistingLocked(nsec: String): Boolean {
        val accountId = cashuAccountId(nsec)
        if (!store.resolvePresent(accountId)) {
            current = WalletState.NotConfigured
            snapshotState.value = LegacyWalletSnapshot()
            return false
        }
        snapshotState.value = snapshotState.value.copy(present = true)
        val key = apiKey()
        if (key.isEmpty()) {
            current = WalletState.NotConfigured
            return false
        }
        connectLocked(nsec, key)
        val node = sdk ?: return false
        store.claim(accountId)
        return node === sdk
    }

    /**
     * Connect + store the SDK against the EXISTING working dir. **Assumes
     * [lock] is held and [sdk] is null.** Never creates the store directory;
     * callers decide that (only the restore check may).
     */
    private suspend fun connectLocked(nsec: String, key: String) {
        val secretHex = Bech32.nsecToSecretHex(nsec)
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
                    workingDir = File(store.workingDir).absolutePath
                }
                var node: BindingLiquidSdk? = null
                var handedOff = false
                try {
                    val connected = connect(ConnectRequest(config, null, null, seed.map { it.toUByte() }))
                    node = connected
                    currentCoroutineContext().ensureActive()
                    val info = connected.getInfo().walletInfo
                    currentCoroutineContext().ensureActive()
                    handedOff = true
                    connected to info
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
                snapshotState.value = snapshotState.value.copy(connected = false)
                WalletState.Failed(outcome.exceptionOrNull()?.message ?: "wallet setup failed")
            }
            outcome.getOrNull() == null -> {
                balance.value = 0L
                snapshotState.value = snapshotState.value.copy(connected = false)
                WalletState.Failed("wallet setup timed out")
            }
            else -> outcome.getOrThrow()!!.let { (node, info) ->
                sdk = node
                syncedSinceConnect = false
                balance.value = info.balanceSat.toLong()
                snapshotState.value = LegacyWalletSnapshot(
                    present = true,
                    connected = true,
                    balanceSats = info.balanceSat.toLong(),
                    pendingSendSats = info.pendingSendSat.toLong(),
                    pendingReceiveSats = info.pendingReceiveSat.toLong(),
                )
                startObservingBalance(node)
                WalletState.Ready(info.balanceSat.toLong())
            }
        }
    }

    actual suspend fun runRestoreCheck(nsec: String): LegacyRestoreCheckOutcome = withContext(Dispatchers.IO) {
        lock.withLock {
            recoverPendingCleanupLocked()
            val key = apiKey()
            if (key.isEmpty()) return@withLock LegacyRestoreCheckOutcome.Skipped
            val accountId = cashuAccountId(nsec)
            if (sdk != null || store.resolvePresent(accountId)) {
                return@withLock LegacyRestoreCheckOutcome.AlreadyPresent
            }
            if (!store.beginRestoreCheck()) return@withLock LegacyRestoreCheckOutcome.Failed
            // The one path allowed to create the store — and it is marked, so
            // a crash here never leaves something that looks like a kept wallet.
            File(store.workingDir).mkdirs()
            connectLocked(nsec, key)
            val node = sdk ?: run {
                store.deleteLive()
                snapshotState.value = LegacyWalletSnapshot()
                return@withLock LegacyRestoreCheckOutcome.Failed
            }
            // One empty pass is not proof (a sync can return before the
            // history lands): an empty wallet is confirmed by a second pass.
            val first = runCatching { restoreFactsLocked(node) }.getOrNull()
            val confirm = if (first?.empty == true) {
                delay(LEGACY_RESTORE_CONFIRM_DELAY_MS)
                runCatching { restoreFactsLocked(node) }.getOrNull()
            } else {
                null
            }
            val verdict = legacyRestoreVerdict(first, confirm)
            if (verdict == LegacyRestoreCheckOutcome.Kept && store.keepRestoreCheck(accountId)) {
                syncedSinceConnect = true
                requestBalanceRefresh()
                return@withLock LegacyRestoreCheckOutcome.Kept
            }
            runCatching { disconnectLocked() }
            store.deleteLive()
            snapshotState.value = LegacyWalletSnapshot()
            // A wallet that showed funds but could not be recorded as kept is
            // a Failed check (retried from the seed), never a Discarded one.
            if (verdict == LegacyRestoreCheckOutcome.Kept) LegacyRestoreCheckOutcome.Failed else verdict
        }
    }

    /** One restore-check pass: sync, then read what the wallet holds. Assumes [lock] is held. */
    private fun restoreFactsLocked(node: BindingLiquidSdk): LegacyRestoreFacts {
        node.sync()
        val info = node.getInfo().walletInfo
        return LegacyRestoreFacts(
            synced = syncedSinceConnect,
            balanceSats = info.balanceSat.toLong(),
            pendingSendSats = info.pendingSendSat.toLong(),
            pendingReceiveSats = info.pendingReceiveSat.toLong(),
            hasHistory = node.listPayments(ListPaymentsRequest(limit = 1u)).isNotEmpty(),
            refundableSwaps = node.listRefundables().size,
        )
    }

    /**
     * Bring the legacy wallet to a live, connected state for a headless Breez
     * wake, atomically under [lock]: connect if there is no SDK (ONLY when the
     * store exists — a push must never create a wallet), or probe a reused
     * handle and reconnect it if its websocket died in Doze. Returns true when
     * [sdk] is usable afterward.
     *
     * Replaces the caller-side `isConnectionLive() → shutdown() → setupIfNeeded()`
     * dance, which was check-then-act across three separate lock acquisitions —
     * two near-simultaneous Breez wakes could interleave it and tear down each
     * other's freshly-built node. Doing the whole probe+reconnect in one lock
     * acquisition serializes overlapping wakes onto a single connection.
     */
    suspend fun ensureLiveConnection(nsec: String): Boolean = withContext(Dispatchers.IO) {
        lock.withLock {
            // Same guard openIfPresent runs, for the same reason: an interrupted
            // delete must finish before ANY seed is opened.
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
            openExistingLocked(nsec)
            sdk != null
        }
    }

    actual suspend fun refreshBalance(): Long = withContext(Dispatchers.IO) {
        val node = sdk ?: return@withContext 0L
        val epoch = walletEpoch
        try {
            val info = node.getInfo().walletInfo
            val bal = info.balanceSat.toLong()
            // Drop the writes if shutdown/re-setup won the race while the
            // blocking getInfo() ran — never resurrect a torn-down wallet.
            if (epoch == walletEpoch && sdk === node) {
                current = WalletState.Ready(bal)
                balance.value = bal
                snapshotState.value = LegacyWalletSnapshot(
                    present = true,
                    connected = true,
                    balanceSats = bal,
                    pendingSendSats = info.pendingSendSat.toLong(),
                    pendingReceiveSats = info.pendingReceiveSat.toLong(),
                )
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
                        is SdkEvent.Synced -> {
                            syncedSinceConnect = true
                            requestBalanceRefresh()
                        }
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
                // Amountless reusable BOLT12 offer. It only backs this wallet's
                // own NDS webhook now; the PUBLISHED offer is the Cashu one.
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
            val node = lock.withLock { sdk } ?: return@withContext SendResult(
                ok = false,
                error = "The old wallet isn't connected. Try again in a moment.",
                errorKind = SendErrorKind.NotReady,
            )
            if (amountSats < 0) return@withContext SendResult(false)
            try {
                val amount: PayAmount? =
                    if (amountSats > 0) PayAmount.Bitcoin(amountSats.toULong()) else null
                val prepared = node.prepareSendPayment(PrepareSendRequest(destination.trim(), amount))
                // Enforce affordability against the REAL prepared fee before
                // Breez is asked to pay (#141). The UI gates on the raw balance
                // and `Max` uses a 0.5% estimate; neither knows the route, so
                // without this an over-estimate route reaches sendPayment and
                // surfaces the raw SDK error — the symptom #141 reports.
                //
                // `feesSat` is nullable in the SDK: with no fee to check the
                // payment proceeds exactly as before rather than being blocked
                // on a number we do not have.
                prepared.feesSat?.let { feesSat ->
                    val fee = feesSat.toLong()
                    // For amountless destinations (BOLT12 offer, LNURL) the
                    // caller passes 0 and the prepared response carries the
                    // real amount.
                    val sending = (prepared.amount as? PayAmount.Bitcoin)
                        ?.receiverAmountSat?.toLong() ?: amountSats
                    val bal = node.getInfo().walletInfo.balanceSat.toLong()
                    if (SpendableBalance.insufficientAfterFee(sending, fee, bal)) {
                        return@withContext SendResult(
                            ok = false,
                            error = SpendableBalance.insufficientMessage(sending, fee, bal),
                            errorKind = SendErrorKind.InsufficientFunds,
                        )
                    }
                }
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
            } catch (t: Throwable) { SendResult(false, errorKind = SendErrorKind.Failed) }
        }

    actual suspend fun registerWebhook(url: String): Unit = withContext(Dispatchers.IO) {
        sdk?.registerWebhook(url)
    }

    actual suspend fun unregisterWebhook(): Unit = withContext(Dispatchers.IO) {
        sdk?.unregisterWebhook()
    }

    actual suspend fun deleteGate(): LegacyDeleteGate = withContext(Dispatchers.IO) {
        lock.withLock { gateLocked() }
    }

    /** Read the gate facts. Assumes [lock] is held. Every read that fails is
     *  reported as unknown, which [legacyDeleteGate] treats as NOT safe. */
    private fun gateLocked(): LegacyDeleteGate {
        val node = sdk ?: return LegacyDeleteGate.Blocked(
            if (store.hasLiveStore()) LegacyDeleteBlock.NotConnected else LegacyDeleteBlock.Absent,
        )
        return legacyDeleteGate(gateFactsLocked(node))
    }

    private fun gateFactsLocked(node: BindingLiquidSdk): LegacyGateFacts {
        val synced = runCatching { node.sync() }.isSuccess
        syncedSinceConnect = synced
        val info = runCatching { node.getInfo().walletInfo }.getOrNull()
        val refundables = runCatching { node.listRefundables().size }.getOrNull()
        val unsettled = runCatching {
            node.listPayments(ListPaymentsRequest(states = UNSETTLED_STATES)).size
        }.getOrNull()
        return LegacyGateFacts(
            connected = true,
            syncedSinceConnect = synced,
            confirmedSats = info?.balanceSat?.toLong(),
            pendingSendSats = info?.pendingSendSat?.toLong(),
            pendingReceiveSats = info?.pendingReceiveSat?.toLong(),
            refundableSwaps = refundables,
            unsettledPayments = unsettled,
        )
    }

    actual suspend fun deleteIfSafe(): LegacyDeleteGate = withContext(Dispatchers.IO) {
        lock.withLock {
            val node = sdk ?: return@withLock gateLocked()
            val before = gateFactsLocked(node)
            val gate = legacyDeleteGate(before)
            if (gate != LegacyDeleteGate.Safe) return@withLock gate
            runCatching { node.unregisterWebhook() }
            // A payment could settle while the webhook was being removed: read
            // again, and delete only if nothing moved. (The webhook comes back
            // with the next push registration if this stops here.)
            val after = gateFactsLocked(node)
            if (!legacyGateUnchanged(before, after)) {
                val moved = legacyDeleteGate(after)
                return@withLock if (moved == LegacyDeleteGate.Safe) {
                    LegacyDeleteGate.Blocked(LegacyDeleteBlock.Unknown)
                } else {
                    moved
                }
            }
            markCleanupPendingLocked(all = false)
            disconnectLocked()
            deleteStorageLocked(all = false)
            completeCleanupLocked()
            snapshotState.value = LegacyWalletSnapshot()
            LegacyDeleteGate.Safe
        }
    }

    actual suspend fun releaseForAccountReplacement(oldAccountId: String): Unit = withContext(Dispatchers.IO) {
        lock.withLock {
            recoverPendingCleanupLocked()
            if (!store.hasLiveStore()) {
                // Nothing that could hold funds: drop any empty leftover dir.
                disconnectLocked()
                store.deleteLive()
                snapshotState.value = LegacyWalletSnapshot()
                return@withLock
            }
            val gate = if (sdk != null) gateLocked() else LegacyDeleteGate.Blocked(LegacyDeleteBlock.NotConnected)
            runCatching { sdk?.unregisterWebhook() }
            disconnectLocked()
            if (gate == LegacyDeleteGate.Safe) {
                markCleanupPendingLocked(all = false)
                deleteStorageLocked(all = false)
                completeCleanupLocked()
            } else {
                // May hold funds: never delete. Put it aside for its account.
                // Archive under the store's recorded owner when it has one.
                check(store.archive(store.owner() ?: oldAccountId)) { "legacy wallet could not be archived" }
            }
            snapshotState.value = LegacyWalletSnapshot()
        }
    }

    actual suspend fun shutdown(): Unit = withContext(Dispatchers.IO) {
        lock.withLock {
            disconnectLocked()
        }
    }

    actual suspend fun wipeLocalStorage(): Unit = withContext(Dispatchers.IO) {
        lock.withLock {
            markCleanupPendingLocked(all = true)
            disconnectLocked()
            deleteStorageLocked(all = true)
            completeCleanupLocked()
            snapshotState.value = LegacyWalletSnapshot()
        }
    }

    /** Complete an interrupted destructive delete before any seed can be opened. */
    private fun recoverPendingCleanupLocked() {
        val prefs = cleanupPrefs()
        if (!prefs.getBoolean(CLEANUP_PENDING_KEY, false)) return
        disconnectLocked()
        deleteStorageLocked(all = prefs.getBoolean(CLEANUP_ALL_KEY, false))
        completeCleanupLocked()
    }

    private fun markCleanupPendingLocked(all: Boolean) {
        check(
            cleanupPrefs().edit()
                .putBoolean(CLEANUP_PENDING_KEY, true)
                .putBoolean(CLEANUP_ALL_KEY, all)
                .commit()
        ) {
            "wallet cleanup marker could not be persisted"
        }
    }

    private fun completeCleanupLocked() {
        check(cleanupPrefs().edit().remove(CLEANUP_PENDING_KEY).remove(CLEANUP_ALL_KEY).commit()) {
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
        syncedSinceConnect = false
        current = WalletState.NotConfigured
        balance.value = 0L
        receiveOffer = null
        snapshotState.value = snapshotState.value.copy(connected = false)
    }

    private fun deleteStorageLocked(all: Boolean) {
        val removed = if (all) store.deleteEverything() else store.deleteLive()
        if (!removed) throw IllegalStateException("wallet storage could not be removed")
    }
}
