package chat.bitchat.sonar.crypto

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

private fun ByteArray.hex() = joinToString("") { ((it.toInt() and 0xFF) + 0x100).toString(16).substring(1) }
private fun String.unhex() = ByteArray(length / 2) { ((this[2 * it].digitToInt(16) shl 4) or this[2 * it + 1].digitToInt(16)).toByte() }

class Sha256Test {
    @Test fun emptyVector() {
        assertEquals("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", Sha256.hash(ByteArray(0)).hex())
    }

    @Test fun abcVector() {
        assertEquals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", Sha256.hash("abc".encodeToByteArray()).hex())
    }

    @Test fun longerVector() {
        val msg = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
        assertEquals("248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1", Sha256.hash(msg.encodeToByteArray()).hex())
    }
}

class HkdfTest {
    @Test fun hmacRfc4231Case1() {
        val key = ByteArray(20) { 0x0b }
        val out = Hkdf.hmacSha256(key, "Hi There".encodeToByteArray())
        assertEquals("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7", out.hex())
    }

    @Test fun hkdfRfc5869Case1() {
        val ikm = "0b".repeat(22).unhex()
        val salt = "000102030405060708090a0b0c".unhex()
        val info = "f0f1f2f3f4f5f6f7f8f9".unhex()
        val okm = Hkdf.derive(ikm, salt, info, 42)
        assertEquals(
            "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865",
            okm.hex(),
        )
    }
}

class Bech32Test {
    // NIP-19 test vector.
    private val nsec = "nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5"
    private val secretHex = "67dea2ed018072d675f5415ecfaed7d2597555e202d85b3d65ea4e58d2d92ffa"

    @Test fun decodesNsec() {
        assertEquals(secretHex, Bech32.nsecToSecretHex(nsec))
    }

    @Test fun rejectsGarbage() {
        assertNull(Bech32.nsecToSecretHex("not-an-nsec"))
        assertNull(Bech32.nsecToSecretHex("npub1xxx"))
    }
}
