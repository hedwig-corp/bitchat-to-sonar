package chat.bitchat.sonar.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import chat.bitchat.sonar.SonarAppState
import chat.bitchat.sonar.resources.Res
import chat.bitchat.sonar.resources.cancel
import chat.bitchat.sonar.resources.couldn_t_update_your_address_retrying
import chat.bitchat.sonar.resources.move_address
import chat.bitchat.sonar.resources.move_back
import chat.bitchat.sonar.resources.move_back_to_your_old_wallet
import chat.bitchat.sonar.resources.move_to_new_wallet
import chat.bitchat.sonar.resources.move_your_address_back_to_your_old
import chat.bitchat.sonar.resources.move_your_address_to_your_new_wallet
import chat.bitchat.sonar.resources.moving
import chat.bitchat.sonar.resources.payments_to_will_go_to_your_new_wallet
import chat.bitchat.sonar.resources.payments_to_will_go_to_your_old
import chat.bitchat.sonar.resources.your_address_still_pays_your_old_wallet
import chat.bitchat.sonar.ui.SNGhostButton
import chat.bitchat.sonar.ui.SNPrimaryButton
import chat.bitchat.sonar.ui.sonar
import chat.bitchat.sonar.wallet.HandleAddressNotice
import chat.bitchat.sonar.wallet.HandleMoveState
import org.jetbrains.compose.resources.stringResource

private enum class HandleMoveTarget { NewWallet, OldWallet }

/** Whether [HandleAddressNotice] has anything to show (hosts skip their container otherwise). */
internal fun handleAddressNoticeVisible(state: SonarAppState): Boolean =
    state.handleAddressNotice !is HandleAddressNotice.None || state.canMoveHandleBackToOldWallet

/**
 * Which wallet the public handle pays, next to wherever the address or the
 * old wallet is shown (Profile username card, Settings wallet section, the
 * Wallet screen's old-wallet card). iOS mirror: `SNHandleAddressNotice`.
 *
 * - "Your address … still pays your old wallet." + Move, while the handle
 *   points at the legacy wallet and it is still here. It stays until the
 *   move succeeds; the app never moves it on its own.
 * - "Couldn't update your address … Retrying." when an automatic
 *   re-registration failed.
 * - "Move back to your old wallet" while the handle pays the new wallet and
 *   the old one is still here.
 *
 * Every move asks first. Renders nothing when there is nothing to say; the
 * host supplies the container.
 */
@Composable
internal fun HandleAddressNotice(state: SonarAppState, modifier: Modifier = Modifier) {
    val s = sonar
    val notice = state.handleAddressNotice
    val canMoveBack = state.canMoveHandleBackToOldWallet
    val moveState = state.handleMoveState
    if (notice is HandleAddressNotice.None && !canMoveBack) return
    var confirming by remember { mutableStateOf<HandleMoveTarget?>(null) }
    val moving = moveState is HandleMoveState.Moving
    val address = when (notice) {
        is HandleAddressNotice.PaysOldWallet -> notice.address
        is HandleAddressNotice.UpdateFailing -> notice.address
        HandleAddressNotice.None -> state.coreClaimedHandle.orEmpty()
    }

    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        when (notice) {
            is HandleAddressNotice.PaysOldWallet -> {
                Text(
                    stringResource(Res.string.your_address_still_pays_your_old_wallet, notice.address),
                    color = s.text, fontSize = 13.sp, lineHeight = 18.sp, fontWeight = FontWeight.SemiBold,
                )
                NoticeAction(
                    if (moving) stringResource(Res.string.moving) else stringResource(Res.string.move_to_new_wallet),
                    primary = true,
                ) { if (!moving) confirming = HandleMoveTarget.NewWallet }
            }
            is HandleAddressNotice.UpdateFailing -> Text(
                stringResource(Res.string.couldn_t_update_your_address_retrying, notice.address),
                color = s.text3, fontSize = 12.5.sp, lineHeight = 17.sp,
            )
            HandleAddressNotice.None -> Unit
        }
        if (canMoveBack) {
            NoticeAction(
                if (moving) stringResource(Res.string.moving) else stringResource(Res.string.move_back_to_your_old_wallet),
            ) { if (!moving) confirming = HandleMoveTarget.OldWallet }
        }
        if (moveState is HandleMoveState.Failed) {
            Text(moveState.message, color = s.danger, fontSize = 12.5.sp, lineHeight = 17.sp)
        }
    }

    when (confirming) {
        HandleMoveTarget.NewWallet -> HandleMoveConfirmDialog(
            title = stringResource(Res.string.move_your_address_to_your_new_wallet),
            body = stringResource(Res.string.payments_to_will_go_to_your_new_wallet, address),
            confirmLabel = stringResource(Res.string.move_address),
            onConfirm = { confirming = null; state.moveHandleToNewWallet() },
            onDismiss = { confirming = null; state.resetHandleMoveState() },
        )
        HandleMoveTarget.OldWallet -> HandleMoveConfirmDialog(
            title = stringResource(Res.string.move_your_address_back_to_your_old),
            body = stringResource(Res.string.payments_to_will_go_to_your_old, address),
            confirmLabel = stringResource(Res.string.move_back),
            onConfirm = { confirming = null; state.moveHandleToOldWallet() },
            onDismiss = { confirming = null; state.resetHandleMoveState() },
        )
        null -> Unit
    }
}

@Composable
private fun NoticeAction(label: String, primary: Boolean = false, onClick: () -> Unit) {
    val s = sonar
    Box(
        Modifier.clip(RoundedCornerShape(999.dp))
            .background(if (primary) s.goldFill else s.surface2)
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 8.dp),
    ) {
        Text(label, color = if (primary) s.onGold else s.text, fontSize = 13.sp, fontWeight = FontWeight.Bold)
    }
}

/** The move's consent: what changes, for whom, and what does not undo it. */
@Composable
private fun HandleMoveConfirmDialog(
    title: String,
    body: String,
    confirmLabel: String,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    val s = sonar
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(dismissOnBackPress = true, dismissOnClickOutside = true, usePlatformDefaultWidth = false),
    ) {
        Box(
            Modifier.fillMaxSize().background(s.scrim).clickable(
                interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onDismiss,
            ),
            contentAlignment = Alignment.Center,
        ) {
            Column(
                Modifier.widthIn(max = 420.dp).fillMaxWidth().padding(horizontal = 18.dp)
                    .clip(RoundedCornerShape(24.dp)).background(s.surface)
                    .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = {})
                    .padding(start = 18.dp, end = 18.dp, top = 20.dp, bottom = 12.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(title, color = s.text, fontSize = 16.5.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
                Spacer(Modifier.height(8.dp))
                Text(body, color = s.text2, fontSize = 13.5.sp, lineHeight = 20.sp, textAlign = TextAlign.Center)
                Spacer(Modifier.height(14.dp))
                SNPrimaryButton(label = confirmLabel, onClick = onConfirm)
                Spacer(Modifier.height(4.dp))
                SNGhostButton(label = stringResource(Res.string.cancel), onClick = onDismiss)
            }
        }
    }
}
