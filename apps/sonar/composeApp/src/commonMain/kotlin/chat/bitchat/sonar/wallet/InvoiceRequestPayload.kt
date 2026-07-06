package chat.bitchat.sonar.wallet

/**
 * The BOLT12 invoice_request push payload from the Breez NDS (breez/notify):
 * `notification_payload` is a flat JSON object with three string fields —
 * `offer`, `invoice_request`, and the server-injected `reply_url`
 * (`{NOTIFY_EXTERNAL_URL}/api/v1/response/{reqId}`) the device must POST the
 * produced invoice to within the server's 60s callback window.
 *
 * Parsed with [JsonLite] instead of a JSON dependency: the app's Kotlin layer
 * has none (structured data rides the Rust FFI), and pulling one in for three
 * flat string fields isn't warranted. [JsonLite] handles standard string
 * escapes, so a URL or field with escaped characters still round-trips.
 */
data class InvoiceRequestPayload(
    val offer: String,
    val invoiceRequest: String,
    val replyUrl: String,
) {
    companion object {
        fun parse(json: String): InvoiceRequestPayload? {
            val offer = JsonLite.stringField(json, "offer") ?: return null
            val invoiceRequest = JsonLite.stringField(json, "invoice_request") ?: return null
            val replyUrl = JsonLite.stringField(json, "reply_url") ?: return null
            if (offer.isBlank() || invoiceRequest.isBlank() || replyUrl.isBlank()) return null
            return InvoiceRequestPayload(offer, invoiceRequest, replyUrl)
        }
    }
}

/**
 * Minimal JSON helpers for flat objects of string fields: extract one field's
 * decoded value, and encode a reply body. Not a general JSON parser — just
 * enough for the NDS push payload and the `{"invoice"|"error": ...}` reply the
 * Breez notification protocol expects (mirrors iOS `InvoiceRequestTask`).
 */
internal object JsonLite {

    /** Decoded value of `"field": "..."` in [json], or null when absent or the
     *  value is not a string. Escape-aware on both the field name match and the
     *  value (\" \\ \/ \b \f \n \r \t \uXXXX). */
    fun stringField(json: String, field: String): String? {
        var i = 0
        while (i < json.length) {
            i = json.indexOf('"', i)
            if (i < 0) return null
            val (name, afterName) = readString(json, i) ?: return null
            var j = skipWs(json, afterName)
            if (j >= json.length || json[j] != ':') { i = afterName; continue }
            j = skipWs(json, j + 1)
            if (name == field) {
                if (j >= json.length || json[j] != '"') return null // non-string value
                return readString(json, j)?.first
            }
            // Skip a string value so its content can't be mistaken for a key.
            i = if (j < json.length && json[j] == '"') readString(json, j)?.second ?: return null else j
        }
        return null
    }

    /** `{"[name]": "[value]"}` with the value JSON-escaped. */
    fun encodeObject(name: String, value: String): String =
        "{\"$name\":\"${escape(value)}\"}"

    private fun escape(s: String): String = buildString(s.length + 8) {
        for (c in s) when {
            c == '"' -> append("\\\"")
            c == '\\' -> append("\\\\")
            c == '\n' -> append("\\n")
            c == '\r' -> append("\\r")
            c == '\t' -> append("\\t")
            c < ' ' -> append("\\u").append(c.code.toString(16).padStart(4, '0'))
            else -> append(c)
        }
    }

    private fun skipWs(s: String, from: Int): Int {
        var i = from
        while (i < s.length && s[i].isWhitespace()) i++
        return i
    }

    /** Reads the JSON string starting at the opening quote [at]; returns the
     *  decoded value and the index just past the closing quote. */
    private fun readString(s: String, at: Int): Pair<String, Int>? {
        if (at >= s.length || s[at] != '"') return null
        val out = StringBuilder()
        var i = at + 1
        while (i < s.length) {
            when (val c = s[i]) {
                '"' -> return out.toString() to i + 1
                '\\' -> {
                    if (i + 1 >= s.length) return null
                    when (s[i + 1]) {
                        '"' -> out.append('"')
                        '\\' -> out.append('\\')
                        '/' -> out.append('/')
                        'b' -> out.append('\b')
                        'f' -> out.append('\u000C')
                        'n' -> out.append('\n')
                        'r' -> out.append('\r')
                        't' -> out.append('\t')
                        'u' -> {
                            if (i + 5 >= s.length) return null
                            val code = s.substring(i + 2, i + 6).toIntOrNull(16) ?: return null
                            out.append(code.toChar())
                            i += 4
                        }
                        else -> return null // invalid escape
                    }
                    i += 2
                }
                else -> { out.append(c); i++ }
            }
        }
        return null // unterminated
    }
}
