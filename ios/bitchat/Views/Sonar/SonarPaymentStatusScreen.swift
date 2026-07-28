//
// SonarPaymentStatusScreen.swift
// bitchat
//
// Payment status — 1:1 with Direction D ("resumable status") of the design's
// `Sonar Payment Status.html` + `sonar/paystatus.jsx`: a status card with a
// spinner, progress bar, plain-language hint and per-state actions; the
// "In your wallet" row that keeps updating after you leave; and the money line
// that always names where the sats are.
//
// Reached from the send-payment picker after confirming an amount for an
// external destination (scanned QR, pasted offer/invoice, Lightning address).
// Payments to a *contact* keep reporting into their chat as a ⚡PAY receipt —
// the design scopes this screen to payments that have no chat thread.
//
// The Compose mirror is
// `apps/sonar/composeApp/src/commonMain/kotlin/chat/bitchat/sonar/screens/SonarPaymentStatusScreen.kt`.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct SonarPaymentStatusScreen: View {
    @EnvironmentObject private var store: SonarAppStore
    /// Observed so the elapsed label and the paying → slow flip stay live.
    /// The clock is separate from the store on purpose (see SNPaymentClock).
    @EnvironmentObject private var clock: SNPaymentClock

    let activityId: String

    /// The screen follows a retry onto the new activity without a push, so
    /// Back still lands on home rather than on a stack of attempts.
    @State private var retriedId: String?
    private var currentId: String { retriedId ?? activityId }

    var body: some View {
        VStack(spacing: 0) {
            SNNavHeader(hairline: false, onBack: { store.pop() }) {
                SNHeaderName("Payment")
            }

            // Reading the tick here is what re-derives the phase each second.
            let _ = clock.tick
            if let status = store.paymentStatus(currentId) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        statusCard(status)
                        SNSectionLabel("In your wallet")
                        walletRow(status)
                        // .rs-note
                        Text("This row keeps updating even if you close the sheet, leave the wallet, "
                             + "or background the app — the payment is owned by the wallet, not the screen.")
                            .font(SonarTheme.uiFont(size: 12))
                            .lineSpacing(12 * 0.5)
                            .foregroundColor(SonarTheme.text3)
                            .padding(EdgeInsets(top: 10, leading: 20, bottom: 0, trailing: 20))
                        moneyLine(status)
                            .padding(EdgeInsets(top: 18, leading: 18, bottom: 0, trailing: 18))
                        Color.clear.frame(height: 40)
                    }
                }
            } else {
                // The activity was wiped (emergency wipe) while the screen was
                // open. Say so rather than rendering an empty shell.
                Text("This payment is no longer in your wallet history.")
                    .font(SonarTheme.uiFont(size: 14))
                    .foregroundColor(SonarTheme.text3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 30)
            }
        }
        .background(SonarTheme.bg.ignoresSafeArea())
    }

    // MARK: .rs-sheet

    private func statusCard(_ status: SNPaymentStatus) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // .rs-top
            HStack(spacing: 11) {
                indicator(status.phase)
                    .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: SNPayStatusCopy.headline(
                        status.phase, payee: status.payeeName, sats: status.sats
                    ))
                    .font(SonarTheme.uiFont(size: 15.5, weight: .bold))
                    .foregroundColor(SonarTheme.text)
                    Text(verbatim: "\(status.payeeName) · \(sonarFormatSats(status.sats))")
                        .font(SonarTheme.uiFont(size: 12.5))
                        .foregroundColor(SonarTheme.text2)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if status.phase.isLive {
                    // .rs-x — closes the screen only. Unlike the labelled
                    // Cancel action below, it never aborts the payment: ✕ is
                    // "I am done looking", Cancel is "do not send this".
                    SNIconButton(action: { store.pop() }) {
                        SNIcon(name: .x, size: 14, weight: 2.4)
                            .foregroundColor(SonarTheme.text2)
                    }
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(SonarTheme.surface2))
                }
            }

            // .rs-bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(SonarTheme.surface2)
                    Capsule()
                        .fill(barColor(status.phase))
                        .frame(width: geo.size.width * status.phase.progress)
                }
            }
            .frame(height: 4)
            .padding(.top, 14)
            .animation(.easeInOut(duration: 0.7), value: status.phase)

            // .rs-hint
            Text(verbatim: SNPayStatusCopy.hint(
                status.phase, payee: status.payeeName, sats: status.sats
            ))
            .font(SonarTheme.uiFont(size: 12.5))
            .lineSpacing(12.5 * 0.5)
            .foregroundColor(SonarTheme.text2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)

            // .rs-acts
            HStack(spacing: 8) {
                ForEach(SNPayStatusCopy.actions(status)) { action in
                    Button {
                        perform(action, on: status)
                    } label: {
                        Text(verbatim: action.label)
                            .font(SonarTheme.uiFont(size: 13.5, weight: .bold))
                            .foregroundColor(actionLabelColor(action.kind))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(action.kind == .primary ? SonarTheme.accentFill : SonarTheme.surface2)
                            )
                    }
                    .buttonStyle(SNScaleStyle(scale: 0.98))
                }
            }
            .padding(.top, 14)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(SonarTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(SonarTheme.hairline, lineWidth: 1)
                )
        )
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 0, trailing: 18))
    }

    /// .rs-spin — a sweeping arc while live, a terminal glyph tile otherwise.
    @ViewBuilder
    private func indicator(_ phase: SNPayPhase) -> some View {
        if phase.isLive {
            Circle()
                .stroke(SonarTheme.surface2, lineWidth: 4)
                .overlay(
                    Circle()
                        .trim(from: 0, to: 0.32)
                        .stroke(
                            phase.isWarn ? SonarTheme.goldFill : SonarTheme.accent,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .modifier(SNSpinForever())
                )
                .padding(2)
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(phase.isGood ? SonarTheme.greenSoft : SonarTheme.danger.opacity(0.14))
                .overlay(
                    SNIcon(name: phase.isGood ? .check : .x, size: 19, weight: 2.6)
                        .foregroundColor(phase.isGood ? SonarTheme.greenDeep : SonarTheme.danger)
                )
        }
    }

    // MARK: .rs-row

    private func walletRow(_ status: SNPaymentStatus) -> some View {
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(rowTileFill(status.phase))
                .frame(width: 36, height: 36)
                .overlay(
                    SNIcon(
                        name: status.phase.isGood ? .check : status.phase.isBad ? .x : .bolt,
                        size: 17, weight: 2.3
                    )
                    .foregroundColor(rowTileTint(status.phase))
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: status.payeeName)
                    .font(SonarTheme.uiFont(size: 14.5, weight: .bold))
                    .foregroundColor(SonarTheme.text)
                    .lineLimit(1)
                Text(verbatim: SNPayStatusCopy.walletRow(
                    status.phase, elapsedSeconds: status.elapsedSeconds
                ))
                .font(SonarTheme.uiFont(size: 12))
                .foregroundColor(SonarTheme.text2)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: status.phase.isBad
                 ? "\u{2014}"
                 : "\u{2212}\(SNPayStatusCopy.amount(status.sats))")
                .font(SonarTheme.uiFont(size: 14, weight: .bold))
                .foregroundColor(status.phase.isGood
                                 ? SonarTheme.text
                                 : status.phase.isBad ? SonarTheme.text3 : SonarTheme.text2)
        }
        .padding(EdgeInsets(top: 11, leading: 12, bottom: 11, trailing: 12))
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(SonarTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(SonarTheme.hairline, lineWidth: 1)
                )
        )
        .padding(.horizontal, 18)
    }

    // MARK: .money

    private func moneyLine(_ status: SNPaymentStatus) -> some View {
        let money = SNPayStatusCopy.money(status.phase, sats: status.sats)
        return HStack(alignment: .top, spacing: 9) {
            SNIcon(name: moneyIcon(money.tone), size: 16, weight: 2.1)
                .foregroundColor(moneyTint(money.tone))
            Text(verbatim: money.text)
                .font(SonarTheme.uiFont(size: 13.5))
                .lineSpacing(13.5 * 0.45)
                .foregroundColor(moneyTint(money.tone))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(EdgeInsets(top: 13, leading: 14, bottom: 13, trailing: 14))
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(moneyFill(money.tone))
        )
    }

    // MARK: Actions

    private func perform(_ action: SNPayAction, on status: SNPaymentStatus) {
        switch action.effect {
        case .dismiss:
            if status.phase == .resolving {
                store.cancelDestinationPayment(status.id)
            }
            store.pop()
        case .copyProof:
            guard let preimage = status.preimage else { return }
            #if os(iOS)
            UIPasteboard.general.string = preimage
            #else
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(preimage, forType: .string)
            #endif
            store.showToast("Proof copied")
        case .retry:
            guard let newId = store.retryDestinationPayment(status.id) else {
                store.showToast("Can't retry — reopen the payment from Send payment.")
                return
            }
            retriedId = newId
        }
    }

    // MARK: Palette

    private func barColor(_ phase: SNPayPhase) -> Color {
        if phase.isGood { return SonarTheme.green }
        if phase.isBad { return SonarTheme.danger }
        return SonarTheme.accent
    }

    private func actionLabelColor(_ kind: SNPayAction.Kind) -> Color {
        switch kind {
        case .primary: return SonarTheme.onAccent
        case .dim: return SonarTheme.text2
        case .plain: return SonarTheme.text
        }
    }

    private func rowTileFill(_ phase: SNPayPhase) -> Color {
        if phase.isGood { return SonarTheme.greenSoft }
        if phase.isBad { return SonarTheme.danger.opacity(0.14) }
        if phase.isWarn { return SonarTheme.goldSoft }
        return SonarTheme.accentSoft
    }

    private func rowTileTint(_ phase: SNPayPhase) -> Color {
        if phase.isGood { return SonarTheme.greenDeep }
        if phase.isBad { return SonarTheme.danger }
        if phase.isWarn { return SonarTheme.goldDeep }
        return SonarTheme.accentDeep
    }

    private func moneyIcon(_ tone: SNPayMoneyTone) -> SNIconName {
        switch tone {
        case .good: return .check
        case .warn: return .shield
        case .flight: return .bolt
        case .safe: return .lock
        }
    }

    private func moneyFill(_ tone: SNPayMoneyTone) -> Color {
        switch tone {
        case .safe: return SonarTheme.surface2
        case .flight: return SonarTheme.netSoft
        case .good: return SonarTheme.greenSoft
        case .warn: return SonarTheme.goldSoft
        }
    }

    private func moneyTint(_ tone: SNPayMoneyTone) -> Color {
        switch tone {
        case .safe: return SonarTheme.text2
        case .flight: return SonarTheme.netDeep
        case .good: return SonarTheme.greenDeep
        case .warn: return SonarTheme.goldDeep
        }
    }
}

// MARK: - Home strip (design: paystatus.jsx H1 `.hp-strip`)

/// The tinted card pinned at the top of the home list while an external
/// payment is in flight. It has no chat thread to live in, so this is its only
/// place in the list — and it clears itself the moment the payment settles or
/// fails, rather than becoming permanent history.
struct SNHomePaymentStrip: View {
    @EnvironmentObject private var store: SonarAppStore
    /// Observed so the strip flips to the "taking longer than usual" copy
    /// without waiting for some other store change to invalidate the home list.
    @EnvironmentObject private var clock: SNPaymentClock

    var body: some View {
        let _ = clock.tick
        if let status = store.livePaymentStatus {
            let copy = SNPayStatusCopy.homeStrip(
                status.phase, payee: status.payeeName, sats: status.sats
            )
            Button {
                store.push(.paymentStatus(status.id))
            } label: {
                HStack(spacing: 11) {
                    miniRing(status.phase)
                        .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: copy.title)
                            .font(SonarTheme.uiFont(size: 14.5, weight: .bold))
                            .foregroundColor(SonarTheme.text)
                            .lineLimit(1)
                        Text(verbatim: copy.sub)
                            .font(SonarTheme.uiFont(size: 12.5))
                            .foregroundColor(SonarTheme.text2)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    SNIcon(name: .chevron, size: 14, weight: 2.2)
                        .foregroundColor(SonarTheme.text3)
                }
                .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(status.phase.isWarn ? SonarTheme.goldSoft : SonarTheme.accentSoft)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(
                                    (status.phase.isWarn ? SonarTheme.goldFill : SonarTheme.accent)
                                        .opacity(0.28),
                                    lineWidth: 1
                                )
                        )
                )
                .padding(EdgeInsets(top: 2, leading: 14, bottom: 8, trailing: 14))
            }
            .buttonStyle(SNScaleStyle(scale: 0.99))
        }
    }

    /// paystatus.jsx `MiniRing`. Only live phases reach the strip, so this is
    /// always the sweeping arc.
    private func miniRing(_ phase: SNPayPhase) -> some View {
        Circle()
            .stroke(SonarTheme.surface2, lineWidth: 3.5)
            .overlay(
                Circle()
                    .trim(from: 0, to: 0.32)
                    .stroke(
                        phase.isWarn ? SonarTheme.goldFill : SonarTheme.accent,
                        style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
                    )
                    .modifier(SNSpinForever())
            )
            .padding(2)
    }
}

/// Continuous rotation that starts as soon as the view exists.
private struct SNSpinForever: ViewModifier {
    @State private var on = false

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(on ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: on)
            .onAppear { on = true }
    }
}
