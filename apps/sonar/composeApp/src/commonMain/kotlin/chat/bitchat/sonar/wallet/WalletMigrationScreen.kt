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
import chat.bitchat.sonar.resources.Res
import chat.bitchat.sonar.resources.arrives_in_cashu
import chat.bitchat.sonar.resources.cashu_wallet
import chat.bitchat.sonar.resources.check_again
import chat.bitchat.sonar.resources.check_amount_and_fee
import chat.bitchat.sonar.resources.fee_unknown
import chat.bitchat.sonar.resources.lightning_wallet
import chat.bitchat.sonar.resources.migration_complete
import chat.bitchat.sonar.resources.migration_stopped
import chat.bitchat.sonar.resources.move_sats_to
import chat.bitchat.sonar.resources.move_your_lightning_balance_into_ecash_2
import chat.bitchat.sonar.resources.network_fee
import chat.bitchat.sonar.resources.paid_waiting_on_the_mint
import chat.bitchat.sonar.resources.paying_from_the_lightning_wallet
import chat.bitchat.sonar.resources.pricing_the_migration
import chat.bitchat.sonar.resources.sats_2
import chat.bitchat.sonar.resources.sats_are_now_in_your_cashu_wallet
import chat.bitchat.sonar.resources.this_changes_who_holds_your_money
import chat.bitchat.sonar.resources.this_pays_now_it_cannot_be_undone_from
import chat.bitchat.sonar.resources.today_your_balance_is_self_custodial
import chat.bitchat.sonar.resources.try_again
import chat.bitchat.sonar.resources.waiting_for_the_mint_to_issue_your_ecash
import chat.bitchat.sonar.resources.your_payment_went_out_the_mint_has_not
import chat.bitchat.sonar.resources.your_tokens_are_recoverable_from_your
import org.jetbrains.compose.resources.stringResource

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
            stringResource(Res.string.move_your_lightning_balance_into_ecash_2),
            style = MaterialTheme.typography.bodyLarge,
        )

        when (phase) {
            is MigrationPhase.Idle -> {
                CustodyExplainer(mintHost)
                Button(onClick = onQuote, modifier = Modifier.fillMaxWidth()) {
                    Text(stringResource(Res.string.check_amount_and_fee))
                }
            }
            is MigrationPhase.Quoting -> ProgressRow(stringResource(Res.string.pricing_the_migration))
            is MigrationPhase.AwaitingConsent -> {
                CustodyExplainer(mintHost)
                Card {
                    Column(Modifier.padding(14.dp), Arrangement.spacedBy(6.dp)) {
                        LabelledRow(
                            stringResource(Res.string.arrives_in_cashu),
                            stringResource(Res.string.sats_2, phase.amountSats.toString()),
                        )
                        LabelledRow(
                            stringResource(Res.string.network_fee),
                            phase.feeSats?.let {
                                stringResource(Res.string.sats_2, it.toString())
                            } ?: stringResource(Res.string.fee_unknown),
                        )
                    }
                }
                Button(onClick = onConfirm, modifier = Modifier.fillMaxWidth()) {
                    Text(
                        stringResource(
                            Res.string.move_sats_to,
                            phase.amountSats.toString(),
                            mintHost,
                        )
                    )
                }
                Text(
                    stringResource(Res.string.this_pays_now_it_cannot_be_undone_from),
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            is MigrationPhase.Paying ->
                ProgressRow(stringResource(Res.string.paying_from_the_lightning_wallet))
            is MigrationPhase.Watching ->
                ProgressRow(stringResource(Res.string.waiting_for_the_mint_to_issue_your_ecash))
            is MigrationPhase.Settled -> ResultRow(
                stringResource(Res.string.migration_complete),
                stringResource(
                    Res.string.sats_are_now_in_your_cashu_wallet,
                    phase.cashuSats.toString(),
                ),
            )
            is MigrationPhase.PendingSettlement -> {
                ResultRow(
                    stringResource(Res.string.paid_waiting_on_the_mint),
                    stringResource(
                        Res.string.your_payment_went_out_the_mint_has_not,
                        phase.cashuSats.toString(),
                    ),
                )
                Button(onClick = onResume, modifier = Modifier.fillMaxWidth()) {
                    Text(stringResource(Res.string.check_again))
                }
            }
            is MigrationPhase.Failed -> {
                ResultRow(stringResource(Res.string.migration_stopped), phase.message)
                Button(onClick = onQuote, modifier = Modifier.fillMaxWidth()) {
                    Text(stringResource(Res.string.try_again))
                }
            }
        }

        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            LabelledRow(
                stringResource(Res.string.lightning_wallet),
                stringResource(Res.string.sats_2, breezBalanceSats.toString()),
            )
            LabelledRow(
                stringResource(Res.string.cashu_wallet),
                stringResource(Res.string.sats_2, cashuBalanceSats.toString()),
            )
        }
    }
}

/** The custody change, in plain language, BEFORE any confirm affordance. */
@Composable
private fun CustodyExplainer(mintHost: String) {
    Card {
        Column(Modifier.padding(14.dp), Arrangement.spacedBy(8.dp)) {
            Text(
                stringResource(Res.string.this_changes_who_holds_your_money),
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.Medium,
            )
            Text(
                stringResource(Res.string.today_your_balance_is_self_custodial, mintHost),
                style = MaterialTheme.typography.bodyMedium,
            )
            Text(
                stringResource(Res.string.your_tokens_are_recoverable_from_your),
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
