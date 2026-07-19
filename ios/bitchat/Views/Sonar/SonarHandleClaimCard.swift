//
// SonarHandleClaimCard.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// Username claim flow (`name@sonarprivacy.xyz`) as a reusable card body:
/// name field with live preview, claim/save button, claimed row with the
/// registrar-claim seal. Used by Profile (iOS + macOS) and Settings modals.
///
/// The seal renders only for the registrar-claimed address
/// (`store.coreClaimedHandle`) — an external payment address from another
/// wallet is stored in the same `bip353` field but is NOT a claimed identity.
struct SonarHandleClaimCard: View {
    @ObservedObject var store: SonarAppStore
    /// When false, parent already rendered `SNSectionLabel("Username")`.
    var showTitle: Bool = true

    @State private var handleDraft = ""
    @State private var editingHandle = false

    private var claimedAddress: String? {
        if case .claimed(let address) = store.handleClaimState { return address }
        let stored = store.bip353.trimmingCharacters(in: .whitespacesAndNewlines)
        return stored.isEmpty ? nil : stored
    }

    private var claiming: Bool { store.handleClaimState == .claiming }

    private var trimmedDraft: String {
        handleDraft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var draftValid: Bool { MarmotService.handleLooksValid(trimmedDraft) }

    /// A full non-default-domain address is an external payment address —
    /// saved locally, never claimed at the registrar (matches the store path).
    private var isExternalDraft: Bool {
        trimmedDraft.contains("@")
            && !trimmedDraft.hasSuffix("@\(SonarAppStore.handleDomain)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if showTitle {
                Text("Username")
                    .font(SonarTheme.uiFont(size: 16, weight: .semibold))
                    .foregroundColor(SonarTheme.text)
            }
            if let address = claimedAddress, !editingHandle {
                claimedRow(address)
            } else {
                claimField
            }
            Text("Claim a username — friends can start a chat or pay you with it. Optional.")
                .font(SonarTheme.uiFont(size: 12))
                .foregroundColor(SonarTheme.text3)
                .lineSpacing(3)
        }
        .onChange(of: store.handleClaimState) { state in
            if case .claimed = state {
                editingHandle = false
                handleDraft = ""
            }
        }
    }

    private func claimedRow(_ address: String) -> some View {
        let isCoreClaimed = address == store.coreClaimedHandle
        return HStack(spacing: 8) {
            Image(systemName: isCoreClaimed ? "checkmark.seal.fill" : "link")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(isCoreClaimed ? SonarTheme.green : SonarTheme.text3)
            Text(verbatim: address)
                .font(SonarTheme.monoFont(size: 13))
                .foregroundColor(SonarTheme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button {
                handleDraft = String(address.split(separator: "@").first ?? "")
                editingHandle = true
            } label: {
                Text("Edit")
                    .font(SonarTheme.uiFont(size: 13, weight: .bold))
                    .foregroundColor(SonarTheme.accentDeep)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit username")
        }
        .padding(EdgeInsets(top: 10, leading: 13, bottom: 10, trailing: 13))
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(SonarTheme.surface2))
    }

    @ViewBuilder
    private var claimField: some View {
        TextField(
            "",
            text: $handleDraft,
            prompt: Text(verbatim: "yourname").foregroundColor(SonarTheme.text3)
        )
        .textFieldStyle(.plain)
        .font(SonarTheme.monoFont(size: 13))
        .foregroundColor(SonarTheme.text)
        #if os(iOS)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        #endif
        .onSubmit(claim)
        .disabled(claiming)
        .padding(EdgeInsets(top: 10, leading: 13, bottom: 10, trailing: 13))
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(SonarTheme.surface2))

        if !trimmedDraft.isEmpty {
            Text(verbatim: isExternalDraft
                ? "External address — saved as your payment address only."
                : "\(trimmedDraft.components(separatedBy: "@")[0])@\(SonarAppStore.handleDomain)")
                .font(SonarTheme.monoFont(size: 12))
                .foregroundColor(SonarTheme.text2)
                .lineLimit(1)
                .truncationMode(.middle)
        }

        if case .failed(let message) = store.handleClaimState {
            Text(verbatim: message)
                .font(SonarTheme.uiFont(size: 12))
                .foregroundColor(SonarTheme.danger)
        }

        HStack(spacing: 8) {
            Button(action: claim) {
                HStack(spacing: 6) {
                    if claiming {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(claiming
                        ? "Claiming\u{2026}"
                        : (isExternalDraft ? "Save address" : "Claim"))
                        .font(SonarTheme.uiFont(size: 13.5, weight: .bold))
                }
                .foregroundColor(SonarTheme.onAccent)
                .padding(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .background(Capsule().fill(SonarTheme.accentDeep.opacity(claiming || !draftValid ? 0.5 : 1)))
            }
            .buttonStyle(.plain)
            .disabled(claiming || !draftValid)
            if editingHandle {
                Button {
                    editingHandle = false
                    handleDraft = ""
                } label: {
                    Text("Cancel")
                        .font(SonarTheme.uiFont(size: 13.5, weight: .semibold))
                        .foregroundColor(SonarTheme.text2)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func claim() {
        guard draftValid, !claiming else { return }
        store.claimHandle(trimmedDraft)
    }
}

// MARK: - Shared identity display helpers

extension SonarAppStore {
    /// Settings/profile card subtitle: `@username` when claimed on the default
    /// domain, full address for external payment addresses, else short npub.
    var profileCardSubtitle: String {
        let address = (coreClaimedHandle ?? bip353)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return shortKey }
        let parts = address.split(separator: "@", maxSplits: 1)
        if parts.count == 2, parts[1].lowercased() == Self.handleDomain {
            return "@\(parts[0])"
        }
        return address
    }

    /// Persisted payment address for copy rows (empty → nil).
    ///
    /// Chat-only registrar claims write the handle into `bip353` before any
    /// BIP-353 DNS/offer exists — hide that until the wallet is ready (the
    /// re-claim path then attaches the offer). External `name@other` addresses
    /// always show.
    var paymentAddressDisplay: String? {
        let stored = bip353.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stored.isEmpty else { return nil }
        if let claimed = coreClaimedHandle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !claimed.isEmpty,
           stored == claimed {
            guard case .ready = walletState else { return nil }
        }
        return stored
    }
}
