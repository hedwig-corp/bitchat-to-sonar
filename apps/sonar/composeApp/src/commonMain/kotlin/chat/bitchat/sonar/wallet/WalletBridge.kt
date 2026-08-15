package chat.bitchat.sonar.wallet

import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow

/** Lightning wallet lifecycle state, mirrored from the iOS WalletBridgeService. */
sealed interface WalletState {
    /** No API key, or not yet asked to set up. */
    data object NotConfigured : WalletState
    data object SettingUp : WalletState
    data class Ready(val balanceSats: Long) : WalletState
    data class Failed(val message: String) : WalletState
}

/** Result of a wallet send: success flag plus the Lightning preimage and the
 *  settlement details the payment-activity ledger records (iOS
 *  `SonarWalletPayment`: id, feesSats, timestamp). */
/**
 * A priced, not-yet-paid send. [id] is an opaque handle into the wallet's
 * pending-quote table.
 */
data class PreparedSendQuote(
    val id: String,
    val amountSats: Long,
    val feesSats: Long?,
)

data class SendResult(
    val ok: Boolean,
    val preimage: String? = null,
    /** Stable wallet payment id (txId, else payment hash, else destination). */
    val paymentId: String? = null,
    val feesSats: Long? = null,
    val settledAtSecs: Long? = null,
    /**
     * User-facing reason a send was refused, when we know one. Set by the
     * prepared-fee preflight (#141) so the UI can say "amount plus fee exceeds
     * your balance" instead of surfacing the raw SDK failure. Null for the
     * generic failure path, which behaves as before.
     */
    val error: String? = null,
)

/**
 * One settled payment surfaced by the Breez SDK event listener — the Compose
 * twin of iOS `SonarWallet.incomingPaymentsStream()`'s `Payment` element. Used
 * to record `walletIncoming` rows in the payment-activity ledger.
 */
data class WalletPaymentEvent(
    /** Stable wallet payment id (txId, else payment hash, else destination). */
    val paymentId: String,
    val incoming: Boolean,
    val amountSats: Long,
    val feesSats: Long?,
    val timestampSecs: Long,
    val preimage: String? = null,
    /**
     * True only for a fully COMPLETE payment. A swap receive is reported while
     * still PENDING (lockup seen, claim in flight) so a headless wake can stop
     * waiting early — but a pending receive must not produce a user-visible
     * "received" banner or a permanent `Paid` ledger row, because the swap can
     * still fail or the lockup be reorged and the notify-once ring would block
     * any later correction.
     */
    val settled: Boolean = true,
)

/**
 * Thin Kotlin façade over the on-device Breez SDK Liquid wallet, the Android
 * twin of iOS `WalletBridgeService`. Seed is derived deterministically from the
 * Nostr identity ([WalletSeed]); the API key is injected from a gitignored
 * build config. All SDK calls are blocking → the `actual` hops to a background
 * dispatcher.
 *
 * Autonomously verifiable on-device with the API key: `setupIfNeeded` (connect),
 * `balance`/getInfo, `createOffer` (BOLT12). `send` needs real funds to settle.
 */
expect object WalletBridge {
    /** True when an API key is compiled in (else the wallet UI shows "unavailable"). */
    fun isAvailable(): Boolean

    /** Current snapshot state. */
    fun state(): WalletState

    /** Connect the SDK (idempotent). [nsec] is the Nostr secret to derive the seed. */
    suspend fun setupIfNeeded(nsec: String)

    /** Refresh + return the spendable balance in sats (0 if not ready). */
    suspend fun refreshBalance(): Long

    /**
     * Live spendable balance in sats — the Compose twin of iOS
     * `WalletBridgeService.startObservingBalance()` (`balanceTask` stream).
     * Produced entirely from a background listener/refresh path in the actuals
     * (never on the Compose render path); the UI only collects. Emits 0 until
     * the wallet is Ready and again after [shutdown].
     */
    val balanceFlow: StateFlow<Long>

    /**
     * Settled wallet payments from the Breez SDK event listener (both
     * directions; consumers filter). Fed from the SDK callback thread via
     * `tryEmit` on a buffered flow — never blocks the SDK, never touches the
     * render path. iOS parity: `WalletBridgeService.incomingPayments()`.
     */
    val paymentEvents: SharedFlow<WalletPaymentEvent>

    /** A reusable BOLT12 offer string to receive payments. */
    suspend fun createOffer(): String

    /** Pay a destination (BOLT11/BOLT12/LNURL/BIP-353). amountSats=0 ⇒ amount from
     *  the invoice/offer. Returns [SendResult] with preimage when available. */
    suspend fun send(destination: String, amountSats: Long, note: String): SendResult

    /**
     * Price a send WITHOUT paying it, so a caller can show the fee and take
     * consent first. Returns null when the wallet cannot quote.
     *
     * Needed by the Breez→Cashu migration (quote → consent → pay); [send]
     * prepares and pays in one step and cannot surface a fee for confirmation.
     */
    suspend fun prepareSend(destination: String, amountSats: Long): PreparedSendQuote?

    /**
     * Why the most recent [prepareSend] returned null, or null when the last
     * one succeeded.
     *
     * [prepareSend] answers with a bare null, which is enough for a UI that
     * only needs "no quote" but loses the distinction the migration engine
     * depends on: a wallet that cannot afford the amount must be reported as
     * insufficient funds so the engine plans a smaller one, while any other
     * failure must not trigger that retry.
     */
    fun lastPrepareFailure(): String?

    /** Pay a quote from [prepareSend]. Single-use — the quote is consumed. */
    suspend fun sendPrepared(id: String, note: String): SendResult

    /** Fetch + cache live BTC→fiat rates. */
    suspend fun fetchRates(): List<ExchangeRate>

    /** Cached rate for a currency (null until [fetchRates] succeeds). */
    fun cachedRate(currency: FiatCurrency): ExchangeRate?

    /**
     * True only when a usable live rate is cached for the selected [currency]
     * (iOS `hasLiveRate`). The UI shows fiat ONLY when this is true; otherwise
     * it must fall back to sats — never a bundled/stale rate.
     */
    fun hasLiveRate(): Boolean

    // ── Display preferences (persisted) ──
    fun showFiat(): Boolean
    fun setShowFiat(value: Boolean)
    fun currency(): FiatCurrency
    fun setCurrency(value: FiatCurrency)

    /** Register a push notification webhook so wallet events (BOLT12
     *  receive, swap update) fire a silent data-only push via Breez NDS. */
    suspend fun registerWebhook(url: String)

    /** Remove the push webhook (sign-out or push disable). */
    suspend fun unregisterWebhook()

    /** Disconnect before a destructive storage mutation. Throws if the native
     *  node cannot release its database cleanly. */
    suspend fun shutdown()

    /**
     * Delete on-disk Breez wallet state after [shutdown]. Throws unless the
     * complete wallet root is absent on return, so restore can never report
     * success while retaining a previous identity's database.
     */
    suspend fun wipeLocalStorage()
}
