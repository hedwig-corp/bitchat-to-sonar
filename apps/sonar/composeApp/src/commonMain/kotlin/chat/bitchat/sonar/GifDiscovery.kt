package chat.bitchat.sonar

import chat.bitchat.sonar.crypto.Sha256

const val SONAR_GIF_CATALOG_NOSTR_KIND = 30078
const val SONAR_GIF_CATALOG_D_TAG = "sonar.gif.catalog.v1"
const val SONAR_GIF_CATALOG_SCHEMA = 1
const val SONAR_GIF_CATALOG_MAX_ITEMS = 64
const val SONAR_GIF_ITEM_MAX_BYTES = 25 * 1024 * 1024L

private const val APP_NAME = "sonar"
private const val CATALOG_TYPE = "gif_catalog"
private const val MAX_CATALOG_NAME = 80
private const val MAX_ITEM_TITLE = 80
private const val MAX_TOKEN = 64
private const val MAX_DIMENSION = 8192

private val allowedGifMimeTypes = setOf("image/gif", "video/mp4", "image/webp")

/** Provider-neutral GIF catalog. Nostr catalogs publish this as kind-30078 with
 *  `d=sonar.gif.catalog.v1`; third-party providers can map into the same shape. */
data class SonarGifCatalog(
    val id: String = SONAR_GIF_CATALOG_D_TAG,
    val name: String,
    val authorNpub: String? = null,
    val items: List<SonarGifItem>,
    val updatedAtSecs: Long? = null,
) {
    fun normalizedOrNull(): SonarGifCatalog? {
        val cleanName = cleanLabel(name, MAX_CATALOG_NAME) ?: return null
        val cleanId = cleanProtocolToken(id).ifBlank { SONAR_GIF_CATALOG_D_TAG }
        val cleanAuthor = authorNpub?.trim()?.takeIf { it.isNotEmpty() }
        val cleanItems = items
            .mapNotNull { it.normalizedOrNull() }
            .distinctBy { it.id }
            .take(SONAR_GIF_CATALOG_MAX_ITEMS)

        if (cleanItems.isEmpty()) return null

        return copy(
            id = cleanId,
            name = cleanName,
            authorNpub = cleanAuthor,
            items = cleanItems,
            updatedAtSecs = updatedAtSecs?.takeIf { it > 0 },
        )
    }

    /** JSON content for the public Nostr catalog event. Parsing is intentionally
     *  done by the Nostr/core layer later; this writer keeps app-authored
     *  catalog events deterministic and dependency-free. */
    fun toNostrContentJson(): String? {
        val catalog = normalizedOrNull() ?: return null
        return buildString {
            append('{')
            append("\"schema\":").append(SONAR_GIF_CATALOG_SCHEMA).append(',')
            append("\"app\":\"").append(APP_NAME).append("\",")
            append("\"type\":\"").append(CATALOG_TYPE).append("\",")
            append("\"name\":\"").append(catalog.name.jsonEscaped()).append("\",")
            append("\"items\":[")
            catalog.items.forEachIndexed { index, item ->
                if (index > 0) append(',')
                append(item.toJsonObject())
            }
            append(']')
            append('}')
        }
    }
}

data class SonarGifItem(
    val id: String = "",
    val title: String,
    val mimeType: String,
    val mediaUrl: String,
    val previewUrl: String? = null,
    val stillUrl: String? = null,
    val width: Int? = null,
    val height: Int? = null,
    val byteSize: Long? = null,
    val source: String = "nostr",
) {
    val isVideoGif: Boolean get() = mimeType.equals("video/mp4", ignoreCase = true)

    val sendFilename: String get() = "${id.ifBlank { stableGifItemId(mediaUrl) }}.${fileExtensionForMime(mimeType)}"

    val aspectRatio: Float?
        get() {
            val w = width ?: return null
            val h = height ?: return null
            if (w <= 0 || h <= 0) return null
            return w.toFloat() / h.toFloat()
        }

    fun normalizedOrNull(): SonarGifItem? {
        val cleanMediaUrl = normalizeHttpsUrl(mediaUrl) ?: return null
        val cleanMime = normalizeGifMime(mimeType)
            ?: mimeType.takeIf { it.isBlank() }?.let { inferGifMimeFromUrl(cleanMediaUrl) }
            ?: return null
        val cleanTitle = cleanLabel(title, MAX_ITEM_TITLE) ?: "GIF"
        val cleanPreview = previewUrl?.let { normalizeHttpsUrl(it) }
        val cleanStill = stillUrl?.let { normalizeHttpsUrl(it) }
        val cleanWidth = width?.takeIf { it in 1..MAX_DIMENSION }
        val cleanHeight = height?.takeIf { it in 1..MAX_DIMENSION }
        val cleanBytes = when {
            byteSize == null -> null
            byteSize in 1..SONAR_GIF_ITEM_MAX_BYTES -> byteSize
            else -> return null
        }
        val cleanSource = cleanProtocolToken(source).ifBlank { "nostr" }
        val cleanId = cleanProtocolToken(id).ifBlank { stableGifItemId(cleanMediaUrl) }

        return copy(
            id = cleanId,
            title = cleanTitle,
            mimeType = cleanMime,
            mediaUrl = cleanMediaUrl,
            previewUrl = cleanPreview,
            stillUrl = cleanStill,
            width = cleanWidth,
            height = cleanHeight,
            byteSize = cleanBytes,
            source = cleanSource,
        )
    }

    internal fun toJsonObject(): String = buildString {
        append('{')
        append("\"id\":\"").append(id.jsonEscaped()).append("\",")
        append("\"title\":\"").append(title.jsonEscaped()).append("\",")
        append("\"mime\":\"").append(mimeType).append("\",")
        append("\"url\":\"").append(mediaUrl.jsonEscaped()).append("\"")
        previewUrl?.let { append(",\"preview_url\":\"").append(it.jsonEscaped()).append("\"") }
        stillUrl?.let { append(",\"still_url\":\"").append(it.jsonEscaped()).append("\"") }
        width?.let { append(",\"width\":").append(it) }
        height?.let { append(",\"height\":").append(it) }
        byteSize?.let { append(",\"bytes\":").append(it) }
        append(",\"source\":\"").append(source.jsonEscaped()).append("\"")
        append('}')
    }
}

fun sonarGifCatalogEventTags(catalogId: String = SONAR_GIF_CATALOG_D_TAG): List<List<String>> =
    listOf(
        listOf("d", cleanProtocolToken(catalogId).ifBlank { SONAR_GIF_CATALOG_D_TAG }),
        listOf("t", APP_NAME),
        listOf("t", "gif"),
    )

fun stableGifItemId(mediaUrl: String): String =
    Sha256.hash(mediaUrl.trim().encodeToByteArray())
        .joinToString(separator = "") { byte -> (byte.toInt() and 0xFF).toString(16).padStart(2, '0') }
        .take(16)

fun normalizeGifMime(mime: String): String? =
    mime.trim().lowercase().substringBefore(';').takeIf { it in allowedGifMimeTypes }

fun inferGifMimeFromUrl(url: String): String? {
    val path = url.substringBefore('?').substringBefore('#').lowercase()
    return when {
        path.endsWith(".gif") -> "image/gif"
        path.endsWith(".mp4") -> "video/mp4"
        path.endsWith(".webp") -> "image/webp"
        else -> null
    }
}

fun normalizeHttpsUrl(value: String): String? {
    val url = value.trim()
    if (url.length !in 9..2048) return null
    if (!url.startsWith("https://", ignoreCase = true)) return null
    if (url.any { it <= ' ' }) return null
    val hostAndPath = url.drop("https://".length)
    val host = hostAndPath.substringBefore('/').substringBefore('?').substringBefore('#')
    if ('@' in host) return null
    if (host.isBlank() || !host.contains('.')) return null
    return "https://" + host.lowercase() + hostAndPath.drop(host.length)
}

fun fileExtensionForMime(mime: String): String =
    when (normalizeGifMime(mime)) {
        "video/mp4" -> "mp4"
        "image/webp" -> "webp"
        else -> "gif"
    }

private fun cleanLabel(value: String, max: Int): String? {
    val clean = value.trim().replace(Regex("\\s+"), " ").take(max)
    return clean.takeIf { it.isNotBlank() }
}

private fun cleanProtocolToken(value: String): String =
    value.trim()
        .lowercase()
        .filter { it.isLetterOrDigit() || it == '-' || it == '_' || it == '.' }
        .take(MAX_TOKEN)

private fun String.jsonEscaped(): String =
    buildString {
        for (ch in this@jsonEscaped) {
            when (ch) {
                '\\' -> append("\\\\")
                '"' -> append("\\\"")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                in '\u0000'..'\u001F' -> append("\\u").append(ch.code.toString(16).padStart(4, '0'))
                else -> append(ch)
            }
        }
    }
