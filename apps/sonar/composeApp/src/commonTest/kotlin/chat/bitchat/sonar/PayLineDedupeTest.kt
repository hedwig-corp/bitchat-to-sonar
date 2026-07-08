package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals

class PayLineDedupeTest {
    private fun msg(id: String, content: String, viaInternet: Boolean = false) =
        SonarMsg(id = id, senderNpub = "npub1x", content = content, mine = true, tsSecs = 100L, viaInternet = viaInternet)

    @Test fun dropsWhiteNoiseCopyOfMeshReceipt() {
        // A partially-failed mesh receipt send re-sends the full set over White
        // Noise: the same PAY uuid arrives on both legs of the merged feed.
        val uuid = "aabbccdd11223344"
        val merged = listOf(
            msg("mesh-1", PayLine.Pay(uuid, 21).encoded()),
            msg("mesh-2", PayLine.Done(uuid).encoded()),
            msg("wn-1", PayLine.Pay(uuid, 21).encoded(), viaInternet = true),
            msg("wn-2", PayLine.Done(uuid).encoded(), viaInternet = true),
        )
        val deduped = dedupePayLines(merged)
        assertEquals(listOf("mesh-1", "mesh-2"), deduped.map { it.id })
    }

    @Test fun keepsDistinctPaymentsAndPlainText() {
        val merged = listOf(
            msg("m1", PayLine.Pay("uuid-one", 10).encoded()),
            msg("m2", "ciao bella"),
            msg("m3", PayLine.Pay("uuid-two", 20).encoded()),
            msg("m4", PayLine.Done("uuid-one").encoded()),
        )
        assertEquals(merged, dedupePayLines(merged))
    }

    @Test fun payAndDoneWithSameUuidAreDistinctKinds() {
        val uuid = "feedface00112233"
        val merged = listOf(
            msg("m1", PayLine.Pay(uuid, 5).encoded()),
            msg("m2", PayLine.Done(uuid, preimage = "ab".repeat(32)).encoded()),
        )
        assertEquals(merged, dedupePayLines(merged))
    }

    @Test fun undecodablePayPrefixedTextSurvives() {
        val merged = listOf(
            msg("m1", "⚡PAY|9|future|stuff"),
            msg("m2", "⚡PAY|9|future|stuff"),
        )
        // Unknown versions render as plain text (forward-compatible) — never drop them.
        assertEquals(merged, dedupePayLines(merged))
    }
}
