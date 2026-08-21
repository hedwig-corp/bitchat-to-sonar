package chat.bitchat.sonar.wallet

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import kotlinx.coroutines.launch
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import java.util.concurrent.atomic.AtomicBoolean
import chat.bitchat.sonar.SonarAppState
import chat.bitchat.sonar.resources.Res
import chat.bitchat.sonar.resources.could_not_open_the_migration
import chat.bitchat.sonar.resources.could_not_price_the_migration_2
import chat.bitchat.sonar.resources.could_not_read_the_cashu_balance
import chat.bitchat.sonar.resources.the_lightning_payment_failed_without
import chat.bitchat.sonar.resources.the_lightning_wallet_is_not_available
import chat.bitchat.sonar.resources.the_payment_did_not_go_through_2
import org.jetbrains.compose.resources.stringResource

/** Where migrated funds land. */
const val SONAR_DEFAULT_MINT_URL: String = "https://mint.hedwig.sh"

/**
 * Per-run ceiling. A migration is one-way, so a mistake is not correctable
 * from here — the cap bounds the damage of a wrong tap and can be raised
 * deliberately by migrating twice.
 */
private const val DEST_MAX_SATS: ULong = 500_000uL

/**
 * Fail-closed fee ceiling. The engine refuses to pay a fee above this rather
 * than surprising the user, so it must be generous enough for a real Boltz
 * swap yet small enough to catch a pathological quote.
 */
private const val FEE_CAP_SATS: ULong = 5_000uL

/** Settlement polls (~5s of mint sync each) before reporting Pending. */
private const val SETTLE_POLLS: UInt = 24u

/**
 * Owns the migration state machine: quote → consent → pay → watch. The Rust
 * engine holds the money logic; this only sequences it and keeps the consent
 * step honest by never calling [WalletMigrationController.execute] except from
 * the confirm handler.
 *
 * Mirrors iOS `SonarMigrationModel`. Both exist because the engine's states
 * are the same on both platforms — the phases are the engine's, not each
 * platform's invention.
 */
@Composable
fun WalletMigrationRoute(state: SonarAppState) {
    val errorMarker = "{sonar-migration-error}"
    val couldNotOpenTemplate =
        stringResource(Res.string.could_not_open_the_migration, errorMarker)
    val couldNotReadBalanceTemplate =
        stringResource(Res.string.could_not_read_the_cashu_balance, errorMarker)
    val couldNotPriceTemplate =
        stringResource(Res.string.could_not_price_the_migration_2, errorMarker)
    val paymentFailedTemplate =
        stringResource(Res.string.the_payment_did_not_go_through_2, errorMarker)
    val lightningUnavailable =
        stringResource(Res.string.the_lightning_wallet_is_not_available)
    val lightningPaymentFailed =
        stringResource(Res.string.the_lightning_payment_failed_without)
    val scope = rememberCoroutineScope()
    var phase by remember { mutableStateOf<MigrationPhase>(MigrationPhase.Idle) }
    var cashuBalance by remember { mutableStateOf(0uL) }
    var quote by remember { mutableStateOf<MigrationQuoteUi?>(null) }
    var openGeneration by remember { mutableStateOf(0) }

    var controller by remember { mutableStateOf<WalletMigrationController?>(null) }
    val abandoned = remember { AtomicBoolean(false) }

    // `createWalletMigrationController` opens the Cashu store, connects to the
    // mint, and on a fresh store runs a NUT-13 restore scan — a network round
    // trip. It must never run during composition or on the main dispatcher:
    // that blocks first paint on the mint and can ANR. Build it on IO and let
    // the screen paint "opening" state meanwhile.
    LaunchedEffect(openGeneration) {
        abandoned.set(false)
        phase = MigrationPhase.Quoting
        runCatching {
            createWalletMigrationController(
                mintUrl = SONAR_DEFAULT_MINT_URL,
                destMaxSats = DEST_MAX_SATS,
                feeCapSats = FEE_CAP_SATS,
            )
        }
            .onFailure { cause ->
                // A real fault reports itself. Collapsing this into
                // "unavailable" is what made the first device run
                // undiagnosable.
                phase = MigrationPhase.Failed(
                    couldNotOpenTemplate.replace(
                        errorMarker,
                        cause.message ?: cause.toString(),
                    )
                )
            }
            .onSuccess { built ->
                if (built == null) {
                    phase = MigrationPhase.Failed(lightningUnavailable)
                    return@onSuccess
                }
                if (abandoned.get()) {
                    built.close()
                    return@onSuccess
                }
                controller = built
                if (abandoned.get()) {
                    controller = null
                    built.close()
                    return@onSuccess
                }
                runCatching {
                    cashuBalance = built.destinationBalanceSats()
                    built.status()
                }
                    .onSuccess { status ->
                        phase = when (status?.state) {
                            null -> MigrationPhase.Idle
                            MigrationAttemptStateUi.AwaitingConsent,
                            MigrationAttemptStateUi.ExpiredUnsent -> {
                                // Prepared source quotes cannot survive a
                                // process restart. Clear only this proven-
                                // unspent state and ask for a fresh quote.
                                built.cancelUnspent()
                                MigrationPhase.Idle
                            }
                            MigrationAttemptStateUi.Settled ->
                                MigrationPhase.Settled(status.amountSats)
                            MigrationAttemptStateUi.SourceFailed ->
                                MigrationPhase.Failed(lightningPaymentFailed)
                            else -> MigrationPhase.PendingSettlement(cashuBalance)
                        }
                    }
                    .onFailure {
                        phase = MigrationPhase.Failed(
                            couldNotReadBalanceTemplate.replace(
                                errorMarker,
                                it.message ?: it.toString(),
                            )
                        )
                    }
            }
    }

    // The destination wallet holds an open store; leaving the screen must
    // release it, or a later migration reopens a locked database.
    //
    // Keyed on Unit, NOT on `controller`: keying on the controller makes the
    // effect re-run the moment it is assigned, and the disposal of the old
    // effect reads `controller` at dispose time — by then the NEW instance,
    // which it would close immediately. That produced "SonarMigration object
    // has already been destroyed" on the first real device run. With Unit,
    // dispose happens only when the screen goes away, which is the intent.
    DisposableEffect(Unit) {
        onDispose {
            abandoned.set(true)
            val owned = controller
            controller = null
            CoroutineScope(SupervisorJob() + Dispatchers.IO).launch(NonCancellable) {
                val state = runCatching { owned?.status()?.state }.getOrNull()
                if (state == MigrationAttemptStateUi.AwaitingConsent ||
                    state == MigrationAttemptStateUi.ExpiredUnsent
                ) {
                    runCatching { owned?.cancelUnspent() }
                }
                owned?.close()
            }
        }
    }

    WalletMigrationScreen(
        phase = phase,
        mintHost = SONAR_DEFAULT_MINT_URL.removePrefix("https://").removePrefix("http://"),
        breezBalanceSats = state.walletBalanceSats().coerceAtLeast(0L).toULong(),
        cashuBalanceSats = cashuBalance,
        onQuote = {
            val c = controller
            if (c == null) {
                openGeneration += 1
                return@WalletMigrationScreen
            }
            phase = MigrationPhase.Quoting
            scope.launch {
                when (val status = runCatching { c.status() }.getOrNull()) {
                    null -> Unit
                    else -> when (status.state) {
                        MigrationAttemptStateUi.Sending,
                        MigrationAttemptStateUi.PaymentUnknown,
                        MigrationAttemptStateUi.SourcePending,
                        MigrationAttemptStateUi.SourcePaid,
                        MigrationAttemptStateUi.MintPaid -> {
                            phase = MigrationPhase.PendingSettlement(cashuBalance)
                            return@launch
                        }
                        MigrationAttemptStateUi.Settled -> {
                            phase = MigrationPhase.Settled(status.amountSats)
                            return@launch
                        }
                        MigrationAttemptStateUi.SourceFailed,
                        MigrationAttemptStateUi.AwaitingConsent,
                        MigrationAttemptStateUi.ExpiredUnsent ->
                            runCatching { c.cancelUnspent() }
                    }
                }
                // amountSats = null: whole-balance drain, minus the quoted fee.
                runCatching { c.quote(null) }
                    .onSuccess {
                        quote = it
                        phase = MigrationPhase.AwaitingConsent(it.amountSats, it.feeSats)
                    }
                    .onFailure {
                        phase = MigrationPhase.Failed(
                            couldNotPriceTemplate.replace(
                                errorMarker,
                                it.message ?: it.toString(),
                            )
                        )
                    }
            }
        },
        onConfirm = {
            val c = controller ?: return@WalletMigrationScreen
            val q = quote ?: return@WalletMigrationScreen
            phase = MigrationPhase.Paying
            scope.launch {
                runCatching { c.execute(q.planId) }
                    .getOrElse {
                        phase = when (runCatching { c.status() }.getOrNull()?.state) {
                            MigrationAttemptStateUi.Sending,
                            MigrationAttemptStateUi.PaymentUnknown,
                            MigrationAttemptStateUi.SourcePending,
                            MigrationAttemptStateUi.SourcePaid,
                            MigrationAttemptStateUi.MintPaid ->
                                MigrationPhase.PendingSettlement(cashuBalance)
                            else -> MigrationPhase.Failed(
                                paymentFailedTemplate.replace(
                                    errorMarker,
                                    it.message ?: it.toString(),
                                )
                            )
                        }
                        return@launch
                    }
                // Past this point the money has LEFT the Lightning wallet.
                // Every branch below must leave the user a way forward.
                phase = MigrationPhase.Watching
                runCatching { c.resume(SETTLE_POLLS) }
                    .onSuccess { result ->
                        phase = when (result) {
                            is MigrationResultUi.Settled -> {
                                cashuBalance = result.cashuSats
                                MigrationPhase.Settled(result.cashuSats)
                            }
                            is MigrationResultUi.Pending -> {
                                cashuBalance = result.cashuSats
                                MigrationPhase.PendingSettlement(result.cashuSats)
                            }
                        }
                    }
                    .onFailure {
                        // Paid but the watch failed: NOT a lost-funds state.
                        // Report it as pending so the screen offers "Check
                        // again" instead of a dead end.
                        phase = MigrationPhase.PendingSettlement(cashuBalance)
                    }
            }
        },
        onResume = {
            val c = controller ?: return@WalletMigrationScreen
            phase = MigrationPhase.Watching
            scope.launch {
                runCatching { c.resume(SETTLE_POLLS) }
                    .onSuccess { result ->
                        phase = when (result) {
                            is MigrationResultUi.Settled -> {
                                cashuBalance = result.cashuSats
                                MigrationPhase.Settled(result.cashuSats)
                            }
                            is MigrationResultUi.Pending -> {
                                cashuBalance = result.cashuSats
                                MigrationPhase.PendingSettlement(result.cashuSats)
                            }
                        }
                    }
                    .onFailure { phase = MigrationPhase.PendingSettlement(cashuBalance) }
            }
        },
    )
}
