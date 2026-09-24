package chat.bitchat.sonar.wallet

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestResult
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * [CashuWalletEngine] over a scripted native: the money rules the app relies
 * on, independent of any mint.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class CashuWalletEngineTest {

    private val nsec = "nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5"

    /** sha256("nsec1vl02…lfe5")[:16] — `printf %s <nsec> | shasum -a 256`. */
    private val accountId = "fa1ccdeec8175c634b4e9e29a985c02c"

    /** Engines built by [engine]; [walletTest] stops their connect loops even
     *  when an assertion fails (else runTest spins a retry loop forever). */
    private val built = mutableListOf<CashuWalletEngine>()

    private fun walletTest(body: suspend TestScope.() -> Unit): TestResult = runTest {
        try {
            body()
        } finally {
            built.forEach { it.onBackground() }
        }
    }

    private fun TestScope.engine(
        native: FakeCashuNative,
        prefs: MapWalletPrefs = MapWalletPrefs(),
        files: WalletFileOps = RecordingWalletFiles(),
        openedDirs: MutableList<String> = mutableListOf(),
    ) = CashuWalletEngine(
        openNative = { _, mint, dir ->
            assertEquals(CASHU_MINT_URL, mint)
            openedDirs += dir
            native
        },
        storageRoot = { "/root" },
        prefs = prefs,
        files = files,
        io = StandardTestDispatcher(testScheduler),
        retryDelaysMs = listOf(1_000L),
    ).also { built += it }

    @Test
    fun accountIdIsTheSharedGoldenDerivation() {
        // Same vector the iOS `SonarCashuStorage.accountId` must produce:
        // devices that ran earlier builds already have stores under it.
        assertEquals(accountId, cashuAccountId(nsec))
        assertEquals("/r/sonar-cashu/$accountId/mainnet", cashuWorkingDir("/r/", accountId))
    }

    @Test
    fun setupOpensThisAccountsOwnStore() = walletTest {
        val dirs = mutableListOf<String>()
        val e = engine(FakeCashuNative(), openedDirs = dirs)
        e.setup(nsec)
        runCurrent()
        assertEquals(listOf("/root/sonar-cashu/$accountId/mainnet"), dirs)
        e.onBackground()
    }

    @Test
    fun offlineConstructPublishesTheOfferAnsweredFromDisk() = walletTest {
        val native = FakeCashuNative(offer = "lno1fromdisk").apply {
            connectError = { CashuWalletException.Network("mint unreachable") }
        }
        val e = engine(native)
        e.setup(nsec)
        runCurrent()
        assertEquals("lno1fromdisk", e.offer.value, "the offer must publish with the mint down")
        assertFalse(e.online.value)
        val attempts = native.count("connect")
        assertTrue(attempts >= 1)
        advanceTimeBy(1_001)
        runCurrent()
        assertTrue(native.count("connect") > attempts, "connect retries with backoff")
        e.onBackground()
    }

    @Test
    fun offlineConstructFallsBackToThisAccountsLastOfferAndBalance() = walletTest {
        val native = FakeCashuNative(offer = null).apply {
            connectError = { CashuWalletException.Timeout() }
            offerError = { CashuWalletException.NotConnected() }
        }
        val prefs = MapWalletPrefs(
            mapOf(
                CashuWalletEngine.offerKey(accountId) to "lno1cached",
                CashuWalletEngine.balanceKey(accountId) to "1234",
                // Another account's cache must never leak into this one.
                CashuWalletEngine.offerKey("someoneelse") to "lno1other",
            ),
        )
        val e = engine(native, prefs)
        e.setup(nsec)
        runCurrent()
        assertEquals("lno1cached", e.offer.value)
        assertEquals(WalletState.Ready(1234), e.state.value, "last-known balance shows until balance() answers")
        e.onBackground()
    }

    @Test
    fun theOfferStaysStableAndOnlyAChangeIsRepublished() = walletTest {
        val native = FakeCashuNative(offer = "lno1stable")
        val prefs = MapWalletPrefs()
        val e = engine(native, prefs)
        val seen = mutableListOf<String?>()
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) { e.offer.collect { seen += it } }
        e.setup(nsec)
        runCurrent()
        native.emit(CashuEvent.Synced)
        native.emit(CashuEvent.Connected)
        runCurrent()
        e.onForeground()
        runCurrent()
        assertEquals("lno1stable", e.receiveOffer())
        assertEquals(listOf(null, "lno1stable"), seen, "one offer, published once")

        native.offer = "lno1rotated"
        native.emit(CashuEvent.Synced)
        runCurrent()
        assertEquals(listOf(null, "lno1stable", "lno1rotated"), seen)
        assertEquals("lno1rotated", prefs.get(CashuWalletEngine.offerKey(accountId)))
        e.onBackground()
    }

    @Test
    fun aPendingSendIsPendingAndItsLaterEventSettlesItWithoutASecondSend() = walletTest {
        val native = FakeCashuNative(confirmedSats = 10_000).apply { sendStatus = CashuPaymentStatus.Pending }
        val e = engine(native)
        val events = mutableListOf<WalletPaymentEvent>()
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) { e.paymentEvents.collect { events += it } }
        e.setup(nsec)
        runCurrent()

        val result = e.send("lno1peer", 1_000, "note")
        assertTrue(result.pending, "Pending is surfaced as pending")
        assertFalse(result.ok)
        assertNull(result.errorKind, "Pending is NOT a failure")
        assertEquals("quote-1", result.paymentId)
        assertEquals(1, native.count("send"))

        native.emit(
            CashuEvent.PaymentSent(
                CashuPayment("quote-1", false, 1_000, 1, 1_700_000_100, CashuPaymentStatus.Complete, "pre", null),
            ),
        )
        runCurrent()
        val settled = events.last { it.paymentId == "quote-1" }
        assertEquals(CashuPaymentStatus.Complete, settled.status)
        assertEquals("pre", settled.preimage, "PAYDONE needs the preimage from the later event")
        assertEquals(1, native.count("send"), "a pending payment is never re-sent")
        e.onBackground()
    }

    @Test
    fun aCashuReceiveIsFinalWhenItArrives() = walletTest {
        val native = FakeCashuNative()
        val e = engine(native)
        val events = mutableListOf<WalletPaymentEvent>()
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) { e.paymentEvents.collect { events += it } }
        e.setup(nsec)
        runCurrent()
        native.emit(
            CashuEvent.PaymentReceived(
                CashuPayment("q:tx", true, 21, null, 1_700_000_000, CashuPaymentStatus.Pending, null, null),
            ),
        )
        runCurrent()
        val received = events.single { it.paymentId == "q:tx" }
        assertTrue(received.settled, "no swap/lockup states for Cashu: PaymentReceived is final")
        assertEquals(CashuPaymentStatus.Complete, received.status)
    }

    @Test
    fun insufficientFundsIsTypedAndNothingIsSent() = walletTest {
        val native = FakeCashuNative(confirmedSats = 1_000, feeReserveSats = 5)
        val e = engine(native)
        e.setup(nsec)
        runCurrent()
        val r = e.send("lno1peer", 1_000, "note")
        assertEquals(SendErrorKind.InsufficientFunds, r.errorKind)
        assertEquals(SpendableBalance.insufficientMessage(1_000, 5, 1_000), r.error)
        assertEquals(0, native.count("send"))
        e.onBackground()
    }

    @Test
    fun theMintsInsufficientFundsErrorStaysTyped() = walletTest {
        val native = FakeCashuNative(confirmedSats = 1_000).apply {
            prepareError = { CashuWalletException.InsufficientFunds() }
        }
        val e = engine(native)
        e.setup(nsec)
        runCurrent()
        val r = e.send("lno1peer", 900, "note")
        assertEquals(SendErrorKind.InsufficientFunds, r.errorKind)
        assertEquals(SpendableBalance.insufficientBalanceMessage(1_000), r.error)
        assertEquals(0, native.count("send"))
        e.onBackground()
    }

    @Test
    fun maxTakesTheQuotedFeeReserveOutOfTheAmount() = walletTest {
        val native = FakeCashuNative(confirmedSats = 1_000, feeReserveSats = 5)
        val e = engine(native)
        e.setup(nsec)
        runCurrent()
        val r = e.send("lno1peer", 1_000, "note", feeFromAmount = true)
        assertTrue(r.ok)
        assertEquals(listOf(995L), native.sentAmounts, "prepare at the balance, subtract the fee, prepare again")
        assertEquals(2, native.count("prepareSend"))
        e.onBackground()
    }

    @Test
    fun aMintOutageIsTypedOfflineAndNothingIsSent() = walletTest {
        val native = FakeCashuNative(confirmedSats = 1_000).apply {
            connectError = { CashuWalletException.Network("down") }
        }
        val e = engine(native)
        e.setup(nsec)
        runCurrent()
        val r = e.send("lno1peer", 100, "note")
        assertEquals(SendErrorKind.Offline, r.errorKind)
        assertEquals(CashuWalletEngine.MINT_OFFLINE_MESSAGE, r.error)
        assertEquals(0, native.count("send"))
        e.onBackground()
    }

    @Test
    fun aFailedMeltIsAFailureNotAPending() = walletTest {
        val native = FakeCashuNative(confirmedSats = 1_000).apply { sendStatus = CashuPaymentStatus.Failed }
        val e = engine(native)
        e.setup(nsec)
        runCurrent()
        val r = e.send("lno1peer", 100, "note")
        assertFalse(r.ok)
        assertFalse(r.pending)
        assertEquals(SendErrorKind.Failed, r.errorKind)
        e.onBackground()
    }

    @Test
    fun backgroundDisconnectsOnlyAfterTheSendReturns() = walletTest {
        val native = FakeCashuNative(confirmedSats = 1_000)
        val e = engine(native)
        e.setup(nsec)
        runCurrent()
        // Backgrounded while the send is inside the native call.
        native.onCall = { if (it == "send") e.onBackground() }
        assertTrue(e.send("lno1peer", 100, "note").ok)
        runCurrent()
        val calls = native.calls
        assertTrue("disconnect" in calls)
        assertTrue(calls.lastIndexOf("disconnect") > calls.indexOf("send"))
    }

    @Test
    fun releaseKeepsTheStore() = walletTest {
        val files = RecordingWalletFiles()
        val native = FakeCashuNative(confirmedSats = 1_000)
        val e = engine(native, files = files)
        e.setup(nsec)
        runCurrent()
        e.release()
        assertTrue(native.closed)
        assertFalse(native.wiped, "account replacement keeps the store: it may hold funds")
        assertTrue(files.deleted.isEmpty())
        assertEquals(WalletState.NotConfigured, e.state.value)
        assertNull(e.offer.value)
    }

    @Test
    fun panicWipeRemovesEveryAccountsStore() = walletTest {
        val files = RecordingWalletFiles()
        val prefs = MapWalletPrefs()
        val native = FakeCashuNative(confirmedSats = 1_000)
        val e = engine(native, prefs, files)
        e.setup(nsec)
        runCurrent()
        e.refreshBalance()
        assertEquals("1000", prefs.get(CashuWalletEngine.balanceKey(accountId)))

        e.wipeAll()
        assertTrue("/root/sonar-cashu" in files.deleted, "every account's store goes, not just this one")
        assertTrue(native.wiped)
        assertTrue(native.calls.indexOf("disconnect") < native.calls.indexOf("wipeLocalStorage"))
        assertNull(prefs.get(CashuWalletEngine.balanceKey(accountId)))
        assertNull(prefs.get(CashuWalletEngine.offerKey(accountId)))
        assertFalse(files.exists("/root/sonar-cashu.wipe-pending"), "marker cleared on success")
    }

    @Test
    fun anInterruptedWipeFinishesBeforeTheNextOpen() = walletTest {
        val files = RecordingWalletFiles().apply { writeText("/root/sonar-cashu.wipe-pending", "1") }
        val e = engine(FakeCashuNative(), files = files)
        e.setup(nsec)
        runCurrent()
        assertTrue("/root/sonar-cashu" in files.deleted)
        assertFalse(files.exists("/root/sonar-cashu.wipe-pending"))
        e.onBackground()
    }

    @Test
    fun aBadKeyFailsLoudlyInsteadOfOpeningAnything() = walletTest {
        val e = CashuWalletEngine(
            openNative = { _, _, _ -> throw CashuWalletException.InvalidInput("bad nsec") },
            storageRoot = { "/root" },
            prefs = MapWalletPrefs(),
            files = RecordingWalletFiles(),
            io = StandardTestDispatcher(testScheduler),
        )
        e.setup(nsec)
        runCurrent()
        assertTrue(e.state.value is WalletState.Failed)
        assertFalse(e.isOpen())
        assertEquals(SendErrorKind.NotReady, e.send("lno1", 1, "").errorKind)
        assertFailsWith<CashuWalletException> { e.receiveOffer() }
        assertEquals(SendErrorKind.NotReady, (e.quoteFee("lno1", 1) as WalletOutcome.Failed).kind)
        assertEquals(SendErrorKind.NotReady, (e.receiveInvoice(1) as WalletOutcome.Failed).kind)
    }

    // ── Fee before confirm (send sheet) ──

    @Test
    fun aFeeQuoteIsTheMintsReserveAndSpendsNothing() = walletTest {
        val native = FakeCashuNative(confirmedSats = 10_000, feeReserveSats = 7)
        val e = engine(native)
        e.setup(nsec)
        runCurrent()

        assertEquals(WalletOutcome.Ok(7L), e.quoteFee("lno1peer", 500))
        // amountSats 0 = the invoice speaks for its own amount, as in `send`.
        assertEquals(WalletOutcome.Ok(7L), e.quoteFee("lnbc5u1pfake", 0))
        assertEquals(listOf<Long?>(500L, null), native.preparedAmounts)
        assertEquals(0, native.count("send"), "a quote never spends")
        assertEquals(10_000L, e.refreshBalance(), "and never touches the balance")
        e.onBackground()
    }

    @Test
    fun aFeeQuoteRefusalIsTyped() = walletTest {
        val native = FakeCashuNative(confirmedSats = 10_000)
        val e = engine(native)
        e.setup(nsec)
        runCurrent()
        val cases = listOf(
            { CashuWalletException.Network("down") } to SendErrorKind.Offline,
            { CashuWalletException.Timeout() } to SendErrorKind.Offline,
            { CashuWalletException.Busy("connecting") } to SendErrorKind.Busy,
            { CashuWalletException.InvalidDestination("bad") } to SendErrorKind.InvalidDestination,
            { CashuWalletException.Unsupported("onchain") } to SendErrorKind.Unsupported,
            { CashuWalletException.InsufficientFunds() } to SendErrorKind.InsufficientFunds,
            { CashuWalletException.Backend("mint 500") } to SendErrorKind.Failed,
        )
        for ((error, kind) in cases) {
            native.prepareError = error
            val r = e.quoteFee("lno1peer", 500)
            assertEquals(kind, (r as? WalletOutcome.Failed)?.kind, "quote refused with ${error()}")
        }
        native.prepareError = null
        assertEquals(SendErrorKind.InvalidDestination, (e.quoteFee("  ", 500) as WalletOutcome.Failed).kind)
        assertEquals(0, native.count("send"))
        e.onBackground()
    }

    @Test
    fun aFeeQuoteNeverConnectsAnOfflineWallet() = walletTest {
        val native = FakeCashuNative(confirmedSats = 10_000).apply {
            connectError = { CashuWalletException.Network("down") }
        }
        val e = engine(native)
        e.setup(nsec)
        runCurrent()
        val connects = native.count("connect")
        assertEquals(SendErrorKind.Offline, (e.quoteFee("lno1peer", 500) as WalletOutcome.Failed).kind)
        assertEquals(connects, native.count("connect"), "the quote leaves connecting to the retry loop")
        e.onBackground()
    }

    // ── Receive: one-time invoice ──

    @Test
    fun aReceiveInvoiceIsTheWalletsBolt11ForThatAmount() = walletTest {
        val native = FakeCashuNative()
        val e = engine(native)
        e.setup(nsec)
        runCurrent()
        assertEquals(WalletOutcome.Ok(CashuInvoice("lnbc2100fake", "mint-quote-2100")), e.receiveInvoice(2_100))
        assertEquals(listOf(2_100L), native.invoiceAmounts)
        e.onBackground()
    }

    @Test
    fun aReceiveInvoiceRefusalIsTyped() = walletTest {
        val native = FakeCashuNative()
        val e = engine(native)
        e.setup(nsec)
        runCurrent()

        val zero = e.receiveInvoice(0) as WalletOutcome.Failed
        assertEquals(SendErrorKind.Failed, zero.kind)
        assertEquals(0, native.count("receiveInvoice"), "no amount: the mint is never asked")

        val cases = listOf(
            { CashuWalletException.Network("down") } to SendErrorKind.Offline,
            { CashuWalletException.Busy("connecting") } to SendErrorKind.Busy,
            { CashuWalletException.InvalidInput("amount above limit") } to SendErrorKind.InvalidDestination,
            { CashuWalletException.Unsupported("bolt11") } to SendErrorKind.Unsupported,
            { CashuWalletException.Backend("mint 500") } to SendErrorKind.Failed,
        )
        for ((error, kind) in cases) {
            native.invoiceError = error
            assertEquals(kind, (e.receiveInvoice(1_000) as? WalletOutcome.Failed)?.kind, "invoice refused with ${error()}")
        }
        native.invoiceError = null
        native.connected = false
        assertEquals(SendErrorKind.Offline, (e.receiveInvoice(1_000) as WalletOutcome.Failed).kind)
        e.onBackground()
    }
}
