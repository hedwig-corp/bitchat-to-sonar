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

    /** Paid, not yet visible. Recoverable, not a failure — settle again.
     *  `cashuSats` is dest confirmed balance, never the invoice amount. */
    data class Pending(val cashuSats: ULong) : MigrationResultUi
}

/**
 * A new quote is unsafe once a source payment may exist. Matches Apple
 * `SonarMigrationModel.confirmAndMigrate` so a host timeout after Breez
 * accepted cannot look like a failed tap that should try another invoice.
 */
fun migrationAttemptBlocksNewQuote(state: MigrationAttemptStateUi): Boolean =
    when (state) {
        MigrationAttemptStateUi.AwaitingConsent,
        MigrationAttemptStateUi.ExpiredUnsent,
        MigrationAttemptStateUi.SourceFailed -> false
        else -> true
    }

/** Paid or ambiguous: resume the journal, never mint a second invoice. */
fun migrationAttemptNeedsRescue(state: MigrationAttemptStateUi): Boolean =
    migrationAttemptBlocksNewQuote(state) && state != MigrationAttemptStateUi.Settled

/**
 * Mapping used when the migration screen opens against an existing journal.
 * Matches Apple `SonarMigrationModel.phaseAfterOpenStatus` so a relaunch
 * after Breez accepted cannot look like a fresh "Check amount and fee".
 */
fun phaseAfterOpenStatus(
    state: MigrationAttemptStateUi?,
    attemptAmountSats: ULong,
    destConfirmedSats: ULong,
    lightningFailedMessage: String,
): MigrationPhase =
    when (state) {
        null,
        MigrationAttemptStateUi.AwaitingConsent,
        MigrationAttemptStateUi.ExpiredUnsent -> MigrationPhase.Idle
        MigrationAttemptStateUi.Settled -> MigrationPhase.Settled(attemptAmountSats)
        MigrationAttemptStateUi.SourceFailed -> MigrationPhase.Failed(lightningFailedMessage)
        else -> MigrationPhase.PendingSettlement(destConfirmedSats)
    }

suspend fun restoreOpenedMigration(
    status: MigrationAttemptStatusUi?,
    destConfirmedSats: ULong,
    lightningFailedMessage: String,
    cancelUnspent: suspend () -> Unit,
    resume: suspend () -> MigrationResultUi,
): MigrationPhase {
    when (status?.state) {
        MigrationAttemptStateUi.AwaitingConsent,
        MigrationAttemptStateUi.ExpiredUnsent -> runCatching { cancelUnspent() }
        else -> Unit
    }
    val opened = phaseAfterOpenStatus(
        state = status?.state,
        attemptAmountSats = status?.amountSats ?: 0uL,
        destConfirmedSats = destConfirmedSats,
        lightningFailedMessage = lightningFailedMessage,
    )
    if (opened !is MigrationPhase.PendingSettlement) return opened
    return runCatching { resume() }.fold(
        onSuccess = { result ->
            when (result) {
                is MigrationResultUi.Settled -> MigrationPhase.Settled(result.cashuSats)
                is MigrationResultUi.Pending -> MigrationPhase.PendingSettlement(result.cashuSats)
            }
        },
        onFailure = { MigrationPhase.PendingSettlement(destConfirmedSats) },
    )
}

/**
 * Host-side read of `cashu.migration.v1.json`. The serde wire names are the
 * PascalCase variant names pinned by `journal.rs::state_json_is_the_pascal_case_variant_name`.
 */
fun parseJournalAttemptState(json: String): MigrationAttemptStateUi? {
    val name = JOURNAL_STATE_FIELD.find(json)?.groupValues?.getOrNull(1) ?: return null
    return when (name) {
        "AwaitingConsent" -> MigrationAttemptStateUi.AwaitingConsent
        "Sending" -> MigrationAttemptStateUi.Sending
        "PaymentUnknown" -> MigrationAttemptStateUi.PaymentUnknown
        "SourcePending" -> MigrationAttemptStateUi.SourcePending
        "SourcePaid" -> MigrationAttemptStateUi.SourcePaid
        "MintPaid" -> MigrationAttemptStateUi.MintPaid
        "Settled" -> MigrationAttemptStateUi.Settled
        "SourceFailed" -> MigrationAttemptStateUi.SourceFailed
        "ExpiredUnsent" -> MigrationAttemptStateUi.ExpiredUnsent
        else -> null
    }
}

fun journalNeedsRescue(json: String?): Boolean {
    val state = parseJournalAttemptState(json ?: return false) ?: return false
    return migrationAttemptNeedsRescue(state)
}

fun peekCashuMigrationNeedsRescue(): Boolean = journalNeedsRescue(readCashuMigrationJournalJson())

private val JOURNAL_STATE_FIELD = Regex(""""state"\s*:\s*"([A-Za-z]+)"""")

fun phaseAfterExecuteError(
    state: MigrationAttemptStateUi?,
    destConfirmedSats: ULong,
    failedMessage: String,
): MigrationPhase =
    when {
        state == null || !migrationAttemptBlocksNewQuote(state) ->
            MigrationPhase.Failed(failedMessage)
        state == MigrationAttemptStateUi.Settled ->
            MigrationPhase.Settled(destConfirmedSats)
        else -> MigrationPhase.PendingSettlement(destConfirmedSats)
    }

/**
 * Breez reports "cannot afford it" only as prose. Matching too broadly is the
 * safer failure: a false positive costs one extra smaller quote; a false
 * negative aborts the whole drain. Keep this list identical on Apple.
 */
fun breezMessageLooksInsufficient(message: String): Boolean {
    val lower = message.lowercase()
    return "not enough funds" in lower ||
        "insufficient" in lower ||
        "balance too low" in lower
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

/**
 * Local journal bytes only. Must never open the Cashu store or talk to the
 * mint — Settings and the wallet log use this for a rescue banner.
 */
expect fun readCashuMigrationJournalJson(): String?
