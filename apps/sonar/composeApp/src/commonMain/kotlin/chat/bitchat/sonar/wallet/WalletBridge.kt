package chat.bitchat.sonar.wallet

/** Lightning wallet lifecycle state, mirrored from the iOS WalletBridgeService. */
sealed interface WalletState {
    /** No API key, or not yet asked to set up. */
    data object NotConfigured : WalletState
    data object SettingUp : WalletState
    data class Ready(val balanceSats: Long) : WalletState
    data class Failed(val message: String) : WalletState
}

/** Result of a wallet send: success flag plus the Lightning preimage when available. */
data class SendResult(val ok: Boolean, val preimage: String? = null)

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

    /** A reusable BOLT12 offer string to receive payments. */
    suspend fun createOffer(): String

    /** Pay a destination (BOLT11/BOLT12/LNURL/BIP-353). amountSats=0 ⇒ amount from
     *  the invoice/offer. Returns [SendResult] with preimage when available. */
    suspend fun send(destination: String, amountSats: Long, note: String): SendResult

    /** Fetch + cache live BTC→fiat rates. */
    suspend fun fetchRates(): List<ExchangeRate>

    /** Cached rate for a currency (null until [fetchRates] succeeds). */
    fun cachedRate(currency: FiatCurrency): ExchangeRate?

    // ── Display preferences (persisted) ──
    fun showFiat(): Boolean
    fun setShowFiat(value: Boolean)
    fun currency(): FiatCurrency
    fun setCurrency(value: FiatCurrency)

    /** Disconnect (on wipe). */
    suspend fun shutdown()
}
