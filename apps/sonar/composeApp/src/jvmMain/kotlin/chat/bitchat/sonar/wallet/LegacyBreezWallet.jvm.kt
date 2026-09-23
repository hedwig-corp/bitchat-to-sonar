package chat.bitchat.sonar.wallet

import breez_sdk_liquid.BindingLiquidSdk
import breez_sdk_liquid.ConnectRequest
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
import chat.bitchat.sonar.DesktopEnv
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
 * Desktop (JVM) `actual`: the SAME Breez SDK Liquid wallet as Android, via the
 * KMP package's `jvm` variant (a UniFFI/JNA binding loading the host
 * `libbreez_sdk_liquid_bindings` off the classpath), now LEGACY (see the
 * common [LegacyBreezWallet] contract). Seed derived via [WalletSeed], so the
 * same nsec opens the same wallet as on Android and iOS. The API key is read
 * from the gitignored generated resource `/breez_api_key.txt`.
 *
 * Opened ONLY when its store already exists ([LegacyBreezStore]); nothing on
 * the normal path creates `sonar-wallet/`. The one exception is the explicit
 * post-restore check, which marks what it creates and removes it unless the
 * derived wallet turns out to hold funds or history.
 */
actual object LegacyBreezWallet {

    private const val CLEANUP_MARKER_NAME = "wallet-cleanup.pending"
    /** Content of the marker when the interrupted cleanup was a panic wipe,
     *  so recovery also removes every archive. */
    private const val CLEANUP_ALL = "all"

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

    /** Non-terminal payment states: any of these blocks a delete. */
    private val UNSETTLED_STATES = listOf(
        PaymentState.CREATED,
        PaymentState.PENDING,
        PaymentState.REFUNDABLE,
        PaymentState.REFUND_PENDING,
        PaymentState.WAITING_FEE_ACCEPTANCE,
    )

    /** Bound on the blocking `connect()`. */
    private const val CONNECT_TIMEOUT_MS = 20_000L

    private val store = LegacyBreezStore({ DesktopEnv.dataDir.absolutePath }, platformWalletFiles())

    private val apiKeyValue: String by lazy {
        runCatching {
            javaClass.getResourceAsStream("/breez_api_key.txt")?.bufferedReader()?.use { it.readText() }
        }.getOrNull().orEmpty().trim()
    }

    private fun apiKey(): String = apiKeyValue

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
            // Zero the balance on failure so balanceFlow never keeps a dead
            // wallet's last balance alongside Failed state.
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
            val keep = runCatching {
                node.sync()
                val info = node.getInfo().walletInfo
                val history = node.listPayments(ListPaymentsRequest(limit = 1u))
                val refundables = node.listRefundables()
                info.balanceSat > 0u || info.pendingSendSat > 0u || info.pendingReceiveSat > 0u ||
                    history.isNotEmpty() || refundables.isNotEmpty()
            }
            if (keep.getOrNull() == true && store.keepRestoreCheck(accountId)) {
                syncedSinceConnect = true
                requestBalanceRefresh()
                return@withLock LegacyRestoreCheckOutcome.Kept
            }
            runCatching { disconnectLocked() }
            store.deleteLive()
            snapshotState.value = LegacyWalletSnapshot()
            if (keep.isFailure) LegacyRestoreCheckOutcome.Failed else LegacyRestoreCheckOutcome.Discarded
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
            // Capture the handle under [lock]; the lock is not held for the
            // multi-second send itself (mirror of the Android actual).
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
                // Real prepared-fee affordability check — mirror of the
                // Android actual; see the comment there and #141.
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
        val synced = runCatching { node.sync() }.isSuccess
        syncedSinceConnect = synced
        val info = runCatching { node.getInfo().walletInfo }.getOrNull()
        val refundables = runCatching { node.listRefundables().size }.getOrNull()
        val unsettled = runCatching {
            node.listPayments(ListPaymentsRequest(states = UNSETTLED_STATES)).size
        }.getOrNull()
        return legacyDeleteGate(
            LegacyGateFacts(
                connected = true,
                syncedSinceConnect = synced,
                confirmedSats = info?.balanceSat?.toLong(),
                pendingSendSats = info?.pendingSendSat?.toLong(),
                pendingReceiveSats = info?.pendingReceiveSat?.toLong(),
                refundableSwaps = refundables,
                unsettledPayments = unsettled,
            )
        )
    }

    actual suspend fun deleteIfSafe(): LegacyDeleteGate = withContext(Dispatchers.IO) {
        lock.withLock {
            val gate = gateLocked()
            if (gate != LegacyDeleteGate.Safe) return@withLock gate
            runCatching { sdk?.unregisterWebhook() }
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

    private fun cleanupMarker(): File = DesktopEnv.file(CLEANUP_MARKER_NAME)

    /** Complete an interrupted destructive delete before any seed can be opened. */
    private fun recoverPendingCleanupLocked() {
        val marker = cleanupMarker()
        if (!marker.exists()) return
        val all = runCatching { marker.readText().trim() == CLEANUP_ALL }.getOrDefault(true)
        disconnectLocked()
        deleteStorageLocked(all = all)
        completeCleanupLocked()
    }

    private fun markCleanupPendingLocked(all: Boolean) {
        val marker = cleanupMarker()
        marker.parentFile?.mkdirs()
        check(runCatching { marker.writeText(if (all) CLEANUP_ALL else "live"); true }.getOrDefault(false)) {
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
