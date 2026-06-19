package chat.bitchat.sonar.wallet

import android.content.Context
import breez_sdk_liquid.BindingLiquidSdk
import breez_sdk_liquid.ConnectRequest
import breez_sdk_liquid.LiquidNetwork
import breez_sdk_liquid.PayAmount
import breez_sdk_liquid.PaymentMethod
import breez_sdk_liquid.PrepareReceiveRequest
import breez_sdk_liquid.PrepareSendRequest
import breez_sdk_liquid.ReceivePaymentRequest
import breez_sdk_liquid.PaymentDetails
import breez_sdk_liquid.SendPaymentRequest
import breez_sdk_liquid.connect
import breez_sdk_liquid.defaultConfig
import chat.bitchat.sonar.AppContextHolder
import chat.bitchat.sonar.BuildConfig
import chat.bitchat.sonar.crypto.Bech32
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
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

    private val lock = Mutex()
    @Volatile private var sdk: BindingLiquidSdk? = null
    @Volatile private var current: WalletState = WalletState.NotConfigured
    @Volatile private var rates: Map<String, ExchangeRate> = emptyMap()

    private val ctx: Context get() = AppContextHolder.ctx
    private fun prefs() = ctx.getSharedPreferences("sonar", Context.MODE_PRIVATE)

    private fun apiKey(): String = BuildConfig.BREEZ_API_KEY.trim()

    actual fun isAvailable(): Boolean = apiKey().isNotEmpty()

    actual fun state(): WalletState = current

    actual suspend fun setupIfNeeded(nsec: String): Unit = withContext(Dispatchers.IO) {
        lock.withLock {
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
                    val node = connect(ConnectRequest(config, null, null, seed.map { it.toUByte() }))
                    node to node.getInfo().walletInfo.balanceSat.toLong()
                }
                runCatching { withTimeoutOrNull(20_000) { work.await() } }
                    .also { if (it.getOrNull() == null) work.cancel() }
            }
            current = when {
                outcome.isFailure -> WalletState.Failed(outcome.exceptionOrNull()?.message ?: "wallet setup failed")
                outcome.getOrNull() == null -> WalletState.Failed("wallet setup timed out")
                else -> outcome.getOrThrow()!!.let { (node, bal) -> sdk = node; WalletState.Ready(bal) }
            }
        }
    }

    actual suspend fun refreshBalance(): Long = withContext(Dispatchers.IO) {
        val node = sdk ?: return@withContext 0L
        try {
            val bal = node.getInfo().walletInfo.balanceSat.toLong()
            current = WalletState.Ready(bal)
            bal
        } catch (t: Throwable) { (current as? WalletState.Ready)?.balanceSats ?: 0L }
    }

    actual suspend fun createOffer(): String = withContext(Dispatchers.IO) {
        val node = sdk ?: error("wallet not ready")
        // Amountless reusable BOLT12 offer.
        val prepared = node.prepareReceivePayment(
            PrepareReceiveRequest(PaymentMethod.BOLT12_OFFER, null)
        )
        node.receivePayment(ReceivePaymentRequest(prepared, "Sonar", null, null)).destination
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
                val preimage = (resp.payment.details as? PaymentDetails.Lightning)?.preimage
                refreshBalance()
                SendResult(true, preimage)
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

    actual fun showFiat(): Boolean = prefs().getBoolean("wallet.showFiat", false)
    actual fun setShowFiat(value: Boolean) { prefs().edit().putBoolean("wallet.showFiat", value).apply() }

    actual fun currency(): FiatCurrency = FiatCurrency.of(prefs().getString("wallet.currency", "USD"))
    actual fun setCurrency(value: FiatCurrency) { prefs().edit().putString("wallet.currency", value.code).apply() }

    actual suspend fun shutdown(): Unit = withContext(Dispatchers.IO) {
        lock.withLock {
            try { sdk?.disconnect() } catch (_: Throwable) {}
            sdk = null
            current = WalletState.NotConfigured
            rates = emptyMap()
        }
    }
}
