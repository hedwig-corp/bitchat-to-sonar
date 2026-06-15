package chat.bitchat.sonar.wallet

/** A live BTC→fiat rate: `value` fiat units per 1 BTC. */
data class ExchangeRate(val currency: String, val perBtc: Double)

/** Fiat currencies the picker offers (mirrors iOS). */
enum class FiatCurrency(val code: String, val symbol: String) {
    USD("USD", "$"),
    EUR("EUR", "€"),
    GBP("GBP", "£"),
    CHF("CHF", "CHF "),
    ;
    companion object {
        fun of(code: String?): FiatCurrency =
            entries.firstOrNull { it.code.equals(code, ignoreCase = true) } ?: USD
    }
}

/**
 * Money display, ported 1:1 from the iOS rule
 * (`2026-06-12-money-display-fiat-toggle.md`): show fiat ONLY when a live rate
 * for the selected currency exists; otherwise fall back to sats. Never invent a
 * fiat figure from a stale/absent rate.
 */
object Money {
    private const val SATS_PER_BTC = 100_000_000.0

    fun formatSats(sats: Long): String {
        val grouped = sats.toString().reversed().chunked(3).joinToString(",").reversed()
        return "$grouped sats"
    }

    /** Fiat string if a live rate is present, else null. */
    fun formatFiat(sats: Long, currency: FiatCurrency, rate: ExchangeRate?): String? {
        if (rate == null || rate.perBtc <= 0.0) return null
        val fiat = sats / SATS_PER_BTC * rate.perBtc
        return currency.symbol + twoDecimals(fiat)
    }

    /**
     * Primary money label: fiat when `showFiat` AND a live rate exists, else sats.
     * Matches iOS `AmountDisplayFormatter.format`.
     */
    fun format(sats: Long, showFiat: Boolean, currency: FiatCurrency, rate: ExchangeRate?): String {
        if (showFiat) formatFiat(sats, currency, rate)?.let { return it }
        return formatSats(sats)
    }

    private fun twoDecimals(v: Double): String {
        val cents = kotlin.math.round(v * 100.0).toLong()
        val whole = cents / 100
        val frac = (cents % 100).let { if (it < 0) -it else it }
        val groupedWhole = whole.toString().let {
            val neg = it.startsWith("-")
            val digits = if (neg) it.drop(1) else it
            val g = digits.reversed().chunked(3).joinToString(",").reversed()
            if (neg) "-$g" else g
        }
        val fracStr = if (frac < 10) "0$frac" else "$frac"
        return "$groupedWhole.$fracStr"
    }
}
