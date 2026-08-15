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
import chat.bitchat.sonar.SonarAppState

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
    val scope = rememberCoroutineScope()
    var phase by remember { mutableStateOf<MigrationPhase>(MigrationPhase.Idle) }
    var cashuBalance by remember { mutableStateOf(0uL) }
    var quote by remember { mutableStateOf<MigrationQuoteUi?>(null) }

    var controller by remember { mutableStateOf<WalletMigrationController?>(null) }

    // `createWalletMigrationController` opens the Cashu store, connects to the
    // mint, and on a fresh store runs a NUT-13 restore scan — a network round
    // trip. It must never run during composition or on the main dispatcher:
    // that blocks first paint on the mint and can ANR. Build it on IO and let
    // the screen paint "opening" state meanwhile.
    LaunchedEffect(Unit) {
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
                    "Could not open the migration: ${cause.message ?: cause.toString()}"
                )
            }
            .onSuccess { built ->
                if (built == null) {
                    phase = MigrationPhase.Failed(
                        "The Lightning wallet is not available on this device."
                    )
                    return@onSuccess
                }
                controller = built
                runCatching { built.destinationBalanceSats() }
                    .onSuccess { cashuBalance = it; phase = MigrationPhase.Idle }
                    .onFailure {
                        phase = MigrationPhase.Failed(
                            "Could not read the Cashu balance: ${it.message}"
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
        onDispose { controller?.close() }
    }

    WalletMigrationScreen(
        phase = phase,
        mintHost = SONAR_DEFAULT_MINT_URL.removePrefix("https://").removePrefix("http://"),
        breezBalanceSats = state.walletBalanceSats().coerceAtLeast(0L).toULong(),
        cashuBalanceSats = cashuBalance,
        onQuote = {
            val c = controller ?: return@WalletMigrationScreen
            phase = MigrationPhase.Quoting
            scope.launch {
                // amountSats = null: whole-balance drain, minus the quoted fee.
                runCatching { c.quote(null) }
                    .onSuccess {
                        quote = it
                        phase = MigrationPhase.AwaitingConsent(it.amountSats, it.feeSats)
                    }
                    .onFailure { phase = MigrationPhase.Failed(it.message ?: "Could not price the migration.") }
            }
        },
        onConfirm = {
            val c = controller ?: return@WalletMigrationScreen
            val q = quote ?: return@WalletMigrationScreen
            phase = MigrationPhase.Paying
            scope.launch {
                val paid = runCatching { c.execute(q.planId) }
                    .getOrElse {
                        phase = MigrationPhase.Failed(it.message ?: "The payment did not go through.")
                        return@launch
                    }
                // Past this point the money has LEFT the Lightning wallet.
                // Every branch below must leave the user a way forward.
                phase = MigrationPhase.Watching
                runCatching { c.settle(q.baselineSats, paid, SETTLE_POLLS) }
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
            val q = quote
            phase = MigrationPhase.Watching
            scope.launch {
                runCatching {
                    c.settle(q?.baselineSats ?: 0uL, q?.amountSats ?: 0uL, SETTLE_POLLS)
                }
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
