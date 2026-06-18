package chat.bitchat.sonar

import chat.bitchat.sonar.crypto.Sha256

const val SONAR_STICKERS_ENABLED_BY_DEFAULT = false
const val SONAR_STICKER_MESSAGE_MARKER = "[sonar-sticker-v1]"
const val SONAR_STICKER_PACK_FORMAT = "sonar-sticker-pack-v1"
const val SONAR_STICKER_PACK_KIND = 30030
const val SONAR_USER_STICKER_PACKS_KIND = 10030
const val SONAR_MAX_RECENT_STICKERS = 24
private const val SONAR_STICKER_STORE_SNAPSHOT_VERSION = "sonar-sticker-store-v1"

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

    fun parsePackEvent(kind: Int, pubkeyHex: String, tags: List<List<String>>): SonarStickerPack? {
        if (kind != SONAR_STICKER_PACK_KIND || !hasTagValue(tags, "pack_format", SONAR_STICKER_PACK_FORMAT)) {
            return null
        }
        val identifier = tagValue(tags, "d") ?: return null
        val title = tagValue(tags, "title") ?: return null
        val address = SonarStickerPackAddress(pubkeyHex, identifier).normalizedOrNull() ?: return null
        val imageTag = tags.firstOrNull { it.firstOrNull() == "image" }
        val cover = if (imageTag == null) null else parseCoverTag(imageTag) ?: return null
        val stickers = mutableListOf<SonarSticker>()
        for (tag in tags.filter { it.firstOrNull() == "sticker" }) {
            stickers += parseStickerTag(tag) ?: return null
        }
        return SonarStickerPack(
            address = address,
            title = title,
            description = tagValue(tags, "description"),
            cover = cover,
            stickers = stickers,
            license = tagValue(tags, "license"),
        ).normalizedOrNull()
    }

    fun parseInstalledPackList(kind: Int, tags: List<List<String>>): List<SonarStickerPackAddress> {
        if (kind != SONAR_USER_STICKER_PACKS_KIND) return emptyList()
        val seen = mutableSetOf<String>()
        val packs = mutableListOf<SonarStickerPackAddress>()
        for (coordinate in tags.filter { it.firstOrNull() == "a" }.mapNotNull { it.getOrNull(1) }) {
            val pack = SonarStickerPackAddress.parse(coordinate) ?: continue
            if (seen.add(pack.coordinate)) packs += pack
        }
        return packs
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

data class SonarStickerChoice(
    val pack: SonarStickerPack,
    val sticker: SonarSticker,
)

class SonarStickerStore {
    private val packsByCoordinate = mutableMapOf<String, SonarStickerPack>()
    private val recentRefs = mutableListOf<SonarStickerRef>()

    val installedPacks: List<SonarStickerPack>
        get() = packsByCoordinate.values.sortedBy { it.title.lowercase() }

    val hasInstalledPacks: Boolean
        get() = packsByCoordinate.isNotEmpty()

    val recentStickers: List<SonarStickerChoice>
        get() = recentRefs.mapNotNull { ref ->
            val pack = packsByCoordinate[ref.pack.coordinate] ?: return@mapNotNull null
            val sticker = pack.sticker(ref.shortcode) ?: return@mapNotNull null
            if (sticker.sha256 != ref.plaintextSha256) return@mapNotNull null
            SonarStickerChoice(pack, sticker)
        }

    fun install(pack: SonarStickerPack): Boolean {
        val clean = pack.normalizedOrNull() ?: return false
        packsByCoordinate[clean.address.coordinate] = clean
        return true
    }

    fun remove(address: SonarStickerPackAddress) {
        address.normalizedOrNull()?.let {
            packsByCoordinate.remove(it.coordinate)
            recentRefs.removeAll { ref -> ref.pack.coordinate == it.coordinate }
        }
    }

    fun clear() {
        packsByCoordinate.clear()
        recentRefs.clear()
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

    fun recordRecent(pack: SonarStickerPack, sticker: SonarSticker): Boolean {
        val ref = refFor(sticker, pack) ?: return false
        recentRefs.removeAll { it == ref }
        recentRefs.add(0, ref)
        while (recentRefs.size > SONAR_MAX_RECENT_STICKERS) {
            recentRefs.removeAt(recentRefs.lastIndex)
        }
        return true
    }

    fun exportSnapshot(): String {
        val lines = mutableListOf(SONAR_STICKER_STORE_SNAPSHOT_VERSION)
        for (pack in installedPacks) {
            lines += listOf(
                "pack",
                pack.address.coordinate,
                pack.title.snapshotHex(),
                pack.description.snapshotNullableHex(),
                pack.license.snapshotNullableHex(),
            ).joinToString("|")
            pack.cover?.let { cover ->
                lines += stickerSnapshotLine("cover", pack.address.coordinate, cover)
            }
            for (sticker in pack.stickers) {
                lines += stickerSnapshotLine("sticker", pack.address.coordinate, sticker)
            }
        }
        for (choice in recentStickers) {
            lines += listOf(
                "recent",
                choice.pack.address.coordinate,
                choice.sticker.shortcode.snapshotHex(),
                choice.sticker.sha256,
            ).joinToString("|")
        }
        return lines.joinToString("\n")
    }

    fun restoreSnapshot(snapshot: String): Boolean {
        val parsed = parseStickerStoreSnapshot(snapshot) ?: return false
        packsByCoordinate.clear()
        recentRefs.clear()
        for (pack in parsed.packs) {
            packsByCoordinate[pack.address.coordinate] = pack
        }
        for (ref in parsed.recentRefs) {
            if (recentRefs.size >= SONAR_MAX_RECENT_STICKERS) break
            if (resolve(ref).state == SonarStickerResolutionState.Resolved && ref !in recentRefs) {
                recentRefs += ref
            }
        }
        return true
    }
}

private data class StickerStoreSnapshot(
    val packs: List<SonarStickerPack>,
    val recentRefs: List<SonarStickerRef>,
)

private data class StickerPackSnapshotBuilder(
    val address: SonarStickerPackAddress,
    val title: String,
    val description: String?,
    val license: String?,
    var cover: SonarSticker? = null,
    val stickers: MutableList<SonarSticker> = mutableListOf(),
)

private fun stickerSnapshotLine(type: String, coordinate: String, sticker: SonarSticker): String =
    listOf(
        type,
        coordinate,
        sticker.shortcode.snapshotHex(),
        sticker.url.snapshotHex(),
        sticker.sha256,
        sticker.mime.snapshotHex(),
        sticker.width.snapshotNullableInt(),
        sticker.height.snapshotNullableInt(),
        sticker.alt.snapshotNullableHex(),
        sticker.emoji.snapshotNullableHex(),
    ).joinToString("|")

private fun parseStickerStoreSnapshot(snapshot: String): StickerStoreSnapshot? {
    val lines = snapshot.lines().filter { it.isNotBlank() }
    if (lines.firstOrNull() != SONAR_STICKER_STORE_SNAPSHOT_VERSION) return null
    val builders = linkedMapOf<String, StickerPackSnapshotBuilder>()
    val recentRefs = mutableListOf<SonarStickerRef>()

    for (line in lines.drop(1)) {
        val parts = line.split('|')
        when (parts.firstOrNull()) {
            "pack" -> {
                if (parts.size != 5) return null
                val address = SonarStickerPackAddress.parse(parts[1]) ?: return null
                if (builders.containsKey(address.coordinate)) return null
                builders[address.coordinate] = StickerPackSnapshotBuilder(
                    address = address,
                    title = parts[2].snapshotDecodeHex() ?: return null,
                    description = (parts[3].snapshotDecodeOptionalHex() ?: return null).value,
                    license = (parts[4].snapshotDecodeOptionalHex() ?: return null).value,
                )
            }
            "cover", "sticker" -> {
                if (parts.size != 10) return null
                val coordinate = parts[1]
                val builder = builders[coordinate] ?: return null
                val sticker = parseSnapshotSticker(parts) ?: return null
                if (parts[0] == "cover") {
                    if (builder.cover != null) return null
                    builder.cover = sticker
                } else {
                    builder.stickers += sticker
                }
            }
            "recent" -> {
                if (parts.size != 4) return null
                val address = SonarStickerPackAddress.parse(parts[1]) ?: return null
                val shortcode = parts[2].snapshotDecodeHex() ?: return null
                val ref = SonarStickerRef(address, shortcode, parts[3]).normalizedOrNull() ?: return null
                recentRefs += ref
            }
            else -> return null
        }
    }

    val packs = builders.values.map { builder ->
        SonarStickerPack(
            address = builder.address,
            title = builder.title,
            description = builder.description,
            cover = builder.cover,
            stickers = builder.stickers,
            license = builder.license,
        ).normalizedOrNull() ?: return null
    }
    val packCoordinates = packs.map { it.address.coordinate }.toSet()
    return StickerStoreSnapshot(
        packs = packs,
        recentRefs = recentRefs.filter { it.pack.coordinate in packCoordinates },
    )
}

private fun parseSnapshotSticker(parts: List<String>): SonarSticker? {
    return SonarSticker(
        shortcode = parts[2].snapshotDecodeHex() ?: return null,
        url = parts[3].snapshotDecodeHex() ?: return null,
        sha256 = parts[4],
        mime = parts[5].snapshotDecodeHex() ?: return null,
        width = (parts[6].snapshotDecodeOptionalInt() ?: return null).value,
        height = (parts[7].snapshotDecodeOptionalInt() ?: return null).value,
        alt = (parts[8].snapshotDecodeOptionalHex() ?: return null).value,
        emoji = (parts[9].snapshotDecodeOptionalHex() ?: return null).value,
    ).normalizedOrNull()
}

private fun String.snapshotHex(): String =
    encodeToByteArray().joinToString("") { byte -> (byte.toInt() and 0xff).toString(16).padStart(2, '0') }

private fun String?.snapshotNullableHex(): String =
    this?.snapshotHex() ?: "-"

private data class SnapshotOptionalString(val value: String?)

private data class SnapshotOptionalInt(val value: Int?)

private fun String.snapshotDecodeHex(): String? {
    if (length % 2 != 0) return null
    val bytes = ByteArray(length / 2)
    for (i in indices step 2) {
        val high = this[i].snapshotHexValue() ?: return null
        val low = this[i + 1].snapshotHexValue() ?: return null
        bytes[i / 2] = ((high shl 4) or low).toByte()
    }
    return runCatching { bytes.decodeToString(throwOnInvalidSequence = true) }.getOrNull()
}

private fun String.snapshotDecodeOptionalHex(): SnapshotOptionalString? {
    return if (this == "-") SnapshotOptionalString(null) else SnapshotOptionalString(snapshotDecodeHex() ?: return null)
}

private fun Int?.snapshotNullableInt(): String =
    this?.toString() ?: "-"

private fun String.snapshotDecodeOptionalInt(): SnapshotOptionalInt? {
    return if (this == "-") SnapshotOptionalInt(null) else SnapshotOptionalInt(toIntOrNull() ?: return null)
}

private fun Char.snapshotHexValue(): Int? =
    when (this) {
        in '0'..'9' -> code - '0'.code
        in 'a'..'f' -> code - 'a'.code + 10
        in 'A'..'F' -> code - 'A'.code + 10
        else -> null
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

private fun tagValue(tags: List<List<String>>, name: String): String? =
    tags.firstOrNull { it.firstOrNull() == name }?.getOrNull(1)

private fun hasTagValue(tags: List<List<String>>, name: String, value: String): Boolean =
    tags.any { it.firstOrNull() == name && it.getOrNull(1) == value }

private fun parseStickerTag(tag: List<String>): SonarSticker? {
    if (tag.size < 6) return null
    val (width, height) = parseStickerDim(tag.getOrNull(5).orEmpty()) ?: return null
    return SonarSticker(
        shortcode = tag[1],
        url = tag[2],
        sha256 = tag[3],
        mime = tag[4],
        width = width,
        height = height,
        alt = tag.getOrNull(6)?.takeIf { it.isNotEmpty() },
        emoji = tag.getOrNull(7)?.takeIf { it.isNotEmpty() },
    ).normalizedOrNull()
}

private fun parseCoverTag(tag: List<String>): SonarSticker? {
    if (tag.size < 3) return null
    val (width, height) = parseStickerDim(tag.getOrNull(3).orEmpty()) ?: return null
    return SonarSticker(
        shortcode = "cover",
        url = tag[1],
        sha256 = tag[2],
        mime = "image/webp",
        width = width,
        height = height,
        alt = "Sticker pack cover",
    ).normalizedOrNull()
}

private fun parseStickerDim(value: String): Pair<Int?, Int?>? {
    if (value.isEmpty()) return null to null
    val parts = value.split('x')
    if (parts.size != 2) return null
    return (parts[0].toIntOrNull() ?: return null) to (parts[1].toIntOrNull() ?: return null)
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
