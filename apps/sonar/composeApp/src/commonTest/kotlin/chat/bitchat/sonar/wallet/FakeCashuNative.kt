package chat.bitchat.sonar.wallet

import chat.bitchat.sonar.ConcurrencyLock

/**
 * Scriptable [CashuNative] for engine and app-state tests. Every call is
 * recorded (with an optional [onCall] hook the JVM tests use to assert the
 * calling thread). Defaults model a healthy wallet with a stable offer.
 */
class FakeCashuNative(
    var offer: String? = "lno1fakeoffer",
    var confirmedSats: Long = 0L,
    var feeReserveSats: Long = 2L,
) : CashuNative {
    private val lock = ConcurrencyLock()
    private val recorded = mutableListOf<String>()

    /** Called at the start of every native call with its name. */
    var onCall: (String) -> Unit = {}

    /** Thrown by [connect] (e.g. Network for "mint offline"). */
    var connectError: (() -> CashuWalletException)? = null
    /** Thrown by [receiveOffer] when set (e.g. NotConnected before the first connect). */
    var offerError: (() -> CashuWalletException)? = null
    /** Thrown by [prepareSend] when set. */
    var prepareError: (() -> CashuWalletException)? = null
    /** The status `send` answers with. */
    var sendStatus: CashuPaymentStatus = CashuPaymentStatus.Complete
    var sendPreimage: String? = "preimage-1"

    @Volatile var connected = false
    @Volatile private var listener: ((CashuEvent) -> Unit)? = null
    var closed = false
        private set
    var wiped = false
        private set
    private var quoteSeq = 0
    private val payments = mutableMapOf<String, CashuPayment>()

    val calls: List<String> get() = lock.withLock { recorded.toList() }
    fun count(name: String): Int = calls.count { it == name }

    private fun record(name: String) {
        onCall(name)
        lock.withLock { recorded += name }
    }

    /** Resolve a stored payment WITHOUT an event (what a lookup after a restart sees). */
    fun settleSilently(id: String, status: CashuPaymentStatus, preimage: String? = null) {
        payments[id]?.let { payments[id] = it.copy(status = status, preimage = preimage) }
    }

    /** Deliver a wallet event as the native wallet thread would. */
    fun emit(event: CashuEvent) {
        if (event is CashuEvent.PaymentSent) payments[event.payment.id] = event.payment
        if (event is CashuEvent.PaymentFailed) payments[event.payment.id] = event.payment
        listener?.invoke(event)
    }

    override fun connect() {
        record("connect")
        connectError?.let { throw it() }
        connected = true
    }

    override fun disconnect() {
        record("disconnect")
        connected = false
    }

    override fun isConnected(): Boolean {
        record("isConnected")
        return connected
    }

    override fun balance(): CashuBalance {
        record("balance")
        if (!connected) throw CashuWalletException.NotConnected()
        return CashuBalance(confirmedSats, 0L, 0L)
    }

    override fun sync() {
        record("sync")
        if (!connected) throw CashuWalletException.NotConnected()
    }

    override fun receiveOffer(): String {
        record("receiveOffer")
        offerError?.let { throw it() }
        return offer ?: throw CashuWalletException.NotConnected()
    }

    override fun receiveInvoice(amountSats: Long, description: String?): String {
        record("receiveInvoice")
        return "lnbc${amountSats}fake"
    }

    override fun parseDestination(input: String): CashuDestination {
        record("parseDestination")
        return CashuDestination(input, CashuDestinationKind.Bolt12Offer, null)
    }

    override fun prepareSend(destination: String, amountSats: Long?): CashuPreparedSend {
        record("prepareSend")
        if (!connected) throw CashuWalletException.NotConnected()
        prepareError?.let { throw it() }
        quoteSeq += 1
        return CashuPreparedSend(
            quoteId = "quote-$quoteSeq",
            destination = destination,
            kind = CashuDestinationKind.Bolt12Offer,
            amountSats = amountSats ?: 0L,
            feesSats = feeReserveSats,
        )
    }

    /** Amounts `send` was actually called with (what really left). */
    val sentAmounts = mutableListOf<Long>()

    override fun send(prepared: CashuPreparedSend, note: String): CashuPayment {
        record("send")
        if (!connected) throw CashuWalletException.NotConnected()
        sentAmounts += prepared.amountSats
        val p = CashuPayment(
            id = prepared.quoteId,
            incoming = false,
            amountSats = prepared.amountSats,
            feesSats = 1L,
            timestampSecs = 1_700_000_000L,
            status = sendStatus,
            preimage = if (sendStatus == CashuPaymentStatus.Complete) sendPreimage else null,
            note = note,
        )
        payments[p.id] = p
        if (sendStatus == CashuPaymentStatus.Complete) confirmedSats -= prepared.amountSats + 1
        return p
    }

    override fun listPayments(limit: Int): List<CashuPayment> {
        record("listPayments")
        return payments.values.toList().take(limit)
    }

    override fun lookupPayment(id: String): CashuPayment? {
        record("lookupPayment")
        return payments[id]
    }

    override fun setListener(listener: (CashuEvent) -> Unit) {
        record("setListener")
        this.listener = listener
    }

    override fun clearListener() {
        record("clearListener")
        listener = null
    }

    override fun wipeLocalStorage() {
        record("wipeLocalStorage")
        check(!connected) { "refused while connected" }
        wiped = true
    }

    override fun close() {
        record("close")
        closed = true
    }
}

/** In-memory [WalletPrefs]. */
class MapWalletPrefs(initial: Map<String, String> = emptyMap()) : WalletPrefs {
    private val lock = ConcurrencyLock()
    private val map = initial.toMutableMap()
    override fun get(key: String): String? = lock.withLock { map[key] }
    override fun put(key: String, value: String) = lock.withLock { map[key] = value }
    override fun remove(key: String) { lock.withLock { map.remove(key) } }
    fun snapshot(): Map<String, String> = lock.withLock { map.toMap() }
}

/** [WalletFileOps] that records deletes and owns no disk. */
class RecordingWalletFiles : WalletFileOps {
    val deleted = mutableListOf<String>()
    val written = mutableMapOf<String, String>()
    override fun exists(path: String) = written.containsKey(path)
    override fun hasEntries(path: String) = written.keys.any { it.startsWith("$path/") }
    override fun deleteTree(path: String): Boolean {
        deleted += path
        written.keys.removeAll { it == path || it.startsWith("$path/") }
        return true
    }
    override fun rename(from: String, to: String) = false
    override fun readText(path: String) = written[path]
    override fun writeText(path: String, text: String): Boolean { written[path] = text; return true }
}
