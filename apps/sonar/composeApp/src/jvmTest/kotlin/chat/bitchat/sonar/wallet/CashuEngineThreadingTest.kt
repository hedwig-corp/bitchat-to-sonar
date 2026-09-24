package chat.bitchat.sonar.wallet

import java.nio.file.Files
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Real threads, real Dispatchers.IO: the engine's threading and in-flight
 * rules as the app experiences them.
 */
class CashuEngineThreadingTest {

    private val nsec = "nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5"

    private val root: String = Files.createTempDirectory("sonar-cashu-thread").toString()

    private fun engine(native: FakeCashuNative, onOpen: () -> Unit = {}) = CashuWalletEngine(
        openNative = { _, _, _ -> onOpen(); native },
        storageRoot = { root },
        prefs = MapWalletPrefs(),
        files = platformWalletFiles(),
        retryDelaysMs = listOf(50L),
    )

    private suspend fun waitUntil(timeoutMs: Long = 5_000, cond: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (!cond()) {
            check(System.currentTimeMillis() < deadline) { "timed out" }
            delay(10)
        }
    }

    @Test
    fun theNativeWalletIsNeverCalledOnTheCallersThread() = runBlocking {
        val mainExec = Executors.newSingleThreadExecutor { r -> Thread(r, "fake-main") }
        val main = mainExec.asCoroutineDispatcher()
        val offenders = CopyOnWriteArrayList<String>()
        // startsWith: under -ea kotlinx appends " @coroutine#N" to thread names.
        fun onMain() = Thread.currentThread().name.startsWith("fake-main")
        val native = FakeCashuNative(confirmedSats = 10_000).apply {
            onCall = { if (onMain()) offenders += it }
        }
        val e = engine(native) { if (onMain()) offenders += "openNative" }
        try {
            withContext(main) {
                e.setup(nsec)
                e.onForeground()
                e.refreshBalance()
                e.receiveOffer()
                e.send("lno1peer", 100, "n")
                e.send("lno1peer", 1_000, "n", feeFromAmount = true)
                // The Receive sheet's invoice and the send sheet's fee line.
                assertTrue(e.receiveInvoice(2_100) is WalletOutcome.Ok)
                assertTrue(e.quoteFee("lno1peer", 500) is WalletOutcome.Ok)
                e.lookupPayment("quote-1")
                e.onBackground()
                e.onForeground()
                e.release()
                e.setup(nsec)
                e.wipeAll()
            }
            delay(300) // let launched background work run
            assertTrue(native.calls.isNotEmpty(), "the fixture must actually drive the native")
            assertEquals(emptyList<String>(), offenders.toList(), "native calls made on the caller's (main) thread")
        } finally {
            main.close()
            mainExec.shutdownNow()
        }
    }

    @Test
    fun backgroundDefersTheDisconnectAndReplacementRefusesWhileASendRuns() = runBlocking {
        val entered = CountDownLatch(1)
        val proceed = CountDownLatch(1)
        val native = FakeCashuNative(confirmedSats = 10_000)
        val e = engine(native)
        e.setup(nsec)
        waitUntil { e.online.value }
        native.onCall = { if (it == "send") { entered.countDown(); proceed.await(5, TimeUnit.SECONDS) } }

        val sending = async(Dispatchers.Default) { e.send("lno1peer", 100, "n") }
        assertTrue(entered.await(5, TimeUnit.SECONDS))

        e.onBackground()
        delay(200)
        assertFalse("disconnect" in native.calls, "never disconnect under an in-flight send")
        assertFailsWith<PaymentInFlightException> { e.release() }

        proceed.countDown()
        assertTrue(sending.await().ok)
        waitUntil { "disconnect" in native.calls }
        val calls = native.calls
        assertTrue(calls.lastIndexOf("disconnect") > calls.indexOf("send"), "the deferred disconnect runs after the send")
        native.onCall = {}
        e.release()
    }
}
