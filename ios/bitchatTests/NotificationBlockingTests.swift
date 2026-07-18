//
// NotificationBlockingTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//
// BCH-01-012: Tests for notification blocking feature

import Testing
import Foundation
import SonarCore
@testable import Sonar

struct NotificationBlockingTests {

    @Test("notification admission is one converging state record")
    func notificationAdmissionConverges() {
        var state = SonarPushProcessor.ContinuationState()
        state.admit(ownerId: "account-a")
        let admitted = state.generation
        #expect(state.dirty)
        #expect(state.needsFallback(for: admitted))
        state.markSurfaced(through: admitted)
        #expect(!state.needsFallback(for: admitted))
    }

    @Test("older surface progress cannot suppress a newer wake fallback")
    func olderSurfaceDoesNotSuppressNewerWake() {
        var state = SonarPushProcessor.ContinuationState()
        state.admit(ownerId: "account-a")
        let first = state.generation
        state.admit(ownerId: "account-a")
        let second = state.generation
        SonarPushProcessor.markRenderedSnapshotSurfaced(
            &state,
            renderedGeneration: first
        )

        #expect(!state.needsFallback(for: first))
        #expect(state.needsFallback(for: second))
    }

    @Test("delayed wake from account A is rejected after account B replaces it")
    func delayedWakeCannotCrossAccountReplacement() {
        var state = SonarPushProcessor.ContinuationState()
        state.admit(ownerId: "account-a")
        let delayedGeneration = state.generation

        state.admit(ownerId: "account-b")

        // Reset-on-owner-change deliberately reuses generation 1. Owner binding
        // is therefore required; generation alone would accept A's delayed task.
        #expect(state.generation == delayedGeneration)
        #expect(!state.belongs(to: "account-a"))
        #expect(state.belongs(to: "account-b"))
        var stale = SonarPushProcessor.ContinuationState(ownerId: "account-a")
        stale.clearUnlessOwned(by: "account-b")
        #expect(stale == SonarPushProcessor.ContinuationState())
    }

    @Test("push call routing rings only for fresh incoming offers")
    func pushCallRoutingFreshOfferOnly() {
        let now: UInt64 = 10_000
        #expect(SonarPushProcessor.callAction(
            control: .offer(callId: "c", video: false, nodeAddrB64: "a", unixSecs: now),
            createdAtSecs: now,
            nowSecs: now
        ) == .incomingOffer(callId: "c"))
        #expect(SonarPushProcessor.callAction(
            control: .offer(callId: "c", video: false, nodeAddrB64: "a", unixSecs: now - 61),
            createdAtSecs: now,
            nowSecs: now
        ) == .cancel(callId: "c"))
        #expect(SonarPushProcessor.callAction(
            control: .offer(callId: "c", video: false, nodeAddrB64: "a", unixSecs: now + 61),
            createdAtSecs: now,
            nowSecs: now
        ) == .cancel(callId: "c"))
    }

    @Test("push call routing cancels terminal controls and ignores ordinary messages")
    func pushCallRoutingTerminalControls() {
        let controls: [CallControlInfo] = [
            .answer(callId: "c", answer: .accept, nodeAddrB64: "a"),
            .cancel(callId: "c"),
            .end(callId: "c", reason: "done"),
        ]
        for control in controls {
            #expect(SonarPushProcessor.callAction(
                control: control,
                createdAtSecs: 10_000,
                nowSecs: 10_000
            ) == .cancel(callId: "c"))
        }
        #expect(SonarPushProcessor.callAction(
            control: nil,
            createdAtSecs: 10_000,
            nowSecs: 10_000
        ) == .message)
    }

    @Test("stale terminal is policy-acked without cancelling a newer call")
    func staleTerminalDoesNotCancelNewCall() {
        #expect(SonarPushProcessor.callAction(
            control: .end(callId: "old", reason: "done"),
            createdAtSecs: 9_900,
            nowSecs: 10_000
        ) == .acknowledge)
        #expect(
            SonarPushProcessor.callNotificationKey(groupId: "group", callId: "old")
                != SonarPushProcessor.callNotificationKey(groupId: "group", callId: "new")
        )
    }

    @Test("persisted blocked sender policy suppresses headless notification")
    func persistedBlockedSenderPolicy() throws {
        let bytes = Data(repeating: 0x2a, count: 32)
        let npub = try Bech32.encode(hrp: "npub", data: bytes)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()

        #expect(SonarPushProcessor.isSenderBlocked(npub, blockedNostr: [hex]))
        #expect(!SonarPushProcessor.isSenderBlocked(npub, blockedNostr: []))
    }

    @Test("headless policy reads the canonical encrypted identity cache")
    func headlessPolicyReadsEncryptedCache() {
        let keychain = MockKeychain()
        let manager = SecureIdentityStateManager(keychain)
        let pubkey = String(repeating: "ab", count: 32)

        manager.setNostrBlocked(pubkey, isBlocked: true)
        manager.forceSave()

        #expect(
            SecureIdentityStateManager.persistedBlockedNostrPubkeys(keychain: keychain)
                .contains(pubkey)
        )
    }

    @Test("wipe fences a suspended fallback notification before post and ACK")
    func wipeFencesSuspendedFallbackNotification() async throws {
        let fence = SonarNotificationSessionFence()
        let oldGeneration = fence.advance()
        let oldLease = try #require(fence.lease(expectedGeneration: oldGeneration))
        let gate = NotificationSubmissionGate()

        let oldRender = Task { @MainActor in
            await SonarPushProcessor.postFallbackWithFence(renderLease: oldLease) { lease in
                await gate.suspendPost()
                let submitted = lease.submitIfCurrent(cleanupOnInvalidation: {}) {}
                if submitted { lease.finishSubmission() }
                return submitted
            }
        }

        await gate.waitUntilPostIsSuspended()
        let replacementGeneration = fence.advance()
        #expect(replacementGeneration != oldGeneration)
        await gate.resumePost()

        #expect(!(await oldRender.value))

        let replacementLease = try #require(
            fence.lease(expectedGeneration: replacementGeneration)
        )
        let replacementSubmitted = replacementLease.submitIfCurrent(
            cleanupOnInvalidation: {}
        ) {}
        #expect(replacementSubmitted)
        #expect(replacementLease.isCurrent)
        replacementLease.finishSubmission()
    }

    // MARK: - Nostr Blocking Tests

    @Test("isNostrBlocked returns true for blocked pubkeys")
    func isNostrBlocked_returnsTrueForBlockedPubkey() {
        let keychain = MockKeychain()
        let manager = MockIdentityManager(keychain)

        let testPubkey = "abc123def456".lowercased()

        // Initially not blocked
        #expect(manager.isNostrBlocked(pubkeyHexLowercased: testPubkey) == false)

        // Block the pubkey
        manager.setNostrBlocked(testPubkey, isBlocked: true)

        // Now should be blocked
        #expect(manager.isNostrBlocked(pubkeyHexLowercased: testPubkey) == true)

        // Unblock
        manager.setNostrBlocked(testPubkey, isBlocked: false)
        #expect(manager.isNostrBlocked(pubkeyHexLowercased: testPubkey) == false)
    }

    @Test("isBlocked returns true for blocked fingerprints")
    func isBlocked_returnsTrueForBlockedFingerprint() {
        let keychain = MockKeychain()
        let manager = MockIdentityManager(keychain)

        let testFingerprint = "fingerprint123"

        // Initially not blocked
        #expect(manager.isBlocked(fingerprint: testFingerprint) == false)

        // Block the fingerprint
        manager.setBlocked(testFingerprint, isBlocked: true)

        // Now should be blocked
        #expect(manager.isBlocked(fingerprint: testFingerprint) == true)

        // Unblock
        manager.setBlocked(testFingerprint, isBlocked: false)
        #expect(manager.isBlocked(fingerprint: testFingerprint) == false)
    }

    @Test("getBlockedNostrPubkeys returns all blocked pubkeys")
    func getBlockedNostrPubkeys_returnsAllBlocked() {
        let keychain = MockKeychain()
        let manager = MockIdentityManager(keychain)

        let pubkey1 = "pubkey1".lowercased()
        let pubkey2 = "pubkey2".lowercased()
        let pubkey3 = "pubkey3".lowercased()

        manager.setNostrBlocked(pubkey1, isBlocked: true)
        manager.setNostrBlocked(pubkey2, isBlocked: true)
        manager.setNostrBlocked(pubkey3, isBlocked: true)

        let blocked = manager.getBlockedNostrPubkeys()

        #expect(blocked.count == 3)
        #expect(blocked.contains(pubkey1))
        #expect(blocked.contains(pubkey2))
        #expect(blocked.contains(pubkey3))
    }

    // MARK: - Message Blocking Tests

    @Test("BitchatMessage with blocked sender is identified")
    func bitchatMessage_blockedSenderIdentified() {
        let keychain = MockKeychain()
        let manager = MockIdentityManager(keychain)

        let blockedFingerprint = "blocked_fingerprint_123"
        manager.setBlocked(blockedFingerprint, isBlocked: true)

        #expect(manager.isBlocked(fingerprint: blockedFingerprint) == true)
    }

    @Test("Case insensitive blocking for Nostr pubkeys")
    func nostrBlocking_caseInsensitive() {
        let keychain = MockKeychain()
        let manager = MockIdentityManager(keychain)

        let pubkeyLower = "abc123def456"

        // Block lowercase
        manager.setNostrBlocked(pubkeyLower, isBlocked: true)

        // Check lowercase is blocked
        #expect(manager.isNostrBlocked(pubkeyHexLowercased: pubkeyLower) == true)

        // Note: The API expects lowercased input, so callers must normalize
        // This test verifies the contract that pubkeys should be lowercased before checking
        // The fix in ChatViewModel+Nostr.swift normalizes via event.pubkey.lowercased()
    }
}

private actor NotificationSubmissionGate {
    private var postIsSuspended = false
    private var postCanResume = false
    private var postContinuation: CheckedContinuation<Void, Never>?
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []

    func suspendPost() async {
        postIsSuspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !postCanResume else { return }
        await withCheckedContinuation { continuation in
            postContinuation = continuation
        }
    }

    func waitUntilPostIsSuspended() async {
        guard !postIsSuspended else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func resumePost() {
        postCanResume = true
        postContinuation?.resume()
        postContinuation = nil
    }
}
