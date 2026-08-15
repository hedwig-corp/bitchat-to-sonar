package chat.bitchat.sonar.wallet

import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import chat.bitchat.sonar.AppContextHolder
import chat.bitchat.sonar.SonarCore
import uniffi.sonar_ffi.MigrationOutcome
import uniffi.sonar_ffi.SonarCashuWallet
import uniffi.sonar_ffi.SonarMigration

/**
 * Android driver for the Rust migration engine.
 *
 * The SOURCE is the app's existing Breez integration, reached through
 * [BreezMigrationSource] — deliberately not a second SDK instance, so the
 * migration spends from the same node the wallet screen shows. The
 * DESTINATION is a Cashu wallet opened from the account key, which is what
 * makes the migrated funds restorable from the same nsec.
 *
 * Every call blocks in Rust, so all of them hop to [Dispatchers.IO]; calling
 * these from the main dispatcher would freeze the UI for the length of a mint
 * round trip.
 */
private class AndroidWalletMigrationController(
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

actual suspend fun createWalletMigrationController(
    mintUrl: String,
    destMaxSats: ULong?,
    feeCapSats: ULong?,
): WalletMigrationController? = withContext(Dispatchers.IO) {
    // No Breez wallet means nothing to migrate FROM; offering the screen would
    // be a dead end. This is the ONLY "not available" case — every other
    // failure below is a real error and must be reported as itself, not
    // flattened into a null that reads as "no wallet".
    if (!WalletBridge.isAvailable()) return@withContext null
    val nsec = SonarCore.identityNsec()

    val dir = File(AppContextHolder.ctx.filesDir, "sonar-cashu/mainnet").apply { mkdirs() }
    val destination = SonarCashuWallet.open(nsec, mintUrl, dir.absolutePath)

    val engine = try {
        SonarMigration(BreezMigrationSource(), destination, destMaxSats, feeCapSats)
    } catch (t: Throwable) {
        runCatching { destination.disconnect() }
        runCatching { destination.close() }
        throw t
    }
    AndroidWalletMigrationController(destination, engine)
}
