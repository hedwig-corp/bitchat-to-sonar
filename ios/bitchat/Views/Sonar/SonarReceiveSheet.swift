//
// SonarReceiveSheet.swift
// bitchat
//
// Receive sheet for the primary (Cashu) wallet, opened from the Wallet
// screen's Receive button. Default view: the wallet's reusable receive offer
// as a QR (the same white plate as the Profile key QR), the value in mono,
// and the Copy / Share pair. "Request an amount" creates a one-time BOLT11
// invoice — what most outside wallets can pay — and swaps the QR to it.
// Mirrors the Compose Multiplatform receive sheet.
//
// Performance: nothing here blocks first paint. The offer is the locally
// cached one; the invoice call runs on the wallet's own queue (never the main
// thread) and the sheet stays interactive while it runs.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Copy decisions for the Receive sheet, kept out of the view so tests can
/// pin them.
enum SNReceiveSheetCopy {
    /// Caption under the QR: the reusable address, or the one-time invoice.
    static func caption(invoiceSats: Int64?, money: (Int64) -> String) -> String {
        guard let sats = invoiceSats else {
            return String(localized: "Anyone can pay this address — any amount, as often as they like.")
        }
        let amount = money(sats)
        return String(localized: "One-time invoice for \(amount). It can be paid once.")
    }

    /// "Received X" for a settled INCOMING wallet payment; nil for anything
    /// else (outgoing sends, a receive still pending, a failure).
    static func receivedLine(_ update: SonarWalletPayment, money: (Int64) -> String) -> String? {
        guard update.isIncoming, update.status == .complete, update.amountSats > 0 else { return nil }
        let amount = money(update.amountSats)
        return String(localized: "Received \(amount)")
    }

    /// The message for a refused invoice: the wallet's shared copy where it
    /// fits a receive, else "Couldn't create the invoice". Never the send
    /// side's "you were not charged" / "Nothing was sent", which read wrong
    /// here. Mirrors Compose `receiveInvoiceErrorMessage`.
    static func invoiceError(_ error: Error) -> String {
        switch CashuWalletError(error) {
        case .notOpen:
            return String(localized: "Your wallet is still starting. Try again in a moment.")
        case .mintOffline:
            return String(localized: "Mint offline — retrying")
        case .busy:
            return String(localized: "Your wallet is busy. Try again in a moment.")
        case .unsupported:
            return String(localized: "This kind of payment isn't supported yet.")
        default:
            return String(localized: "Couldn't create the invoice. Try again.")
        }
    }

    /// Whether `update` is the payment of the one-time invoice on show (by
    /// id, never by amount: a same-sized payment to the reusable address is
    /// not this invoice). Once paid, the sheet stops offering it.
    static func paysShownInvoice(_ update: SonarWalletPayment, paymentId: String?) -> Bool {
        guard let paymentId, update.isIncoming, update.status == .complete else { return false }
        return update.id == paymentId
    }

    /// Digits only, no leading zeros, at most 9 digits (< 10 BTC).
    static func sanitizedAmount(_ raw: String) -> String {
        var digits = String(raw.filter(\.isASCII).filter(\.isNumber).prefix(9))
        while digits.count > 1 && digits.hasPrefix("0") { digits.removeFirst() }
        return digits == "0" ? "" : digits
    }
}

/// A one-time invoice on show, with the amount it asks for.
private struct SNReceiveInvoice: Equatable {
    let value: String
    let sats: Int64
    /// The id its payment arrives under; nil when the wallet cannot say.
    let paymentId: String?
}

struct SNReceiveSheetContent: View {
    @EnvironmentObject private var store: SonarAppStore

    @State private var offer: String?
    @State private var invoice: SNReceiveInvoice?
    @State private var amountText = ""
    @State private var creating = false
    @State private var errorText: String?
    @State private var copied = false
    @State private var receivedLine: String?
    /// Bumped by "back to address" so a late invoice result is dropped.
    @State private var requestToken = 0
    @FocusState private var amountFocused: Bool

    private var currentOffer: String? { offer ?? store.wallet.cachedReceiveOffer }
    private var shown: String? { invoice?.value ?? currentOffer }
    private var connected: Bool { store.wallet.connectivity == .online }
    private var requestedSats: Int64? {
        guard let sats = Int64(amountText), sats > 0 else { return nil }
        return sats
    }
    private var canCreate: Bool { connected && !creating && requestedSats != nil }

    var body: some View {
        VStack(spacing: 0) {
            if let value = shown {
                codeBlock(value)
            } else {
                Text("Your wallet is still connecting to the mint.")
                    .font(SonarTheme.uiFont(size: 13.5))
                    .lineSpacing(13.5 * 0.3)
                    .foregroundColor(SonarTheme.text2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(EdgeInsets(top: 18, leading: 14, bottom: 14, trailing: 14))
            }

            if let receivedLine {
                HStack(spacing: 6) {
                    SNIcon(name: .check, size: 14, weight: 2.4)
                    Text(verbatim: receivedLine)
                        .font(SonarTheme.uiFont(size: 13.5, weight: .bold))
                }
                .foregroundColor(SonarTheme.greenDeep)
                .padding(.top, 10)
                .transition(.opacity)
            }

            requestSection
        }
        .animation(.easeOut(duration: 0.18), value: amountFocused)
        .animation(.easeOut(duration: 0.18), value: invoice)
        .task {
            // No offer on this device yet: ask for it once (it answers from
            // disk, or after the connect the service is already running).
            if currentOffer == nil {
                _ = try? await store.wallet.createOffer()
            }
        }
        .task {
            // Follow the offer while the sheet is open (it appears once the
            // wallet connects). A task, not `onReceive`: the publisher is a
            // computed property and would be resubscribed on every render.
            for await next in store.wallet.receiveOfferPublisher.values {
                offer = next
            }
        }
        .task {
            for await update in store.wallet.paymentUpdates() {
                guard let line = SNReceiveSheetCopy.receivedLine(update, money: { store.money($0) }) else { continue }
                withAnimation(.easeOut(duration: 0.18)) {
                    receivedLine = line
                    // A paid one-time invoice cannot be paid again: stop
                    // showing it and go back to the reusable address.
                    // (Only the shown invoice: an invoice still being
                    // created must not be dropped.)
                    if SNReceiveSheetCopy.paysShownInvoice(update, paymentId: invoice?.paymentId) {
                        invoice = nil
                        copied = false
                    }
                }
            }
        }
    }

    // MARK: QR + value + Copy / Share

    @ViewBuilder
    private func codeBlock(_ value: String) -> some View {
        // While the amount is being typed the keyboard needs the room; the
        // QR comes back (showing the new invoice) once typing ends.
        if !amountFocused {
            SNShareCode(seed: value, size: 184)
                .accessibilityLabel(SNReceiveSheetCopy.caption(invoiceSats: invoice?.sats, money: { store.money($0) }))
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.white)
                        .shadow(color: Color(sonarHex: 0x081E28, opacity: 0.12), radius: 5, y: 2)
                )
                .padding(.top, 6)
                .transition(.opacity)
        }

        Text(verbatim: value)
            .font(SonarTheme.monoFont(size: 12.5))
            .tracking(0.25)
            .foregroundColor(SonarTheme.text2)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity)
            .padding(EdgeInsets(top: 11, leading: 14, bottom: 11, trailing: 14))
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SonarTheme.surface2))
            .contentShape(Rectangle())
            // A number pad has no return key. Only non-input rows dismiss it:
            // a tap gesture on an ancestor of the field can swallow its focus.
            .onTapGesture { amountFocused = false }
            .padding(EdgeInsets(top: 12, leading: 6, bottom: 0, trailing: 6))

        HStack(spacing: 10) {
            Button { copy(value) } label: {
                SNPairButtonLabel(
                    icon: copied ? .check : .copy,
                    iconWeight: 2.2,
                    text: copied ? String(localized: "Copied") : String(localized: "Copy"),
                    fg: SonarTheme.onAccent,
                    bg: copied ? SonarTheme.green : SonarTheme.accentFill
                )
            }
            .buttonStyle(SNScaleStyle(scale: 0.97))

            ShareLink(item: value) {
                SNPairButtonLabel.neutral(icon: .share, text: String(localized: "Share"))
            }
            .buttonStyle(SNScaleStyle(scale: 0.97))
        }
        .padding(EdgeInsets(top: 10, leading: 6, bottom: 0, trailing: 6))

        if !amountFocused {
            Text(verbatim: SNReceiveSheetCopy.caption(invoiceSats: invoice?.sats, money: { store.money($0) }))
                .font(SonarTheme.uiFont(size: 12.5))
                .lineSpacing(12.5 * 0.45)
                .foregroundColor(SonarTheme.text2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
                .padding(.top, 12)
                .transition(.opacity)
        }
    }

    // MARK: Request an amount

    private var requestSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(verbatim: String(localized: "Request an amount").uppercased())
                    .font(SonarTheme.uiFont(size: 12.5, weight: .bold))
                    .kerning(12.5 * 0.06)
                    .foregroundColor(SonarTheme.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { amountFocused = false }
                if invoice != nil {
                    // Back to the reusable address.
                    Button(action: backToAddress) {
                        HStack(spacing: 4) {
                            SNIcon(name: .back, size: 12, weight: 2.4)
                            Text(verbatim: String(localized: "Payment address"))
                                .font(SonarTheme.uiFont(size: 12.5, weight: .bold))
                        }
                        .foregroundColor(SonarTheme.accentDeep)
                        .padding(EdgeInsets(top: 5, leading: 9, bottom: 5, trailing: 11))
                        .background(Capsule().fill(SonarTheme.accentSoft))
                    }
                    .buttonStyle(SNScaleStyle(scale: 0.96))
                }
            }
            .padding(EdgeInsets(top: 18, leading: 8, bottom: 8, trailing: 6))

            HStack(spacing: 8) {
                TextField(
                    "",
                    text: $amountText,
                    prompt: Text("Amount in sats").foregroundColor(SonarTheme.text3)
                )
                .textFieldStyle(.plain)
                .font(SonarTheme.uiFont(size: 15))
                .foregroundColor(SonarTheme.text)
                .focused($amountFocused)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .onChange(of: amountText) { raw in
                    let clean = SNReceiveSheetCopy.sanitizedAmount(raw)
                    if clean != raw { amountText = clean }
                    errorText = nil
                }
                .onSubmit(createInvoice)
                .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(SonarTheme.surface2))

                Button(action: createInvoice) {
                    ZStack {
                        Text("Create invoice")
                            .font(SonarTheme.uiFont(size: 14, weight: .bold))
                            .opacity(creating ? 0 : 1)
                        if creating {
                            ProgressView().tint(SonarTheme.onAccent)
                        }
                    }
                    .foregroundColor(canCreate || creating ? SonarTheme.onAccent : SonarTheme.onDisabled)
                    .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                    .background(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(canCreate || creating ? SonarTheme.accentFill : SonarTheme.disabledFill)
                    )
                }
                .buttonStyle(SNScaleStyle(scale: 0.97))
                .disabled(!canCreate)
            }
            .padding(.horizontal, 6)

            if let errorText {
                Text(verbatim: errorText)
                    .font(SonarTheme.uiFont(size: 12.5))
                    .foregroundColor(SonarTheme.danger)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(EdgeInsets(top: 8, leading: 10, bottom: 0, trailing: 10))
            }
        }
    }

    // MARK: Actions

    private func createInvoice() {
        guard canCreate, let sats = requestedSats else { return }
        amountFocused = false
        creating = true
        errorText = nil
        requestToken &+= 1
        let token = requestToken
        Task {
            do {
                let issued = try await store.receiveInvoice(sats: sats)
                guard token == requestToken else { return }
                copied = false
                invoice = SNReceiveInvoice(value: issued.invoice, sats: sats, paymentId: issued.paymentId)
            } catch {
                guard token == requestToken else { return }
                errorText = SNReceiveSheetCopy.invoiceError(error)
            }
            creating = false
        }
    }

    private func backToAddress() {
        requestToken &+= 1
        creating = false
        copied = false
        invoice = nil
        errorText = nil
    }

    private func copy(_ value: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = value
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #endif
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) {
            withAnimation(.easeOut(duration: 0.15)) { copied = false }
        }
    }
}
