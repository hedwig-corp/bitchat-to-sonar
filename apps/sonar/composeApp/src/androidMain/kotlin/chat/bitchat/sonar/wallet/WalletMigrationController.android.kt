package chat.bitchat.sonar.wallet

import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import chat.bitchat.sonar.AppContextHolder
import chat.bitchat.sonar.SonarCore
import uniffi.sonar_ffi.MigrationOutcome
import uniffi.sonar_ffi.MigrationAttemptState
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

    override suspend fun resume(polls: UInt): MigrationResultUi = withContext(Dispatchers.IO) {
        when (val outcome = engine.resume(polls)) {
            is MigrationOutcome.Settled -> MigrationResultUi.Settled(outcome.`cashuConfirmedSats`)
            is MigrationOutcome.Pending -> MigrationResultUi.Pending(outcome.`cashuConfirmedSats`)
        }
    }

    override suspend fun status(): MigrationAttemptStatusUi? = withContext(Dispatchers.IO) {
        engine.status()?.let {
            MigrationAttemptStatusUi(
                settlementId = it.`settlementId`,
                amountSats = it.`amountSats`,
                feeSats = it.`feeSats`,
                state = when (it.state) {
                    MigrationAttemptState.AWAITING_CONSENT -> MigrationAttemptStateUi.AwaitingConsent
                    MigrationAttemptState.SENDING -> MigrationAttemptStateUi.Sending
                    MigrationAttemptState.PAYMENT_UNKNOWN -> MigrationAttemptStateUi.PaymentUnknown
                    MigrationAttemptState.SOURCE_PENDING -> MigrationAttemptStateUi.SourcePending
                    MigrationAttemptState.SOURCE_PAID -> MigrationAttemptStateUi.SourcePaid
                    MigrationAttemptState.MINT_PAID -> MigrationAttemptStateUi.MintPaid
                    MigrationAttemptState.SETTLED -> MigrationAttemptStateUi.Settled
                    MigrationAttemptState.SOURCE_FAILED -> MigrationAttemptStateUi.SourceFailed
                    MigrationAttemptState.EXPIRED_UNSENT -> MigrationAttemptStateUi.ExpiredUnsent
                },
                paymentHash = it.`paymentHash`,
            )
        }
    }

    override suspend fun cancelUnspent() = withContext(Dispatchers.IO) {
        engine.cancelUnspent()
    }

    override suspend fun close() = withContext(Dispatchers.IO) {
        runCatching { destination.disconnect() }
        runCatching { destination.close() }
        runCatching { engine.close() }
        Unit
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

    val accountId = java.security.MessageDigest.getInstance("SHA-256")
        .digest(nsec.toByteArray(Charsets.UTF_8))
        .take(16)
        .joinToString("") { "%02x".format(it) }
    val dir = File(AppContextHolder.ctx.filesDir, "sonar-cashu/$accountId/mainnet").apply { mkdirs() }
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

actual suspend fun wipeCashuMigrationStorage(): Unit = withContext(Dispatchers.IO) {
    val root = File(AppContextHolder.ctx.filesDir, "sonar-cashu")
    if (root.exists() && !root.deleteRecursively()) {
        error("Cashu wallet storage could not be cleared")
    }
}
