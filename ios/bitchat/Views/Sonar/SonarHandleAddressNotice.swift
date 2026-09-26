//
// SonarHandleAddressNotice.swift
// bitchat
//
// Which wallet the public handle pays, next to wherever the address or the
// old wallet is shown: the username card (Profile, Mac panes) and the old
// Lightning wallet section (Settings, Wallet). Compose mirror:
// `screens/HandleAddressNotice.kt`.
//
// - "Your address … still pays your old wallet." + Move, while the handle
//   points at the legacy wallet and it is still here. It stays until the move
//   succeeds; the app never moves it on its own.
// - "Couldn't update your address … Retrying." when an automatic
//   re-registration failed.
// - "Move back to your old wallet" while the handle pays the new wallet and
//   the old one is still here.
//
// Every move asks first, in words: where payments will go, that the old
// wallet stays spendable, and that deleting the new wallet does not undo it.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct SNHandleAddressNotice: View {
    @ObservedObject var store: SonarAppStore

    @State private var confirmNewWallet = false
    @State private var confirmOldWallet = false

    /// Whether the notice has anything to show (hosts skip their container).
    static func isVisible(_ store: SonarAppStore) -> Bool {
        store.handleAddressNotice != .none || store.canMoveHandleBackToOldWallet
    }

    private var moving: Bool { store.handleMoveState == .moving }

    private var address: String {
        switch store.handleAddressNotice {
        case .paysOldWallet(let address), .updateFailing(let address):
            return address
        case .none:
            return store.coreClaimedHandle ?? ""
        }
    }

    var body: some View {
        if Self.isVisible(store) {
            VStack(alignment: .leading, spacing: 8) {
                switch store.handleAddressNotice {
                case .paysOldWallet(let address):
                    Text(verbatim: String(localized: "Your address \(address) still pays your old wallet."))
                        .font(SonarTheme.uiFont(size: 13, weight: .semibold))
                        .foregroundColor(SonarTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    action(
                        moving ? String(localized: "Moving\u{2026}") : String(localized: "Move to new wallet"),
                        primary: true
                    ) {
                        confirmNewWallet = true
                    }
                case .updateFailing(let address):
                    Text(verbatim: String(localized: "Couldn't update your address \(address). Retrying."))
                        .font(SonarTheme.uiFont(size: 12.5))
                        .foregroundColor(SonarTheme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                case .none:
                    EmptyView()
                }
                if store.canMoveHandleBackToOldWallet {
                    action(
                        moving ? String(localized: "Moving\u{2026}") : String(localized: "Move back to your old wallet"),
                        primary: false
                    ) {
                        confirmOldWallet = true
                    }
                }
                if case .failed(let message) = store.handleMoveState {
                    Text(verbatim: message)
                        .font(SonarTheme.uiFont(size: 12.5))
                        .foregroundColor(SonarTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .alert(
                Text("Move your address to your new wallet?"),
                isPresented: $confirmNewWallet
            ) {
                Button(String(localized: "Move address")) { store.moveHandleToNewWallet() }
                Button(String(localized: "Cancel"), role: .cancel) { store.resetHandleMoveState() }
            } message: {
                Text(verbatim: String(localized: "Payments to \(address) will go to your new wallet, held as ecash at mint.hedwig.sh. Your old wallet stays spendable. Deleting the new wallet does not move the address back."))
            }
            .alert(
                Text("Move your address back to your old wallet?"),
                isPresented: $confirmOldWallet
            ) {
                Button(String(localized: "Move back")) { store.moveHandleToOldWallet() }
                Button(String(localized: "Cancel"), role: .cancel) { store.resetHandleMoveState() }
            } message: {
                Text(verbatim: String(localized: "Payments to \(address) will go to your old Lightning wallet again. Your ecash wallet keeps what it holds."))
            }
        }
    }

    private func action(_ label: String, primary: Bool, perform: @escaping () -> Void) -> some View {
        Button {
            guard !moving else { return }
            perform()
        } label: {
            Text(verbatim: label)
                .font(SonarTheme.uiFont(size: 13, weight: .bold))
                .foregroundColor(primary ? SonarTheme.onGold : SonarTheme.text)
                .padding(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
                .background(Capsule().fill(primary ? SonarTheme.goldFill : SonarTheme.surface2))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(moving)
    }
}
