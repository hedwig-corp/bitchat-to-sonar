package chat.bitchat.sonar

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Platform WebSocket probe: open [url], send disposable REQ kinds:[0] limit:1,
 * wait for matching EOSE, CLOSE, return RTT ms. Throws / returns error on timeout.
 *
 * Implemented with an Android-supported client on Android and java.net.http on
 * desktop JVM.
 */
internal expect suspend fun platformProbeRelayLatency(
    url: String,
    timeoutMs: Long = 5_000L,
): RelayBenchmarkResult

/**
 * Probe a single relay. Always returns a result (never throws).
 * Safe for UI: bounded timeout, no message content, no key material.
 */
suspend fun probeRelayLatency(
    url: String,
    timeoutMs: Long = 5_000L,
): RelayBenchmarkResult {
    val canonical = canonicalRelayUrl(url)
    return try {
        platformProbeRelayLatency(canonical, timeoutMs).let { result ->
            result.copy(url = canonicalRelayUrl(result.url.ifBlank { canonical }))
        }
    } catch (t: Throwable) {
        val message = t.message?.takeIf { it.isNotBlank() } ?: "probe failed"
        RelayBenchmarkResult(
            url = canonical,
            success = false,
            rttMs = null,
            error = message,
            measuredAtMs = SonarClock.nowSecs() * 1000L,
            durationMs = 0,
        )
    }
}

/**
 * Sequential probes for [urls] (or snapshot/defaults when null).
 * Sequential avoids racing a single receive pump on shared stacks.
 */
suspend fun runRelayBenchmarks(
    urls: List<String>? = null,
    snapshot: RelaySyncSnapshot? = null,
    timeoutMs: Long = 5_000L,
): List<RelayBenchmarkResult> {
    val targets = urls?.map { canonicalRelayUrl(it) }?.filter { it.isNotBlank() }?.distinct()
        ?: relayUrlsForBenchmark(snapshot)
    if (targets.isEmpty()) return emptyList()
    return withContext(Dispatchers.Default) {
        val results = ArrayList<RelayBenchmarkResult>(targets.size)
        for (url in targets) {
            results.add(probeRelayLatency(url, timeoutMs))
        }
        results
    }
}
