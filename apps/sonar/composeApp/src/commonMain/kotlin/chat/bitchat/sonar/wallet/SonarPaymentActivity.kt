package chat.bitchat.sonar.wallet

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import chat.bitchat.sonar.PayEntry
import chat.bitchat.sonar.PayStatus
import chat.bitchat.sonar.SonarClock
import chat.bitchat.sonar.SonarCore
import chat.bitchat.sonar.crypto.Sha256

/**
 * Local activity for direct wallet payments — the Compose port of iOS
 * `SonarPaymentActivity` / `SonarPaymentActivityLedger` (SonarPayLedger.swift).
 *
 * Unlike the ⚡PAY [chat.bitchat.sonar.SonarPayLedger], this is not a claimable
 * chat state machine: money is paid directly by the wallet (Sonar metadata
 * BOLT12, Unify nearby, or an external incoming payment) and the wallet payment
 * id is the settlement link.
 */
data class SonarPaymentActivity(
    val id: String,
    val kind: Kind,
    /** Conversation key the payment belongs to (chat id, Unify peer id, or "wallet"). */
    val peerKey: String,
    val peerName: String,
    val direction: Direction,
    val sats: Long,
    /** Transport the payment context traveled over ("mesh"/"internet"). */
    val via: String,
    val createdAtSecs: Long,
    /** SHA-256 hex of the Lightning destination we paid (audit link; nil for incoming). */
    val destinationHash: String?,
    val status: Status,
    val walletPaymentId: String? = null,
    val feesSats: Long? = null,
    val settledAtSecs: Long? = null,
    val failure: String? = null,
    /**
     * Lightning preimage when the wallet surfaced one. Compose-only extension
     * over the iOS model: used to fold a walletIncoming row into the matching
     * chat ⚡PAY receipt on the merged activity screen (iOS keeps the incoming
     * stream idle in v1, so it never needs this dedupe).
     */
    val preimage: String? = null,
) {
    enum class Kind { SonarDirect, UnifyNearby, WalletIncoming }
    enum class Direction { Outgoing, Incoming }
    enum class Status { Pending, Paid, Failed }

    /** iOS sort key: settled time when known, else creation time. */
    val displaySecs: Long get() = settledAtSecs ?: createdAtSecs
}

/** SHA-256 hex of a Lightning destination (iOS `SonarAppStore.sha256Hex`). */
fun paymentDestinationHash(destination: String): String =
    Sha256.hash(destination.encodeToByteArray())
        .joinToString("") { ((it.toInt() and 0xFF) + 0x100).toString(16).substring(1) }

/**
 * Persisted ledger of direct wallet payment activity, keyed by activity id.
 * Mirrors iOS `SonarPaymentActivityLedger`: `recordPending` is idempotent
 * (same id records once), `markPaid`/`markFailed` only update existing rows.
 * Serialized to a blob (persisted via SonarCore.saveBlob by
 * [PaymentActivityStore]) in the same line-per-entry style as
 * [chat.bitchat.sonar.SonarPayLedger], with free-text fields hex-encoded so
 * names/errors with `|` or newlines can't corrupt the framing.
 */
class SonarPaymentActivityLedger(blob: String = "") {
    private val entries = LinkedHashMap<String, SonarPaymentActivity>()

    init {
        for (line in blob.split("\n")) {
            val a = decodeLine(line) ?: continue
            entries[a.id] = a
        }
    }

    fun all(): List<SonarPaymentActivity> = entries.values.toList()

    fun get(id: String): SonarPaymentActivity? = entries[id]

    /** Newest-first, iOS `sorted`: by settled time when known, else created. */
    fun sorted(): List<SonarPaymentActivity> =
        entries.values.sortedByDescending { it.displaySecs }

    fun activities(peerKey: String): List<SonarPaymentActivity> =
        sorted().filter { it.peerKey == peerKey }

    /** Records a new activity. Returns false (and changes nothing) when an
     *  entry with the same id already exists — idempotent like iOS. */
    fun recordPending(activity: SonarPaymentActivity): Boolean {
        if (entries.containsKey(activity.id)) return false
        entries[activity.id] = activity
        return true
    }

    /** Wallet settled — link the wallet payment and clear any failure. */
    fun markPaid(
        id: String,
        walletPaymentId: String?,
        feesSats: Long?,
        settledAtSecs: Long,
    ): Boolean {
        val e = entries[id] ?: return false
        entries[id] = e.copy(
            status = SonarPaymentActivity.Status.Paid,
            walletPaymentId = walletPaymentId ?: e.walletPaymentId,
            feesSats = feesSats ?: e.feesSats,
            settledAtSecs = settledAtSecs,
            failure = null,
        )
        return true
    }

    /** Wallet send failed. iOS stamps `settledAt = now` on failure too. */
    fun markFailed(id: String, message: String, nowSecs: Long): Boolean {
        val e = entries[id] ?: return false
        entries[id] = e.copy(
            status = SonarPaymentActivity.Status.Failed,
            failure = message,
            settledAtSecs = nowSecs,
        )
        return true
    }

    fun serialize(): String = entries.values.joinToString("\n") { encodeLine(it) }

    private companion object {
        // Wire tokens match the iOS Codable raw values for cross-reference.
        fun kindToken(k: SonarPaymentActivity.Kind) = when (k) {
            SonarPaymentActivity.Kind.SonarDirect -> "sonarDirect"
            SonarPaymentActivity.Kind.UnifyNearby -> "unifyNearby"
            SonarPaymentActivity.Kind.WalletIncoming -> "walletIncoming"
        }

        fun kindOf(t: String) = when (t) {
            "sonarDirect" -> SonarPaymentActivity.Kind.SonarDirect
            "unifyNearby" -> SonarPaymentActivity.Kind.UnifyNearby
            "walletIncoming" -> SonarPaymentActivity.Kind.WalletIncoming
            else -> null
        }

        fun statusToken(s: SonarPaymentActivity.Status) = when (s) {
            SonarPaymentActivity.Status.Pending -> "pending"
            SonarPaymentActivity.Status.Paid -> "paid"
            SonarPaymentActivity.Status.Failed -> "failed"
        }

        fun statusOf(t: String) = when (t) {
            "pending" -> SonarPaymentActivity.Status.Pending
            "paid" -> SonarPaymentActivity.Status.Paid
            "failed" -> SonarPaymentActivity.Status.Failed
            else -> null
        }

        fun encodeLine(a: SonarPaymentActivity): String = listOf(
            hexEnc(a.id),
            kindToken(a.kind),
            hexEnc(a.peerKey),
            hexEnc(a.peerName),
            if (a.direction == SonarPaymentActivity.Direction.Outgoing) "outgoing" else "incoming",
            a.sats.toString(),
            hexEnc(a.via),
            a.createdAtSecs.toString(),
            hexEnc(a.destinationHash.orEmpty()),
            statusToken(a.status),
            hexEnc(a.walletPaymentId.orEmpty()),
            a.feesSats?.toString().orEmpty(),
            a.settledAtSecs?.toString().orEmpty(),
            hexEnc(a.failure.orEmpty()),
            hexEnc(a.preimage.orEmpty()),
        ).joinToString("|")

        fun decodeLine(line: String): SonarPaymentActivity? {
            if (line.isBlank()) return null
            val p = line.split("|")
            if (p.size < 15) return null
            val id = hexDec(p[0])?.takeIf { it.isNotEmpty() } ?: return null
            val kind = kindOf(p[1]) ?: return null
            val direction = when (p[4]) {
                "outgoing" -> SonarPaymentActivity.Direction.Outgoing
                "incoming" -> SonarPaymentActivity.Direction.Incoming
                else -> return null
            }
            val sats = p[5].toLongOrNull() ?: return null
            val createdAt = p[7].toLongOrNull() ?: return null
            val status = statusOf(p[9]) ?: return null
            return SonarPaymentActivity(
                id = id,
                kind = kind,
                peerKey = hexDec(p[2]) ?: return null,
                peerName = hexDec(p[3]) ?: return null,
                direction = direction,
                sats = sats,
                via = hexDec(p[6]) ?: return null,
                createdAtSecs = createdAt,
                destinationHash = hexDec(p[8])?.ifEmpty { null },
                status = status,
                walletPaymentId = hexDec(p[10])?.ifEmpty { null },
                feesSats = p[11].toLongOrNull(),
                settledAtSecs = p[12].toLongOrNull(),
                failure = hexDec(p[13])?.ifEmpty { null },
                preimage = hexDec(p[14])?.ifEmpty { null },
            )
        }

        fun hexEnc(s: String): String =
            s.encodeToByteArray().joinToString("") { ((it.toInt() and 0xFF) + 0x100).toString(16).substring(1) }

        fun hexDec(s: String): String? {
            if (s.isEmpty()) return ""
            if (s.length % 2 != 0) return null
            val bytes = ByteArray(s.length / 2)
            for (i in bytes.indices) {
                val hi = s[2 * i].digitToIntOrNull(16) ?: return null
                val lo = s[2 * i + 1].digitToIntOrNull(16) ?: return null
                bytes[i] = ((hi shl 4) or lo).toByte()
            }
            return bytes.decodeToString()
        }
    }
}

/**
 * One row of the merged wallet Activity list: either a chat ⚡PAY receipt
 * ([PayEntry]) or a direct wallet payment ([SonarPaymentActivity]) projected
 * into the shape the iOS `SonarWalletActivityScreen` row renders (Sent/Received
 * title, Completed/Pending/Failed status, amount).
 */
data class WalletActivityItem(
    val id: String,
    val sent: Boolean,
    val sats: Long,
    val status: SonarPaymentActivity.Status,
    /** Sort key, newest first. 0 for legacy receipts persisted without a time. */
    val sortSecs: Long,
)

/**
 * Merge chat ⚡PAY receipts with direct wallet activity, newest first.
 * Dedupe rules:
 *  - a receipt whose uuid is also an activity id is dropped (direct Sonar
 *    sends record BOTH; the activity row carries the richer settlement state),
 *  - a receipt whose preimage matches an activity preimage is dropped (an
 *    incoming chat payment also fires the wallet's incoming-payment event).
 * The sort is stable, so legacy receipts without timestamps keep their
 * previous insertion order at the bottom of the list.
 */
fun mergeWalletActivity(
    receipts: List<PayEntry>,
    activities: List<SonarPaymentActivity>,
): List<WalletActivityItem> {
    val activityIds = activities.mapTo(HashSet()) { it.id }
    val activityPreimages = activities.mapNotNullTo(HashSet()) { it.preimage }
    val items = ArrayList<WalletActivityItem>(receipts.size + activities.size)
    for (a in activities) {
        items += WalletActivityItem(
            id = a.id,
            sent = a.direction == SonarPaymentActivity.Direction.Outgoing,
            sats = a.sats,
            status = a.status,
            sortSecs = a.displaySecs,
        )
    }
    for (r in receipts.asReversed()) {
        if (r.uuid in activityIds) continue
        if (r.preimage != null && r.preimage in activityPreimages) continue
        items += WalletActivityItem(
            id = r.uuid,
            sent = r.mine,
            sats = r.sats,
            status = when (r.status) {
                PayStatus.Claimed -> SonarPaymentActivity.Status.Paid
                PayStatus.Failed -> SonarPaymentActivity.Status.Failed
                PayStatus.Sealed, PayStatus.Claiming, PayStatus.Settling ->
                    SonarPaymentActivity.Status.Pending
            },
            sortSecs = r.tsSecs,
        )
    }
    return items.sortedByDescending { it.sortSecs } // stable: ties keep order
}

/**
 * App-wide holder of the payment activity ledger, persisting through
 * `SonarCore.saveBlob` like the ⚡PAY ledger ("pay.ledger" ⇄ "payment.activity").
 * [version] is a Compose state counter (the `payVersion` pattern) so screens
 * that read it recompose when the ledger changes. All mutators are expected on
 * the app's main scope (same threading contract as SonarAppState's payLedger).
 */
object PaymentActivityStore {
    private const val BLOB_KEY = "payment.activity"

    private var ledger: SonarPaymentActivityLedger? = null

    /** Bumped whenever the ledger changes, so activity UI recomposes. */
    var version by mutableStateOf(0)
        private set

    private fun ledger(): SonarPaymentActivityLedger =
        ledger ?: SonarPaymentActivityLedger(SonarCore.loadBlob(BLOB_KEY)).also { ledger = it }

    fun sorted(): List<SonarPaymentActivity> = ledger().sorted()

    fun activities(peerKey: String): List<SonarPaymentActivity> = ledger().activities(peerKey)

    fun get(id: String): SonarPaymentActivity? = ledger().get(id)

    fun recordPending(activity: SonarPaymentActivity): Boolean {
        if (!ledger().recordPending(activity)) return false
        persist(); version++
        return true
    }

    /** Record a settled INCOMING external wallet payment. Called at the event
     *  source (WalletBridge's Breez listener) so it lands even when there is no
     *  live UI collector — e.g. a killed/background FCM Breez wakeup where no
     *  SonarAppState exists. Idempotent on the stable wallet payment id, and
     *  persisted via saveBlob, so it survives the wakeup and is not double-
     *  recorded when the UI later observes the same event. No-op for outgoing. */
    fun recordIncomingWalletPayment(ev: WalletPaymentEvent) {
        if (!ev.incoming) return
        recordPending(
            SonarPaymentActivity(
                id = "wallet-${ev.paymentId}",
                kind = SonarPaymentActivity.Kind.WalletIncoming,
                peerKey = "wallet",
                peerName = "External wallet",
                direction = SonarPaymentActivity.Direction.Incoming,
                sats = ev.amountSats,
                via = "internet",
                createdAtSecs = ev.timestampSecs,
                destinationHash = null,
                status = SonarPaymentActivity.Status.Paid,
                walletPaymentId = ev.paymentId,
                feesSats = ev.feesSats,
                settledAtSecs = ev.timestampSecs,
                preimage = ev.preimage,
            )
        )
    }

    fun markPaid(
        id: String,
        walletPaymentId: String?,
        feesSats: Long?,
        settledAtSecs: Long = SonarClock.nowSecs(),
    ): Boolean {
        if (!ledger().markPaid(id, walletPaymentId, feesSats, settledAtSecs)) return false
        persist(); version++
        return true
    }

    fun markFailed(id: String, message: String, nowSecs: Long = SonarClock.nowSecs()): Boolean {
        if (!ledger().markFailed(id, message, nowSecs)) return false
        persist(); version++
        return true
    }

    /** Emergency wipe: forget every payment (iOS `wipe()`). */
    fun wipe() {
        ledger = SonarPaymentActivityLedger()
        SonarCore.saveBlob(BLOB_KEY, "")
        version++
    }

    private fun persist() {
        SonarCore.saveBlob(BLOB_KEY, ledger().serialize())
    }
}
