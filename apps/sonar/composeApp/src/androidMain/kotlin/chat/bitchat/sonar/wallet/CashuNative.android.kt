package chat.bitchat.sonar.wallet

import chat.bitchat.sonar.AppContextHolder
import uniffi.sonar_ffi.CashuWalletEvent
import uniffi.sonar_ffi.CashuWalletListener
import uniffi.sonar_ffi.SonarCashuWallet
import uniffi.sonar_ffi.WalletDestinationKind
import uniffi.sonar_ffi.WalletFfiException
import uniffi.sonar_ffi.WalletPayment
import uniffi.sonar_ffi.WalletPaymentStatus
import uniffi.sonar_ffi.WalletPreparedSend
import uniffi.sonar_ffi.fetchFiatRates

/**
 * Android `actual`: a 1:1 forward onto the generated `SonarCashuWallet`
 * (core/sonar-ffi/src/wallet.rs). No policy lives here — see
 * [CashuWalletEngine]. Kept in step with `CashuNative.jvm.kt`, which forwards
 * onto its own copy of the same bindings.
 */
actual fun openCashuNative(nsec: String, mintUrl: String, workingDir: String): CashuNative =
    ffi { AndroidCashuNative(SonarCashuWallet(nsec, mintUrl, workingDir)) }

actual fun fetchFiatRatesNative(): List<ExchangeRate> =
    ffi { fetchFiatRates().map { ExchangeRate(it.currency.uppercase(), it.perBtc) } }

actual fun walletStorageRoot(): String = AppContextHolder.ctx.filesDir.absolutePath

private class AndroidCashuNative(private val w: SonarCashuWallet) : CashuNative {
    override fun connect() = ffi { w.connect() }
    override fun disconnect() = ffi { w.disconnect() }
    override fun isConnected(): Boolean = w.isConnected()
    override fun balance(): CashuBalance = ffi {
        w.balance().let {
            CashuBalance(
                confirmedSats = it.confirmedSats.toLong(),
                pendingReceiveSats = it.pendingReceiveSats.toLong(),
                pendingSendSats = it.pendingSendSats.toLong(),
            )
        }
    }
    override fun sync() = ffi { w.sync() }
    override fun receiveOffer(): String = ffi { w.receiveOffer() }
    override fun offerBackup(): String? = ffi { w.offerBackup() }
    override fun restoreOfferBackups(backups: List<String>): Int = ffi { w.restoreOfferBackups(backups).toInt() }
    override fun receiveInvoice(amountSats: Long, description: String?): CashuInvoice =
        ffi { w.receiveInvoice(amountSats.toULong(), description).let { CashuInvoice(it.invoice, it.paymentId) } }
    override fun parseDestination(input: String): CashuDestination = ffi {
        w.parseDestination(input).let { CashuDestination(it.raw, it.kind.common(), it.amountSats?.toLong()) }
    }
    override fun prepareSend(destination: String, amountSats: Long?): CashuPreparedSend = ffi {
        w.prepareSend(destination, amountSats?.toULong()).let {
            CashuPreparedSend(it.quoteId, it.destination, it.kind.common(), it.amountSats.toLong(), it.feesSats?.toLong())
        }
    }
    override fun send(prepared: CashuPreparedSend, note: String): CashuPayment = ffi {
        w.send(
            WalletPreparedSend(
                quoteId = prepared.quoteId,
                destination = prepared.destination,
                kind = prepared.kind.ffi(),
                amountSats = prepared.amountSats.toULong(),
                feesSats = prepared.feesSats?.toULong(),
            ),
            note,
        ).common()
    }
    override fun listPayments(limit: Int): List<CashuPayment> =
        ffi { w.listPayments(limit.coerceAtLeast(0).toUInt()).map { it.common() } }
    override fun lookupPayment(id: String): CashuPayment? = ffi { w.lookupPayment(id)?.common() }
    override fun setListener(listener: (CashuEvent) -> Unit) {
        w.setListener(object : CashuWalletListener {
            override fun onEvent(event: CashuWalletEvent) {
                // Never let a host exception unwind into the wallet thread.
                runCatching { listener(event.common()) }
            }
        })
    }
    override fun clearListener() = w.clearListener()
    override fun wipeLocalStorage() = ffi { w.wipeLocalStorage() }
    override fun close() = w.destroy()
}

private fun CashuWalletEvent.common(): CashuEvent = when (this) {
    CashuWalletEvent.Connected -> CashuEvent.Connected
    CashuWalletEvent.Disconnected -> CashuEvent.Disconnected
    CashuWalletEvent.Synced -> CashuEvent.Synced
    is CashuWalletEvent.PaymentReceived -> CashuEvent.PaymentReceived(payment.common())
    is CashuWalletEvent.PaymentSent -> CashuEvent.PaymentSent(payment.common())
    is CashuWalletEvent.PaymentFailed -> CashuEvent.PaymentFailed(payment.common())
}

private fun WalletPayment.common() = CashuPayment(
    id = id,
    incoming = incoming,
    amountSats = amountSats.toLong(),
    feesSats = feesSats?.toLong(),
    timestampSecs = timestampSecs.toLong(),
    status = when (status) {
        WalletPaymentStatus.PENDING -> CashuPaymentStatus.Pending
        WalletPaymentStatus.COMPLETE -> CashuPaymentStatus.Complete
        WalletPaymentStatus.FAILED -> CashuPaymentStatus.Failed
        WalletPaymentStatus.REFUNDABLE -> CashuPaymentStatus.Refundable
    },
    preimage = preimage,
    note = note,
)

private fun WalletDestinationKind.common() = when (this) {
    WalletDestinationKind.BOLT11 -> CashuDestinationKind.Bolt11
    WalletDestinationKind.BOLT12_OFFER -> CashuDestinationKind.Bolt12Offer
    WalletDestinationKind.LIGHTNING_ADDRESS -> CashuDestinationKind.LightningAddress
    WalletDestinationKind.LNURL_PAY -> CashuDestinationKind.LnurlPay
    WalletDestinationKind.UNKNOWN -> CashuDestinationKind.Unknown
}

private fun CashuDestinationKind.ffi() = when (this) {
    CashuDestinationKind.Bolt11 -> WalletDestinationKind.BOLT11
    CashuDestinationKind.Bolt12Offer -> WalletDestinationKind.BOLT12_OFFER
    CashuDestinationKind.LightningAddress -> WalletDestinationKind.LIGHTNING_ADDRESS
    CashuDestinationKind.LnurlPay -> WalletDestinationKind.LNURL_PAY
    CashuDestinationKind.Unknown -> WalletDestinationKind.UNKNOWN
}

/** Run an FFI call, re-throwing its typed error as the common type. */
private inline fun <T> ffi(block: () -> T): T =
    try {
        block()
    } catch (e: WalletFfiException) {
        throw e.common()
    }

internal fun WalletFfiException.common(): CashuWalletException = when (this) {
    is WalletFfiException.NotConnected -> CashuWalletException.NotConnected()
    is WalletFfiException.Busy -> CashuWalletException.Busy(reason)
    is WalletFfiException.Unsupported -> CashuWalletException.Unsupported(reason)
    is WalletFfiException.InvalidDestination -> CashuWalletException.InvalidDestination(reason)
    is WalletFfiException.InsufficientFunds -> CashuWalletException.InsufficientFunds()
    is WalletFfiException.InvalidInput -> CashuWalletException.InvalidInput(reason)
    is WalletFfiException.Network -> CashuWalletException.Network(reason)
    is WalletFfiException.Timeout -> CashuWalletException.Timeout()
    is WalletFfiException.Backend -> CashuWalletException.Backend(reason)
}
