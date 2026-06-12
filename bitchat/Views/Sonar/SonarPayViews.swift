//
// SonarPayViews.swift
// bitchat
//
// Bitcoin payments UI, ported 1:1 from design/handoff/project/sonar/pay.jsx
// + the .pay-* styles in theme.css: the sealed-coin PayBubble (money as a
// message) and the PaySheet amount keypad with transport-aware send.
// Backed by the real SonarPayLedger + SonarWalletProviding — fiat lines
// only render when the wallet has a live rate.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

// MARK: - payFmt (pay.jsx: toLocaleString('en-US'))

func snPayFmt(_ sats: Int64) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.locale = Locale(identifier: "en_US")
    return f.string(from: NSNumber(value: sats)) ?? String(sats)
}

// MARK: - Pay bubble (money as a message; incoming arrives sealed)

struct SNPayBubble: View {
    let m: SNMessage           // m.pay != nil
    let peerName: String
    /// Primary money string (fiat or sats, unit included).
    let money: (Int64) -> String
    /// Secondary detail line (the sats amount when the primary is fiat); nil
    /// when the primary is already sats.
    let fiatText: (Int64) -> String?
    let maxBubbleWidth: CGFloat
    let onClaim: ((String) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pay: SNPayInfo { m.pay! }
    private var sealed: Bool { pay.state == .sealed }
    private var viaIcon: SNIconName { m.via == .mesh ? .mesh : .bolt }

    var body: some View {
        VStack(alignment: m.mine ? .trailing : .leading, spacing: 0) {
            if m.mine {
                card(amount: true)
                stateLine(mineStateText)
            } else if sealed || pay.state == .claiming {
                Button {
                    if sealed { onClaim?(pay.id) }
                } label: {
                    card(amount: false)
                }
                .buttonStyle(SNScaleStyle(scale: 0.97))
                .disabled(!sealed || onClaim == nil)
                stateLine("Sealed for you")
            } else {
                card(amount: true)
                    .modifier(SNPayPop())
                stateLine("Added to your balance")
            }
        }
        .frame(maxWidth: maxBubbleWidth, alignment: m.mine ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: m.mine ? .trailing : .leading)
        .padding(.top, 9)
    }

    // bc-state under mine cards (sealed/claimed; "settling" is an honest
    // in-between the demo didn't have — the Lightning payment is in flight).
    private var mineStateText: String {
        switch pay.state {
        case .sealed, .claiming: return "Sealed — waiting for \(peerName) to claim"
        case .settling: return "Claim received — paying over the internet"
        case .claimed: return "Claimed by \(peerName)"
        }
    }

    // .pay-card
    private func card(amount showAmount: Bool) -> some View {
        HStack(spacing: 12) {
            coin(pulse: !m.mine && sealed)
            VStack(alignment: .leading, spacing: 1) {
                if showAmount {
                    Text(verbatim: money(pay.sats))
                        .font(SonarTheme.uiFont(size: 19, weight: .heavy))
                        .kerning(-19 * 0.01)
                    if let detail = fiatText(pay.sats) {
                        Text(verbatim: detail)
                            .font(SonarTheme.uiFont(size: 11.5, weight: .semibold))
                            .opacity(0.72)
                    }
                } else {
                    Text(verbatim: "Payment from \(peerName)")
                        .font(SonarTheme.uiFont(size: 15, weight: .bold))
                    Text(pay.state == .claiming ? "Claiming\u{2026}" : "Tap to claim")
                        .font(SonarTheme.uiFont(size: 11.5, weight: .semibold))
                        .opacity(0.72)
                }
            }
        }
        .foregroundColor(SonarTheme.onGold)
        .padding(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 16))
        .frame(minWidth: 190, alignment: .leading)
        .background(cardShape.fill(SonarTheme.goldFill))
    }

    // border-radius: var(--r) with the 0.28r tail on the bubble side
    private var cardShape: UnevenRoundedRectangle {
        let r = SonarTheme.bubbleRadius
        let tail = r * 0.28
        return UnevenRoundedRectangle(
            topLeadingRadius: r,
            bottomLeadingRadius: m.mine ? r : tail,
            bottomTrailingRadius: m.mine ? tail : r,
            topTrailingRadius: r,
            style: .continuous
        )
    }

    // .pay-coin (+ .pulse: scale 1→1.08, 2 s ease-in-out, infinite)
    private func coin(pulse: Bool) -> some View {
        let base = Circle()
            .fill(Color.black.opacity(0.16))
            .overlay(
                // inset 0 1.5px 0 white/.35 + inset 0 -1.5px 0 black/.18
                Circle().strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.35), Color.black.opacity(0.18)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1.5
                )
            )
            .frame(width: 40, height: 40)
            .overlay(
                Text(verbatim: "\u{20BF}")
                    .font(SonarTheme.uiFont(size: 20, weight: .heavy))
            )
        return Group {
            if pulse && !reduceMotion {
                TimelineView(.animation) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let phase = t.truncatingRemainder(dividingBy: 2) / 2
                    // ease-in-out 1 → 1.08 → 1
                    let s = 1 + 0.08 * 0.5 * (1 - cos(2 * .pi * phase))
                    base.scaleEffect(s)
                }
            } else {
                base
            }
        }
    }

    // .bc-state
    private func stateLine(_ text: String) -> some View {
        HStack(spacing: 3) {
            SNIcon(name: viaIcon, size: 11, weight: 2.4)
            Text(verbatim: "\(text) · \(m.time)")
                .font(SonarTheme.uiFont(size: 11))
        }
        .foregroundColor(SonarTheme.text3)
        .padding(EdgeInsets(top: 3, leading: 4, bottom: 0, trailing: 4))
    }
}

/// payPop: 0.35 s cubic-bezier(0.25, 0.9, 0.3, 1) from scale(0.85), run
/// whenever the revealed card appears (like the CSS animation on mount).
private struct SNPayPop: ViewModifier {
    @State private var revealed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(revealed || reduceMotion ? 1 : 0.85)
            .onAppear {
                withAnimation(.timingCurve(0.25, 0.9, 0.3, 1, duration: 0.35)) {
                    revealed = true
                }
            }
    }
}

// MARK: - Pay sheet (balance, big amount, quick chips, keypad, send)

private let snPayKeys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "00", "0", "del"]
private let snPayChips: [Int64] = [1000, 10000, 21000]

struct SNPaySheet: View {
    let peerName: String
    let balance: Int64
    let transport: SNVia
    /// Primary money string for the balance (fiat or sats, unit included).
    let money: (Int64) -> String
    /// Live fiat line; nil = no live rate, the € line simply doesn't render.
    let fiatText: (Int64) -> String?
    let onClose: () -> Void
    let onSend: (Int64) -> Void

    @State private var v = ""

    private var sats: Int64 { Int64(v) ?? 0 }
    private var over: Bool { sats > balance }
    private var can: Bool { sats > 0 && !over }
    private var mesh: Bool { transport == .mesh }

    private func tap(_ k: String) {
        if k == "del" {
            v = String(v.dropLast())
            return
        }
        var nv = v + k
        // (v + k).replace(/^0+(?=\d)/, '')
        while nv.count > 1 && nv.hasPrefix("0") { nv.removeFirst() }
        if nv.count <= 7 { v = nv }
    }

    private func send() {
        guard can else { return }
        onSend(sats)
        onClose()
    }

    var body: some View {
        VStack(spacing: 0) {
            // .pay-balance
            HStack(spacing: 6) {
                SNIcon(name: .coin, size: 13, weight: 2)
                Text(verbatim: "Balance · \(money(balance))")
            }
            .font(SonarTheme.uiFont(size: 12.5))
            .foregroundColor(SonarTheme.text3)
            .padding(EdgeInsets(top: 2, leading: 0, bottom: 4, trailing: 0))

            // .pay-amountbox
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(verbatim: v.isEmpty ? "0" : snPayFmt(sats))
                        .font(SonarTheme.uiFont(size: 42, weight: .heavy))
                        .kerning(-42 * 0.02)
                        .foregroundColor(over ? SonarTheme.danger : SonarTheme.text)
                    Text("sats")
                        .font(SonarTheme.uiFont(size: 15, weight: .bold))
                        .foregroundColor(SonarTheme.text3)
                }
                // .pay-fiatline (min-height 20)
                Text(verbatim: over ? "Not enough sats" : (fiatText(sats) ?? ""))
                    .font(SonarTheme.uiFont(size: 13.5))
                    .foregroundColor(SonarTheme.text3)
                    .padding(.top, 3)
                    .frame(minHeight: 20)
            }
            .padding(EdgeInsets(top: 8, leading: 0, bottom: 2, trailing: 0))

            // .pay-chips
            HStack(spacing: 8) {
                ForEach(snPayChips, id: \.self) { c in
                    Button {
                        v = String(c)
                    } label: {
                        Text(verbatim: snPayFmt(c))
                            .font(SonarTheme.uiFont(size: 13, weight: .bold))
                            .foregroundColor(SonarTheme.goldDeep)
                            .padding(.vertical, 7)
                            .padding(.horizontal, 14)
                            .background(Capsule().fill(SonarTheme.goldSoft))
                    }
                    .buttonStyle(SNScaleStyle(scale: 0.95))
                }
            }
            .padding(EdgeInsets(top: 10, leading: 0, bottom: 2, trailing: 0))

            // .pay-pad
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                ForEach(snPayKeys, id: \.self) { k in
                    Button {
                        tap(k)
                    } label: {
                        Group {
                            if k == "del" {
                                SNIcon(name: .back, size: 18, weight: 2.2)
                            } else {
                                Text(verbatim: k)
                                    .font(SonarTheme.uiFont(size: 21, weight: .semibold))
                            }
                        }
                        .foregroundColor(SonarTheme.text)
                        .frame(maxWidth: .infinity)
                        .padding(12)
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(SNRowPressStyle(cornerRadius: 12))
                    .accessibilityLabel(k == "del" ? "Delete" : k)
                }
            }
            .padding(EdgeInsets(top: 8, leading: 18, bottom: 2, trailing: 18))

            // .bc-sheetactions
            VStack(spacing: 6) {
                SNPrimaryButton(
                    label: mesh ? "Send over Bluetooth" : "Send over the internet",
                    net: !mesh,
                    disabled: !can,
                    action: send
                )
                Text(verbatim: mesh
                    ? "Travels phone-to-phone as ecash — works offline. Sealed until \(peerName) claims it."
                    : "Instant over the internet. Sealed until \(peerName) claims it.")
                    .font(SonarTheme.uiFont(size: 12))
                    .lineSpacing(12 * 0.5)
                    .foregroundColor(SonarTheme.text3)
                    .multilineTextAlignment(.center)
                    .padding(EdgeInsets(top: 2, leading: 14, bottom: 0, trailing: 14))
            }
            .padding(EdgeInsets(top: 6, leading: 8, bottom: 0, trailing: 8))
        }
    }
}

// MARK: - Wallet setup sheet (wallet not ready yet — honest, no fake money)

struct SNWalletSetupSheetContent: View {
    var settingUp: Bool = false
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(SonarTheme.goldSoft)
                .frame(width: 56, height: 56)
                .overlay(
                    SNIcon(name: .coin, size: 26)
                        .foregroundColor(SonarTheme.goldDeep)
                )
                .padding(.top, 8)
            Text(settingUp
                ? "Your wallet is being set up. Sats you receive will land here, and payments you send will settle from it — try again in a moment."
                : "Payments in Sonar need a wallet on this phone. Yours isn\u{2019}t set up yet — once it is, money you receive lands here and payments you send come from it.")
                .font(SonarTheme.uiFont(size: 13.5))
                .lineSpacing(13.5 * 0.3)
                .foregroundColor(SonarTheme.text2)
                .multilineTextAlignment(.center)
                .padding(EdgeInsets(top: 10, leading: 14, bottom: 2, trailing: 14))
            VStack(spacing: 6) {
                SNGhostButton(label: "Done", action: onClose)
            }
            .padding(EdgeInsets(top: 6, leading: 8, bottom: 0, trailing: 8))
        }
    }
}

// MARK: - Unify nearby-payments sheet (direct Lightning send, payments-only)

/// The "Send sats" sheet for a Unify Wallet user discovered over Bluetooth.
/// Unlike the ⚡PAY sealed-coin chat flow, this is a direct Lightning send to
/// the receiver's served BOLT12/BOLT11 destination. The sheet walks the phases
/// the store drives: fetching → (amount keypad | direct pay) → sent / failed.
struct UnifyPaySheetView: View {
    let peerName: String
    let phase: SonarAppStore.UnifyPayPhase
    let balance: Int64
    /// Primary money string for the balance (fiat or sats, unit included).
    let money: (Int64) -> String
    let fiatText: (Int64) -> String?
    let onConfirmAmount: (_ destination: String, _ sats: Int64) -> Void
    let onClose: () -> Void

    var body: some View {
        switch phase {
        case .fetching:
            status(icon: .bolt, tint: SonarTheme.goldDeep,
                   title: "Reading \(peerName)\u{2019}s payment\u{2026}",
                   desc: "Connecting over Bluetooth to fetch their payment request.",
                   busy: true)
        case .amount(let destination):
            UnifyAmountKeypad(
                peerName: peerName,
                balance: balance,
                money: money,
                fiatText: fiatText,
                onSend: { sats in onConfirmAmount(destination, sats) }
            )
        case .paying(_, let sats):
            status(icon: .bolt, tint: SonarTheme.goldDeep,
                   title: "Sending \(money(sats))\u{2026}",
                   desc: "Paying \(peerName) over the internet.",
                   busy: true)
        case .sent(let sats):
            status(icon: .check, tint: SonarTheme.green,
                   title: "Sent \(money(sats))",
                   desc: "\(peerName) has been paid over the internet.",
                   busy: false, done: true)
        case .failed(let message):
            status(icon: .x, tint: SonarTheme.danger,
                   title: "Couldn\u{2019}t send",
                   desc: message,
                   busy: false, done: true)
        }
    }

    private func status(icon: SNIconName, tint: Color, title: String, desc: String,
                        busy: Bool, done: Bool = false) -> some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(SonarTheme.goldSoft)
                    .frame(width: 56, height: 56)
                if busy {
                    ProgressView().tint(tint)
                } else {
                    SNIcon(name: icon, size: 26).foregroundColor(tint)
                }
            }
            .padding(.top, 8)
            Text(verbatim: title)
                .font(SonarTheme.uiFont(size: 16, weight: .bold))
                .foregroundColor(SonarTheme.text)
                .padding(.top, 10)
            Text(verbatim: desc)
                .font(SonarTheme.uiFont(size: 13.5))
                .lineSpacing(13.5 * 0.3)
                .foregroundColor(SonarTheme.text2)
                .multilineTextAlignment(.center)
                .padding(EdgeInsets(top: 6, leading: 14, bottom: 2, trailing: 14))
            if done {
                VStack(spacing: 6) { SNGhostButton(label: "Done", action: onClose) }
                    .padding(EdgeInsets(top: 12, leading: 8, bottom: 0, trailing: 8))
            }
        }
    }
}

/// Amount keypad for an amountless Unify offer (mirrors SNPaySheet's pad, but
/// always sends "over Lightning" — Unify payments are never mesh ecash).
private struct UnifyAmountKeypad: View {
    let peerName: String
    let balance: Int64
    let money: (Int64) -> String
    let fiatText: (Int64) -> String?
    let onSend: (Int64) -> Void

    @State private var v = ""

    private var sats: Int64 { Int64(v) ?? 0 }
    private var over: Bool { sats > balance }
    private var can: Bool { sats > 0 && !over }

    private func tap(_ k: String) {
        if k == "del" { v = String(v.dropLast()); return }
        var nv = v + k
        while nv.count > 1 && nv.hasPrefix("0") { nv.removeFirst() }
        if nv.count <= 7 { v = nv }
    }

    private let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "00", "0", "del"]
    private let chips: [Int64] = [1000, 10000, 21000]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                SNIcon(name: .coin, size: 13, weight: 2)
                Text(verbatim: "Balance \u{00B7} \(money(balance))")
            }
            .font(SonarTheme.uiFont(size: 12.5))
            .foregroundColor(SonarTheme.text3)
            .padding(EdgeInsets(top: 2, leading: 0, bottom: 4, trailing: 0))

            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(verbatim: v.isEmpty ? "0" : snPayFmt(sats))
                        .font(SonarTheme.uiFont(size: 42, weight: .heavy))
                        .kerning(-42 * 0.02)
                        .foregroundColor(over ? SonarTheme.danger : SonarTheme.text)
                    Text("sats")
                        .font(SonarTheme.uiFont(size: 15, weight: .bold))
                        .foregroundColor(SonarTheme.text3)
                }
                Text(verbatim: over ? "Not enough sats" : (fiatText(sats) ?? ""))
                    .font(SonarTheme.uiFont(size: 13.5))
                    .foregroundColor(SonarTheme.text3)
                    .padding(.top, 3)
                    .frame(minHeight: 20)
            }
            .padding(EdgeInsets(top: 8, leading: 0, bottom: 2, trailing: 0))

            HStack(spacing: 8) {
                ForEach(chips, id: \.self) { c in
                    Button { v = String(c) } label: {
                        Text(verbatim: snPayFmt(c))
                            .font(SonarTheme.uiFont(size: 13, weight: .bold))
                            .foregroundColor(SonarTheme.goldDeep)
                            .padding(.vertical, 7)
                            .padding(.horizontal, 14)
                            .background(Capsule().fill(SonarTheme.goldSoft))
                    }
                    .buttonStyle(SNScaleStyle(scale: 0.95))
                }
            }
            .padding(EdgeInsets(top: 10, leading: 0, bottom: 2, trailing: 0))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                ForEach(keys, id: \.self) { k in
                    Button { tap(k) } label: {
                        Group {
                            if k == "del" {
                                SNIcon(name: .back, size: 18, weight: 2.2)
                            } else {
                                Text(verbatim: k).font(SonarTheme.uiFont(size: 21, weight: .semibold))
                            }
                        }
                        .foregroundColor(SonarTheme.text)
                        .frame(maxWidth: .infinity)
                        .padding(12)
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(SNRowPressStyle(cornerRadius: 12))
                    .accessibilityLabel(k == "del" ? "Delete" : k)
                }
            }
            .padding(EdgeInsets(top: 8, leading: 18, bottom: 2, trailing: 18))

            VStack(spacing: 6) {
                SNPrimaryButton(label: "Send over the internet", net: true, disabled: !can) {
                    guard can else { return }
                    onSend(sats)
                }
                Text(verbatim: "Instant over the internet, straight to \(peerName)\u{2019}s wallet.")
                    .font(SonarTheme.uiFont(size: 12))
                    .lineSpacing(12 * 0.5)
                    .foregroundColor(SonarTheme.text3)
                    .multilineTextAlignment(.center)
                    .padding(EdgeInsets(top: 2, leading: 14, bottom: 0, trailing: 14))
            }
            .padding(EdgeInsets(top: 6, leading: 8, bottom: 0, trailing: 8))
        }
    }
}
