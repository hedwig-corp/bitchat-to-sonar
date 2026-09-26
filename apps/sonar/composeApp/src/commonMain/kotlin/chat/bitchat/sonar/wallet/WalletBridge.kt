package chat.bitchat.sonar.wallet

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext

/** Wallet lifecycle state, mirrored from the iOS WalletBridgeService. */
sealed interface WalletState {
    /** Not asked to set up yet (or torn down). */
    data object NotConfigured : WalletState
    /** Constructed, no balance known yet (no cache, not connected). */
    data object SettingUp : WalletState
    /** Balance known: the cached last-known value until the mint answers. */
    data class Ready(val balanceSats: Long) : WalletState
    data class Failed(val message: String) : WalletState
}

/** Why a send was refused. Callers branch on this, never on [SendResult.error] text. */
enum class SendErrorKind {
    /** Amount plus the real fee exceeds the balance. */
    InsufficientFunds,
    /** Mint unreachable / not connected. Nothing was sent; the wallet retries. */
    Offline,
    Busy,
    InvalidDestination,
    Unsupported,
    /** The wallet has not been constructed yet. */
    NotReady,
    /** The payment itself failed; nothing left the wallet. */
    Failed,
    /**
     * The fee of the quote about to be paid is above the fee the user agreed
     * to on the send sheet. Nothing was sent; [SendResult.quotedFeeSats] is
     * the new fee to ask about.
     */
    FeeChanged,
}

/** Result of a wallet send: success flag plus the Lightning preimage and the
 *  settlement details the payment-activity ledger records (iOS
 *  `SonarWalletPayment`: id, feesSats, timestamp). */
data class SendResult(
    val ok: Boolean,
    val preimage: String? = null,
    /** Stable wallet payment id. For a Cashu send this is the melt quote id,
     *  and a pending send's later event carries the same id. */
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
    /**
     * The payment is IN FLIGHT: not failed, not complete. Its outcome arrives
     * later as a [WalletPaymentEvent] with [paymentId]. Callers must record it
     * as pending and must never retry it (a second quote can pay twice).
     */
    val pending: Boolean = false,
    /** Typed reason for a refusal; null on success/pending. */
    val errorKind: SendErrorKind? = null,
    /**
     * With [SendErrorKind.FeeChanged]: the mint's fee reserve for the quote
     * that was refused — the fee the user has to agree to next. Null otherwise.
     */
    val quotedFeeSats: Long? = null,
)

/**
 * A wallet call that answers [Ok] or is refused with a typed reason. Callers
 * branch on [Failed.kind] (the same [SendErrorKind] a send uses), never on
 * [Failed.message], which is the engine's English fallback.
 */
sealed interface WalletOutcome<out T> {
    data class Ok<out T>(val value: T) : WalletOutcome<T>
    data class Failed(val kind: SendErrorKind, val message: String) : WalletOutcome<Nothing>
}

/**
 * One payment surfaced by a wallet's event listener — the Compose twin of iOS
 * `SonarWallet.incomingPaymentsStream()`'s `Payment` element. Used to record
 * `walletIncoming` rows and to resolve pending sends.
 */
data class WalletPaymentEvent(
    /** Stable wallet payment id. */
    val paymentId: String,
    val incoming: Boolean,
    val amountSats: Long,
    val feesSats: Long?,
    val timestampSecs: Long,
    val preimage: String? = null,
    /**
     * True only for a fully COMPLETE payment. A swap receive (legacy Breez) is
     * reported while still PENDING so a headless wake can stop waiting early —
     * but a pending receive must not produce a user-visible "received" banner
     * or a permanent `Paid` ledger row, because the swap can still fail and
     * the notify-once ring would block any later correction.
     */
    val settled: Boolean = true,
    /** Wallet-reported status; drives pending-send resolution. */
    val status: CashuPaymentStatus =
        if (settled) CashuPaymentStatus.Complete else CashuPaymentStatus.Pending,
)

/**
 * Sonar's wallet: the Cashu (ecash) wallet at [CASHU_MINT_URL], for everyone.
 * A thin facade over one [CashuWalletEngine] so the app's call sites stay
 * stable; the legacy Breez wallet is [LegacyBreezWallet], never this.
 *
 * Every member that can touch the native wallet is `suspend` and hops off the
 * caller's dispatcher inside the engine.
 */
object WalletBridge {

    private val defaultEngine: CashuWalletEngine by lazy {
        CashuWalletEngine(
            openNative = ::openCashuNative,
            storageRoot = ::walletStorageRoot,
            prefs = CoreWalletPrefs,
            files = platformWalletFiles(),
            offerBackups = NostrOfferBackups,
        )
    }

    @Volatile private var testEngine: CashuWalletEngine? = null

    internal val engine: CashuWalletEngine get() = testEngine ?: defaultEngine

    /**
     * Test seam: route the app's wallet through [engine] (typically one built
     * over a fake [CashuNative]); null restores the production engine.
     */
    internal fun useEngineForTest(engine: CashuWalletEngine?) {
        testEngine = engine
    }

    @Volatile private var rates: Map<String, ExchangeRate> = emptyMap()

    /** The rates source (the FFI's Yadio fetch). Tests swap it: no network. */
    @Volatile internal var ratesSource: () -> List<ExchangeRate> = ::fetchFiatRatesNative

    /** Cashu needs no API key: the wallet exists on every build. */
    fun isAvailable(): Boolean = true

    fun state(): WalletState = engine.state.value
    val stateFlow: StateFlow<WalletState> get() = engine.state

    /** Construct locally, publish cache + offer, connect in the background. */
    suspend fun setupIfNeeded(nsec: String) = engine.setup(nsec)

    suspend fun refreshBalance(): Long = engine.refreshBalance()

    /** Confirmed sats; the per-account cached value until the mint answers. */
    val balanceFlow: StateFlow<Long> get() = engine.balanceSats

    /** Confirmed / pending-receive / pending-send, once a live read answered. */
    val balanceDetails: StateFlow<CashuBalance?> get() = engine.balance

    /** Wallet events (both directions; consumers filter). */
    val paymentEvents: SharedFlow<WalletPaymentEvent> get() = engine.paymentEvents

    /** THE published Cashu offer, or null while unknown. */
    val offerFlow: StateFlow<String?> get() = engine.offer

    fun currentOffer(): String? = engine.offer.value

    /** True while connected to the mint. */
    val onlineFlow: StateFlow<Boolean> get() = engine.online

    fun isOpen(): Boolean = engine.isOpen()

    /** The reusable BOLT12 offer to receive payments. */
    suspend fun createOffer(): String = engine.receiveOffer()

    /**
     * A one-time BOLT11 invoice for [amountSats] (FFI `receive_invoice`), for
     * wallets that cannot pay the reusable offer. Off the caller's thread;
     * typed refusal, never a throw.
     */
    suspend fun receiveInvoice(amountSats: Long): WalletOutcome<CashuInvoice> =
        engine.receiveInvoice(amountSats)

    /**
     * The mint's fee reserve for paying [amountSats] to [destination]
     * (amountSats=0 ⇒ the invoice's own amount), via FFI `prepare_send`. The
     * quote is discarded — [send] prepares again, and the fee shown from this
     * one is the ceiling that send enforces (`maxFeeSats`). Off the caller's
     * thread.
     */
    suspend fun quoteFee(destination: String, amountSats: Long): WalletOutcome<Long> =
        engine.quoteFee(destination, amountSats)

    /**
     * Pay a destination. amountSats=0 ⇒ amount from the invoice. See [SendResult.pending].
     *
     * [maxFeeSats] is required on purpose: every caller states the fee the
     * user agreed to (the send sheet's "up to N", 0 when it showed none), or
     * null when no fee was ever shown for this path. A higher fee is refused
     * as [SendErrorKind.FeeChanged] — see [CashuWalletEngine.send].
     */
    suspend fun send(
        destination: String,
        amountSats: Long,
        note: String,
        maxFeeSats: Long?,
        feeFromAmount: Boolean = false,
        onQuoted: ((paymentId: String) -> Unit)? = null,
    ): SendResult = engine.send(destination, amountSats, note, feeFromAmount, maxFeeSats, onQuoted)

    suspend fun lookupPayment(id: String): CashuPayment? = engine.lookupPayment(id)

    fun onForeground() = engine.onForeground()
    fun onBackground() = engine.onBackground()

    /** Fetch + cache live BTC→fiat rates (Yadio, via the FFI). */
    suspend fun fetchRates(): List<ExchangeRate> = withContext(Dispatchers.IO) {
        runCatching { ratesSource() }
            .onSuccess { list -> rates = list.associateBy { it.currency.uppercase() } }
            .getOrElse { rates.values.toList() }
    }

    /** Cached rate for a currency (null until [fetchRates] succeeds). */
    fun cachedRate(currency: FiatCurrency): ExchangeRate? = rates[currency.code]

    /**
     * True only when a usable live rate is cached for the selected currency
     * (iOS `hasLiveRate`). The UI shows fiat ONLY when this is true.
     */
    fun hasLiveRate(): Boolean = Money.isLiveRate(rates[currency().code])

    // ── Display preferences (persisted; not wallet-owned) ──
    fun showFiat(): Boolean = WalletDisplayPrefs.showFiat()
    fun setShowFiat(value: Boolean) = WalletDisplayPrefs.setShowFiat(value)
    fun currency(): FiatCurrency = FiatCurrency.of(WalletDisplayPrefs.currencyCode())
    fun setCurrency(value: FiatCurrency) = WalletDisplayPrefs.setCurrencyCode(value.code)

    /**
     * Account replacement: disconnect and detach, KEEPING
     * `sonar-cashu/<accountId>/` on disk. Throws while a send is in flight.
     */
    suspend fun shutdown() = engine.release()

    /** Panic wipe: every `sonar-cashu/` store goes. Throws if any remains. */
    suspend fun wipeLocalStorage() {
        rates = emptyMap()
        engine.wipeAll()
    }
}

/** The account's relays, through the core node. */
private object NostrOfferBackups : OfferBackupRelay {
    override suspend fun fetch(): List<String>? = chat.bitchat.sonar.SonarCore.fetchWalletOfferBackups()
    override suspend fun publish(backup: String): Boolean =
        chat.bitchat.sonar.SonarCore.publishWalletOfferBackup(backup)
}
