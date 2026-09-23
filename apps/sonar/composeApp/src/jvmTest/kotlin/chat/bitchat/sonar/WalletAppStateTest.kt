package chat.bitchat.sonar

import chat.bitchat.sonar.wallet.CashuEvent
import chat.bitchat.sonar.wallet.CashuPayment
import chat.bitchat.sonar.wallet.CashuPaymentStatus
import chat.bitchat.sonar.wallet.CashuWalletEngine
import chat.bitchat.sonar.wallet.CashuWalletException
import chat.bitchat.sonar.wallet.CoreWalletPrefs
import chat.bitchat.sonar.wallet.FakeCashuNative
import chat.bitchat.sonar.wallet.LegacyBreezStore
import chat.bitchat.sonar.wallet.LegacyBreezWallet
import chat.bitchat.sonar.wallet.MapWalletPrefs
import chat.bitchat.sonar.wallet.PaymentActivityStore
import chat.bitchat.sonar.wallet.PaymentInFlightException
import chat.bitchat.sonar.wallet.SonarPaymentActivity
import chat.bitchat.sonar.wallet.WalletBridge
import chat.bitchat.sonar.wallet.cashuAccountId
import chat.bitchat.sonar.wallet.fetchFiatRatesNative
import chat.bitchat.sonar.wallet.platformWalletFiles
import java.io.File
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
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
