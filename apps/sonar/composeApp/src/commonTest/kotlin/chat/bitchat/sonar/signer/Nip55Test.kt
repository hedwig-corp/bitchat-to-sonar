package chat.bitchat.sonar.signer

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Pins the NIP-55 wire helpers: the permission batch requested at Amber login
 * and the parsing of batched `results` responses. A drift here silently turns
 * into "Amber asks for approval on every single event" or lost responses.
 */
class Nip55Test {

    @Test
    fun loginPermissionsCoverEveryIdentitySignedKind() {
        val json = Nip55.loginPermissionsJson()
        // Every kind Sonar signs with the account key must be in the batch —
        // a missing kind means a surprise approval screen (or a background
        // failure) the first time that event type is signed.
        listOf(22242, 24242, 0, 13, 30078, 10063, 10031, 30443, 23353).forEach { kind ->
            assertTrue(
                json.contains("""{"type":"sign_event","kind":$kind}"""),
                "missing sign_event permission for kind $kind in $json",
            )
        }
        assertTrue(json.contains("""{"type":"nip44_encrypt"}"""))
        assertTrue(json.contains("""{"type":"nip44_decrypt"}"""))
        // Well-formed JSON array shape (no trailing comma).
        assertTrue(json.startsWith("[") && json.endsWith("]"))
        assertFalse(json.contains(",]"))
    }

    @Test
    fun kind445GroupMessagesNeverReachTheSigner() {
        // Kind-445 (MLS group message) and kind-1059 (outer gift wrap) are
        // signed by ephemeral keys — requesting them would over-grant.
        val json = Nip55.loginPermissionsJson()
        assertFalse(json.contains("\"kind\":445"))
        assertFalse(json.contains("\"kind\":1059"))
    }

    @Test
    fun parsesBatchedResults() {
        val batch = """
            [
              {"id":"req-1","result":"aabb","package":"com.greenart7c3.nostrsigner"},
              {"id":"req-2","event":"{\"id\":\"ee\",\"sig\":\"ss\"}","signature":"ss"},
              {"id":"req-3","rejected":true}
            ]
        """.trimIndent()
        val parsed = Nip55.parseResultsArray(batch)
        assertEquals(3, parsed.size)

        assertEquals("req-1", parsed[0].id)
        assertEquals("aabb", parsed[0].result)
        assertEquals("com.greenart7c3.nostrsigner", parsed[0].packageName)
        assertFalse(parsed[0].rejected)

        assertEquals("req-2", parsed[1].id)
        // The embedded event JSON survives unescaping intact.
        assertEquals("""{"id":"ee","sig":"ss"}""", parsed[1].event)
        // `signature` is the legacy alias for `result`.
        assertEquals("ss", parsed[1].result)

        assertTrue(parsed[2].rejected)
        assertNull(parsed[2].result)
    }

    @Test
    fun parsesStringifiedRejectedFlag() {
        // Amber has emitted rejected both as a boolean and as a string.
        val parsed = Nip55.parseResultsArray("""[{"id":"a","rejected":"true"}]""")
        assertEquals(1, parsed.size)
        assertTrue(parsed[0].rejected)
    }

    @Test
    fun malformedBatchYieldsEmpty() {
        assertTrue(Nip55.parseResultsArray("").isEmpty())
        assertTrue(Nip55.parseResultsArray("not json").isEmpty())
        assertTrue(Nip55.parseResultsArray("[]").isEmpty())
        assertTrue(Nip55.parseResultsArray("""[{}]""").isEmpty())
    }

    @Test
    fun decryptFailureSentinelIsNotUsable() {
        assertFalse(Nip55.isUsableResult(Nip55.DECRYPT_FAILURE_SENTINEL))
        assertFalse(Nip55.isUsableResult(""))
        assertFalse(Nip55.isUsableResult(null))
        assertTrue(Nip55.isUsableResult("ciphertext"))
    }

    @Test
    fun fieldExtractionIgnoresKeyTextInsideValues() {
        // A result value containing the literal `"id"` must not confuse the
        // field extractor.
        val parsed = Nip55.parseResultsArray(
            """[{"result":"payload with \"id\": inside","id":"real-id"}]""",
        )
        assertEquals(1, parsed.size)
        assertEquals("real-id", parsed[0].id)
        assertEquals("""payload with "id": inside""", parsed[0].result)
    }

}
