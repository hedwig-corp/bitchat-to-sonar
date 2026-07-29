package chat.bitchat.sonar.signer

/**
 * NIP-55 (Android external signer, e.g. Amber) protocol helpers.
 *
 * Pure string/JSON logic only — no Android types — so the wire contract is
 * unit-testable from commonTest. The Android-only transport (intents +
 * ContentResolver) lives in `androidMain/.../signer/AmberSignerClient.kt`.
 *
 * Spec: https://github.com/nostr-protocol/nips/blob/master/55.md
 */
object Nip55 {
    /** URI scheme every NIP-55 signer handles (`nostrsigner:<payload>`). */
    const val SCHEME = "nostrsigner"

    const val TYPE_GET_PUBLIC_KEY = "get_public_key"
    const val TYPE_SIGN_EVENT = "sign_event"
    const val TYPE_NIP44_ENCRYPT = "nip44_encrypt"
    const val TYPE_NIP44_DECRYPT = "nip44_decrypt"

    /**
     * Every kind Sonar signs with the ACCOUNT identity key. Kind-445 group
     * messages and outer kind-1059 wraps use ephemeral keys and never reach
     * the signer; MLS itself has its own credentials.
     */
    val SIGN_EVENT_KINDS: List<Int> = listOf(
        22242, // NIP-42 relay auth
        24242, // Blossom (BUD-01) HTTP authorization
        0, // profile metadata
        13, // NIP-59 seal (welcomes, push notify, NIP-17 DMs)
        30078, // Sonar descriptor (pay/call capabilities)
        10063, // Blossom server list (BUD-03)
        10031, // user sticker-pack list
        30443, // Marmot KeyPackage
        23353, // handle-registrar claim
    )

    /**
     * The `permissions` JSON for the `get_public_key` login request: asks for
     * every signing kind plus NIP-44 both ways in ONE approval screen, so
     * later operations (relay auth, message receive in background) run
     * through the signer's remembered grants without UI.
     */
    fun loginPermissionsJson(): String {
        val entries = buildList {
            SIGN_EVENT_KINDS.forEach { kind ->
                add("""{"type":"sign_event","kind":$kind}""")
            }
            add("""{"type":"nip44_encrypt"}""")
            add("""{"type":"nip44_decrypt"}""")
        }
        return entries.joinToString(prefix = "[", separator = ",", postfix = "]")
    }

    /** One signer response (single-request extras or one `results[]` entry). */
    data class Response(
        val id: String?,
        /** Primary result: pubkey / signature / ciphertext / plaintext. */
        val result: String?,
        /** Full signed event JSON (`sign_event` only, preferred over [result]). */
        val event: String?,
        val rejected: Boolean,
        val packageName: String?,
    )

    /**
     * Parse the batched `results` extra: a JSON array of response objects the
     * signer returns when several queued requests are approved on one screen.
     * Malformed input yields an empty list (callers fall back to the
     * single-response extras).
     */
    fun parseResultsArray(json: String): List<Response> =
        splitTopLevelObjects(json.trim()).mapNotNull { obj ->
            val id = stringField(obj, "id")
            val result = stringField(obj, "result")
            val event = stringField(obj, "event")
            val signature = stringField(obj, "signature")
            val rejected = boolField(obj, "rejected") ?: false
            if (id == null && result == null && signature == null && event == null && !rejected) {
                null
            } else {
                Response(
                    id = id,
                    result = result ?: signature,
                    event = event,
                    rejected = rejected,
                    packageName = stringField(obj, "package"),
                )
            }
        }

    /**
     * Amber returns this literal in `result` when a decrypt fails; treat it as
     * failure, never as plaintext.
     */
    const val DECRYPT_FAILURE_SENTINEL = "Could not decrypt the message"

    /** True when a non-rejected result payload is actually usable. */
    fun isUsableResult(result: String?): Boolean =
        !result.isNullOrBlank() && result != DECRYPT_FAILURE_SENTINEL

    /**
     * Assemble full signed-event JSON from the unsigned event JSON we sent and
     * a bare 64-byte schnorr signature (some NIP-55 signers return only the
     * `signature`/`result` extra, no `event`). Purely mechanical: appends a
     * `"sig"` field to the JSON object. Callers verify the result end-to-end
     * (id, author, signature) in the Rust adapter, so a bad assembly can only
     * fail closed. Returns null when the inputs don't have the right shape.
     */
    fun assembleSignedEvent(unsignedEventJson: String, signatureHex: String): String? {
        val sig = signatureHex.trim()
        if (!sig.matches(Regex("^[0-9a-fA-F]{128}$"))) return null
        val json = unsignedEventJson.trim()
        if (!json.startsWith("{") || !json.endsWith("}")) return null
        return json.dropLast(1) + ",\"sig\":\"" + sig + "\"}"
    }

    // ── minimal JSON extraction (same no-dependency style as RelayDiagnostics) ──

    /** Split the body of a JSON array into its top-level `{...}` chunks. */
    private fun splitTopLevelObjects(json: String): List<String> {
        val out = ArrayList<String>()
        var depth = 0
        var start = -1
        var inString = false
        var escaped = false
        for (i in json.indices) {
            val c = json[i]
            if (inString) {
                when {
                    escaped -> escaped = false
                    c == '\\' -> escaped = true
                    c == '"' -> inString = false
                }
                continue
            }
            when (c) {
                '"' -> inString = true
                '{' -> {
                    if (depth == 0) start = i
                    depth++
                }
                '}' -> {
                    depth--
                    if (depth == 0 && start >= 0) {
                        out.add(json.substring(start, i + 1))
                        start = -1
                    }
                }
            }
        }
        return out
    }

    /** Extract a top-level string field, JSON-unescaped. Null when absent. */
    private fun stringField(obj: String, key: String): String? {
        val prefix = "\"$key\""
        var searchFrom = 0
        while (true) {
            val keyAt = obj.indexOf(prefix, searchFrom)
            if (keyAt < 0) return null
            // Only accept when followed by a colon (skip values that merely
            // contain the key text).
            var i = keyAt + prefix.length
            while (i < obj.length && obj[i].isWhitespace()) i++
            if (i >= obj.length || obj[i] != ':') {
                searchFrom = keyAt + prefix.length
                continue
            }
            i++
            while (i < obj.length && obj[i].isWhitespace()) i++
            if (i >= obj.length || obj[i] != '"') return null
            i++
            val sb = StringBuilder()
            var escaped = false
            while (i < obj.length) {
                val c = obj[i]
                if (escaped) {
                    when (c) {
                        'n' -> sb.append('\n')
                        't' -> sb.append('\t')
                        'r' -> sb.append('\r')
                        'b' -> sb.append('\b')
                        'u' -> {
                            if (i + 4 < obj.length) {
                                obj.substring(i + 1, i + 5).toIntOrNull(16)?.let {
                                    sb.append(it.toChar())
                                }
                                i += 4
                            }
                        }
                        else -> sb.append(c)
                    }
                    escaped = false
                } else {
                    when (c) {
                        '\\' -> escaped = true
                        '"' -> return sb.toString()
                        else -> sb.append(c)
                    }
                }
                i++
            }
            return null
        }
    }

    /** Extract a top-level boolean field (`true`/`false` or `"true"`). */
    private fun boolField(obj: String, key: String): Boolean? {
        val m = Regex("\"${Regex.escape(key)}\"\\s*:\\s*(?:\"(true|false)\"|(true|false))")
            .find(obj) ?: return null
        val raw = m.groupValues[1].ifEmpty { m.groupValues[2] }
        return raw.equals("true", ignoreCase = true)
    }
}
