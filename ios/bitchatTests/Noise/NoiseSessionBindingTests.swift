//
// NoiseSessionBindingTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import CryptoKit
import Foundation
import Testing

@testable import Sonar

/// Noise XX authenticates the remote static key, but the peer ID a handshake is
/// filed under comes from the unauthenticated packet header. These tests pin the
/// binding between the two, and the isolation that keeps a forged replacement
/// from destroying a working session.
struct NoiseSessionBindingTests {

    private enum HandshakeTestError: Error {
        case missingHandshakeMessage
    }

    private let aliceKey = Curve25519.KeyAgreement.PrivateKey()
    private let bobKey = Curve25519.KeyAgreement.PrivateKey()
    private let malloryKey = Curve25519.KeyAgreement.PrivateKey()
    private let mockKeychain = MockKeychain()

    /// Wire IDs as the mesh derives them: the short hex of the static key.
    private var alicePeerID: PeerID { PeerID(publicKey: aliceKey.publicKey.rawRepresentation) }
    private var bobPeerID: PeerID { PeerID(publicKey: bobKey.publicKey.rawRepresentation) }

    private func manager(_ key: Curve25519.KeyAgreement.PrivateKey) -> NoiseSessionManager {
        NoiseSessionManager(localStaticKey: key, keychain: mockKeychain)
    }

    /// Completes a full XX handshake so that `alice` holds a session keyed by
    /// `bobPeerID` and `bob` holds one keyed by `alicePeerID`.
    private func establishSession(alice: NoiseSessionManager, bob: NoiseSessionManager) throws {
        let message1 = try bob.initiateHandshake(with: alicePeerID)
        guard let message2 = try alice.handleIncomingHandshake(from: bobPeerID, message: message1) else {
            throw HandshakeTestError.missingHandshakeMessage
        }
        guard let message3 = try bob.handleIncomingHandshake(from: alicePeerID, message: message2) else {
            throw HandshakeTestError.missingHandshakeMessage
        }
        _ = try alice.handleIncomingHandshake(from: bobPeerID, message: message3)
    }

    /// Drives Mallory's own valid XX handshake at Alice while every packet
    /// claims to come from Bob, and returns Mallory's final message.
    private func forgedHandshakeMessage3(
        from mallory: NoiseSessionManager,
        to alice: NoiseSessionManager
    ) throws -> Data {
        let message1 = try mallory.initiateHandshake(with: alicePeerID)
        guard let message2 = try alice.handleIncomingHandshake(from: bobPeerID, message: message1) else {
            throw HandshakeTestError.missingHandshakeMessage
        }
        guard let message3 = try mallory.handleIncomingHandshake(from: alicePeerID, message: message2) else {
            throw HandshakeTestError.missingHandshakeMessage
        }
        return message3
    }

    @Test
    func handshakeAuthenticatedByAnotherKeyCannotClaimAPeerID() throws {
        let alice = manager(aliceKey)
        let mallory = manager(malloryKey)

        let message3 = try forgedHandshakeMessage3(from: mallory, to: alice)

        #expect(throws: NoiseSessionError.peerIdentityMismatch) {
            _ = try alice.handleIncomingHandshake(from: bobPeerID, message: message3)
        }
        #expect(alice.getSession(for: bobPeerID)?.isEstablished() != true)
    }

    @Test
    func forgedReplacementHandshakeLeavesTheEstablishedSessionIntact() throws {
        let alice = manager(aliceKey)
        let bob = manager(bobKey)
        try establishSession(alice: alice, bob: bob)

        let mallory = manager(malloryKey)
        let message3 = try forgedHandshakeMessage3(from: mallory, to: alice)
        #expect(throws: NoiseSessionError.peerIdentityMismatch) {
            _ = try alice.handleIncomingHandshake(from: bobPeerID, message: message3)
        }

        // Alice's real session with Bob must still encrypt to Bob.
        let plaintext = Data("still alive".utf8)
        let ciphertext = try alice.encrypt(plaintext, for: bobPeerID)
        let decrypted = try bob.decrypt(ciphertext, from: alicePeerID)
        #expect(decrypted == plaintext)
    }

    /// The denial-of-service half: before this fix an established session was
    /// evicted the instant any handshake byte arrived, so one unauthenticated
    /// message was enough to tear down a working session.
    @Test
    func unauthenticatedHandshakeMessageAloneCannotTearDownASession() throws {
        let alice = manager(aliceKey)
        let bob = manager(bobKey)
        try establishSession(alice: alice, bob: bob)

        let mallory = manager(malloryKey)
        let message1 = try mallory.initiateHandshake(with: alicePeerID)
        _ = try alice.handleIncomingHandshake(from: bobPeerID, message: message1)

        let plaintext = Data("survives the probe".utf8)
        let ciphertext = try alice.encrypt(plaintext, for: bobPeerID)
        let decrypted = try bob.decrypt(ciphertext, from: alicePeerID)
        #expect(decrypted == plaintext)
    }

    /// The isolation must not strand a genuine peer: a real rehandshake still
    /// has to be promoted over the old session, or a restarted peer can never
    /// reconnect.
    @Test
    func genuineRehandshakeStillReplacesTheEstablishedSession() throws {
        let alice = manager(aliceKey)
        let bob = manager(bobKey)
        try establishSession(alice: alice, bob: bob)

        // Bob restarts with the same static key and handshakes again.
        let bobRestarted = manager(bobKey)
        try establishSession(alice: alice, bob: bobRestarted)

        let plaintext = Data("after restart".utf8)
        let ciphertext = try bobRestarted.encrypt(plaintext, for: alicePeerID)
        let decrypted = try alice.decrypt(ciphertext, from: bobPeerID)
        #expect(decrypted == plaintext)
    }
}
