package chat.bitchat.sonar

import chat.bitchat.sonar.wallet.CashuEvent
import chat.bitchat.sonar.wallet.CashuInvoice
import chat.bitchat.sonar.wallet.CashuPayment
import chat.bitchat.sonar.wallet.CashuPaymentStatus
import chat.bitchat.sonar.wallet.CashuWalletEngine
import chat.bitchat.sonar.wallet.CashuWalletException
import chat.bitchat.sonar.wallet.CoreWalletPrefs
import chat.bitchat.sonar.wallet.FakeCashuNative
import chat.bitchat.sonar.wallet.HandleAddressNotice
import chat.bitchat.sonar.wallet.HandleAddressRecord
import chat.bitchat.sonar.wallet.HandleAddressWallet
import chat.bitchat.sonar.wallet.HandleMoveState
import chat.bitchat.sonar.wallet.LegacyWalletPresence
import chat.bitchat.sonar.wallet.LegacyBreezStore
import chat.bitchat.sonar.wallet.LegacyBreezWallet
import chat.bitchat.sonar.wallet.MapWalletPrefs
import chat.bitchat.sonar.wallet.PaymentActivityStore
import chat.bitchat.sonar.wallet.PaymentInFlightException
import chat.bitchat.sonar.wallet.SendErrorKind
import chat.bitchat.sonar.wallet.WalletOutcome
import chat.bitchat.sonar.wallet.SonarPaymentActivity
import chat.bitchat.sonar.wallet.WalletBridge
import chat.bitchat.sonar.wallet.cashuAccountId
import chat.bitchat.sonar.wallet.fetchFiatRatesNative
import chat.bitchat.sonar.wallet.platformWalletFiles
import java.io.File
import java.nio.file.Files
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The wallet as the REAL [SonarAppState] drives it, over a fake Cashu native
 * and a throwaway desktop data dir: the app-state call sites (setup, CAP_PAY,
 * sends, restore, panic wipe), not helpers fed by the test.
 */
class WalletAppStateTest {

    private val nsec = "nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5"
    private lateinit var root: File
    private lateinit var native: FakeCashuNative
    private lateinit var engine: CashuWalletEngine
    private val scopeJob = Job()

    @BeforeTest
    fun setUp() {
        root = Files.createTempDirectory("sonar-wallet-state").toFile()
        DesktopEnv.useTestRoot(root)
        // Never the real keychain namespace (Account Key Durability Rule).
        DesktopSecrets.useTestService("chat.bitchat.sonar.wallettest")
        DesktopSecrets.put("nsec", nsec)
        native = FakeCashuNative()
        engine = CashuWalletEngine(
            openNative = { _, _, _ -> native },
            storageRoot = { DesktopEnv.dataDir.absolutePath },
            prefs = MapWalletPrefs(),
            files = platformWalletFiles(),
            retryDelaysMs = listOf(50L),
        )
        WalletBridge.useEngineForTest(engine)
        WalletBridge.ratesSource = { emptyList() }
    }

    @AfterTest
    fun tearDown() {
        scopeJob.cancel()
        native.onCall = {}
        runBlocking { runCatching { engine.release() } }
        WalletBridge.useEngineForTest(null)
        WalletBridge.ratesSource = ::fetchFiatRatesNative
        runCatching { DesktopSecrets.clear("nsec") }
        DesktopSecrets.resetService()
        DesktopEnv.useTestRoot(null)
    }

    private fun state() = SonarAppState(CoroutineScope(Dispatchers.Default + scopeJob))

    private suspend fun waitUntil(what: String, timeoutMs: Long = 5_000, cond: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (!cond()) {
            check(System.currentTimeMillis() < deadline) { "timed out waiting for: $what" }
            delay(10)
        }
    }

    /**
     * Run [block] on a stand-in main thread and return the native calls that
     * ran ON it — the app must make none (every native call hops to IO).
     */
    private suspend fun nativeCallsOnMain(block: suspend () -> Unit): List<String> {
        val mainExec = Executors.newSingleThreadExecutor { r -> Thread(r, "fake-main") }
        val main = mainExec.asCoroutineDispatcher()
        val offenders = CopyOnWriteArrayList<String>()
        // startsWith: under -ea kotlinx appends " @coroutine#N" to thread names.
        native.onCall = { if (Thread.currentThread().name.startsWith("fake-main")) offenders += it }
        try {
            withContext(main) { block() }
        } finally {
            native.onCall = {}
            main.close()
            mainExec.shutdownNow()
        }
        return offenders.toList()
    }

    private fun seedPayableChat(s: SonarAppState, chatId: String, offer: String) = s.seedCallableChatForTest(
        chatId,
        "npub1zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygse4sl3h",
        SonarDescriptor(
            schema = 1,
            calls = false,
            media = emptyList(),
            signaling = listOf("marmot"),
            transports = emptyList(),
            callIdentity = "",
            bolt12Offer = offer,
            paymentReceipts = emptyList(),
            publishedAtSecs = 0,
        ),
    )

    @Test
    fun theSendSheetFeeLineIsTheMintsQuotedReserveFetchedOffMain() = runBlocking {
        native.confirmedSats = 10_000
        native.feeReserveSats = 9
        val s = state()
        s.setupWallet()
        waitUntil("online") { WalletBridge.isOpen() && s.walletOnline }
        seedPayableChat(s, "fee-quote-peer-group", "lno1peeroffer")

        val onMain = nativeCallsOnMain {
            assertEquals(9L, s.quoteSendFee("lno1destination", 500))
            // A fixed invoice is quoted at its own amount — exactly how it is sent.
            assertEquals(9L, s.quoteSendFee("lnbc5u1pfakeinvoice", 500))
            // A contact: its cached offer, priced at the typed amount.
            assertEquals(9L, s.quoteChatPayFee("fee-quote-peer-group", 700))
        }
        assertEquals(emptyList<String>(), onMain, "the fee quote must never run the native on the main thread")
        assertEquals(listOf<Long?>(500L, null, 700L), native.preparedAmounts)
        assertEquals(0, native.count("send"), "quoting never pays")

        // No quote ⇒ no line (null), and the send is never blocked on it.
        assertNull(s.quoteChatPayFee("no-such-chat", 700), "no cached offer: no quote, and no fetch")
        assertNull(s.quoteSendFee("lno1destination", 0))
        native.prepareError = { CashuWalletException.Network("mint down") }
        assertNull(s.quoteSendFee("lno1destination", 500), "a refused quote hides the line")
    }

    @Test
    fun theReceiveSheetInvoiceIsTypedAndAnIncomingPaymentIsSurfaced() = runBlocking {
        val s = state()
        s.setupWallet()
        waitUntil("online") { WalletBridge.isOpen() && s.walletOnline }

        val onMain = nativeCallsOnMain {
            assertEquals(WalletOutcome.Ok(CashuInvoice("lnbc2100fake", "mint-quote-2100")), s.createReceiveInvoice(2_100))
            native.invoiceError = { CashuWalletException.Busy("syncing") }
            assertEquals(SendErrorKind.Busy, (s.createReceiveInvoice(2_100) as WalletOutcome.Failed).kind)
            native.invoiceError = { CashuWalletException.Network("mint down") }
            assertEquals(SendErrorKind.Offline, (s.createReceiveInvoice(2_100) as WalletOutcome.Failed).kind)
        }
        assertEquals(emptyList<String>(), onMain, "the invoice call must never run the native on the main thread")
        assertEquals(listOf(2_100L), native.invoiceAmounts)

        // The sheet's "Received …" line reads this.
        assertNull(s.lastIncomingWalletPayment)
        native.emit(
            CashuEvent.PaymentReceived(
                CashuPayment("q:rx", true, 2_100, null, 1_700_000_000, CashuPaymentStatus.Pending, null, null),
            ),
        )
        waitUntil("incoming surfaced") { s.lastIncomingWalletPayment?.paymentId == "q:rx" }
        assertEquals(2_100L, s.lastIncomingWalletPayment?.amountSats)
        // An outgoing settlement is never shown as received.
        native.emit(
            CashuEvent.PaymentSent(
                CashuPayment("q:tx", false, 50, 1, 1_700_000_050, CashuPaymentStatus.Complete, "pre", null),
            ),
        )
        delay(150)
        assertEquals("q:rx", s.lastIncomingWalletPayment?.paymentId)
    }

    /** A payment from outside Sonar (another wallet paying the receive offer
     *  or a one-time invoice) has no chat line, so nothing announced it. */
    @Test
    fun anOutsidePaymentIsAnnouncedOnceWhenItSettles() = runBlocking {
        val s = state()
        val posted = CopyOnWriteArrayList<SonarNotification>()
        s.postNotification = { posted += it }
        s.walletReceiveGraceMs = 100
        s.setupWallet()
        waitUntil("online") { WalletBridge.isOpen() && s.walletOnline }

        val rx = CashuPayment("q1:rx", true, 2_100, null, 1_700_000_000, CashuPaymentStatus.Complete, null, null)
        native.emit(CashuEvent.PaymentReceived(rx))
        native.emit(CashuEvent.PaymentReceived(rx)) // a replay
        native.emit(
            CashuEvent.PaymentSent(
                CashuPayment("q3:tx", false, 90, 1, 1_700_000_010, CashuPaymentStatus.Complete, "pre", null),
            ),
        )
        waitUntil("receive surfaced") { s.lastIncomingWalletPayment?.paymentId == "q1:rx" }
        delay(400)

        assertEquals(listOf("Payment received"), posted.map { it.title }, "exactly one banner, for the receive")
        assertEquals("2,100 sats received.", posted.single().body)
    }

    /** A chat ⚡PAY is announced by its chat line; the wallet cannot link the
     *  receive to it (the payer pays the public offer), so without pairing
     *  every chat payment raised a second "Payment received" banner. */
    @Test
    fun aChatPaymentIsAnnouncedByItsChatLineOnly() = runBlocking {
        val s = state()
        val posted = CopyOnWriteArrayList<SonarNotification>()
        s.postNotification = { posted += it }
        s.walletReceiveGraceMs = 300
        s.setupWallet()
        waitUntil("online") { WalletBridge.isOpen() && s.walletOnline }
        val now = System.currentTimeMillis() / 1_000
        fun payLine(id: String, uuid: String, sats: Long, mine: Boolean = false) =
            SonarMsg(id, "npub1peer", PayLine.Pay(uuid, sats).encoded(), mine, now)
        fun receive(id: String, sats: Long) = native.emit(
            CashuEvent.PaymentReceived(
                CashuPayment(id, true, sats, null, now, CashuPaymentStatus.Complete, null, null),
            ),
        )

        // The chat line lands first, then the wallet mints the payment.
        s.processPayLines("chat-a", listOf(payLine("m1", "u1", 210)))
        receive("chatpay1:rx", 210)
        // The wallet sees the payment before the chat line arrives.
        receive("chatpay2:rx", 350)
        waitUntil("second receive surfaced") { s.lastIncomingWalletPayment?.paymentId == "chatpay2:rx" }
        s.processPayLines("chat-a", listOf(payLine("m2", "u2", 350)))
        // Our own ⚡PAY never pairs with a receive, and a payment nobody
        // announced still gets its banner.
        s.processPayLines("chat-a", listOf(payLine("m3", "u3", 777, mine = true)))
        receive("chatpay3:rx", 777)
        waitUntil("third receive surfaced") { s.lastIncomingWalletPayment?.paymentId == "chatpay3:rx" }
        delay(900)

        assertEquals(
            listOf("777 sats received."),
            posted.map { it.body },
            "only the payment no chat line announced gets a wallet banner",
        )
    }

    @Test
    fun capPayMeansACashuOfferExistsNotABreezKey() = runBlocking {
        native.offer = null
        native.offerError = { CashuWalletException.NotConnected() }
        native.connectError = { CashuWalletException.Network("mint down") }
        val s = state()
        s.setupWallet()
        waitUntil("wallet constructed") { WalletBridge.isOpen() }
        delay(150)
        assertEquals(
            0, s.capabilities() and SonarAnnounce.CAP_PAY,
            "no Cashu offer ⇒ no payments bit, whatever the Breez key says " +
                "(this build hasApiKey=${LegacyBreezWallet.hasApiKey()})",
        )

        native.offerError = null
        native.connectError = null
        native.offer = "lno1cashuoffer"
        waitUntil("offer published") { s.cashuOffer == "lno1cashuoffer" }
        assertEquals(SonarAnnounce.CAP_PAY, s.capabilities() and SonarAnnounce.CAP_PAY)
    }

    /** Every 0x53 packet the real mesh engine would put on the air for [payload]. */
    private fun sonarAnnouncePackets(payload: ByteArray): List<ByteArray> {
        val key = "11".repeat(32)
        val engine = uniffi.sonar_ffi.MeshLinkEngine(key, key, key, "qa")
        return try {
            engine.setSonarPayload(payload, 0)
            engine.onServerSubscribed("central", 0).commands
                .filterIsInstance<uniffi.sonar_ffi.MeshEngineCommand.NotifyConn>()
                .map { it.bytes }
                .filter { it.size > 1 && it[1] == SonarAnnounce.PACKET_TYPE.toByte() }
        } finally {
            engine.close()
        }
    }

    @Test
    fun theMeshAnnounceCarryingTheCashuOfferFitsOneBleAttribute() = runBlocking {
        // An Android 13+ radio throws on a GATT notify or write over 512 bytes,
        // and the app crash-looped whenever another Sonar was in range: every
        // install now has a mint offer (~400 chars) and the announce carried it.
        SonarCore.saveBlob("sonar.npub", "npub1zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygse4sl3h")
        SonarCore.setOnboardingComplete(true)
        val shortOffer = "lno1" + "q".repeat(196)
        native.offer = shortOffer
        val s = state()
        s.setupWallet()
        waitUntil("the offer reaches the announce") { s.localSonarAnnounce()?.bolt12Offer == shortOffer }
        assertTrue(sonarAnnouncePackets(s.localSonarAnnounce()!!.encode()).all { it.size <= 512 })

        val mintOffer = "lno1" + "q".repeat(396)
        val oversized = sonarAnnouncePackets(s.localSonarAnnounce()!!.copy(bolt12Offer = mintOffer).encode())
        assertTrue(oversized.isNotEmpty() && oversized.all { it.size > 512 }, "premise: this offer does not fit")

        native.offer = mintOffer
        engine.onForeground() // re-reads the offer, as a return to the app does
        waitUntil("the mint offer is published") { s.cashuOffer == mintOffer }
        waitUntil("the announce follows the new offer") { s.localSonarAnnounce()?.bolt12Offer != shortOffer }
        val announce = s.localSonarAnnounce()!!
        assertNull(announce.bolt12Offer, "an offer that does not fit stays off the mesh")
        assertEquals(SonarAnnounce.CAP_PAY, announce.capabilities and SonarAnnounce.CAP_PAY, "still payable")
        val packets = sonarAnnouncePackets(announce.encode())
        assertTrue(packets.isNotEmpty() && packets.all { it.size <= 512 }, "sizes ${packets.map { it.size }}")
    }

    /** The registrar as the app state reaches it, captured. */
    private class Registrar {
        val claims = CopyOnWriteArrayList<Pair<String, String?>>()
        @Volatile var fail = false
    }

    /**
     * A state whose account claimed `alice@…` (the core sidecar), with the
     * registrar captured and the legacy presence pinned (the real presence
     * opens Breez when this build carries a key).
     */
    private fun handleState(presence: LegacyWalletPresence, registrar: Registrar): SonarAppState {
        val s = state()
        s.handleClaimer = { name, offer ->
            registrar.claims += name to offer
            if (registrar.fail) throw IllegalStateException("registrar down")
            "$name@sonarprivacy.xyz"
        }
        s.legacyPresenceForTest = presence
        s.seedClaimedHandleForTest("alice@sonarprivacy.xyz")
        return s
    }

    /**
     * The reported scenario (PR #614 review, H3): an address claimed on the
     * Breez wallet, which is still here. Publishing the Cashu offer — on
     * setup, and again when the offer rotates — must NOT re-register the
     * handle; the notice says where it pays; the confirmed Move registers
     * the Cashu offer and records it for this account.
     */
    @Test
    fun anAddressOnTheOldWalletMovesOnlyOnAConfirmedMove() = runBlocking {
        val registrar = Registrar()
        val s = handleState(LegacyWalletPresence.Present, registrar)
        s.setupWallet()
        waitUntil("offer published") { s.cashuOffer == "lno1fakeoffer" }
        native.offer = "lno1rotatedoffer"
        engine.onForeground() // re-reads the offer: the descriptor publish runs again
        waitUntil("rotated offer published") { s.cashuOffer == "lno1rotatedoffer" }
        delay(600)
        assertEquals(
            emptyList<Pair<String, String?>>(), registrar.claims.toList(),
            "the handle must not be re-registered with the Cashu offer without consent",
        )
        assertEquals(HandleAddressNotice.PaysOldWallet("alice@sonarprivacy.xyz"), s.handleAddressNotice)
        assertNull(s.handleAddressWallet)
        assertFalse(s.canMoveHandleBackToOldWallet)

        s.moveHandleToNewWallet()
        waitUntil("the move registered") { s.handleAddressWallet == HandleAddressWallet.Cashu }
        assertEquals(listOf<Pair<String, String?>>("alice" to "lno1rotatedoffer"), registrar.claims.toList())
        assertEquals(HandleMoveState.Idle, s.handleMoveState)
        assertEquals(HandleAddressNotice.None, s.handleAddressNotice)
        assertTrue(s.canMoveHandleBackToOldWallet, "the old wallet is still here: offer the way back")
        assertEquals(
            HandleAddressRecord(HandleAddressWallet.Cashu, "lno1rotatedoffer"),
            HandleAddressRecord.load(CoreWalletPrefs, cashuAccountId(nsec)),
            "persisted per account, so the next launch neither asks again nor re-registers",
        )

        // From now on the handle follows the Cashu offer, once per offer.
        native.offer = "lno1thirdoffer"
        engine.onForeground()
        waitUntil("the rotated offer registered") { registrar.claims.size == 2 }
        assertEquals("alice" to "lno1thirdoffer", registrar.claims.last())
    }

    /**
     * Positive control for the test above: with no old wallet here, the same
     * descriptor publish DOES register the Cashu offer (nothing to move away
     * from), so that test's silence is the decision, not a dead path.
     */
    @Test
    fun withNoOldWalletTheDescriptorPublishRegistersTheCashuOffer() = runBlocking {
        val registrar = Registrar()
        val s = handleState(LegacyWalletPresence.Absent, registrar)
        s.setupWallet()
        waitUntil("re-registered") { s.handleAddressWallet == HandleAddressWallet.Cashu }
        assertEquals(listOf<Pair<String, String?>>("alice" to "lno1fakeoffer"), registrar.claims.toList())
        assertEquals(HandleAddressNotice.None, s.handleAddressNotice)
    }

    /** A failed Move leaves the address where it was, and says so. */
    @Test
    fun aFailedMoveLeavesTheAddressOnTheOldWallet() = runBlocking {
        val registrar = Registrar().apply { fail = true }
        val s = handleState(LegacyWalletPresence.Present, registrar)
        s.setupWallet()
        waitUntil("offer published") { s.cashuOffer == "lno1fakeoffer" }
        s.moveHandleToNewWallet()
        waitUntil("the move failed") { s.handleMoveState is HandleMoveState.Failed }
        assertEquals(1, registrar.claims.size)
        assertNull(s.handleAddressWallet)
        assertEquals(HandleAddressNotice.PaysOldWallet("alice@sonarprivacy.xyz"), s.handleAddressNotice)
    }

    /** A failed automatic re-registration is surfaced and backed off, not retried silently. */
    @Test
    fun aFailedAutomaticUpdateIsSurfaced() = runBlocking {
        val registrar = Registrar().apply { fail = true }
        val s = handleState(LegacyWalletPresence.Absent, registrar)
        s.setupWallet()
        waitUntil("the failure is shown") {
            s.handleAddressNotice == HandleAddressNotice.UpdateFailing("alice@sonarprivacy.xyz")
        }
        delay(300)
        assertEquals(1, registrar.claims.size, "retried with backoff, not in a tight loop")
        assertNull(s.handleAddressWallet)
    }

    @Test
    fun aFreshInstallNeverCreatesTheBreezStore() = runBlocking {
        val s = state()
        s.setupWallet()
        waitUntil("wallet constructed") { WalletBridge.isOpen() }
        // The exact function setupWallet launches, awaited so the assertion
        // below cannot race it.
        s.setupLegacyWallet(nsec)
        assertFalse(File(root, "sonar-wallet").exists(), "a new install must never create a Breez store")
        assertFalse(File(root, "sonar-wallet-archive").exists())
        assertFalse(s.legacyWallet.present)
        assertNull(
            CoreWalletPrefs.get(LegacyBreezStore.restoreCheckKey(cashuAccountId(nsec))),
            "a fresh install is not a restore: no Breez check is scheduled",
        )
    }

    @Test
    fun aPendingPaymentStaysPendingAndItsLaterEventSettlesItOnce() = runBlocking {
        native.confirmedSats = 10_000
        native.sendStatus = CashuPaymentStatus.Pending
        val s = state()
        s.setupWallet()
        waitUntil("online") { WalletBridge.isOpen() && s.walletOnline }

        // The record is linked to the wallet payment BEFORE the spending call,
        // so a process death inside `send` still leaves something to look up.
        var linkedBeforeSend: Boolean? = null
        native.onCall = { name ->
            if (name == "send") {
                linkedBeforeSend = PaymentActivityStore.sorted()
                    .any { it.peerName == "Dest" && it.status == SonarPaymentActivity.Status.Pending && it.walletPaymentId != null }
            }
        }
        val id = assertNotNull(s.beginDestinationPayment("lno1destination", 500, "Dest"))
        waitUntil("pending linked") { PaymentActivityStore.get(id)?.walletPaymentId != null }
        val row = PaymentActivityStore.get(id)!!
        assertEquals(SonarPaymentActivity.Status.Pending, row.status, "Pending is not a failure")
        assertEquals(1, native.count("send"))
        assertEquals(true, linkedBeforeSend, "linked before the spending call")

        native.emit(
            CashuEvent.PaymentSent(
                CashuPayment(row.walletPaymentId!!, false, 500, 1, 1_700_000_500, CashuPaymentStatus.Complete, "pre", null),
            ),
        )
        waitUntil("settled") { PaymentActivityStore.get(id)?.status == SonarPaymentActivity.Status.Paid }
        delay(100)
        assertEquals(1, native.count("send"), "a pending payment is never re-sent")
    }

    @Test
    fun aPendingPaymentMissedByTheListenerSettlesOnReconnect() = runBlocking {
        native.confirmedSats = 10_000
        native.sendStatus = CashuPaymentStatus.Pending
        val s = state()
        s.setupWallet()
        waitUntil("online") { WalletBridge.isOpen() && s.walletOnline }
        val id = assertNotNull(s.beginDestinationPayment("lno1destination", 400, "Dest"))
        waitUntil("pending linked") { PaymentActivityStore.get(id)?.walletPaymentId != null }

        WalletBridge.onBackground()
        waitUntil("offline") { !s.walletOnline }
        // Resolved while we were away; no event reaches us.
        native.settleSilently(PaymentActivityStore.get(id)!!.walletPaymentId!!, CashuPaymentStatus.Failed)
        WalletBridge.onForeground()
        waitUntil("reconciled") { PaymentActivityStore.get(id)?.status == SonarPaymentActivity.Status.Failed }
        assertEquals(1, native.count("send"))
    }

    /**
     * A send the wallet reported Failed, whose melt the mint then paid (an
     * ambiguous confirm): the later Complete for the same wallet payment
     * must settle the row as paid, not leave "you were not charged" on a
     * payment that went through. A later Failed never un-pays it.
     */
    @Test
    fun aSendReportedFailedIsPaidWhenTheWalletLaterCompletesIt() = runBlocking {
        native.confirmedSats = 10_000
        native.sendStatus = CashuPaymentStatus.Failed
        val s = state()
        s.setupWallet()
        waitUntil("online") { WalletBridge.isOpen() && s.walletOnline }
        val id = assertNotNull(s.beginDestinationPayment("lno1destination", 600, "Dest"))
        waitUntil("failed") { PaymentActivityStore.get(id)?.status == SonarPaymentActivity.Status.Failed }
        val walletId = assertNotNull(PaymentActivityStore.get(id)!!.walletPaymentId, "linked before the send")

        native.emit(
            CashuEvent.PaymentSent(
                CashuPayment(walletId, false, 600, 1, 1_700_000_600, CashuPaymentStatus.Complete, "pre", null),
            ),
        )
        waitUntil("paid after failing") { PaymentActivityStore.get(id)?.status == SonarPaymentActivity.Status.Paid }
        assertNull(PaymentActivityStore.get(id)!!.failure)

        native.emit(
            CashuEvent.PaymentFailed(
                CashuPayment(walletId, false, 600, 0, 1_700_000_601, CashuPaymentStatus.Failed, null, null),
            ),
        )
        delay(200)
        assertEquals(SonarPaymentActivity.Status.Paid, PaymentActivityStore.get(id)!!.status, "paid is final")
        assertEquals(1, native.count("send"), "nothing is ever re-sent")
    }

    @Test
    fun aPendingChatPayIsReceiptedOnlyOnceItSettles() = runBlocking {
        native.confirmedSats = 10_000
        native.sendStatus = CashuPaymentStatus.Pending
        val s = state()
        s.setupWallet()
        waitUntil("online") { WalletBridge.isOpen() && s.walletOnline }
        val chatId = "cashu-pay-peer-group"
        s.seedCallableChatForTest(
            chatId,
            "npub1zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygse4sl3h",
            SonarDescriptor(
                schema = 1,
                calls = false,
                media = emptyList(),
                signaling = listOf("marmot"),
                transports = emptyList(),
                callIdentity = "",
                bolt12Offer = "lno1peeroffer",
                paymentReceipts = emptyList(),
                publishedAtSecs = 0,
            ),
        )
        assertNull(s.sendPay(chatId, 700))
        // The pending branch's last step: everything it does has happened.
        waitUntil("pending branch done") { s.toast == "Payment is on its way — it shows in the chat once it settles." }
        val row = PaymentActivityStore.sorted().first { it.peerKey == chatId && it.walletPaymentId != null }
        assertEquals(SonarPaymentActivity.Status.Pending, row.status)
        assertNull(s.payStatus(row.id), "no ⚡PAY receipt while the payment is only in flight")

        native.emit(
            CashuEvent.PaymentSent(
                CashuPayment(row.walletPaymentId!!, false, 700, 1, 1_700_000_700, CashuPaymentStatus.Complete, "pre", null),
            ),
        )
        waitUntil("settled") { PaymentActivityStore.get(row.id)?.status == SonarPaymentActivity.Status.Paid }
        waitUntil("receipt recorded") { s.payStatus(row.id) != null }
        assertEquals(1, native.count("send"))
    }

    @Test
    fun accountReplacementKeepsEveryWalletThatMayHoldFunds() = runBlocking {
        val oldId = cashuAccountId(nsec)
        val proofs = File(root, "sonar-cashu/$oldId/mainnet/cashu.redb").apply { parentFile.mkdirs(); writeText("proofs") }
        val breez = File(root, "sonar-wallet/mainnet/storage.sql").apply { parentFile.mkdirs(); writeText("breez") }
        WalletBridge.setupIfNeeded(nsec)

        state().setAsideWalletsForAccountReplacement()

        assertTrue(proofs.isFile, "sonar-cashu/<oldAccountId>/ must survive a restore")
        assertFalse(native.wiped)
        assertTrue(native.closed)
        assertFalse(WalletBridge.isOpen())
        // Unverifiable legacy funds: archived under the old account, not deleted.
        assertFalse(breez.exists())
        assertTrue(File(root, "sonar-wallet-archive/$oldId/mainnet/storage.sql").isFile)
        // …and handed back when that account returns.
        assertTrue(LegacyBreezWallet.isPresent(oldId))
        assertTrue(breez.isFile)
    }

    @Test
    fun accountReplacementRefusesWhileAPaymentIsInFlight() = runBlocking {
        native.confirmedSats = 10_000
        WalletBridge.setupIfNeeded(nsec)
        waitUntil("online") { engine.online.value }
        val entered = CountDownLatch(1)
        val proceed = CountDownLatch(1)
        native.onCall = { if (it == "send") { entered.countDown(); proceed.await(5, TimeUnit.SECONDS) } }
        val sending = async(Dispatchers.Default) { WalletBridge.send("lno1peer", 100, "n") }
        assertTrue(entered.await(5, TimeUnit.SECONDS))
        assertFailsWith<PaymentInFlightException> { state().setAsideWalletsForAccountReplacement() }
        proceed.countDown()
        assertTrue(sending.await().ok)
    }

    @Test
    fun panicWipeRemovesEveryWalletStore() = runBlocking {
        File(root, "sonar-cashu/acct-a/mainnet/cashu.redb").apply { parentFile.mkdirs(); writeText("a") }
        File(root, "sonar-cashu/acct-b/mainnet/cashu.redb").apply { parentFile.mkdirs(); writeText("b") }
        File(root, "sonar-wallet/mainnet/storage.sql").apply { parentFile.mkdirs(); writeText("breez") }
        File(root, "sonar-wallet-archive/acct-c/mainnet/storage.sql").apply { parentFile.mkdirs(); writeText("c") }
        WalletBridge.setupIfNeeded(nsec)

        val (shutdownFailure, wipeFailure) = state().wipeWalletStorage()

        assertNull(shutdownFailure)
        assertNull(wipeFailure)
        assertFalse(File(root, "sonar-cashu").exists(), "every sonar-cashu root goes")
        assertFalse(File(root, "sonar-wallet").exists())
        assertFalse(File(root, "sonar-wallet-archive").exists())
        assertTrue(native.wiped)
    }
}
