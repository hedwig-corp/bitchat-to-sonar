package chat.bitchat.sonar.wallet

import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.runBlocking
import uniffi.sonar_ffi.HostMigrationSource
import uniffi.sonar_ffi.HostPayment
import uniffi.sonar_ffi.HostSendQuote
import uniffi.sonar_ffi.SonarFfiException

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
            ?: throw SonarFfiException.Core("the Lightning wallet could not price this payment")
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
            throw SonarFfiException.Core(result.error ?: "the Lightning payment failed")
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
