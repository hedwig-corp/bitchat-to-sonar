//
// SonarLinkedDevicesSheet.swift
// bitchat
//
// Settings → Linked devices: add another device of THIS account as a second
// MLS leaf in every admin chat (Approach B device linking). The NEW device
// shows a link code (a fresh KeyPackage `d`-tag prefix, QR + text); the OLD
// device enters that code and runs the link pass. History does not move —
// the new device sees messages from the moment it is linked (tracked gap).
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct SNLinkedDevicesSheetContent: View {
    @EnvironmentObject private var store: SonarAppStore

    /// NEW-device side: the freshly published link code, once generated.
    @State private var linkCode: String?
    @State private var generatingCode = false

    /// OLD-device side: code entry + link pass state.
    @State private var enteredCode = ""
    @State private var linking = false
    @State private var report: MarmotService.DeviceLinkReport?
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            showCodeCard
            linkDeviceCard
            if let report {
                reportCard(report)
            }
            Text("Linking adds your other device to every chat where you are an admin. New messages appear on both devices; older history stays on this one.")
                .font(SonarTheme.uiFont(size: 13))
                .lineSpacing(13 * 0.5)
                .foregroundColor(SonarTheme.text3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(EdgeInsets(top: 12, leading: 18, bottom: 4, trailing: 18))
        }
    }

    // MARK: - New device: show a link code

    private var showCodeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This device")
                .font(SonarTheme.uiFont(size: 13, weight: .bold))
                .foregroundColor(SonarTheme.text2)
            if let linkCode {
                VStack(spacing: 10) {
                    QRCodeImage(data: linkCode, size: 148)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white))
                    Text(verbatim: Self.grouped(code: linkCode))
                        .font(SonarTheme.monoFont(size: 20))
                        .foregroundColor(SonarTheme.text)
                        .textSelection(.enabled)
                    Text("On your other device: Settings → Linked devices → enter this code, then keep this device online.")
                        .font(SonarTheme.uiFont(size: 12))
                        .foregroundColor(SonarTheme.text3)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            } else {
                Button(action: generateCode) {
                    HStack(spacing: 7) {
                        SNIcon(name: .link, size: 17, weight: 2.2)
                        Text(verbatim: generatingCode ? "Publishing\u{2026}" : "Show link code")
                            .font(SonarTheme.uiFont(size: 14.5, weight: .bold))
                    }
                    .foregroundColor(SonarTheme.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(SonarTheme.accentFill))
                }
                .buttonStyle(SNScaleStyle(scale: 0.97))
                .disabled(generatingCode)
                Text("Use this on the device you are ADDING (your new phone). It publishes a fresh key so your other device can link it.")
                    .font(SonarTheme.uiFont(size: 12))
                    .foregroundColor(SonarTheme.text3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 13, leading: 15, bottom: 13, trailing: 15))
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SonarTheme.surface2))
        .padding(EdgeInsets(top: 2, leading: 8, bottom: 12, trailing: 8))
    }

    // MARK: - Old device: enter a code and link

    private var linkDeviceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Link a new device")
                .font(SonarTheme.uiFont(size: 13, weight: .bold))
                .foregroundColor(SonarTheme.text2)
            TextField("Link code from the new device", text: $enteredCode)
                .font(SonarTheme.monoFont(size: 15))
                .foregroundColor(SonarTheme.text)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.asciiCapable)
                #endif
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(SonarTheme.surface))
            Button(action: runLink) {
                HStack(spacing: 7) {
                    SNIcon(name: .check, size: 17, weight: 2.2)
                    Text(verbatim: linking ? "Linking\u{2026}" : "Link device")
                        .font(SonarTheme.uiFont(size: 14.5, weight: .bold))
                }
                .foregroundColor(SonarTheme.onAccent)
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(SonarTheme.accentFill))
            }
            .buttonStyle(SNScaleStyle(scale: 0.97))
            .disabled(linking || !Self.isPlausible(code: enteredCode))
            if let errorText {
                Text(verbatim: errorText)
                    .font(SonarTheme.uiFont(size: 12))
                    .foregroundColor(SonarTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 13, leading: 15, bottom: 13, trailing: 15))
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SonarTheme.surface2))
        .padding(EdgeInsets(top: 0, leading: 8, bottom: 12, trailing: 8))
    }

    private func reportCard(_ report: MarmotService.DeviceLinkReport) -> some View {
        let linked = report.outcomes.filter { $0.status == "linked" }.count
        let already = report.outcomes.filter { $0.status == "already_linked" }.count
        let skipped = report.outcomes.filter { $0.status == "skipped_not_admin" }
        let failed = report.outcomes.filter { $0.status == "failed" }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Result")
                .font(SonarTheme.uiFont(size: 13, weight: .bold))
                .foregroundColor(SonarTheme.text2)
            Text(verbatim: "\(linked) chat\(linked == 1 ? "" : "s") linked"
                 + (already > 0 ? " · \(already) already linked" : ""))
                .font(SonarTheme.uiFont(size: 13))
                .foregroundColor(SonarTheme.text)
            ForEach(skipped, id: \.groupIdHex) { outcome in
                Text(verbatim: "Skipped \(outcome.groupName.isEmpty ? "unnamed chat" : outcome.groupName) — you are not an admin there")
                    .font(SonarTheme.uiFont(size: 12))
                    .foregroundColor(SonarTheme.text3)
            }
            ForEach(failed, id: \.groupIdHex) { outcome in
                Text(verbatim: "Failed \(outcome.groupName.isEmpty ? "unnamed chat" : outcome.groupName): \(outcome.error ?? "unknown error")")
                    .font(SonarTheme.uiFont(size: 12))
                    .foregroundColor(SonarTheme.danger)
            }
            if !failed.isEmpty {
                Text("Run the link again to retry. If a chat keeps failing, generate a fresh code on the new device.")
                    .font(SonarTheme.uiFont(size: 12))
                    .foregroundColor(SonarTheme.text3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 13, leading: 15, bottom: 13, trailing: 15))
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SonarTheme.surface2))
        .padding(EdgeInsets(top: 0, leading: 8, bottom: 12, trailing: 8))
    }

    // MARK: - Actions

    private func generateCode() {
        guard !generatingCode else { return }
        generatingCode = true
        Task {
            do {
                let code = try await store.createDeviceLinkCode()
                await MainActor.run {
                    generatingCode = false
                    linkCode = code
                }
            } catch {
                await MainActor.run {
                    generatingCode = false
                    store.toast = "Could not publish a link code — check your connection"
                }
            }
        }
    }

    private func runLink() {
        guard !linking else { return }
        linking = true
        errorText = nil
        report = nil
        Task {
            do {
                let result = try await store.linkDevice(code: enteredCode)
                await MainActor.run {
                    linking = false
                    report = result
                }
            } catch {
                await MainActor.run {
                    linking = false
                    errorText = Self.message(for: error)
                }
            }
        }
    }

    private static func message(for error: Error) -> String {
        if let service = error as? MarmotService.ServiceError {
            switch service {
            case .notConnected:
                return "Not connected to relays yet — try again in a moment"
            case .cancelled:
                return "Cancelled — try again"
            case .invalidInput(let message), .core(let message):
                return message
            }
        }
        return error.localizedDescription
    }

    /// Client-side plausibility only (length + hex); the core re-validates.
    /// Whitespace is ignored — the code is displayed in spaced groups and
    /// users copy or retype it that way.
    private static func isPlausible(code: String) -> Bool {
        let cleaned = code.filter { !$0.isWhitespace }
        return cleaned.count >= 8 && cleaned.allSatisfy(\.isHexDigit)
    }

    /// `abcd efgh ijkl` grouping for readability.
    private static func grouped(code: String) -> String {
        stride(from: 0, to: code.count, by: 4).map { start in
            let lower = code.index(code.startIndex, offsetBy: start)
            let upper = code.index(lower, offsetBy: 4, limitedBy: code.endIndex) ?? code.endIndex
            return String(code[lower..<upper])
        }
        .joined(separator: " ")
    }
}
