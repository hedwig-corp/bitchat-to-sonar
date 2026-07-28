package chat.bitchat.sonar.screens

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.bitchat.sonar.Screen
import chat.bitchat.sonar.SonarAppState
import chat.bitchat.sonar.payFmt
import chat.bitchat.sonar.ui.SNIcon
import chat.bitchat.sonar.ui.SNIconName
import chat.bitchat.sonar.ui.SNNavHeader
import chat.bitchat.sonar.ui.SNSectionLabel
import chat.bitchat.sonar.ui.SonarPalette
import chat.bitchat.sonar.ui.sonar
import chat.bitchat.sonar.wallet.PayAction
import chat.bitchat.sonar.wallet.PayMoneyTone
import chat.bitchat.sonar.wallet.PayPhase
import chat.bitchat.sonar.wallet.PayStatusCopy
import chat.bitchat.sonar.wallet.PaymentStatus

/**
 * Payment status — 1:1 with Direction D ("resumable status") of the design's
 * `Sonar Payment Status.html` + `sonar/paystatus.jsx`: a status card with a
 * spinner, progress bar, plain-language hint and per-state actions; the
 * "In your wallet" row that keeps updating after you leave; and the money line
 * that always names where the sats are.
 *
 * Reached from the send-payment picker after confirming an amount for an
 * external destination (scanned QR, pasted offer/invoice, Lightning address).
 * Payments to a *contact* keep reporting into their chat as a ⚡PAY receipt —
 * the design scopes this screen to payments that have no chat thread.
 *
 * The iOS mirror is `ios/bitchat/Views/Sonar/SonarPaymentStatusScreen.swift`.
 */
@Composable
fun SonarPaymentStatusScreen(state: SonarAppState, activityId: String) {
    val s = sonar
    val clipboard = LocalClipboardManager.current
    // Recompose as the ledger settles and as the elapsed clock ticks.
    state.paymentActivityVersion
    state.paymentClock
    state.livePayments

    // Following a retry in place keeps Back on home rather than stacking
    // attempt after attempt.
    var retriedId by remember(activityId) { mutableStateOf<String?>(null) }
    val currentId = retriedId ?: activityId
    val status = state.paymentStatus(currentId)

    Column(Modifier.fillMaxSize().background(s.bg)) {
        SNNavHeader("Payment", hairline = false, onBack = { state.back() })

        if (status == null) {
            // The activity was wiped (emergency wipe) while the screen was
            // open. Say so rather than rendering an empty shell.
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(
                    "This payment is no longer in your wallet history.",
                    color = s.text3, fontSize = 14.sp, textAlign = TextAlign.Center,
                    modifier = Modifier.padding(horizontal = 30.dp),
                )
            }
            return@Column
        }

        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState())
                .padding(bottom = 40.dp),
        ) {
            StatusCard(
                status = status,
                onAction = { action ->
                    when (action.effect) {
                        PayAction.Effect.Dismiss -> {
                            if (status.phase == PayPhase.Resolving) {
                                state.cancelDestinationPayment(status.id)
                            }
                            state.back()
                        }
                        PayAction.Effect.CopyProof -> status.preimage?.let {
                            clipboard.setText(AnnotatedString(it))
                            state.toast = "Proof copied"
                        }
                        PayAction.Effect.Retry -> {
                            val next = state.retryDestinationPayment(status.id)
                            if (next == null) {
                                state.toast = "Can't retry — reopen the payment from Send payment."
                            } else {
                                retriedId = next
                            }
                        }
                    }
                },
                onClose = { state.back() },
            )

            SNSectionLabel("In your wallet")
            WalletRow(status)

            // .rs-note
            Text(
                "This row keeps updating even if you close the sheet, leave the wallet, " +
                    "or background the app — the payment is owned by the wallet, not the screen.",
                color = s.text3, fontSize = 12.sp, lineHeight = 18.sp,
                modifier = Modifier.padding(start = 20.dp, end = 20.dp, top = 10.dp),
            )

            MoneyLine(status, Modifier.padding(start = 18.dp, end = 18.dp, top = 18.dp))
        }
    }
}

/** .rs-sheet */
@Composable
private fun StatusCard(
    status: PaymentStatus,
    onAction: (PayAction) -> Unit,
    onClose: () -> Unit,
) {
    val s = sonar
    Column(
        Modifier.fillMaxWidth().padding(start = 18.dp, end = 18.dp, top = 16.dp)
            .clip(RoundedCornerShape(22.dp)).background(s.surface)
            .border(1.dp, s.hairline, RoundedCornerShape(22.dp))
            .padding(16.dp),
    ) {
        // .rs-top
        Row(verticalAlignment = Alignment.CenterVertically) {
            Indicator(status.phase, 38.dp)
            Spacer(Modifier.width(11.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    PayStatusCopy.headline(status.phase, status.payeeName, status.sats),
                    color = s.text, fontSize = 15.5.sp, fontWeight = FontWeight.Bold,
                )
                Text(
                    "${status.payeeName} · ${payFmt(status.sats)} sats",
                    color = s.text2, fontSize = 12.5.sp, maxLines = 1,
                )
            }
            if (status.phase.isLive) {
                // .rs-x — same effect as the dismiss action below it.
                Box(
                    Modifier.size(30.dp).clip(CircleShape).background(s.surface2)
                        .clickable(onClick = onClose),
                    contentAlignment = Alignment.Center,
                ) { SNIcon(SNIconName.X, 14.dp, s.text2, weight = 2.4f) }
            }
        }

        // .rs-bar
        Box(
            Modifier.fillMaxWidth().padding(top = 14.dp).height(4.dp)
                .clip(RoundedCornerShape(2.dp)).background(s.surface2),
        ) {
            Box(
                Modifier.fillMaxWidth(status.phase.progress).height(4.dp)
                    .clip(RoundedCornerShape(2.dp))
                    .background(
                        when {
                            status.phase.isGood -> s.green
                            status.phase.isBad -> s.danger
                            else -> s.accent
                        }
                    ),
            )
        }

        // .rs-hint
        Text(
            PayStatusCopy.hint(status.phase, status.payeeName, status.sats),
            color = s.text2, fontSize = 12.5.sp, lineHeight = 19.sp,
            modifier = Modifier.padding(top = 12.dp),
        )

        // .rs-acts
        Row(
            Modifier.fillMaxWidth().padding(top = 14.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            PayStatusCopy.actions(status).forEach { action ->
                Box(
                    Modifier.weight(1f).clip(RoundedCornerShape(12.dp))
                        .background(
                            if (action.kind == PayAction.Kind.Primary) s.accentFill else s.surface2
                        )
                        .clickable { onAction(action) }
                        .padding(vertical = 11.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        action.label,
                        color = when (action.kind) {
                            PayAction.Kind.Primary -> s.onAccent
                            PayAction.Kind.Dim -> s.text2
                            PayAction.Kind.Plain -> s.text
                        },
                        fontSize = 13.5.sp, fontWeight = FontWeight.Bold, maxLines = 1,
                    )
                }
            }
        }
    }
}

/** .rs-spin — a sweeping arc while live, a terminal glyph tile otherwise. */
@Composable
private fun Indicator(phase: PayPhase, size: Dp) {
    val s = sonar
    if (phase.isLive) {
        SpinningArc(
            size = size,
            stroke = 4.dp,
            track = s.surface2,
            color = if (phase.isWarn) s.goldFill else s.accent,
        )
    } else {
        Box(
            Modifier.size(size).clip(RoundedCornerShape(12.dp))
                .background(if (phase.isGood) s.greenSoft else s.danger.copy(alpha = 0.14f)),
            contentAlignment = Alignment.Center,
        ) {
            SNIcon(
                if (phase.isGood) SNIconName.Check else SNIconName.X,
                19.dp,
                if (phase.isGood) s.greenDeep else s.danger,
                weight = 2.6f,
            )
        }
    }
}

/** .rs-row */
@Composable
private fun WalletRow(status: PaymentStatus) {
    val s = sonar
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 18.dp)
            .clip(RoundedCornerShape(14.dp)).background(s.surface)
            .border(1.dp, s.hairline, RoundedCornerShape(14.dp))
            .padding(horizontal = 12.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(36.dp).clip(RoundedCornerShape(11.dp))
                .background(rowTileFill(status.phase, s)),
            contentAlignment = Alignment.Center,
        ) {
            SNIcon(
                when {
                    status.phase.isGood -> SNIconName.Check
                    status.phase.isBad -> SNIconName.X
                    else -> SNIconName.Bolt
                },
                17.dp, rowTileTint(status.phase, s), weight = 2.3f,
            )
        }
        Spacer(Modifier.width(11.dp))
        Column(Modifier.weight(1f)) {
            Text(
                status.payeeName,
                color = s.text, fontSize = 14.5.sp, fontWeight = FontWeight.Bold, maxLines = 1,
            )
            Text(
                PayStatusCopy.walletRow(status.phase, status.elapsedSecs),
                color = s.text2, fontSize = 12.sp, maxLines = 1,
            )
        }
        Text(
            if (status.phase.isBad) "—" else "−${payFmt(status.sats)}",
            color = when {
                status.phase.isGood -> s.text
                status.phase.isBad -> s.text3
                else -> s.text2
            },
            fontSize = 14.sp, fontWeight = FontWeight.Bold,
        )
    }
}

/** .money */
@Composable
private fun MoneyLine(status: PaymentStatus, modifier: Modifier = Modifier) {
    val s = sonar
    val (tone, text) = PayStatusCopy.money(status.phase, status.sats)
    val fill = when (tone) {
        PayMoneyTone.Safe -> s.surface2
        PayMoneyTone.Flight -> s.netSoft
        PayMoneyTone.Good -> s.greenSoft
        PayMoneyTone.Warn -> s.goldSoft
    }
    val tint = when (tone) {
        PayMoneyTone.Safe -> s.text2
        PayMoneyTone.Flight -> s.netDeep
        PayMoneyTone.Good -> s.greenDeep
        PayMoneyTone.Warn -> s.goldDeep
    }
    Row(
        modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(fill)
            .padding(horizontal = 14.dp, vertical = 13.dp),
    ) {
        SNIcon(
            when (tone) {
                PayMoneyTone.Good -> SNIconName.Check
                PayMoneyTone.Warn -> SNIconName.Shield
                PayMoneyTone.Flight -> SNIconName.Bolt
                PayMoneyTone.Safe -> SNIconName.Lock
            },
            16.dp, tint, weight = 2.1f,
        )
        Spacer(Modifier.width(9.dp))
        Text(text, color = tint, fontSize = 13.5.sp, lineHeight = 20.sp)
    }
}

/**
 * The H1 pinned strip (design: paystatus.jsx `.hp-strip`) — the tinted card at
 * the top of the home list while an external payment is in flight. It has no
 * chat thread to live in, so this is its only place in the list, and it clears
 * itself the moment the payment settles or fails rather than becoming
 * permanent history.
 */
@Composable
fun HomePaymentStrip(state: SonarAppState) {
    val s = sonar
    state.paymentClock
    val status = state.livePaymentStatus() ?: return
    val (title, sub) = PayStatusCopy.homeStrip(status.phase, status.payeeName, status.sats)
    val tint = if (status.phase.isWarn) s.goldFill else s.accent
    Row(
        Modifier.fillMaxWidth().padding(start = 14.dp, end = 14.dp, top = 2.dp, bottom = 8.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(if (status.phase.isWarn) s.goldSoft else s.accentSoft)
            .border(1.dp, tint.copy(alpha = 0.28f), RoundedCornerShape(16.dp))
            .clickable { state.push(Screen.PaymentStatus(status.id)) }
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // paystatus.jsx MiniRing. Only live phases reach the strip, so this is
        // always the sweeping arc.
        SpinningArc(size = 34.dp, stroke = 3.5.dp, track = s.surface2, color = tint)
        Spacer(Modifier.width(11.dp))
        Column(Modifier.weight(1f)) {
            Text(title, color = s.text, fontSize = 14.5.sp, fontWeight = FontWeight.Bold, maxLines = 1)
            Text(sub, color = s.text2, fontSize = 12.5.sp, maxLines = 1)
        }
        SNIcon(SNIconName.Chevron, 14.dp, s.text3, weight = 2.2f)
    }
}

/** The `.spin` keyframes: a 32% arc rotating once a second. */
@Composable
private fun SpinningArc(size: Dp, stroke: Dp, track: Color, color: Color) {
    val angle by rememberInfiniteTransition(label = "paySpin").animateFloat(
        initialValue = 0f,
        targetValue = 360f,
        animationSpec = infiniteRepeatable(
            animation = tween(1000, easing = LinearEasing),
            repeatMode = RepeatMode.Restart,
        ),
        label = "paySpinAngle",
    )
    androidx.compose.foundation.Canvas(Modifier.size(size).rotate(angle)) {
        val w = stroke.toPx()
        val inset = w / 2f
        val arcSize = Size(this.size.width - w, this.size.height - w)
        drawArc(
            color = track, startAngle = 0f, sweepAngle = 360f, useCenter = false,
            topLeft = androidx.compose.ui.geometry.Offset(inset, inset),
            size = arcSize, style = Stroke(width = w),
        )
        drawArc(
            color = color, startAngle = -90f, sweepAngle = 115f, useCenter = false,
            topLeft = androidx.compose.ui.geometry.Offset(inset, inset),
            size = arcSize, style = Stroke(width = w, cap = StrokeCap.Round),
        )
    }
}

private fun rowTileFill(phase: PayPhase, s: SonarPalette): Color = when {
    phase.isGood -> s.greenSoft
    phase.isBad -> s.danger.copy(alpha = 0.14f)
    phase.isWarn -> s.goldSoft
    else -> s.accentSoft
}

private fun rowTileTint(phase: PayPhase, s: SonarPalette): Color = when {
    phase.isGood -> s.greenDeep
    phase.isBad -> s.danger
    phase.isWarn -> s.goldDeep
    else -> s.accentDeep
}
