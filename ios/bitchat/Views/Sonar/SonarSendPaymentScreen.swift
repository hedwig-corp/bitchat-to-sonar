//
// SonarSendPaymentScreen.swift
// bitchat
//
// Send payment — the standalone recipient picker reached from the new-chat
// sheet ("Start a chat → Send a payment"). 1:1 with the design's
// `SendPaymentScreen` in `design/handoff/project/sonar/pay.jsx`: balance line,
// a destination field, an external "Pay …" row that appears once the input
// looks like an address/offer/invoice, and the "People you can pay" list of
// contacts who publish a payment address.
//
// The "Scan a QR code" row is camera-backed, reusing the AVCaptureMetadataOutput
// pipeline that already powers safety-number verification (`CameraScannerView`).
// The Compose app has the matching row on Android via CameraX + zxing; desktop
// has no camera pipeline and hides the row there.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct SonarSendPaymentScreen: View {
    @EnvironmentObject private var store: SonarAppStore

    @State private var query = ""
    /// Chosen recipient: a contact (pay through their chat) or a raw destination.
    @State private var contactTarget: SNPayableContact?
    @State private var externalTarget: String?
    /// Amount carried by a scanned invoice, if it fixes one.
    @State private var fixedSats: Int64?
    @State private var scanning = false

    /// Snapshot of the payable contacts, taken when the screen appears.
    ///
    /// `store.payableContacts` walks `dmRows`, which is a full scan of every
    /// private chat, mutual favourite and npub fold. As a computed property it
    /// re-ran on every SwiftUI `body` evaluation — and this view read it twice
    /// per body, so a single keystroke in the field cost two complete chat
    /// scans. That is what made the list feel slow and jumpy.
    ///
    /// The list only changes when peers or chats do, not while someone types,
    /// so it is snapshotted once per appearance and the search filters the
    /// snapshot.
    @State private var contacts: [SNPayableContact] = []

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var listed: [SNPayableContact] {
        trimmed.isEmpty
            ? contacts
            : contacts.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        VStack(spacing: 0) {
            SNNavHeader(hairline: false, onBack: { store.pop() }) {
                SNHeaderName("Send payment")
            }

            ScrollView {
                VStack(spacing: 0) {
                    HStack(spacing: 7) {
                        SNIcon(name: .coin, size: 14, weight: 2)
                            .foregroundColor(SonarTheme.text3)
                        Text(verbatim: "Your balance · \(store.money(store.balanceSats ?? 0))")
                            .font(SonarTheme.uiFont(size: 13))
                            .foregroundColor(SonarTheme.text2)
                        Spacer(minLength: 0)
                    }
                    .padding(EdgeInsets(top: 4, leading: 18, bottom: 10, trailing: 18))

                    // ── Destination field ──
                    HStack(spacing: 9) {
                        SNIcon(name: .search, size: 17, weight: 2)
                            .foregroundColor(SonarTheme.text3)
                        TextField(
                            "",
                            text: $query,
                            prompt: Text(verbatim: "Name, @username, name@domain or Bolt12\u{2026}")
                                .foregroundColor(SonarTheme.text3)
                        )
                        .textFieldStyle(.plain)
                        .font(SonarTheme.uiFont(size: 15))
                        .foregroundColor(SonarTheme.text)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    }
                    .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                    .background(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(SonarTheme.surface2)
                    )
                    .padding(.horizontal, 14)

                    // ── .sp-scan: scan a QR code ──
                    Button {
                        scanning = true
                    } label: {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(SonarTheme.accentFill)
                                .frame(width: 38, height: 38)
                                .overlay(
                                    SNIcon(name: .qr, size: 20)
                                        .foregroundColor(SonarTheme.onAccent)
                                )
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Scan a QR code")
                                    .font(SonarTheme.uiFont(size: 15, weight: .bold))
                                    .foregroundColor(SonarTheme.text)
                                Text("Bitcoin, Lightning invoice or Bolt12 offer")
                                    .font(SonarTheme.uiFont(size: 12.5))
                                    .foregroundColor(SonarTheme.accentDeep)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            SNIcon(name: .chevron, size: 15, weight: 2.2)
                                .foregroundColor(SonarTheme.text3)
                        }
                        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(SonarTheme.accentSoft)
                        )
                        .padding(EdgeInsets(top: 8, leading: 14, bottom: 0, trailing: 14))
                    }
                    .buttonStyle(SNScaleStyle(scale: 0.99))

                    // ── External destination ──
                    if let external = SNExternalDestination(input: trimmed) {
                        Button {
                            externalTarget = external.destination
                            fixedSats = external.fixedSats
                        } label: {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(SonarTheme.netFill)
                                    .frame(width: 38, height: 38)
                                    .overlay(
                                        SNIcon(name: external.icon, size: 19)
                                            .foregroundColor(SonarTheme.onNet)
                                    )
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: "Pay \u{201c}\(trimmed)\u{201d}")
                                        .font(SonarTheme.uiFont(size: 15, weight: .bold))
                                        .foregroundColor(SonarTheme.text)
                                        .lineLimit(1)
                                    Text(verbatim: external.subtitle)
                                        .font(SonarTheme.uiFont(size: 12.5))
                                        .foregroundColor(SonarTheme.netDeep)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                SNIcon(name: .chevron, size: 15, weight: 2.2)
                                    .foregroundColor(SonarTheme.text3)
                            }
                            .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(SonarTheme.netSoft)
                            )
                            .padding(EdgeInsets(top: 8, leading: 14, bottom: 0, trailing: 14))
                        }
                        .buttonStyle(SNScaleStyle(scale: 0.99))
                    }

                    // ── People you can pay ──
                    SNSectionLabel("People you can pay")

                    if listed.isEmpty {
                        // .wallet-empty, verbatim from the design — a quiet
                        // line, not a full empty state with an icon tile.
                        Text("No matching contacts. Try a username or Bolt12 offer above.")
                            .font(SonarTheme.uiFont(size: 14))
                            .foregroundColor(SonarTheme.text3)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(EdgeInsets(top: 24, leading: 20, bottom: 24, trailing: 20))
                    } else {
                        // The design uses the shared ConvRow (`.bc-row`): 16/11
                        // padding, 16.5/650 title, a `.bc-signal` sub, a hairline
                        // from x=72 suppressed on the last row — and nothing on
                        // the right. Hand-rolling this row is what made the list
                        // look wrong; reuse the component instead.
                        // LazyVStack: a plain VStack inside a ScrollView
                        // builds every row up front and rebuilds them on each
                        // body evaluation.
                        LazyVStack(spacing: 0) {
                            ForEach(Array(listed.enumerated()), id: \.element.id) { index, contact in
                                SNConvRow(
                                    title: contact.name,
                                    divider: index < listed.count - 1,
                                    action: { contactTarget = contact },
                                    avatar: {
                                        SonarAvatar(name: contact.name, size: 44, presence: contact.nearby)
                                    },
                                    sub: {
                                        HStack(spacing: 6) {
                                            if contact.nearby {
                                                Circle()
                                                    .fill(SonarTheme.accent)
                                                    .frame(width: 8, height: 8)
                                            } else {
                                                SNIcon(name: .bolt, size: 12, weight: 2.2)
                                                    .foregroundColor(SonarTheme.net)
                                            }
                                            Text(verbatim: contact.subtitle)
                                                .font(SonarTheme.uiFont(size: 13.5))
                                                .foregroundColor(SonarTheme.text2)
                                                .lineLimit(1)
                                        }
                                    }
                                )
                            }
                        }
                    }

                    Text("Only people who publish a payment address appear here. "
                         + "Payments settle directly to their wallet — no claim step.")
                        .font(SonarTheme.uiFont(size: 12))
                        .lineSpacing(12 * 0.4)
                        .foregroundColor(SonarTheme.text3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(EdgeInsets(top: 12, leading: 24, bottom: 4, trailing: 24))

                    Color.clear.frame(height: 40)
                }
            }
        }
        .background(SonarTheme.bg.ignoresSafeArea())
        .task { contacts = store.payableContacts }
        .snSheet(
            isPresented: Binding(
                get: { contactTarget != nil },
                set: { if !$0 { contactTarget = nil } }
            ),
            title: "Send money · \(contactTarget?.name ?? "")"
        ) {
            if let contact = contactTarget {
                SNPaySheet(
                    peerName: contact.name,
                    balance: store.balanceSats ?? 0,
                    transport: contact.nearby ? .mesh : .internet,
                    money: { store.money($0) },
                    fiatText: { store.fiatText($0) },
                    onClose: { contactTarget = nil },
                    onSend: { sats in
                        // Route through the chat so the peer still gets the
                        // in-chat ⚡PAY receipt, as paying from the chat does.
                        // The screen pops immediately, so the outcome must go
                        // to the app-level toast (rendered by SonarRootView).
                        // A view-local toast here is written to a dismissed
                        // view and never appears — the payment fails silently.
                        Task {
                            if let message = await store.sendPay(contact.id, sats: sats) {
                                store.showToast(message)
                            }
                        }
                        store.pop()
                    }
                )
            }
        }
        .snSheet(
            isPresented: $scanning,
            title: "Scan to pay"
        ) {
            SonarScanQrSheet(
                onClose: { scanning = false },
                onDetect: { destination, sats in
                    scanning = false
                    fixedSats = sats
                    externalTarget = destination
                }
            )
        }
        .snSheet(
            isPresented: Binding(
                get: { externalTarget != nil },
                set: { if !$0 { externalTarget = nil; fixedSats = nil } }
            ),
            title: "Send money · \(SNExternalDestination.displayName(externalTarget ?? ""))"
        ) {
            if let destination = externalTarget {
                SNPaySheet(
                    peerName: SNExternalDestination.displayName(destination),
                    balance: store.balanceSats ?? 0,
                    transport: .internet,
                    money: { store.money($0) },
                    fiatText: { store.fiatText($0) },
                    fixedSats: fixedSats,
                    onClose: { externalTarget = nil; fixedSats = nil },
                    onSend: { sats in
                        // An external payment has no chat thread to report
                        // into, so it gets its own status screen (design:
                        // paystatus.jsx Direction D). The send runs on the
                        // store, not here, so popping this picker cannot
                        // cancel it. `replaceTop` keeps Back on home: the
                        // picker's payment is already gone by then.
                        let name = SNExternalDestination.displayName(destination)
                        externalTarget = nil
                        fixedSats = nil
                        guard let activityId = store.beginDestinationPayment(
                            destination, sats: sats, displayName: name
                        ) else {
                            // Refused before anything was sent; the store
                            // toasted why, so stay on the picker to fix it.
                            return
                        }
                        store.replaceTop(.paymentStatus(activityId))
                    }
                )
            }
        }
    }

}

/// How an external destination is labelled in the "Pay …" row.
///
/// Anything the wallet can resolve counts: a BOLT12 offer (`lno1…`), a BOLT11
/// invoice (`lnbc…`/`lntb…`), or a Lightning address (`name@domain`). The
/// initializer returns nil while the input is still just a contact-name search,
/// which keeps the row from flickering in on every keystroke.
struct SNExternalDestination {
    let icon: SNIconName
    let subtitle: String
    /// What to hand the wallet — for a BIP-21 URI this is the extracted rail.
    let destination: String
    /// Amount the payload fixes, if any.
    let fixedSats: Int64?

    init?(input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let v = trimmed.lowercased()
        // A pasted BIP-21 / lightning URI resolves exactly like a scanned one,
        // so the offer inside `?lno=` is paid rather than the URI itself.
        if v.hasPrefix("bitcoin:") || v.hasPrefix("lightning:") {
            let kind = SNScannedKind(trimmed)
            guard !kind.destination.isEmpty else { return nil }
            self.icon = kind.icon
            self.subtitle = kind.sub
            self.destination = kind.destination
            self.fixedSats = kind.fixedSats
        } else if v.hasPrefix("lno1") {
            self.icon = .bolt
            self.subtitle = "Bolt12 offer · over Lightning"
            self.destination = v
            self.fixedSats = nil
        } else if v.hasPrefix("lnbc") || v.hasPrefix("lntb") || v.hasPrefix("lnbcrt") {
            self.icon = .bolt
            self.subtitle = "Lightning invoice"
            self.destination = v
            self.fixedSats = SNScannedKind.bolt11AmountSats(v)
        } else if Self.looksLikeLightningAddress(v) {
            self.icon = .globe
            self.subtitle = "Resolve address · over the internet"
            self.destination = trimmed
            self.fixedSats = nil
        } else {
            return nil
        }
    }

    /// A Lightning address needs a user and a dotted host: "a@b.c".
    private static func looksLikeLightningAddress(_ v: String) -> Bool {
        let parts = v.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let host = parts[1]
        return host.contains(".") && !host.hasPrefix(".") && !host.hasSuffix(".")
    }

    /// Short human label for a raw destination (design: `raw.split('@')[0]`).
    static func displayName(_ destination: String) -> String {
        let v = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        if let at = v.firstIndex(of: "@") { return String(v[v.startIndex..<at]) }
        return v.count > 14 ? String(v.prefix(12)) + "\u{2026}" : v
    }
}
