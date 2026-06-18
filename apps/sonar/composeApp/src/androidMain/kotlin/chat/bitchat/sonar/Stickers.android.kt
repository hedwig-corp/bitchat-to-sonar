package chat.bitchat.sonar

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL

actual object SonarStickerAssetFetcher {
    actual suspend fun fetch(url: String, maxBytes: Int): ByteArray? =
        withContext(Dispatchers.IO) {
            fetchHttpsBounded(url, maxBytes)
        }
}

private fun fetchHttpsBounded(url: String, maxBytes: Int): ByteArray? {
    val parsed = runCatching { URL(url) }.getOrNull() ?: return null
    if (!parsed.protocol.equals("https", ignoreCase = true)) return null
    val conn = (parsed.openConnection() as? HttpURLConnection) ?: return null
    return try {
        conn.instanceFollowRedirects = false
        conn.connectTimeout = 10_000
        conn.readTimeout = 15_000
        conn.requestMethod = "GET"
        val length = conn.contentLengthLong
        if (length > maxBytes) return null
        if (conn.responseCode !in 200..299) return null
        conn.inputStream.use { input ->
            val out = ByteArrayOutputStream()
            val buffer = ByteArray(16 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                out.write(buffer, 0, read)
                if (out.size() > maxBytes) return null
            }
            out.toByteArray()
        }
    } catch (_: Throwable) {
        null
    } finally {
        conn.disconnect()
    }
}
