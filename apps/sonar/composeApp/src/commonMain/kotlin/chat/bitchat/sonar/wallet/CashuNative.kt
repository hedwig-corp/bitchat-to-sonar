package chat.bitchat.sonar.wallet

import chat.bitchat.sonar.crypto.Sha256

/**
 * Common view of the Rust `SonarCashuWallet` (core/sonar-ffi/src/wallet.rs).
 *
 * UniFFI generates the Kotlin bindings once per target (androidMain and
 * jvmMain each get their own `uniffi.sonar_ffi` copy), so common code cannot
 * name them. This is the 1:1 seam: the `actual`s in `CashuNative.android.kt`
 * and `CashuNative.jvm.kt` forward every call and translate
 * `WalletFfiException` into [CashuWalletException], and everything above them
 * (the engine, the app state, the tests) speaks only these types.
 *
 * EVERY method blocks (mint round-trips, store I/O). Callers run them on an
 * IO dispatcher; [CashuWalletEngine] is the only production caller.
 */
interface CashuNative {
    /** Mint info, NUT-13 restore when owed, crash recovery, watcher. Idempotent. */
    fun connect()
    fun disconnect()
    fun isConnected(): Boolean
    /** Local store read; requires [connect]. */
    fun balance(): CashuBalance
    fun sync()
    /** THE published offer. Stable; answered from disk once it exists. */
    fun receiveOffer(): String
    fun receiveInvoice(amountSats: Long, description: String?): String
    fun parseDestination(input: String): CashuDestination
    fun prepareSend(destination: String, amountSats: Long?): CashuPreparedSend
    /** `status == Pending` is NOT a failure; see [CashuPaymentStatus.Pending]. */
    fun send(prepared: CashuPreparedSend, note: String): CashuPayment
    fun listPayments(limit: Int): List<CashuPayment>
    fun lookupPayment(id: String): CashuPayment?
    /** Events arrive on a wallet thread, never the caller's. */
    fun setListener(listener: (CashuEvent) -> Unit)
    fun clearListener()
    /** Refused while connected. Panic wipe only. */
    fun wipeLocalStorage()
    /** Release the native handle. Safe to call more than once. */
    fun close()
}

data class CashuBalance(
    /** Spendable now. */
    val confirmedSats: Long,
    /** Paid to us at the mint, not yet minted into proofs. */
    val pendingReceiveSats: Long,
    /** Inputs of an in-flight or prepared payment. */
    val pendingSendSats: Long,
)

enum class CashuPaymentStatus {
    /**
     * In flight. NOT a failure: the outcome arrives later as an event with the
     * same id. Never retry a Pending send with a new quote — that can pay twice.
     */
    Pending,
    Complete,
    Failed,
    Refundable,
}

data class CashuPayment(
    val id: String,
    val incoming: Boolean,
    /** Excluding fees. */
    val amountSats: Long,
    val feesSats: Long?,
    val timestampSecs: Long,
    val status: CashuPaymentStatus,
    /** Lightning preimage of an outgoing payment: the proof of payment. */
    val preimage: String?,
    val note: String?,
)

enum class CashuDestinationKind { Bolt11, Bolt12Offer, LightningAddress, LnurlPay, Unknown }

data class CashuDestination(val raw: String, val kind: CashuDestinationKind, val amountSats: Long?)

/** A priced send from `prepareSend`: pass it back unchanged to `send`. */
data class CashuPreparedSend(
    val quoteId: String,
    val destination: String,
    val kind: CashuDestinationKind,
    val amountSats: Long,
    /** The mint's fee RESERVE: the most the payment can cost on top of [amountSats]. */
    val feesSats: Long?,
)

sealed interface CashuEvent {
    data object Connected : CashuEvent
    data object Disconnected : CashuEvent
    /** State changed without a tracked payment: re-read balance and offer. */
    data object Synced : CashuEvent
    data class PaymentReceived(val payment: CashuPayment) : CashuEvent
    /** Also emitted with `status: Pending` while a send is in flight. */
    data class PaymentSent(val payment: CashuPayment) : CashuEvent
    data class PaymentFailed(val payment: CashuPayment) : CashuEvent
}

/**
 * Typed mirror of `WalletFfiError`. Callers branch on the subtype, never on
 * the message text.
 */
sealed class CashuWalletException(reason: String) : Exception(reason) {
    class NotConnected : CashuWalletException("wallet is not connected")
    class Busy(val reason: String) : CashuWalletException("wallet is busy: $reason")
    class Unsupported(val reason: String) : CashuWalletException("not supported: $reason")
    class InvalidDestination(val reason: String) : CashuWalletException("invalid destination: $reason")
    class InsufficientFunds : CashuWalletException("insufficient funds")
    class InvalidInput(val reason: String) : CashuWalletException("invalid input: $reason")
    class Network(val reason: String) : CashuWalletException("network error: $reason")
    class Timeout : CashuWalletException("wallet operation timed out")
    class Backend(val reason: String) : CashuWalletException("wallet error: $reason")

    /** The mint is unreachable (or we are not connected yet): retry later. */
    val isOffline: Boolean get() = this is NotConnected || this is Network || this is Timeout
}

/**
 * Construct the platform wallet. LOCAL ONLY — no network, no store I/O until
 * [CashuNative.connect]. Throws [CashuWalletException.InvalidInput] for a bad
 * nsec or an empty dir.
 */
expect fun openCashuNative(nsec: String, mintUrl: String, workingDir: String): CashuNative

/** Yadio display rates through the FFI (`fetch_fiat_rates`). Blocking, ≤10s. */
expect fun fetchFiatRatesNative(): List<ExchangeRate>

/**
 * The platform's wallet storage root: Android `filesDir`, desktop the
 * `DesktopEnv` data dir. `sonar-cashu/` and the legacy `sonar-wallet/` live
 * directly under it.
 */
expect fun walletStorageRoot(): String

/** Sonar's mint. */
const val CASHU_MINT_URL = "https://mint.hedwig.sh"

/** Host shown in the custody line. */
const val CASHU_MINT_HOST = "mint.hedwig.sh"

/** Directory (under [walletStorageRoot]) holding every account's Cashu store. */
const val CASHU_ROOT_DIR = "sonar-cashu"

/**
 * THE per-account id every platform keys wallet storage on: lower-case hex of
 * the first 16 bytes of SHA-256(nsec as UTF-8), 32 chars. The nsec is the
 * bech32 `nsec1…` string the app exports. Must stay byte-identical to iOS —
 * devices that ran earlier test builds already have stores under these ids.
 */
fun cashuAccountId(nsec: String): String =
    Sha256.hash(nsec.encodeToByteArray())
        .copyOf(16)
        .joinToString("") { ((it.toInt() and 0xFF) + 0x100).toString(16).substring(1) }

/** `<root>/sonar-cashu/<accountId>/mainnet` — the dir the FFI must be handed. */
fun cashuWorkingDir(root: String, accountId: String): String =
    "${root.trimEnd('/')}/$CASHU_ROOT_DIR/$accountId/mainnet"
