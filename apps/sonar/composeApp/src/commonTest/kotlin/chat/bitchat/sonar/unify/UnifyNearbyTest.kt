package chat.bitchat.sonar.unify

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class UnifyNearbyTest {

    // ── BIP321 parsing ──

    @Test fun bareBolt12Offer() {
        val p = UnifyBIP321.parse("lno1qsgytechgabc")!!
        assertEquals("lno1qsgytechgabc", p.lightning)
        assertNull(p.amountSats)
    }

    @Test fun lightningSchemeStripped() {
        val p = UnifyBIP321.parse("lightning:LNBC1ABC")!!
        assertEquals("lnbc1abc", p.lightning)
    }

    @Test fun bitcoinUriWithLightningAndAmount() {
        val p = UnifyBIP321.parse("bitcoin:bc1qxyz?lightning=lno1abc&amount=0.0001")!!
        assertEquals("lno1abc", p.lightning)
        assertEquals(10_000L, p.amountSats)  // 0.0001 BTC = 10k sats
    }

    @Test fun bitcoinUriLnoAlias() {
        val p = UnifyBIP321.parse("bitcoin:?lno=lno1zzz")!!
        assertEquals("lno1zzz", p.lightning)
        assertNull(p.amountSats)
    }

    @Test fun onChainOnlyReturnsNull() {
        assertNull(UnifyBIP321.parse("bitcoin:bc1qonlyonchain"))
    }

    @Test fun garbageReturnsNull() {
        assertNull(UnifyBIP321.parse("hello world"))
        assertNull(UnifyBIP321.parse(""))
    }

    @Test fun btcToSatsPrecision() {
        assertEquals(100_000_000L, UnifyBIP321.btcStringToSats("1"))
        assertEquals(1L, UnifyBIP321.btcStringToSats("0.00000001"))
        assertEquals(123_456_789L, UnifyBIP321.btcStringToSats("1.23456789"))
        assertNull(UnifyBIP321.btcStringToSats("0"))
        assertNull(UnifyBIP321.btcStringToSats("abc"))
    }

    // ── Framing round-trip ──

    @Test fun frameThenReassembleSingleChunk() {
        val payload = "bitcoin:?lno=lno1offer"
        val framed = UnifyFraming.frame(payload)
        assertEquals(UnifyFraming.HEADER_SIZE + payload.encodeToByteArray().size, framed.size)
        val r = UnifyFraming.Reassembler()
        assertEquals(payload, r.append(framed))
    }

    @Test fun reassembleAcrossChunks() {
        val payload = "bitcoin:?lno=" + "x".repeat(500)  // > one 180B chunk
        val framed = UnifyFraming.frame(payload)
        val r = UnifyFraming.Reassembler()
        var result: String? = null
        var i = 0
        while (i < framed.size) {
            val end = minOf(i + UnifyContract.MAX_CHUNK_SIZE, framed.size)
            result = r.append(framed.copyOfRange(i, end))
            i = end
        }
        assertEquals(payload, result)
    }

    @Test fun reassemblerWaitsForFullHeaderAndBody() {
        val framed = UnifyFraming.frame("abcdef")
        val r = UnifyFraming.Reassembler()
        assertNull(r.append(framed.copyOfRange(0, 2)))   // partial header
        assertNull(r.append(framed.copyOfRange(2, 6)))   // header complete, body partial
        assertTrue(r.append(framed.copyOfRange(6, framed.size)) == "abcdef")
    }
}
