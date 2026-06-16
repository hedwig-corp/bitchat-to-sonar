package chat.bitchat.sonar.wallet

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNull

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
}
