package chat.bitchat.sonar

internal const val SOCIAL_STATE_BLOB_KEY = "sonar.social.v1"

internal data class SonarSocialState(
    val favoritePeers: Set<String> = emptySet(),
    val remoteFavoritePeers: Set<String> = emptySet(),
    val blockedPeers: Set<String> = emptySet(),
    val blockedNostrPubkeys: Set<String> = emptySet(),
) {
    fun isFavoritePeer(peerId: String): Boolean =
        normalizeSocialPeerId(peerId) in favoritePeers

    fun isBlockedPeer(peerId: String): Boolean =
        normalizeSocialPeerId(peerId) in blockedPeers

    fun isMutualFavorite(peerId: String): Boolean {
        val key = normalizeSocialPeerId(peerId)
        return key in favoritePeers && key in remoteFavoritePeers
    }

    fun isBlockedNostr(value: String): Boolean =
        normalizeSocialNostrKey(value)?.let { it in blockedNostrPubkeys } == true

    fun allowsChannelSender(senderPubkey: String, mine: Boolean): Boolean {
        if (mine) return true
        val nostr = normalizeSocialNostrKey(senderPubkey)
        return if (nostr != null) {
            nostr !in blockedNostrPubkeys
        } else {
            normalizeSocialPeerId(senderPubkey) !in blockedPeers
        }
    }

    fun allowsChatMessage(chatId: String, senderNpub: String, mine: Boolean): Boolean {
        if (mine) return true
        val peerId = chatId.takeIf { it.startsWith("mesh:") }?.let { normalizeSocialPeerId(it) }
        return senderNpub.let { it.isBlank() || !isBlockedNostr(it) } &&
            peerId?.let { it !in blockedPeers } != false
    }

    fun withFavoritePeer(peerId: String, favorite: Boolean): SonarSocialState {
        val key = normalizeSocialPeerId(peerId)
        return copy(favoritePeers = if (favorite) favoritePeers + key else favoritePeers - key)
    }

    fun withRemoteFavoritePeer(peerId: String, favorite: Boolean): SonarSocialState {
        val key = normalizeSocialPeerId(peerId)
        return copy(remoteFavoritePeers = if (favorite) remoteFavoritePeers + key else remoteFavoritePeers - key)
    }

    fun withBlockedPeer(peerId: String, blocked: Boolean): SonarSocialState {
        val key = normalizeSocialPeerId(peerId)
        return copy(blockedPeers = if (blocked) blockedPeers + key else blockedPeers - key)
    }

    fun withBlockedNostr(value: String, blocked: Boolean): SonarSocialState {
        val key = normalizeSocialNostrKey(value) ?: return this
        return copy(blockedNostrPubkeys = if (blocked) blockedNostrPubkeys + key else blockedNostrPubkeys - key)
    }
}

internal fun normalizeSocialPeerId(value: String): String =
    value.trim().removePrefix("mesh:").lowercase()

internal fun normalizeSocialNostrKey(value: String): String? {
    val clean = value.trim()
    if (clean.isBlank()) return null
    val decoded = chat.bitchat.sonar.crypto.Bech32.decode(clean)
    if (decoded?.hrp == "npub" && decoded.data.size == 32) return decoded.data.toHexLower()
    val hex = clean.hexBytesOrNull()
    return if (hex?.size == 32) hex.toHexLower() else null
}

internal fun encodeSonarSocialState(state: SonarSocialState): String =
    buildList {
        state.favoritePeers.sorted().forEach { add("fav\t$it") }
        state.remoteFavoritePeers.sorted().forEach { add("favRemote\t$it") }
        state.blockedPeers.sorted().forEach { add("blockPeer\t$it") }
        state.blockedNostrPubkeys.sorted().forEach { add("blockNostr\t$it") }
    }.joinToString("\n")

internal fun decodeSonarSocialState(blob: String): SonarSocialState {
    var state = SonarSocialState()
    blob.lineSequence().forEach { line ->
        if (line.isBlank()) return@forEach
        val parts = line.split("\t", limit = 2)
        if (parts.size != 2) return@forEach
        state = when (parts[0]) {
            "fav" -> state.withFavoritePeer(parts[1], true)
            "favRemote" -> state.withRemoteFavoritePeer(parts[1], true)
            "blockPeer" -> state.withBlockedPeer(parts[1], true)
            "blockNostr" -> state.withBlockedNostr(parts[1], true)
            else -> state
        }
    }
    return state
}

private fun ByteArray.toHexLower(): String =
    joinToString("") { (it.toInt() and 0xFF).toString(16).padStart(2, '0') }

private fun String.hexBytesOrNull(): ByteArray? {
    val clean = trim().removePrefix("0x").removePrefix("0X")
    if (clean.isEmpty() || clean.length % 2 != 0) return null
    val bytes = ByteArray(clean.length / 2)
    for (i in bytes.indices) {
        val hi = clean[2 * i].digitToIntOrNull(16) ?: return null
        val lo = clean[2 * i + 1].digitToIntOrNull(16) ?: return null
        bytes[i] = ((hi shl 4) or lo).toByte()
    }
    return bytes
}
