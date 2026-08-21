package chat.bitchat.sonar.wallet

import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.runBlocking
import uniffi.sonar_ffi.HostMigrationSource
import uniffi.sonar_ffi.HostPayment
import uniffi.sonar_ffi.HostPaymentLookup
import uniffi.sonar_ffi.HostPaymentLookupStatus
import uniffi.sonar_ffi.HostSendQuote
import uniffi.sonar_ffi.HostWalletException

/**
 * Breez→Cashu migration source on Compose Desktop (JVM).
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
 */
/** Mirror of the Android classifier; see that file for why it is textual. */
private fun looksInsufficient(message: String): Boolean =
    message.contains("not enough funds", ignoreCase = true) ||
        message.contains("insufficient", ignoreCase = true) ||
        message.contains("balance too low", ignoreCase = true)

class BreezMigrationSource : HostMigrationSource {

    /**
     * Amount per quote token. [WalletBridge.SendResult] does not carry the
     * amount, and the engine needs it back on the payment, so it is remembered
     * at prepare time. Bounded by the bridge's own quote cap.
     */
    private val quotedAmounts = ConcurrentHashMap<String, ULong>()

    override fun `balanceSats`(): ULong = runBlocking {
        val sats = WalletBridge.refreshBalance()
        if (sats < 0) 0uL else sats.toULong()
    }

    override fun `prepare`(invoice: String, amountSats: ULong): HostSendQuote = runBlocking {
        val quote = WalletBridge.prepareSend(invoice, amountSats.toLong())
            ?: run {
                val reason = WalletBridge.lastPrepareFailure()
                // InsufficientFunds is the engine's signal to plan a smaller
                // amount; anything else aborts the migration.
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

    override fun `lookupPayment`(paymentHash: String): HostPaymentLookup = runBlocking {
        try {
            val lookup = WalletBridge.lookupPayment(paymentHash)
            HostPaymentLookup(
                status = when (lookup.status) {
                    WalletPaymentLookupStatus.Pending -> HostPaymentLookupStatus.PENDING
                    WalletPaymentLookupStatus.Complete -> HostPaymentLookupStatus.COMPLETE
                    WalletPaymentLookupStatus.Failed -> HostPaymentLookupStatus.FAILED
                    WalletPaymentLookupStatus.Refundable -> HostPaymentLookupStatus.REFUNDABLE
                    WalletPaymentLookupStatus.Unknown -> HostPaymentLookupStatus.UNKNOWN
                },
                id = lookup.id,
                feesSats = lookup.feesSats?.coerceAtLeast(0)?.toULong(),
            )
        } catch (t: Throwable) {
            throw HostWalletException.Failed(t.message ?: t.toString())
        }
    }
}
