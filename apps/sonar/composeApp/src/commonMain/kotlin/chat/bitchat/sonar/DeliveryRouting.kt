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
