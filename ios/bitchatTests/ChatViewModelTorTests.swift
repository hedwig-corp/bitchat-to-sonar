//
// ChatViewModelTorTests.swift
// bitchatTests
//
// Tests for ChatViewModel+Tor.swift Tor lifecycle notification handlers.
//

import Testing
import Foundation
@testable import Sonar

// MARK: - Test Helpers

@MainActor
private func makeTestableViewModel() -> (viewModel: ChatViewModel, transport: MockTransport) {
    let keychain = MockKeychain()
    let keychainHelper = MockKeychainHelper()
    let idBridge = NostrIdentityBridge(keychain: keychainHelper)
    let identityManager = MockIdentityManager(keychain)
    let transport = MockTransport()

    let viewModel = ChatViewModel(
        keychain: keychain,
        idBridge: idBridge,
        identityManager: identityManager,
        transport: transport
    )

    return (viewModel, transport)
}

// MARK: - Tor Notification Handler Tests

struct ChatViewModelTorTests {

    // MARK: - handleTorWillStart Tests

    /// Tor is disabled product-wide — `TorManager.torEnforced` is a hardcoded
    /// `false` (Sonar decision 2026-06-13), so `handleTorWillStart` cannot
    /// announce. This pins that: the announce must stay silent while Tor is
    /// off, or users get "Tor is starting" system messages for a Tor that never
    /// starts.
    ///
    /// This test previously asserted the opposite, with the comment
    /// "torEnforced is true in tests". It had been failing since Tor was
    /// disabled, unnoticed because the iOS suite does not run in CI (#476).
    /// Coverage of the *enforced* path returns when Tor does — it needs
    /// `torEnforced` injectable, tracked in #476.
    @Test @MainActor
    func handleTorWillStart_whileTorDisabled_announcesNothingNew() async {
        let (viewModel, _) = makeTestableViewModel()

        // Startup already consumed the announce: with Tor disabled,
        // `ChatViewModel` init takes the `else if !torEnforced` branch and sets
        // the flag without posting a message (ChatViewModel.swift:502).
        #expect(viewModel.torStatusAnnounced)

        viewModel.switchLocationChannel(to: .location(GeohashChannel(level: .city, geohash: "u4pruydq")))
        try? await Task.sleep(nanoseconds: 100_000_000)
        let before = viewModel.messages.count

        viewModel.handleTorWillStart()
        try? await Task.sleep(nanoseconds: 100_000_000)

        // The handler must stay silent — no "Tor is starting" for a Tor that
        // never starts.
        #expect(viewModel.messages.count == before)
        #expect(viewModel.torStatusAnnounced)
    }

    @Test @MainActor
    func handleTorWillStart_whenAlreadyAnnounced_doesNotDuplicate() async {
        let (viewModel, _) = makeTestableViewModel()

        // Setup: pre-set the flag
        viewModel.torStatusAnnounced = true

        // Switch to a geohash channel so messages would be visible
        viewModel.switchLocationChannel(to: .location(GeohashChannel(level: .city, geohash: "u4pruydq")))
        try? await Task.sleep(nanoseconds: 100_000_000)

        let initialMessageCount = viewModel.messages.count

        // Action: call handler again
        viewModel.handleTorWillStart()
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Assert: no new message added (flag was already true)
        #expect(viewModel.messages.count == initialMessageCount)
    }

    // MARK: - handleTorWillRestart Tests

    @Test @MainActor
    func handleTorWillRestart_setsPendingFlag() async {
        let (viewModel, _) = makeTestableViewModel()

        // Precondition
        #expect(!viewModel.torRestartPending)

        // Action
        viewModel.handleTorWillRestart()
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Assert
        #expect(viewModel.torRestartPending)
    }

    @Test @MainActor
    func handleTorWillRestart_setsFlag_regardlessOfChannel() async {
        let (viewModel, _) = makeTestableViewModel()

        // Action: call handler (works regardless of channel)
        viewModel.handleTorWillRestart()
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Assert: flag should be set
        #expect(viewModel.torRestartPending)
    }

    // MARK: - handleTorDidBecomeReady Tests

    @Test @MainActor
    func handleTorDidBecomeReady_afterRestart_clearsPendingFlag() async {
        let (viewModel, _) = makeTestableViewModel()

        // Setup: simulate restart pending state
        viewModel.torRestartPending = true

        // Action
        viewModel.handleTorDidBecomeReady()
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Assert: should clear pending flag
        #expect(!viewModel.torRestartPending)
    }

    @Test @MainActor
    func handleTorDidBecomeReady_whileTorDisabled_doesNotAnnounce() async {
        let (viewModel, _) = makeTestableViewModel()

        // Setup: not restarting, but initial ready not announced yet
        viewModel.torRestartPending = false
        viewModel.torInitialReadyAnnounced = false

        // Action
        viewModel.handleTorDidBecomeReady()
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Tor is disabled (`torEnforced == false`, Sonar decision 2026-06-13),
        // so the initial-ready announce must stay silent. This asserted the
        // opposite until now; see the note on
        // `handleTorWillStart_whileTorDisabled_announcesNothingNew`.
        #expect(!viewModel.torInitialReadyAnnounced)
    }

    @Test @MainActor
    func handleTorDidBecomeReady_alreadyAnnounced_noDuplicate() async {
        let (viewModel, _) = makeTestableViewModel()

        // Setup: already announced initial ready
        viewModel.torRestartPending = false
        viewModel.torInitialReadyAnnounced = true
        viewModel.switchLocationChannel(to: .location(GeohashChannel(level: .city, geohash: "u4pruydq")))
        try? await Task.sleep(nanoseconds: 100_000_000)

        let initialMessageCount = viewModel.messages.count

        // Action
        viewModel.handleTorDidBecomeReady()
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Assert: no new message
        #expect(viewModel.messages.count == initialMessageCount)
    }

    // MARK: - handleTorPreferenceChanged Tests

    @Test @MainActor
    func handleTorPreferenceChanged_resetsAllFlags() async {
        let (viewModel, _) = makeTestableViewModel()

        // Setup: set all flags
        viewModel.torStatusAnnounced = true
        viewModel.torInitialReadyAnnounced = true
        viewModel.torRestartPending = true

        // Action
        viewModel.handleTorPreferenceChanged(Notification(name: .init("test")))
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Assert: all flags reset
        #expect(!viewModel.torStatusAnnounced)
        #expect(!viewModel.torInitialReadyAnnounced)
        #expect(!viewModel.torRestartPending)
    }
}
