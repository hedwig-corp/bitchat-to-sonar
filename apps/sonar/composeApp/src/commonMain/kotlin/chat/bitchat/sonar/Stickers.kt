package chat.bitchat.sonar

import chat.bitchat.sonar.crypto.Sha256

const val SONAR_STICKERS_ENABLED_BY_DEFAULT = false
const val SONAR_STICKER_MESSAGE_MARKER = "[sonar-sticker-v1]"

object SonarStickers {
    fun buildChatMessage(stickerRef: SonarStickerRef): String? {
        val clean = stickerRef.normalizedOrNull() ?: return null
        return "[sticker] $SONAR_STICKER_MESSAGE_MARKER pack=${clean.pack.coordinate} shortcode=${clean.shortcode} sha256=${clean.plaintextSha256}"
    }

    fun parseChatMessageOrNull(content: String): SonarStickerRef? {
        val trimmed = content.trim()
        if (!trimmed.startsWith("[sticker]")) return null
        var rest = trimmed.removePrefix("[sticker]").trimStart()
        if (!rest.startsWith(SONAR_STICKER_MESSAGE_MARKER)) return null
        rest = rest.removePrefix(SONAR_STICKER_MESSAGE_MARKER).trimStart()
        val fields = rest.split(Regex("\\s+")).filter { it.isNotBlank() }
        if (fields.size != 3) return null
        val pack = fields[0].removePrefixOrNull("pack=")?.let(SonarStickerPackAddress::parse) ?: return null
        val shortcode = fields[1].removePrefixOrNull("shortcode=") ?: return null
        val sha256 = fields[2].removePrefixOrNull("sha256=") ?: return null
        return SonarStickerRef(pack, shortcode, sha256).normalizedOrNull()
    }
}

data class SonarStickerPackAddress(
    val authorPubkeyHex: String,
    val identifier: String,
) {
    val coordinate: String get() = "30030:$authorPubkeyHex:$identifier"

    fun normalizedOrNull(): SonarStickerPackAddress? {
        val pubkey = authorPubkeyHex.lowercase()
        if (!pubkey.isHex(64) || !identifier.isStickerIdentifier()) return null
        return copy(authorPubkeyHex = pubkey)
    }

    companion object {
        fun parse(value: String): SonarStickerPackAddress? {
            val parts = value.split(':')
            if (parts.size != 3 || parts[0] != "30030") return null
            return SonarStickerPackAddress(parts[1], parts[2]).normalizedOrNull()
        }
    }
}

data class SonarSticker(
    val shortcode: String,
    val url: String,
    val sha256: String,
    val mime: String,
    val width: Int? = null,
    val height: Int? = null,
    val alt: String? = null,
    val emoji: String? = null,
) {
    fun normalizedOrNull(): SonarSticker? {
        val cleanHash = sha256.lowercase()
        val cleanMime = mime.lowercase()
        val cleanUrl = normalizeHttpsUrl(url) ?: return null
        if (!shortcode.isStickerShortcode()) return null
        if (!cleanHash.isHex(64)) return null
        if (cleanMime !in allowedMimes) return null
        if (!cleanUrl.blossomPathContains(cleanHash)) return null
        if (!validDimensions(width, height)) return null
        if ((alt?.length ?: 0) > 160) return null
        if ((emoji?.length ?: 0) > 8) return null
        return copy(
            url = cleanUrl,
            sha256 = cleanHash,
            mime = cleanMime,
            alt = alt?.trim()?.takeIf { it.isNotEmpty() },
            emoji = emoji?.trim()?.takeIf { it.isNotEmpty() },
        )
    }

    companion object {
        private val allowedMimes = setOf("image/webp", "image/png", "image/apng", "image/gif")

        private fun validDimensions(width: Int?, height: Int?): Boolean =
            when {
                width == null && height == null -> true
                width != null && height != null -> width in 1..4096 && height in 1..4096
                else -> false
            }
    }
}

data class SonarStickerPack(
    val address: SonarStickerPackAddress,
    val title: String,
    val description: String? = null,
    val cover: SonarSticker? = null,
    val stickers: List<SonarSticker>,
    val license: String? = null,
) {
    fun normalizedOrNull(): SonarStickerPack? {
        val cleanAddress = address.normalizedOrNull() ?: return null
        val cleanTitle = title.trim().split(Regex("\\s+")).joinToString(" ")
        if (cleanTitle.isEmpty() || cleanTitle.length > 80) return null
        if ((description?.length ?: 0) > 500) return null
        if (stickers.isEmpty() || stickers.size > 200) return null
        val cleanStickers = stickers.map { it.normalizedOrNull() ?: return null }
        if (cleanStickers.distinctBy { it.shortcode }.size != cleanStickers.size) return null
        if (cleanStickers.distinctBy { it.sha256 }.size != cleanStickers.size) return null
        return copy(
            address = cleanAddress,
            title = cleanTitle,
            description = description?.trim()?.takeIf { it.isNotEmpty() },
            cover = cover?.normalizedOrNull(),
            stickers = cleanStickers,
            license = license?.trim()?.takeIf { it.isNotEmpty() },
        )
    }

    fun sticker(shortcode: String): SonarSticker? =
        stickers.firstOrNull { it.shortcode == shortcode }
}

data class SonarStickerRef(
    val pack: SonarStickerPackAddress,
    val shortcode: String,
    val plaintextSha256: String,
) {
    fun normalizedOrNull(): SonarStickerRef? {
        val cleanPack = pack.normalizedOrNull() ?: return null
        val cleanHash = plaintextSha256.lowercase()
        if (!shortcode.isStickerShortcode() || !cleanHash.isHex(64)) return null
        return copy(pack = cleanPack, plaintextSha256 = cleanHash)
    }
}

enum class SonarStickerResolutionState { Resolved, MissingPack, MissingSticker, HashMismatch }

data class SonarStickerResolution(
    val state: SonarStickerResolutionState,
    val sticker: SonarSticker? = null,
)

class SonarStickerStore {
    private val packsByCoordinate = mutableMapOf<String, SonarStickerPack>()

    val installedPacks: List<SonarStickerPack>
        get() = packsByCoordinate.values.sortedBy { it.title.lowercase() }

    val hasInstalledPacks: Boolean
        get() = packsByCoordinate.isNotEmpty()

    fun install(pack: SonarStickerPack): Boolean {
        val clean = pack.normalizedOrNull() ?: return false
        packsByCoordinate[clean.address.coordinate] = clean
        return true
    }

    fun remove(address: SonarStickerPackAddress) {
        address.normalizedOrNull()?.let { packsByCoordinate.remove(it.coordinate) }
    }

    fun resolve(stickerRef: SonarStickerRef): SonarStickerResolution {
        val cleanRef = stickerRef.normalizedOrNull()
            ?: return SonarStickerResolution(SonarStickerResolutionState.MissingSticker)
        val pack = packsByCoordinate[cleanRef.pack.coordinate]
            ?: return SonarStickerResolution(SonarStickerResolutionState.MissingPack)
        val sticker = pack.sticker(cleanRef.shortcode)
            ?: return SonarStickerResolution(SonarStickerResolutionState.MissingSticker)
        if (sticker.sha256 != cleanRef.plaintextSha256) {
            return SonarStickerResolution(SonarStickerResolutionState.HashMismatch)
        }
        return SonarStickerResolution(SonarStickerResolutionState.Resolved, sticker)
    }

    fun refFor(sticker: SonarSticker, pack: SonarStickerPack): SonarStickerRef? {
        val installed = packsByCoordinate[pack.address.coordinate] ?: return null
        if (installed.sticker(sticker.shortcode) != sticker) return null
        return SonarStickerRef(
            pack = installed.address,
            shortcode = sticker.shortcode,
            plaintextSha256 = sticker.sha256,
        ).normalizedOrNull()
    }
}

class SonarStickerByteCache(
    private val maxStickerBytes: Int = DEFAULT_MAX_STICKER_BYTES,
) {
    private val bytesByHash = mutableMapOf<String, ByteArray>()

    fun putVerified(sticker: SonarSticker, bytes: ByteArray): Boolean {
        if (bytes.size > maxStickerBytes) return false
        if (Sha256.hash(bytes).toHexLower() != sticker.sha256) return false
        bytesByHash[sticker.sha256] = bytes.copyOf()
        return true
    }

    fun get(sticker: SonarSticker): ByteArray? =
        bytesByHash[sticker.sha256]?.copyOf()

    companion object {
        const val DEFAULT_MAX_STICKER_BYTES = 1024 * 1024
    }
}

expect object SonarStickerAssetFetcher {
    suspend fun fetch(url: String, maxBytes: Int): ByteArray?
}

private fun String.removePrefixOrNull(prefix: String): String? =
    takeIf { startsWith(prefix) }?.removePrefix(prefix)

private fun String.isStickerShortcode(): Boolean =
    isNotEmpty() && length <= 64 && all { it.isLetterOrDigit() && it.code < 128 || it == '_' }

private fun String.isStickerIdentifier(): Boolean =
    isNotEmpty() && length <= 80 && all {
        (it.isLetterOrDigit() && it.code < 128) || it == '-' || it == '.' || it == '_'
    }

private fun String.isHex(expectedLength: Int): Boolean =
    length == expectedLength && all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }

private fun String.blossomPathContains(sha256: String): Boolean {
    val pathStart = indexOf('/', startIndex = "https://".length)
    if (pathStart < 0) return false
    return substring(pathStart)
        .substringBefore('?')
        .substringBefore('#')
        .lowercase()
        .contains(sha256)
}

private fun ByteArray.toHexLower(): String =
    joinToString("") { ((it.toInt() and 0xFF) + 0x100).toString(16).substring(1) }
