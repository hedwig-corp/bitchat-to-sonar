package chat.bitchat.sonar

/** Attempts every delivery and returns only the items that failed, in order. */
internal inline fun <T> collectFailedDeliveries(
    items: List<T>,
    deliver: (T) -> Boolean,
): List<T> = buildList {
    for (item in items) {
        if (!deliver(item)) add(item)
    }
}

/** Small atomic FIFO used by one live transport lifetime.
 *
 * This is deliberately not a reconnect/outbox queue: the owner drains it on the
 * current link and discards/reports every entry when that link is torn down. */
internal class BoundedFifo<T>(private val capacity: Int) {
    private val entries = ArrayDeque<T>()

    init {
        require(capacity > 0) { "capacity must be positive" }
    }

    val size: Int get() = entries.size

    fun isNotEmpty(): Boolean = entries.isNotEmpty()

    fun tryAdd(value: T): Boolean {
        if (entries.size >= capacity) return false
        entries.addLast(value)
        return true
    }

    /** Adds [values] as one operation so a fragmented delivery is never partial. */
    fun tryAddAll(values: List<T>): Boolean {
        if (values.size > capacity - entries.size) return false
        entries.addAll(values)
        return true
    }

    fun removeFirstOrNull(): T? =
        if (entries.isEmpty()) null else entries.removeFirst()

    fun removeAll(predicate: (T) -> Boolean) {
        entries.removeAll(predicate)
    }

    fun drain(): List<T> = entries.toList().also { entries.clear() }
}

/** Latest-wins holding area for favorite controls awaiting a live mesh route. */
internal class PendingFavoriteControls {
    private val payloadByPeer = mutableMapOf<String, String>()

    fun clear() {
        payloadByPeer.clear()
    }

    fun peerIds(): List<String> = payloadByPeer.keys.toList()

    fun hold(peerId: String, payload: String) {
        payloadByPeer[normalizeSocialPeerId(peerId)] = payload
    }

    fun delivered(peerId: String) {
        payloadByPeer.remove(normalizeSocialPeerId(peerId))
    }

    fun discard(peerId: String) {
        payloadByPeer.remove(normalizeSocialPeerId(peerId))
    }

    /** Blocking is a trust boundary: stale social controls must not cross it. */
    fun payloadForFlush(peerId: String, blocked: Boolean): String? {
        val key = normalizeSocialPeerId(peerId)
        if (blocked) {
            payloadByPeer.remove(key)
            return null
        }
        return payloadByPeer[key]
    }
}
