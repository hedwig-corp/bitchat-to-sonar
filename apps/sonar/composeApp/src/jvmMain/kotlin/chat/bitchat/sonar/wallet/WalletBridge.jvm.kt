package chat.bitchat.sonar.wallet

import chat.bitchat.sonar.DesktopEnv

/**
 * Desktop (JVM) `actual`: the on-device Breez SDK Liquid wallet ships native
 * Android/iOS bindings but no desktop-JVM artifact today, so the Lightning wallet
 * is reported unavailable on desktop. The UI degrades exactly like a keyless
 * build (the iOS/Android behavior with no API key): wallet rows show
 * "unavailable", ⚡PAY claim/send is gated with a friendly toast. Display
 * preferences (fiat toggle, currency) still persist so they round-trip with the
 * other platforms.
 *
 * Wiring a desktop Lightning backend (a JVM Breez build, or an LDK/CLN/LND
 * bridge) is the documented follow-up to make payments testable on desktop too.
 */
actual object WalletBridge {
    @Volatile private var rates: Map<String, ExchangeRate> = emptyMap()

    actual fun isAvailable(): Boolean = false

    actual fun state(): WalletState = WalletState.NotConfigured

    actual suspend fun setupIfNeeded(nsec: String) { /* unavailable on desktop */ }

    actual suspend fun refreshBalance(): Long = 0L

    actual suspend fun createOffer(): String = error("wallet unavailable on desktop")

    actual suspend fun send(destination: String, amountSats: Long, note: String): Boolean = false

    actual suspend fun fetchRates(): List<ExchangeRate> = emptyList()

    actual fun cachedRate(currency: FiatCurrency): ExchangeRate? = rates[currency.code]

    actual fun showFiat(): Boolean = DesktopEnv.getBoolean("wallet.showFiat", false)
    actual fun setShowFiat(value: Boolean) { DesktopEnv.putBoolean("wallet.showFiat", value) }

    actual fun currency(): FiatCurrency = FiatCurrency.of(DesktopEnv.getString("wallet.currency", "USD"))
    actual fun setCurrency(value: FiatCurrency) { DesktopEnv.putString("wallet.currency", value.code) }

    actual suspend fun shutdown() { rates = emptyMap() }
}
