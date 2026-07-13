package chat.bitchat.sonar

/**
 * Connection → Internet diagnostics: Marmot/core sync snapshot parsing and
 * Nostr relay latency benchmark helpers. Free of message content / key material.
 *
 * Mirrors iOS `SonarRelayStatusSheet` + `NostrRelayManager` probe UX.
 */

/** Decoded Marmot/core sync snapshot (same shape as Diagnostics). */
data class RelaySyncSnapshot(
    val watermarkSecs: Long = 0L,
    val liveMarmotEnabled: Boolean = false,
    val subscribedGroupCount: Int = 0,
    val relays: List<RelaySyncEntry> = emptyList(),
)

data class RelaySyncEntry(
    val url: String,
    val status: String,
)

/** One relay probe result for Connection → Internet diagnostics. */
data class RelayBenchmarkResult(
    val url: String,
    val success: Boolean,
    val rttMs: Int? = null,
    val error: String? = null,
    val measuredAtMs: Long = 0L,
    val durationMs: Int = 0,
)

/** Public defaults used when the sync snapshot is empty (parity with iOS). */
val DEFAULT_RELAY_URLS: List<String> = listOf(
    "wss://relay.damus.io",
    "wss://nos.lol",
    "wss://relay.primal.net",
    "wss://relay.kaleidoswap.com",
    "wss://nostr.relay.hedwig.sh",
)

const val HEDWIG_RELAY_URL: String = "wss://nostr.relay.hedwig.sh"

/**
 * Canonicalize a relay URL the same way iOS `NostrRelayManager.canonicalRelayURL` does:
 * trim, drop trailing `/`, lower scheme+host, drop default ports, keep non-root path.
 */
fun canonicalRelayUrl(raw: String): String {
    var trimmed = raw.trim()
    while (trimmed.endsWith("/")) trimmed = trimmed.dropLast(1)
    if (trimmed.isEmpty()) return trimmed

    val schemeSep = trimmed.indexOf("://")
    if (schemeSep <= 0) return trimmed
    val scheme = trimmed.substring(0, schemeSep).lowercase()
    val rest = trimmed.substring(schemeSep + 3)
    if (rest.isEmpty()) return trimmed

    val pathIdx = rest.indexOf('/')
    val authority = if (pathIdx >= 0) rest.substring(0, pathIdx) else rest
    val path = if (pathIdx >= 0) rest.substring(pathIdx) else ""

    // Drop userinfo if present (rare for relays).
    val hostPort = authority.substringAfter('@')
    val host: String
    val port: Int?
    if (hostPort.startsWith("[")) {
        // IPv6 literal: [::1]:port
        val end = hostPort.indexOf(']')
        if (end < 0) return trimmed
        host = hostPort.substring(0, end + 1).lowercase()
        val after = hostPort.substring(end + 1)
        port = if (after.startsWith(":")) after.drop(1).toIntOrNull() else null
    } else {
        val colon = hostPort.lastIndexOf(':')
        if (colon > 0 && hostPort.indexOf(':') == colon) {
            host = hostPort.substring(0, colon).lowercase()
            port = hostPort.substring(colon + 1).toIntOrNull()
        } else {
            host = hostPort.lowercase()
            port = null
        }
    }

    val dropDefault =
        (scheme == "wss" && port == 443) || (scheme == "ws" && port == 80)
    val portPart = if (port != null && !dropDefault) ":$port" else ""
    val pathPart = if (path.isNotEmpty() && path != "/") path else ""
    return "$scheme://$host$portPart$pathPart"
}

/** Host-only display label for a relay URL (middle-truncation left to UI). */
fun displayRelayHost(url: String): String {
    val trimmed = url.trim()
    val withoutScheme = when {
        trimmed.startsWith("wss://", ignoreCase = true) -> trimmed.drop(6)
        trimmed.startsWith("ws://", ignoreCase = true) -> trimmed.drop(5)
        else -> trimmed
    }
    val hostPort = withoutScheme.substringBefore('/').substringBefore('?')
    val host = if (hostPort.startsWith("[")) {
        hostPort.substringBefore(']').removePrefix("[") + "]"
    } else {
        hostPort.substringBefore(':')
    }
    return host.ifBlank { url }
}

fun hostsMatch(a: String, b: String): Boolean {
    val ha = displayRelayHost(a).lowercase()
    val hb = displayRelayHost(b).lowercase()
    if (ha.isNotBlank() && hb.isNotBlank() && ha == hb) return true
    return canonicalRelayUrl(a) == canonicalRelayUrl(b)
}

/**
 * Tolerant parse of `SonarCore.syncStateSnapshotJson()`.
 * Missing / malformed fields are zeroed rather than failing hard.
 */
fun parseSyncStateSnapshot(json: String?): RelaySyncSnapshot? {
    if (json.isNullOrBlank()) return null
    val watermark = extractLongField(json, "watermark_secs") ?: 0L
    val live = extractBoolField(json, "live_marmot_enabled") ?: false
    val groups = extractIntField(json, "subscribed_group_count") ?: 0
    val relays = extractRelayEntries(json)
    return RelaySyncSnapshot(
        watermarkSecs = watermark,
        liveMarmotEnabled = live,
        subscribedGroupCount = groups,
        relays = relays,
    )
}

/**
 * Build the ordered, de-duplicated URL list for a benchmark run:
 * 1. Snapshot relay URLs (preserve order)
 * 2. Always include hedwig if missing
 * 3. If snapshot empty, fall back to [DEFAULT_RELAY_URLS]
 */
fun relayUrlsForBenchmark(snapshot: RelaySyncSnapshot?): List<String> {
    val out = ArrayList<String>()
    val seen = LinkedHashSet<String>()

    fun add(raw: String) {
        val canon = canonicalRelayUrl(raw)
        if (canon.isBlank()) return
        if (seen.add(canon)) out.add(canon)
    }

    snapshot?.relays?.forEach { add(it.url) }
    if (out.isEmpty()) {
        DEFAULT_RELAY_URLS.forEach { add(it) }
    } else {
        add(HEDWIG_RELAY_URL)
    }
    return out
}

/** Merge a new result into a map keyed by canonical URL (host-level overwrite). */
fun mergeBenchmarkResult(
    existing: Map<String, RelayBenchmarkResult>,
    result: RelayBenchmarkResult,
): Map<String, RelayBenchmarkResult> {
    val canon = canonicalRelayUrl(result.url)
    val next = existing.toMutableMap()
    // Drop any host-level aliases so the latest probe wins.
    val stale = next.keys.filter { hostsMatch(it, canon) && it != canon }
    stale.forEach { next.remove(it) }
    next[canon] = result.copy(url = canon)
    return next
}

fun bestRttMs(results: Collection<RelayBenchmarkResult>): Int? =
    results.mapNotNull { it.rttMs }.minOrNull()

fun formatBenchmarkSummary(results: List<RelayBenchmarkResult>): String {
    if (results.isEmpty()) {
        return "No relays to measure — open a chat so relays connect, then retry"
    }
    val ok = results.filter { it.success }
    val fail = results.size - ok.size
    val best = ok.mapNotNull { it.rttMs }.minOrNull()
    val worst = ok.mapNotNull { it.rttMs }.maxOrNull()
    return if (best != null && worst != null) {
        "Last run · ${ok.size} up / $fail down · best $best ms · worst $worst ms"
    } else {
        val sample = results.mapNotNull { it.error }.filter { it.isNotBlank() }.take(2).joinToString("; ")
        "Last run · all ${results.size} probes failed" + if (sample.isEmpty()) "" else " · $sample"
    }
}

fun formatWatermark(secs: Long, nowSecs: Long = SonarClock.nowSecs()): String {
    if (secs <= 0L) return "never"
    val ago = (nowSecs - secs).coerceAtLeast(0L)
    return when {
        ago < 60 -> "just now"
        ago < 3600 -> "${ago / 60} min ago"
        ago < 86400 -> "${ago / 3600} h ago"
        else -> "${ago / 86400} d ago"
    }
}

// ── JSON helpers (no kotlinx.serialization dependency) ──────────────────────

private fun extractLongField(json: String, key: String): Long? {
    val m = Regex("\"$key\"\\s*:\\s*(-?\\d+)").find(json) ?: return null
    return m.groupValues[1].toLongOrNull()
}

private fun extractIntField(json: String, key: String): Int? =
    extractLongField(json, key)?.toInt()

private fun extractBoolField(json: String, key: String): Boolean? {
    val m = Regex("\"$key\"\\s*:\\s*(true|false)", RegexOption.IGNORE_CASE).find(json) ?: return null
    return m.groupValues[1].equals("true", ignoreCase = true)
}

private fun extractRelayEntries(json: String): List<RelaySyncEntry> {
    val arrayMatch = Regex("\"relays\"\\s*:\\s*\\[(.*?)]", setOf(RegexOption.DOT_MATCHES_ALL))
        .find(json)
        ?: return emptyList()
    val body = arrayMatch.groupValues[1]
    val objects = Regex("\\{(.*?)}", setOf(RegexOption.DOT_MATCHES_ALL)).findAll(body)
    val out = ArrayList<RelaySyncEntry>()
    for (obj in objects) {
        val chunk = obj.groupValues[1]
        val url = extractStringField(chunk, "url") ?: continue
        val status = extractStringField(chunk, "status") ?: "unknown"
        out.add(RelaySyncEntry(url = url, status = status))
    }
    return out
}

private fun extractStringField(json: String, key: String): String? {
    // Match "key": "value" with basic escape support for \" and \\.
    val m = Regex("\"$key\"\\s*:\\s*\"((?:\\\\.|[^\"\\\\])*)\"").find(json) ?: return null
    return unescapeJsonString(m.groupValues[1])
}

private fun unescapeJsonString(raw: String): String {
    val sb = StringBuilder(raw.length)
    var i = 0
    while (i < raw.length) {
        val c = raw[i]
        if (c == '\\' && i + 1 < raw.length) {
            when (val n = raw[i + 1]) {
                '"', '\\', '/' -> { sb.append(n); i += 2 }
                'n' -> { sb.append('\n'); i += 2 }
                'r' -> { sb.append('\r'); i += 2 }
                't' -> { sb.append('\t'); i += 2 }
                else -> { sb.append(n); i += 2 }
            }
        } else {
            sb.append(c)
            i++
        }
    }
    return sb.toString()
}
