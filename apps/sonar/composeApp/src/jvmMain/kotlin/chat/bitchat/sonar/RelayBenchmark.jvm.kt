package chat.bitchat.sonar

import java.net.URI
import java.net.http.HttpClient
import java.net.http.WebSocket
import java.nio.ByteBuffer
import java.time.Duration
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CompletionStage
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Desktop JVM probe: java.net.http WebSocket, REQ kinds:[0] limit:1 → EOSE → CLOSE.
 */
internal actual suspend fun platformProbeRelayLatency(
    url: String,
    timeoutMs: Long,
): RelayBenchmarkResult {
    val canonical = canonicalRelayUrl(url)
    val started = System.currentTimeMillis()
    val subId = "sonar-bench-${UUID.randomUUID().toString().take(8)}"
    val req = """["REQ","$subId",{"kinds":[0],"limit":1}]"""
    val close = """["CLOSE","$subId"]"""
    val finished = AtomicBoolean(false)
    val future = CompletableFuture<RelayBenchmarkResult>()

    fun complete(result: RelayBenchmarkResult) {
        if (!finished.compareAndSet(false, true)) return
        future.complete(result)
    }

    val client = HttpClient.newBuilder()
        .connectTimeout(Duration.ofMillis(timeoutMs))
        .build()

    var openedAt = 0L
    val listener = object : WebSocket.Listener {
        private val textBuf = StringBuilder()

        override fun onOpen(webSocket: WebSocket) {
            openedAt = System.currentTimeMillis()
            webSocket.sendText(req, true)
            webSocket.request(1)
        }

        override fun onText(webSocket: WebSocket, data: CharSequence, last: Boolean): CompletionStage<*>? {
            textBuf.append(data)
            if (!last) {
                webSocket.request(1)
                return null
            }
            val text = textBuf.toString()
            textBuf.setLength(0)
            if (text.contains("\"EOSE\"") && text.contains(subId)) {
                val rtt = (System.currentTimeMillis() - openedAt).toInt().coerceAtLeast(1)
                webSocket.sendText(close, true)
                webSocket.sendClose(WebSocket.NORMAL_CLOSURE, "done")
                complete(
                    RelayBenchmarkResult(
                        url = canonical,
                        success = true,
                        rttMs = rtt,
                        measuredAtMs = System.currentTimeMillis(),
                        durationMs = (System.currentTimeMillis() - started).toInt(),
                    )
                )
            } else {
                webSocket.request(1)
            }
            return null
        }

        override fun onBinary(webSocket: WebSocket, data: ByteBuffer, last: Boolean): CompletionStage<*>? {
            webSocket.request(1)
            return null
        }

        override fun onError(webSocket: WebSocket, error: Throwable) {
            complete(
                RelayBenchmarkResult(
                    url = canonical,
                    success = false,
                    error = error.message?.takeIf { it.isNotBlank() } ?: "transport error",
                    measuredAtMs = System.currentTimeMillis(),
                    durationMs = (System.currentTimeMillis() - started).toInt(),
                )
            )
        }

        override fun onClose(webSocket: WebSocket, statusCode: Int, reason: String?): CompletionStage<*>? {
            complete(
                RelayBenchmarkResult(
                    url = canonical,
                    success = false,
                    error = "closed before EOSE",
                    measuredAtMs = System.currentTimeMillis(),
                    durationMs = (System.currentTimeMillis() - started).toInt(),
                )
            )
            return null
        }
    }

    return try {
        client.newWebSocketBuilder()
            .connectTimeout(Duration.ofMillis(timeoutMs))
            .buildAsync(URI.create(canonical), listener)

        future.get(timeoutMs, TimeUnit.MILLISECONDS)
    } catch (t: java.util.concurrent.TimeoutException) {
        complete(
            RelayBenchmarkResult(
                url = canonical,
                success = false,
                error = "timeout",
                measuredAtMs = System.currentTimeMillis(),
                durationMs = (System.currentTimeMillis() - started).toInt(),
            )
        )
        future.getNow(
            RelayBenchmarkResult(
                url = canonical,
                success = false,
                error = "timeout",
                measuredAtMs = System.currentTimeMillis(),
                durationMs = (System.currentTimeMillis() - started).toInt(),
            )
        )
    } catch (t: Throwable) {
        val cause = (t as? java.util.concurrent.ExecutionException)?.cause ?: t
        RelayBenchmarkResult(
            url = canonical,
            success = false,
            error = cause.message?.takeIf { it.isNotBlank() } ?: "probe failed",
            measuredAtMs = System.currentTimeMillis(),
            durationMs = (System.currentTimeMillis() - started).toInt(),
        )
    }
}
