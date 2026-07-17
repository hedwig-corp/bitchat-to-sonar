package chat.bitchat.sonar

import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicBoolean
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener

private val relayProbeClient = OkHttpClient.Builder()
    .retryOnConnectionFailure(false)
    .build()

/**
 * Android probe: OkHttp WebSocket, REQ kinds:[0] limit:1 → wait EOSE → CLOSE.
 * OkHttp supplies the Android transport; java.net.http is unavailable on ART.
 */
internal actual suspend fun platformProbeRelayLatency(
    url: String,
    timeoutMs: Long,
): RelayBenchmarkResult {
    val canonical = canonicalRelayUrl(url)
    val started = System.currentTimeMillis()
    val boundedTimeoutMs = timeoutMs.coerceAtLeast(1L)
    val subId = "sonar-bench-${UUID.randomUUID().toString().take(8)}"
    val req = """["REQ","$subId",{"kinds":[0],"limit":1}]"""
    val close = """["CLOSE","$subId"]"""
    val finished = AtomicBoolean(false)
    val future = CompletableFuture<RelayBenchmarkResult>()

    fun result(success: Boolean, rttMs: Int? = null, error: String? = null) =
        RelayBenchmarkResult(
            url = canonical,
            success = success,
            rttMs = rttMs,
            error = error,
            measuredAtMs = System.currentTimeMillis(),
            durationMs = (System.currentTimeMillis() - started).toInt(),
        )

    fun complete(value: RelayBenchmarkResult) {
        if (finished.compareAndSet(false, true)) future.complete(value)
    }

    var openedAt = 0L
    val listener = object : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            openedAt = System.currentTimeMillis()
            webSocket.send(req)
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            if (text.contains("\"EOSE\"") && text.contains("\"$subId\"")) {
                val rtt = (System.currentTimeMillis() - openedAt).toInt().coerceAtLeast(1)
                webSocket.send(close)
                complete(result(success = true, rttMs = rtt))
                webSocket.close(1000, "done")
            }
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            complete(result(success = false, error = "closed before EOSE"))
            webSocket.close(code, reason)
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            complete(result(success = false, error = "closed before EOSE"))
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            complete(
                result(
                    success = false,
                    error = t.message?.takeIf { it.isNotBlank() } ?: "transport error",
                ),
            )
        }
    }

    var webSocket: WebSocket? = null
    return try {
        val client = relayProbeClient.newBuilder()
            .connectTimeout(boundedTimeoutMs, TimeUnit.MILLISECONDS)
            .build()
        val request = Request.Builder().url(canonical).build()
        webSocket = client.newWebSocket(request, listener)
        future.get(boundedTimeoutMs, TimeUnit.MILLISECONDS)
    } catch (_: TimeoutException) {
        val timeout = result(success = false, error = "timeout")
        complete(timeout)
        webSocket?.cancel()
        future.getNow(timeout)
    } catch (t: InterruptedException) {
        Thread.currentThread().interrupt()
        webSocket?.cancel()
        result(success = false, error = "interrupted")
    } catch (t: Throwable) {
        webSocket?.cancel()
        val cause = (t as? ExecutionException)?.cause ?: t
        result(
            success = false,
            error = cause.message?.takeIf { it.isNotBlank() } ?: "probe failed",
        )
    }
}
