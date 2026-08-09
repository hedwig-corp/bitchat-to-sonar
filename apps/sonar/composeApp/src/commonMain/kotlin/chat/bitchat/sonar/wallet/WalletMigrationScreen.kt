package chat.bitchat.sonar.wallet

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/**
 * Breez→Cashu migration UI state. Mirrors the Apple `SonarMigrationModel`
 * phases exactly — both drive the same Rust engine, so the states they can be
 * in are the engine's, not each platform's invention.
 */
sealed interface MigrationPhase {
    data object Idle : MigrationPhase
    data object Quoting : MigrationPhase
    /** Quote in hand; the consent screen is showing these numbers. */
    data class AwaitingConsent(val amountSats: ULong, val feeSats: ULong?) : MigrationPhase
    data object Paying : MigrationPhase
    data object Watching : MigrationPhase
    data class Settled(val cashuSats: ULong) : MigrationPhase
    /** Paid, funds not visible yet. Recoverable — not a failure. */
    data class PendingSettlement(val cashuSats: ULong) : MigrationPhase
    data class Failed(val message: String) : MigrationPhase
}

/**
 * Consent + progress. The custody change is stated before a confirm button
 * exists, and the fee is on screen at the moment of consent.
 */
@Composable
fun WalletMigrationScreen(
    phase: MigrationPhase,
    mintHost: String,
    breezBalanceSats: ULong,
    cashuBalanceSats: ULong,
    onQuote: () -> Unit,
    onConfirm: () -> Unit,
    onResume: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(
            "Move your Lightning balance into ecash held on this device.",
            style = MaterialTheme.typography.bodyLarge,
        )

        when (phase) {
            is MigrationPhase.Idle -> {
                CustodyExplainer(mintHost)
                Button(onClick = onQuote, modifier = Modifier.fillMaxWidth()) {
                    Text("Check amount and fee")
                }
            }
            is MigrationPhase.Quoting -> ProgressRow("Pricing the migration…")
            is MigrationPhase.AwaitingConsent -> {
                CustodyExplainer(mintHost)
                Card {
                    Column(Modifier.padding(14.dp), Arrangement.spacedBy(6.dp)) {
                        LabelledRow("Arrives in Cashu", "${phase.amountSats} sats")
                        LabelledRow(
                            "Network fee",
                            phase.feeSats?.let { "$it sats" } ?: "unknown",
                        )
                    }
                }
                Button(onClick = onConfirm, modifier = Modifier.fillMaxWidth()) {
                    Text("Move ${phase.amountSats} sats to $mintHost")
                }
                Text(
                    "This pays now. It cannot be undone from here.",
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            is MigrationPhase.Paying -> ProgressRow("Paying from the Lightning wallet…")
            is MigrationPhase.Watching -> ProgressRow("Waiting for the mint to issue your ecash…")
            is MigrationPhase.Settled -> ResultRow(
                "Migration complete",
                "${phase.cashuSats} sats are now in your Cashu wallet.",
            )
            is MigrationPhase.PendingSettlement -> {
                ResultRow(
                    "Paid — waiting on the mint",
                    "Your payment went out. The mint has not issued the ecash yet; your wallet " +
                        "keeps trying. Current Cashu balance: ${phase.cashuSats} sats.",
                )
                Button(onClick = onResume, modifier = Modifier.fillMaxWidth()) {
                    Text("Check again")
                }
            }
            is MigrationPhase.Failed -> {
                ResultRow("Migration stopped", phase.message)
                Button(onClick = onQuote, modifier = Modifier.fillMaxWidth()) {
                    Text("Try again")
                }
            }
        }

        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            LabelledRow("Lightning wallet", "$breezBalanceSats sats")
            LabelledRow("Cashu wallet", "$cashuBalanceSats sats")
        }
    }
}

/** The custody change, in plain language, BEFORE any confirm affordance. */
@Composable
private fun CustodyExplainer(mintHost: String) {
    Card {
        Column(Modifier.padding(14.dp), Arrangement.spacedBy(8.dp)) {
            Text(
                "This changes who holds your money",
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.Medium,
            )
            Text(
                "Today your balance is self-custodial. After moving, you hold ecash tokens on " +
                    "this device and $mintHost holds the Lightning side. If that mint " +
                    "disappears, the ecash it issued cannot be redeemed.",
                style = MaterialTheme.typography.bodyMedium,
            )
            Text(
                "Your tokens are recoverable from your account key on this mint, so a reinstall " +
                    "does not lose them.",
                style = MaterialTheme.typography.bodySmall,
            )
        }
    }
}

@Composable
private fun LabelledRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth(), Arrangement.SpaceBetween) {
        Text(label, style = MaterialTheme.typography.bodyMedium)
        Text(value, style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
private fun ProgressRow(label: String) {
    Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
        CircularProgressIndicator()
        Text(label, Modifier.padding(start = 12.dp), style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
private fun ResultRow(title: String, detail: String) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Medium)
        Text(detail, style = MaterialTheme.typography.bodyMedium)
    }
}
