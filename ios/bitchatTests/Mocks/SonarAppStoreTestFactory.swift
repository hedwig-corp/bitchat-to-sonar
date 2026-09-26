//
// SonarAppStoreTestFactory.swift
// bitchatTests
//
// A `SonarAppStore` wired to mocks: no BLE transport, no keychain, no relays,
// and a throwaway UserDefaults suite for the Marmot model. Lets tests drive the
// store's real call sites instead of re-implementing them in helpers.
//

import Foundation
@testable import Sonar

@MainActor
func makeIsolatedSonarAppStore(
    wallet: SonarWalletProviding = UnconfiguredWallet()
) -> (store: SonarAppStore, cleanup: () -> Void) {
    let suiteName = "SonarAppStoreTestFactory-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let keychain = MockKeychain()
    let idBridge = NostrIdentityBridge(keychain: MockKeychainHelper())
    let chatViewModel = ChatViewModel(
        keychain: keychain,
        idBridge: idBridge,
        identityManager: MockIdentityManager(keychain),
        transport: MockTransport()
    )
    let marmot = MarmotChatModel(
        service: MarmotService(relayUrls: []),
        keychain: keychain,
        defaults: defaults
    )
    let store = SonarAppStore(
        chatViewModel: chatViewModel,
        marmot: marmot,
        keychain: keychain,
        idBridge: idBridge,
        wallet: wallet
    )
    return (store, { defaults.removePersistentDomain(forName: suiteName) })
}
