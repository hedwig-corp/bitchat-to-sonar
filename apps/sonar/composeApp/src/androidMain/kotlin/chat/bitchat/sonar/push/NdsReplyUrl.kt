package chat.bitchat.sonar.push

import android.util.Log
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Path prefix breez/notify injects into every reply_url
 *  (`{NOTIFY_EXTERNAL_URL}/api/v1/response/{reqId}`). */
internal const val NDS_RESPONSE_PATH_PREFIX = "/api/v1/response/"

/**
 * Whether [raw] is a reply URL we are willing to POST a freshly signed BOLT12
 * invoice to.
 *
 * This is the single control standing between a forged push and a redirected
 * payment invoice, so it is a pure function taking [expectedHost] rather than
 * reading it from `SonarPushRegistration` — that keeps it directly testable
 * (see `NdsReplyUrlTest`) instead of stranded behind an Android `Service`.
 * Upstream's Kotlin notification job does no validation here at all.
 *
 * Fails closed on every axis, in order:
 *  - unparseable, or a scheme other than `https`
 *  - any userinfo, so `https://nds.example@evil/` cannot borrow the real host's
 *    name (the parsed host there is `evil`, but reject on userinfo regardless)
 *  - host not EXACTLY [expectedHost] (case-insensitive; not a suffix match, so
 *    `nds.example.evil.com` is rejected)
 *  - a non-default port, so a compromised path on the real host cannot be
 *    redirected to some other listener on it
 *  - a path outside [NDS_RESPONSE_PATH_PREFIX]
 *
 * Note `java.net.URL` does NOT normalize dot-segments — only `URI.normalize()`
 * does — so `/api/v1/response/../../admin` would otherwise sail through the
 * prefix check. The path is normalized before comparing, and percent-encoded
 * separators/dots are rejected outright rather than guessing how the far side
 * decodes them.
 */
internal fun isAcceptableNdsReplyUrl(raw: String, expectedHost: String): Boolean {
    val url = runCatching { URL(raw) }.getOrNull() ?: return false
    if (url.protocol != "https") return false
    if (url.userInfo != null) return false
    val host = url.host ?: return false
    if (!host.equals(expectedHost, ignoreCase = true)) return false
    // -1 is "not specified"; 443 is https default written out explicitly.
    if (url.port != -1 && url.port != 443) return false
    val rawPath = url.path ?: return false
    // Encoded separators/dots would let traversal survive normalization here and
    // reappear once the NDS decodes. Nothing legitimate needs them: the id in
    // {NOTIFY_EXTERNAL_URL}/api/v1/response/{reqId} is decimal digits.
    val lower = rawPath.lowercase()
    if (lower.contains("%2e") || lower.contains("%2f") || lower.contains("%5c")) return false
    val path = runCatching { URI(raw).normalize().path }.getOrNull() ?: return false
    return path.startsWith(NDS_RESPONSE_PATH_PREFIX)
}

/**
 * POST [body] as JSON to an already-validated NDS reply [url]; true on 2xx.
 *
 * Top-level rather than a service method so a bail-out reply can be sent from a
 * scope that outlives the wake (see `stopWakeWork`) — the payer is blocked on
 * the NDS's 60s window, and a fast error beats letting it expire.
 *
 * Callers MUST have passed [isAcceptableNdsReplyUrl] first. Redirects are
 * disabled: the pin validates one URL, and a 3xx from a compromised or
 * open-redirecting host would otherwise bounce the invoice past it.
 */
internal suspend fun postNdsReply(url: String, body: String): Boolean =
    withContext(Dispatchers.IO) {
        runCatching {
            val conn = URL(url).openConnection() as HttpURLConnection
            try {
                conn.requestMethod = "POST"
                conn.instanceFollowRedirects = false
                conn.connectTimeout = 10_000
                conn.readTimeout = 10_000
                conn.doOutput = true
                conn.setRequestProperty("Content-Type", "application/json")
                conn.outputStream.use { it.write(body.encodeToByteArray()) }
                conn.responseCode in 200..299
            } finally {
                conn.disconnect()
            }
        }.getOrElse {
            Log.w("SonarNdsReply", "reply POST failed", it)
            false
        }
    }
