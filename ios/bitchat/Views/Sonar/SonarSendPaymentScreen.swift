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
    @State private var toast: String?

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var contacts: [SNPayableContact] { store.payableContacts }
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
                            prompt: Text(verbatim: "Name, name@domain or Bolt12\u{2026}")
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
                            externalTarget = trimmed
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
                        SNEmptyState(
                            icon: .coin,
                            title: contacts.isEmpty ? "Nobody to pay yet" : "No matching contacts",
                            desc: "Only people who publish a payment address show up here. "
                                + "You can still pay any Lightning address or Bolt12 offer using the field above."
                        )
                        .frame(height: 220)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(listed) { contact in
                                Button {
                                    contactTarget = contact
                                } label: {
                                    HStack(spacing: 12) {
                                        SonarAvatar(name: contact.name, size: 44, presence: contact.nearby)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(verbatim: contact.name)
                                                .font(SonarTheme.uiFont(size: 16, weight: .semibold))
                                                .foregroundColor(SonarTheme.text)
                                            Text(verbatim: contact.subtitle)
                                                .font(SonarTheme.uiFont(size: 13))
                                                .foregroundColor(SonarTheme.text2)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        SNIcon(name: .chevron, size: 15, weight: 2.2)
                                            .foregroundColor(SonarTheme.text3)
                                    }
                                    .padding(EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14))
                                }
                                .buttonStyle(SNScaleStyle(scale: 0.99))
                            }
                        }
                    }

                    Text("Payments settle straight to their wallet — there is no claim step.")
                        .font(SonarTheme.uiFont(size: 12.5))
                        .lineSpacing(12.5 * 0.3)
                        .foregroundColor(SonarTheme.text3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(EdgeInsets(top: 10, leading: 18, bottom: 0, trailing: 18))

                    Color.clear.frame(height: 40)
                }
            }
        }
        .background(SonarTheme.bg.ignoresSafeArea())
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
                        Task {
                            if let message = await store.sendPay(contact.id, sats: sats) {
                                showToast(message)
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
                        Task {
                            let name = SNExternalDestination.displayName(destination)
                            if let message = await store.payDestination(
                                destination, sats: sats, displayName: name
                            ) {
                                showToast(message)
                            }
                        }
                        store.pop()
                    }
                )
            }
        }
        .overlay(alignment: .bottom) { toastView }
        .animation(.easeOut(duration: 0.2), value: toast)
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(verbatim: toast)
                .font(SonarTheme.uiFont(size: 13.5, weight: .medium))
                .foregroundColor(SonarTheme.text)
                .multilineTextAlignment(.center)
                .padding(EdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 16))
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(SonarTheme.surface2)
                        .shadow(color: Color.black.opacity(0.18), radius: 12, y: 6)
                )
                .padding(.horizontal, 24)
                .padding(.bottom, 88)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func showToast(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            if toast == text { toast = nil }
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

    init?(input: String) {
        let v = input.lowercased()
        if v.hasPrefix("lno1") {
            self.icon = .bolt
            self.subtitle = "Bolt12 offer · over Lightning"
        } else if v.hasPrefix("lnbc") || v.hasPrefix("lntb") || v.hasPrefix("lnbcrt") {
            self.icon = .bolt
            self.subtitle = "Lightning invoice"
        } else if Self.looksLikeLightningAddress(v) {
            self.icon = .globe
            self.subtitle = "Lightning address · over the internet"
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
