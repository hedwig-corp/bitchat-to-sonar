package chat.bitchat.sonar

import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.runBlocking
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class RelayBenchmarkAndroidTest {

    @Test
    fun probeSucceedsAfterMatchingEose() = withServer(
        object : WebSocketListener() {
            override fun onMessage(webSocket: WebSocket, text: String) {
                val subId = text.split('"').getOrNull(3) ?: return
                webSocket.send("""["EOSE","$subId"]""")
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                webSocket.close(code, reason)
            }
        },
    ) { url ->
        val result = runBlocking { platformProbeRelayLatency(url, timeoutMs = 2_000L) }

        assertTrue(result.error.orEmpty(), result.success)
        assertNotNull(result.rttMs)
        assertTrue(result.durationMs >= 0)
    }

    @Test
    fun probeTimesOutWhenRelayNeverSendsEose() = withServer(
        object : WebSocketListener() {},
    ) { url ->
        val result = runBlocking { platformProbeRelayLatency(url, timeoutMs = 150L) }

        assertFalse(result.success)
        assertEquals("timeout", result.error)
    }

    @Test
    fun probeFailsWhenRelayClosesBeforeEose() = withServer(
        object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                webSocket.close(1000, "no EOSE")
            }
        },
    ) { url ->
        val result = runBlocking { platformProbeRelayLatency(url, timeoutMs = 2_000L) }

        assertFalse(result.success)
        assertEquals("closed before EOSE", result.error)
    }

    private fun withServer(
        listener: WebSocketListener,
        test: (String) -> Unit,
    ) {
        MockWebServer().use { server ->
            server.enqueue(
                MockResponse.Builder()
                    .webSocketUpgrade(listener)
                    .build(),
            )
            server.start()
            val url = server.url("/").toString().replaceFirst("http://", "ws://")
            test(url)
        }
    }
}
