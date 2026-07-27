//
// SonarScanQrSheet.swift
// bitchat
//
// Scan to pay — 1:1 with the design's `ScanQrSheet`
// (design/handoff/project/sonar/pay.jsx + the `.scan-*` styles in theme.css):
// viewfinder with corner brackets and a sweeping line, then the "found" card
// with the decoded code and a Continue / Scan again pair.
//
// Where the design fakes detection with sample codes, this runs the real
// camera. iOS already had a QR pipeline for safety-number verification
// (`CameraScannerView`, AVCaptureMetadataOutput restricted to `.qr`), so this
// reuses it rather than adding a second capture stack.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct SonarScanQrSheet: View {
    let onClose: () -> Void
    /// (destination, amount the code fixes — nil when the payer chooses)
    let onDetect: (String, Int64?) -> Void

    @State private var found: String?
    @State private var sweep = false

    var body: some View {
        VStack(spacing: 0) {
            if let code = found {
                foundContent(code)
            } else {
                scanContent
            }
        }
    }

    // MARK: Viewfinder

    private var scanContent: some View {
        VStack(spacing: 14) {
            ZStack {
                // .scan-frame background gradient
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.063, green: 0.094, blue: 0.125),
                                     Color(red: 0.024, green: 0.035, blue: 0.047)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )

                #if os(iOS)
                CameraScannerView(isActive: found == nil) { code in
                    guard found == nil else { return }
                    let text = code.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    found = text
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                #endif

                corners
                sweepLine
            }
            .frame(width: 210, height: 210)

            // .scan-hint
            Text("Point at a bitcoin, Lightning or Bolt12 QR code")
                .font(SonarTheme.uiFont(size: 13))
                .foregroundColor(SonarTheme.text3)
                .multilineTextAlignment(.center)

            Button("Cancel") { onClose() }
                .buttonStyle(.plain)
                .font(SonarTheme.uiFont(size: 15, weight: .semibold))
                .foregroundColor(SonarTheme.text2)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
        }
        .padding(EdgeInsets(top: 10, leading: 16, bottom: 4, trailing: 16))
        .onAppear { sweep = true }
    }

    /// .scan-frame .c — four 34pt L-brackets inset 14pt, 3pt accent. CSS builds
    /// each by dropping two borders off a square; SwiftUI has no per-side
    /// border either, so each bracket is two bars.
    private var corners: some View {
        ZStack {
            bracket(top: true, leading: true)
            bracket(top: true, leading: false)
            bracket(top: false, leading: true)
            bracket(top: false, leading: false)
        }
        .padding(14)
    }

    private func bracket(top: Bool, leading: Bool) -> some View {
        ZStack {
            Capsule().fill(SonarTheme.accent)
                .frame(width: 34, height: 3)
                .frame(maxHeight: .infinity, alignment: top ? .top : .bottom)
            Capsule().fill(SonarTheme.accent)
                .frame(width: 3, height: 34)
                .frame(maxWidth: .infinity, alignment: leading ? .leading : .trailing)
        }
        .frame(width: 34, height: 34)
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: Alignment(horizontal: leading ? .leading : .trailing,
                                    vertical: top ? .top : .bottom))
    }

    /// .scan-line — a 2.2s ease-in-out sweep down the frame and back.
    private var sweepLine: some View {
        LinearGradient(
            colors: [.clear, SonarTheme.accent, .clear],
            startPoint: .leading, endPoint: .trailing
        )
        .frame(height: 2)
        .clipShape(Capsule())
        .padding(.horizontal, 18)
        .shadow(color: SonarTheme.accent.opacity(0.7), radius: 7)
        .offset(y: sweep ? 77 : -77)
        .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: sweep)
    }

    // MARK: Found

    private func foundContent(_ code: String) -> some View {
        let kind = SNScannedKind(code)
        return VStack(spacing: 0) {
            // .scan-found
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(SonarTheme.netSoft)
                    .frame(width: 44, height: 44)
                    .overlay(
                        SNIcon(name: kind.icon, size: 22)
                            .foregroundColor(SonarTheme.netDeep)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: kind.name)
                        .font(SonarTheme.uiFont(size: 15, weight: .bold))
                        .foregroundColor(SonarTheme.text)
                        .lineLimit(1)
                    Text(verbatim: kind.sub)
                        .font(SonarTheme.uiFont(size: 12.5))
                        .foregroundColor(SonarTheme.text2)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(EdgeInsets(top: 10, leading: 14, bottom: 6, trailing: 14))

            // .scan-code
            Text(verbatim: code)
                .font(SonarTheme.monoFont(size: 12))
                .foregroundColor(SonarTheme.text2)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 13))
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(SonarTheme.surface2)
                )
                .padding(.horizontal, 14)

            VStack(spacing: 6) {
                SNPrimaryButton(
                    label: kind.fixedSats.map { "Continue · \(sonarFormatSats($0)) sats" } ?? "Enter amount",
                    net: true,
                    action: { onDetect(code, kind.fixedSats) }
                )
                Button("Scan again") { found = nil }
                    .buttonStyle(.plain)
                    .font(SonarTheme.uiFont(size: 15, weight: .semibold))
                    .foregroundColor(SonarTheme.text2)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
            }
            .padding(EdgeInsets(top: 10, leading: 8, bottom: 0, trailing: 8))
        }
    }
}

/// What a decoded payload is, for the "found" card.
struct SNScannedKind {
    let icon: SNIconName
    let name: String
    let sub: String
    let fixedSats: Int64?

    init(_ raw: String) {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var lower = v.lowercased()
        for scheme in ["lightning:", "bitcoin:"] where lower.hasPrefix(scheme) {
            lower = String(lower.dropFirst(scheme.count))
        }
        if lower.hasPrefix("lno1") {
            icon = .bolt
            name = "Bolt12 offer"
            sub = "Reusable · over Lightning"
            fixedSats = nil
        } else if lower.hasPrefix("lnbc") || lower.hasPrefix("lntb") || lower.hasPrefix("lnbcrt") {
            let sats = SNScannedKind.bolt11AmountSats(lower)
            icon = .bolt
            name = "Lightning invoice"
            sub = sats.map { "\(sonarFormatSats($0)) sats requested" } ?? "No amount · you choose"
            fixedSats = sats
        } else if lower.contains("@") {
            icon = .globe
            name = v
            sub = "Lightning address"
            fixedSats = nil
        } else {
            icon = .coin
            name = "Bitcoin address"
            sub = "On-chain"
            fixedSats = nil
        }
    }

    /// Amount encoded in a BOLT11 human-readable part, in sats, or nil when the
    /// invoice leaves the amount open. `lnbc21u1…` → 21 micro-BTC → 2,100 sats.
    /// Multipliers per BOLT-11: m = 10⁻³, u = 10⁻⁶, n = 10⁻⁹, p = 10⁻¹² BTC.
    static func bolt11AmountSats(_ invoice: String) -> Int64? {
        let chars = Array(invoice)
        guard chars.count > 4 else { return nil }
        // The separator is the LAST "1": bech32 excludes "1" from the data
        // charset, so any earlier one belongs to the amount ("lnbc21u1…" —
        // taking the first would read 2 BTC instead of 2,100 sats).
        guard let sepOffset = chars.lastIndex(of: "1"), sepOffset > 3 else { return nil }
        let prefix = String(chars[0..<sepOffset])
        guard let digitsStart = prefix.firstIndex(where: { $0.isNumber }) else { return nil }
        var amountPart = String(prefix[digitsStart...])
        guard !amountPart.isEmpty else { return nil }
        let multiplier = amountPart.removeLast()
        let scale: Double
        switch multiplier {
        case "m": scale = 1e-3
        case "u": scale = 1e-6
        case "n": scale = 1e-9
        case "p": scale = 1e-12
        default:
            // No multiplier: the trailing character was part of the number.
            amountPart.append(multiplier)
            scale = 1.0
        }
        guard let value = Double(amountPart), value > 0 else { return nil }
        // p-denominated invoices can encode sub-satoshi amounts; round up so we
        // never underpay, and treat a zero result as "no amount".
        let sats = Int64((value * scale * 100_000_000.0).rounded(.up))
        return sats > 0 ? sats : nil
    }
}
