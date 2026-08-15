package chat.bitchat.sonar.wallet

import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.runBlocking
import uniffi.sonar_ffi.HostMigrationSource
import uniffi.sonar_ffi.HostPayment
import uniffi.sonar_ffi.HostSendQuote
import uniffi.sonar_ffi.HostWalletException

/**
 * Breez reports "cannot afford it" only as prose, with no code to switch on,
 * so the classification has to be textual. Matching too broadly is the safer
 * failure here: a false positive costs one extra, smaller quote attempt; a
 * false negative aborts the whole migration.
 */
private fun looksInsufficient(message: String): Boolean =
    message.contains("not enough funds", ignoreCase = true) ||
        message.contains("insufficient", ignoreCase = true) ||
        message.contains("balance too low", ignoreCase = true)

/**
 * Breez→Cashu migration source on Android.
 *
 * The engine is Rust (`sonar-wallet-migrate`, exposed as `SonarMigration`).
 * Breez cannot live in that library — its forked SQLite would collide with the
 * SQLCipher core — so this supplies the SOURCE side over the app's existing
 * [WalletBridge] Breez integration.
 *
 * Threading contract: the trait methods are called synchronously from the Rust
 * thread that invoked plan/execute, so they block via [runBlocking]. Callers
 * must therefore invoke the engine from `Dispatchers.IO`, never the main
 * dispatcher.
 *
 * Error contract: throw [HostWalletException.InsufficientFunds] when the
 * wallet cannot afford the amount — the engine treats it as the signal to plan
 * a smaller one — and [HostWalletException.Failed] for anything else, which
 * aborts the migration.
 */
class BreezMigrationSource : HostMigrationSource {

    /**
     * Amount per quote token. [WalletBridge.SendResult] does not carry the
     * amount, and the engine needs it back on the payment, so it is remembered
     * at prepare time. Bounded by the bridge's own quote cap.
     */
    private val quotedAmounts = ConcurrentHashMap<String, ULong>()

    override fun `balanceSats`(): ULong = runBlocking {
        // Any throw here crosses a flat-error FFI boundary and reaches the
        // engine as "Can't lift flat errors" with the cause erased, so it has
        // to be logged on this side to be diagnosable at all.
        try {
            val sats = WalletBridge.refreshBalance()
            android.util.Log.i("SonarWallet", "migration balanceSats -> $sats")
            if (sats < 0) 0uL else sats.toULong()
        } catch (t: Throwable) {
            android.util.Log.w("SonarWallet", "migration balanceSats failed: ${t.message ?: t}")
            throw HostWalletException.Failed(t.message ?: t.toString())
        }
    }

    override fun `prepare`(invoice: String, amountSats: ULong): HostSendQuote = runBlocking {
        val quote = WalletBridge.prepareSend(invoice, amountSats.toLong())
            ?: run {
                val reason = WalletBridge.lastPrepareFailure()
                android.util.Log.w(
                    "SonarWallet",
                    "migration prepare($amountSats sats) got no quote: ${reason ?: "unknown"}",
                )
                // The engine plans a SMALLER amount when it is told the wallet
                // cannot afford this one, and gives up on anything else — so
                // this distinction decides whether a whole-balance drain can
                // succeed at all.
                throw if (reason != null && looksInsufficient(reason)) {
                    HostWalletException.InsufficientFunds()
                } else {
                    HostWalletException.Failed(
                        reason ?: "the Lightning wallet could not price this payment"
                    )
                }
            }
        val quoted = quote.amountSats.coerceAtLeast(0).toULong()
        quotedAmounts[quote.id] = quoted
        HostSendQuote(
            `amountSats` = quoted,
            `feesSats` = quote.feesSats?.coerceAtLeast(0)?.toULong(),
            `token` = quote.id,
        )
    }

    override fun `send`(token: String, note: String): HostPayment = runBlocking {
        val amount = quotedAmounts.remove(token) ?: 0uL
        val result = WalletBridge.sendPrepared(token, note)
        if (!result.ok) {
            val reason = result.error ?: "the Lightning payment failed"
            android.util.Log.w("SonarWallet", "migration send failed: $reason")
            throw if (looksInsufficient(reason)) {
                HostWalletException.InsufficientFunds()
            } else {
                HostWalletException.Failed(reason)
            }
        }
        HostPayment(
            `id` = result.paymentId ?: token,
            `amountSats` = amount,
            `feesSats` = result.feesSats?.coerceAtLeast(0)?.toULong(),
            // The bridge returns ok only once Breez accepted the payment.
            `complete` = true,
        )
    }
}
