package chat.bitchat.sonar.wallet

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking

class WalletSeedTest {
    private val secret = "67dea2ed018072d675f5415ecfaed7d2597555e202d85b3d65ea4e58d2d92ffa"
    private val vectorSecret = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    private val iosVectorEntropy = "801a82b16248f5c4c6363cae5ab6b9aff24724cb696ed41d936e53687c282806"

    @Test fun deterministic() {
        val a = WalletSeed.entropyHex(WalletSeed.hexToBytes(secret))
        val b = WalletSeed.entropyHex(WalletSeed.hexToBytes(secret))
        assertEquals(a, b)
        assertEquals(64, a.length) // 32 bytes hex
    }

    @Test fun differsByIdentity() {
        val other = "0000000000000000000000000000000000000000000000000000000000000001"
        assertNotEquals(
            WalletSeed.entropyHex(WalletSeed.hexToBytes(secret)),
            WalletSeed.entropyHex(WalletSeed.hexToBytes(other)),
        )
    }

    @Test fun breezSeedMatchesIosSeedV1() {
        val seed = WalletSeed.breezSeed(WalletSeed.hexToBytes(vectorSecret))

        assertEquals(32, seed.size)
        assertEquals(iosVectorEntropy, seed.toHex())
    }

    @Test fun notRawSecret() {
        // Entropy must be domain-separated, not the raw nsec bytes.
        assertNotEquals(secret, WalletSeed.entropyHex(WalletSeed.hexToBytes(secret)))
    }
}

private fun ByteArray.toHex(): String =
    joinToString("") { ((it.toInt() and 0xFF) + 0x100).toString(16).substring(1) }

class MoneyTest {
    @Test fun satsFormatting() {
        assertEquals("1,234 sats", Money.formatSats(1234))
        assertEquals("0 sats", Money.formatSats(0))
        assertEquals("100,000,000 sats", Money.formatSats(100_000_000))
    }

    @Test fun fiatNeedsLiveRate() {
        assertNull(Money.formatFiat(100_000_000, FiatCurrency.USD, null))
        // 1 BTC at $60,000 = $60,000.00
        assertEquals("$60,000.00", Money.formatFiat(100_000_000, FiatCurrency.USD, ExchangeRate("USD", 60_000.0)))
    }

    @Test fun fallsBackToSatsWithoutRate() {
        assertEquals("50,000 sats", Money.format(50_000, showFiat = true, FiatCurrency.USD, rate = null))
    }

    @Test fun showsFiatWhenRequestedAndRatePresent() {
        val out = Money.format(100_000_000, showFiat = true, FiatCurrency.EUR, ExchangeRate("EUR", 55_000.0))
        assertEquals("€55,000.00", out)
    }

    @Test fun currencyLookup() {
        assertEquals(FiatCurrency.GBP, FiatCurrency.of("gbp"))
        assertEquals(FiatCurrency.USD, FiatCurrency.of(null))
        assertEquals(FiatCurrency.USD, FiatCurrency.of("ZZZ"))
    }

    // iOS `hasLiveRate` predicate backing WalletBridge.hasLiveRate():
    // true only for a present, positive live rate — never a stale/zero one.
    @Test fun liveRatePredicate() {
        assertFalse(Money.isLiveRate(null))
        assertFalse(Money.isLiveRate(ExchangeRate("USD", 0.0)))
        assertFalse(Money.isLiveRate(ExchangeRate("USD", -1.0)))
        assertTrue(Money.isLiveRate(ExchangeRate("USD", 60_000.0)))
    }

    @Test fun liveRatePredicateMatchesFiatFormatting() {
        // The predicate and formatFiat must agree: fiat renders iff live rate.
        for (rate in listOf(null, ExchangeRate("EUR", 0.0), ExchangeRate("EUR", 55_000.0))) {
            assertEquals(
                Money.isLiveRate(rate),
                Money.formatFiat(100_000, FiatCurrency.EUR, rate) != null,
            )
        }
    }
}

class WalletMigrationContractTest {
    @Test fun pendingPhaseCarriesDestConfirmedSatsNotInvoice() {
        val invoiceSats = 2_000uL
        val destConfirmedSats = 500uL
        val pending = MigrationPhase.PendingSettlement(destConfirmedSats)
        val result = MigrationResultUi.Pending(destConfirmedSats)
        assertEquals(destConfirmedSats, pending.cashuSats)
        assertEquals(destConfirmedSats, result.cashuSats)
        assertNotEquals(invoiceSats, pending.cashuSats)
        assertNotEquals(invoiceSats, result.cashuSats)
    }

    @Test fun executeErrorAfterSourceAcceptedIsPendingNotANewQuote() {
        val dest = 500uL
        val failed = "payment failed"
        for (state in listOf(
            MigrationAttemptStateUi.Sending,
            MigrationAttemptStateUi.PaymentUnknown,
            MigrationAttemptStateUi.SourcePending,
            MigrationAttemptStateUi.SourcePaid,
            MigrationAttemptStateUi.MintPaid,
        )) {
            assertTrue(migrationAttemptBlocksNewQuote(state), "$state must not mint a second invoice")
            assertEquals(
                MigrationPhase.PendingSettlement(dest),
                phaseAfterExecuteError(state, dest, failed),
            )
        }
        assertEquals(
            MigrationPhase.Settled(dest),
            phaseAfterExecuteError(MigrationAttemptStateUi.Settled, dest, failed),
        )
        for (state in listOf(
            MigrationAttemptStateUi.AwaitingConsent,
            MigrationAttemptStateUi.ExpiredUnsent,
            MigrationAttemptStateUi.SourceFailed,
        )) {
            assertFalse(migrationAttemptBlocksNewQuote(state))
            assertEquals(
                MigrationPhase.Failed(failed),
                phaseAfterExecuteError(state, dest, failed),
            )
        }
        assertEquals(
            MigrationPhase.Failed(failed),
            phaseAfterExecuteError(null, dest, failed),
        )
    }

    @Test fun breezProseInsufficientFundsIsTheDrainSignal() {
        assertTrue(breezMessageLooksInsufficient("Cannot pay: not enough funds"))
        assertTrue(breezMessageLooksInsufficient("InsufficientFunds"))
        assertTrue(breezMessageLooksInsufficient("balance too low for this swap"))
        assertFalse(breezMessageLooksInsufficient("Boltz is unavailable"))
        assertFalse(breezMessageLooksInsufficient("timeout"))
    }

    @Test fun relaunchAfterPaidJournalIsPendingNotANewQuote() {
        val dest = 500uL
        val failed = "Lightning payment failed"
        for (state in listOf(
            MigrationAttemptStateUi.Sending,
            MigrationAttemptStateUi.PaymentUnknown,
            MigrationAttemptStateUi.SourcePending,
            MigrationAttemptStateUi.SourcePaid,
            MigrationAttemptStateUi.MintPaid,
        )) {
            assertTrue(migrationAttemptNeedsRescue(state), "$state must resume, not re-quote")
            assertEquals(
                MigrationPhase.PendingSettlement(dest),
                phaseAfterOpenStatus(state, 2_000uL, dest, failed),
            )
        }
        assertEquals(
            MigrationPhase.Idle,
            phaseAfterOpenStatus(null, 0uL, dest, failed),
        )
        assertEquals(
            MigrationPhase.Idle,
            phaseAfterOpenStatus(MigrationAttemptStateUi.AwaitingConsent, 2_000uL, dest, failed),
        )
        assertEquals(
            MigrationPhase.Settled(2_000uL),
            phaseAfterOpenStatus(MigrationAttemptStateUi.Settled, 2_000uL, dest, failed),
        )
        assertEquals(
            MigrationPhase.Failed(failed),
            phaseAfterOpenStatus(MigrationAttemptStateUi.SourceFailed, 2_000uL, dest, failed),
        )
        assertFalse(migrationAttemptNeedsRescue(MigrationAttemptStateUi.Settled))
    }

    @Test fun journalBytesNeedRescueWithoutOpeningTheMint() {
        fun journal(state: String) = """
            {
              "version": 1,
              "account_fingerprint": "aa",
              "mint_fingerprint": "bb",
              "attempt": {
                "settlement_id": "qid",
                "invoice": "lnbc1",
                "payment_hash": "hh",
                "amount_sats": 2000,
                "source_fee_sats": 20,
                "expires_at_secs": null,
                "source_payment_id": null,
                "state": "$state"
              }
            }
        """.trimIndent()
        assertEquals(
            MigrationAttemptStateUi.SourcePaid,
            parseJournalAttemptState(journal("SourcePaid")),
        )
        assertTrue(journalNeedsRescue(journal("Sending")))
        assertTrue(journalNeedsRescue(journal("PaymentUnknown")))
        assertTrue(journalNeedsRescue(journal("SourcePaid")))
        assertFalse(journalNeedsRescue(journal("AwaitingConsent")))
        assertFalse(journalNeedsRescue(journal("Settled")))
        assertFalse(journalNeedsRescue(journal("SourceFailed")))
        assertFalse(journalNeedsRescue(null))
        assertFalse(journalNeedsRescue("{}"))
        assertFalse(journalNeedsRescue(journal("NotAState")))
    }

    @Test fun paidJournalShowsOnHomeStripAfterRelaunch() {
        // Opposite of the live-payment H1 rule: a killed process with a
        // paid journal is exactly when the chat list has to offer rescue.
        assertTrue(showsMigrationRescueOnHomeStrip(true, true))
        assertFalse(showsMigrationRescueOnHomeStrip(false, true))
        assertFalse(showsMigrationRescueOnHomeStrip(true, false))
        assertFalse(showsMigrationRescueOnHomeStrip(false, false))
    }

    @Test fun openWithPaidJournalResumesAndDoesNotQuote() = runBlocking {
        var cancelled = 0
        var resumed = 0
        val quoted = 0
        val dest = 500uL
        val status = MigrationAttemptStatusUi(
            settlementId = "qid",
            amountSats = 2_000uL,
            feeSats = 20uL,
            state = MigrationAttemptStateUi.SourcePaid,
            paymentHash = "hh",
        )
        val phase = restoreOpenedMigration(
            status = status,
            destConfirmedSats = dest,
            lightningFailedMessage = "fail",
            cancelUnspent = { cancelled += 1 },
            resume = {
                resumed += 1
                MigrationResultUi.Pending(dest)
            },
        )
        assertEquals(0, cancelled)
        assertEquals(1, resumed)
        assertEquals(0, quoted)
        assertEquals(MigrationPhase.PendingSettlement(dest), phase)
    }

    @Test fun openWithUnspentConsentClearsAndDoesNotResume() = runBlocking {
        var cancelled = 0
        var resumed = 0
        val status = MigrationAttemptStatusUi(
            settlementId = "qid",
            amountSats = 2_000uL,
            feeSats = 20uL,
            state = MigrationAttemptStateUi.AwaitingConsent,
            paymentHash = "hh",
        )
        val phase = restoreOpenedMigration(
            status = status,
            destConfirmedSats = 0uL,
            lightningFailedMessage = "fail",
            cancelUnspent = { cancelled += 1 },
            resume = {
                resumed += 1
                MigrationResultUi.Pending(0uL)
            },
        )
        assertEquals(1, cancelled)
        assertEquals(0, resumed)
        assertEquals(MigrationPhase.Idle, phase)
    }

    @Test fun openResumeFailureStaysPendingNotANewQuote() = runBlocking {
        val dest = 500uL
        val status = MigrationAttemptStatusUi(
            settlementId = "qid",
            amountSats = 2_000uL,
            feeSats = 20uL,
            state = MigrationAttemptStateUi.Sending,
            paymentHash = "hh",
        )
        val phase = restoreOpenedMigration(
            status = status,
            destConfirmedSats = dest,
            lightningFailedMessage = "fail",
            cancelUnspent = {},
            resume = { error("mint timeout") },
        )
        assertEquals(MigrationPhase.PendingSettlement(dest), phase)
    }

    @Test
    fun backgroundRescueSkipsWhenJournalDoesNotNeedRescue() = runBlocking {
        var opened = 0
        var acquired = 0
        val phase = resumePaidCashuMigrationIfNeeded(
            peekNeedsRescue = false,
            acquireExclusive = { acquired += 1; true },
            releaseExclusive = {},
            open = {
                opened += 1
                error("must not open the mint")
            },
            lightningFailedMessage = "fail",
            polls = 24u,
        )
        assertNull(phase)
        assertEquals(0, acquired)
        assertEquals(0, opened)
    }

    @Test
    fun backgroundRescueSkipsWhenStoreAlreadyOwned() = runBlocking {
        var opened = 0
        val phase = resumePaidCashuMigrationIfNeeded(
            peekNeedsRescue = true,
            acquireExclusive = { false },
            releaseExclusive = { error("must not release a lock we never took") },
            open = {
                opened += 1
                error("must not open the mint")
            },
            lightningFailedMessage = "fail",
            polls = 24u,
        )
        assertNull(phase)
        assertEquals(0, opened)
    }

    @Test
    fun backgroundRescueResumesPaidJournalAndCloses() = runBlocking {
        var closed = 0
        var resumed = 0
        var quoted = 0
        var released = 0
        val dest = 500uL
        val controller = object : WalletMigrationController {
            override suspend fun destinationBalanceSats() = dest
            override suspend fun quote(amountSats: ULong?): MigrationQuoteUi {
                quoted += 1
                error("quote must not run during rescue")
            }
            override suspend fun execute(planId: String) = error("execute must not run")
            override suspend fun resume(polls: UInt): MigrationResultUi {
                resumed += 1
                return MigrationResultUi.Pending(dest)
            }
            override suspend fun status() = MigrationAttemptStatusUi(
                settlementId = "qid",
                amountSats = 2_000uL,
                feeSats = 20uL,
                state = MigrationAttemptStateUi.SourcePaid,
                paymentHash = "hh",
            )
            override suspend fun cancelUnspent() {}
            override suspend fun close() { closed += 1 }
        }
        val phase = resumePaidCashuMigrationIfNeeded(
            peekNeedsRescue = true,
            acquireExclusive = { true },
            releaseExclusive = { released += 1 },
            open = { controller },
            lightningFailedMessage = "fail",
            polls = 24u,
        )
        assertEquals(MigrationPhase.PendingSettlement(dest), phase)
        assertEquals(1, resumed)
        assertEquals(0, quoted)
        assertEquals(1, closed)
        assertEquals(1, released)
    }

    @Test
    fun acceptedBreezSendWithoutPreimageIsPending() {
        assertFalse(hostSendReportsComplete(null))
        assertFalse(hostSendReportsComplete(""))
        assertTrue(hostSendReportsComplete("00"))
    }
}
