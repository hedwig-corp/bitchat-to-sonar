package chat.bitchat.sonar.wallet

/**
 * Parsing for the strings a user can pay: BOLT11 invoices and BIP-21 unified
 * URIs.
 *
 * This lives beside the wallet rather than in the screens package because the
 * app state needs it too — `payDestination` has to know whether a BOLT11 is
 * amountless before it hands anything to the wallet. State reaching up into the
 * UI layer for that was the wrong direction.
 */

/**
 * Amount encoded in a BOLT11 human-readable part, in sats, or null when the
 * invoice leaves the amount open. `lnbc21u1…` → 21 micro-BTC → 2,100 sats.
 * Multipliers per BOLT-11: m = 10⁻³, u = 10⁻⁶, n = 10⁻⁹, p = 10⁻¹² BTC.
 */
fun bolt11AmountSats(invoice: String): Long? {
    // The separator is the LAST '1': bech32 excludes '1' from the data
    // charset, so any earlier one belongs to the amount ("lnbc21u1…" — taking
    // the first would read 2 BTC instead of 2,100 sats).
    val hrpEnd = invoice.lastIndexOf('1').takeIf { it > 3 } ?: return null
    val prefix = invoice.substring(0, hrpEnd)
    val digitsStart = prefix.indexOfFirst { it.isDigit() }.takeIf { it > 0 } ?: return null
    var amountPart = prefix.substring(digitsStart)
    if (amountPart.isEmpty()) return null
    val multiplier = amountPart.last()
    val scale: Double = when (multiplier) {
        'm' -> 1e-3
        'u' -> 1e-6
        'n' -> 1e-9
        'p' -> 1e-12
        else -> 1.0
    }
    if (!multiplier.isDigit()) amountPart = amountPart.dropLast(1)
    val value = amountPart.toDoubleOrNull() ?: return null
    if (value <= 0.0) return null
    val sats = value * scale * 100_000_000.0
    // p-denominated invoices can encode sub-satoshi amounts; round up so we
    // never underpay, and treat a zero result as "no amount".
    val rounded = kotlin.math.ceil(sats - 1e-9).toLong()
    return rounded.takeIf { it > 0 }
}

/** True for a BOLT11 invoice on any network. */
fun looksLikeBolt11(destination: String): Boolean {
    val v = destination.lowercase()
    return v.startsWith("lnbc") || v.startsWith("lntb") || v.startsWith("lnbcrt")
}

/** Bech32 addresses are case-insensitive; base58 ones are NOT. */
fun looksBech32(address: String): Boolean {
    val a = address.lowercase()
    return a.startsWith("bc1") || a.startsWith("tb1") || a.startsWith("bcrt1")
}

/** `k=v&k=v` → map, keys lower-cased, values percent-decoded. */
fun parseUriParams(query: String): Map<String, String> {
    if (query.isBlank()) return emptyMap()
    val out = LinkedHashMap<String, String>()
    for (pair in query.split('&')) {
        if (pair.isBlank()) continue
        val key = pair.substringBefore('=').lowercase()
        val value = pair.substringAfter('=', "")
        if (key.isNotEmpty() && key !in out) out[key] = percentDecode(value)
    }
    return out
}

private fun percentDecode(value: String): String {
    if ('%' !in value && '+' !in value) return value
    val sb = StringBuilder(value.length)
    var i = 0
    while (i < value.length) {
        val c = value[i]
        when {
            c == '+' -> { sb.append(' '); i++ }
            c == '%' && i + 2 < value.length -> {
                val hex = value.substring(i + 1, i + 3).toIntOrNull(16)
                if (hex != null) { sb.append(hex.toChar()); i += 3 } else { sb.append(c); i++ }
            }
            else -> { sb.append(c); i++ }
        }
    }
    return sb.toString()
}

/**
 * BIP-21 `amount` is decimal **BTC**. Parsed digit-by-digit rather than through
 * a Double: `0.1 + 0.2` arithmetic has no place anywhere near an amount a user
 * is about to send.
 */
fun btcToSats(amount: String?): Long? {
    val raw = amount?.trim()?.takeIf { it.isNotEmpty() } ?: return null
    if (!raw.all { it.isDigit() || it == '.' }) return null
    if (raw.count { it == '.' } > 1) return null
    val whole = raw.substringBefore('.').ifEmpty { "0" }
    val fractionRaw = raw.substringAfter('.', "")
    // More than 8 decimals cannot be expressed in sats; refuse rather than
    // silently truncate someone's amount.
    if (fractionRaw.length > 8) return null
    val fraction = fractionRaw.padEnd(8, '0')
    val wholeSats = whole.toLongOrNull()?.times(100_000_000L) ?: return null
    val fracSats = fraction.toLongOrNull() ?: return null
    val total = wholeSats + fracSats
    return total.takeIf { it > 0 }
}
