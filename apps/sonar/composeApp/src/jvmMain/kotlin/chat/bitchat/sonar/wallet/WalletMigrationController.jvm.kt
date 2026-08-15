package chat.bitchat.sonar.wallet

import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import chat.bitchat.sonar.SonarCore
import uniffi.sonar_ffi.MigrationOutcome
import uniffi.sonar_ffi.SonarCashuWallet
import uniffi.sonar_ffi.SonarMigration

/**
 * Desktop driver for the Rust migration engine — the same shape as the Android
 * actual, differing only in where the Cashu store lives. Desktop gets the
 * migration because it runs the same Breez wallet from the same account key;
 * a user who moved funds on the phone must not see a stale Lightning balance
 * here.
 */
private class JvmWalletMigrationController(
    private val destination: SonarCashuWallet,
    private val engine: SonarMigration,
) : WalletMigrationController {

    override suspend fun destinationBalanceSats(): ULong = withContext(Dispatchers.IO) {
        destination.balance().`confirmedSats`
    }

    override suspend fun quote(amountSats: ULong?): MigrationQuoteUi = withContext(Dispatchers.IO) {
        val q = engine.plan(amountSats)
        MigrationQuoteUi(
            planId = q.`planId`,
            amountSats = q.`amountSats`,
            feeSats = q.`sourceFeeSats`,
            baselineSats = q.`destinationBaselineSats`,
        )
    }

    override suspend fun execute(planId: String): ULong = withContext(Dispatchers.IO) {
        engine.execute(planId).`amountSats`
    }

    override suspend fun settle(
        baselineSats: ULong,
        expectedSats: ULong,
        polls: UInt,
    ): MigrationResultUi = withContext(Dispatchers.IO) {
        when (val outcome = engine.settle(baselineSats, expectedSats, polls)) {
            is MigrationOutcome.Settled -> MigrationResultUi.Settled(outcome.`cashuConfirmedSats`)
            is MigrationOutcome.Pending -> MigrationResultUi.Pending(outcome.`cashuConfirmedSats`)
        }
    }

    override fun close() {
        runCatching { destination.disconnect() }
        runCatching { destination.close() }
        runCatching { engine.close() }
    }
}

private fun desktopCashuDir(): File {
    val home = System.getProperty("user.home") ?: "."
    return File(home, ".sonar/sonar-cashu/mainnet")
}

actual suspend fun createWalletMigrationController(
    mintUrl: String,
    destMaxSats: ULong?,
    feeCapSats: ULong?,
): WalletMigrationController? = withContext(Dispatchers.IO) {
    // Only "no Breez wallet configured" is a null. Everything else throws, so
    // a broken mint or a missing key reports itself instead of masquerading
    // as "wallet unavailable".
    if (!WalletBridge.isAvailable()) return@withContext null
    val nsec = SonarCore.identityNsec()

    val dir = desktopCashuDir().apply { mkdirs() }
    val destination = SonarCashuWallet.open(nsec, mintUrl, dir.absolutePath)

    val engine = try {
        SonarMigration(BreezMigrationSource(), destination, destMaxSats, feeCapSats)
    } catch (t: Throwable) {
        runCatching { destination.disconnect() }
        runCatching { destination.close() }
        throw t
    }
    JvmWalletMigrationController(destination, engine)
}
