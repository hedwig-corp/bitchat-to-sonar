package chat.bitchat.sonar.wallet

/**
 * Host-side driver for the Rust migration engine.
 *
 * The engine (`sonar-wallet-migrate`, exposed as `SonarMigration`) lives in
 * the FFI layer, which only the platform source sets can see — hence the
 * expect/actual seam. Everything money-related stays in Rust: this interface
 * exists so [WalletMigrationScreen] can drive it without knowing about UniFFI.
 *
 * Lifecycle mirrors the engine's own: [quote] → (consent UI) → [execute] →
 * [resume]. `execute` is the only call that spends, and it consumes the plan,
 * so a double-tap cannot pay twice.
 */
interface WalletMigrationController {
    /** Cashu balance before anything moves — the settle baseline. */
    suspend fun destinationBalanceSats(): ULong

    /** Price the migration. Nothing is paid. `null` plans a whole-balance drain. */
    suspend fun quote(amountSats: ULong?): MigrationQuoteUi

    /** THE spending call. Only reachable after explicit consent to the custody change. */
    suspend fun execute(planId: String): ULong

    /**
     * Watch until the funds land. Safe to call repeatedly, including after a
     * crash between [execute] and settlement — this only observes the wallet's
     * own reconciliation.
     */
    suspend fun resume(polls: UInt): MigrationResultUi

    /** Durable attempt state, available after process restart. */
    suspend fun status(): MigrationAttemptStatusUi?

    /** Remove an unspent consent/expired attempt; refuses ambiguous/paid states. */
    suspend fun cancelUnspent()

    /** Release the destination wallet's store. */
    suspend fun close()
}

/** What the consent screen shows. `planId` is single-use. */
data class MigrationQuoteUi(
    val planId: String,
    val amountSats: ULong,
    val feeSats: ULong?,
    val baselineSats: ULong,
)

enum class MigrationAttemptStateUi {
    AwaitingConsent,
    Sending,
    PaymentUnknown,
    SourcePending,
    SourcePaid,
    MintPaid,
    Settled,
    SourceFailed,
    ExpiredUnsent,
}

data class MigrationAttemptStatusUi(
    val settlementId: String,
    val amountSats: ULong,
    val feeSats: ULong?,
    val state: MigrationAttemptStateUi,
    val paymentHash: String,
)

sealed interface MigrationResultUi {
    /** Funds are in the Cashu wallet. */
    data class Settled(val cashuSats: ULong) : MigrationResultUi

    /** Paid, not yet visible. Recoverable, not a failure — settle again. */
    data class Pending(val cashuSats: ULong) : MigrationResultUi
}

/**
 * Build a controller, or `null` where no Breez wallet is configured — the one
 * case that means "migration not offered" rather than "something broke".
 * Anything else throws, carrying its own reason.
 *
 * Suspending on purpose: opening the destination connects to the mint and, on
 * a fresh store, runs a NUT-13 restore scan. The actuals move that to IO so it
 * can never block composition or first paint.
 */
expect suspend fun createWalletMigrationController(
    mintUrl: String,
    destMaxSats: ULong?,
    feeCapSats: ULong?,
): WalletMigrationController?

/** Remove only Cashu-derived state and migration journals, never the account key. */
expect suspend fun wipeCashuMigrationStorage()
