//
// SecureRandomTests.swift
// bitchatTests
//
// Pins the invariant behind the RNG-hardening change: a CSPRNG failure must
// never surface as a predictable value. The bug this guards was five
// `SecRandomCopyBytes` call sites that discarded the `OSStatus` while writing
// into a zero-filled buffer, so an RNG failure yielded all-zeros "random"
// bytes — silently, with every test still green.
//
// Be clear about what these do NOT do: `SecRandomCopyBytes` cannot be made to
// fail from a test without injecting a seam, so none of this exercises the
// failure branch. On a machine with a working CSPRNG the OLD code passes these
// too — the old bug was invisible precisely because the happy path was fine.
//
// What they do pin is that the wiring is right and stays right: the NIP-44
// nonce, read straight out of the wire format, is drawn fresh per message
// rather than derived, cached, or hoisted to a constant, and the plumbing
// still decrypts. That catches the *other* way this regresses — someone
// "optimising" a per-message draw into a stored value. The failure branch
// itself is guarded mechanically, not here, by scripts/check-rng-hygiene.sh.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
@testable import Sonar

struct SecureRandomTests {

    @Test func bytesReturnsRequestedLength() throws {
        for n in [1, 12, 16, 24, 32, 64] {
            #expect(try SecureRandom.bytes(n).count == n)
        }
    }

    @Test func bytesAreNotAllZero() throws {
        // The shape the defect produced when the RNG failed: a discarded
        // OSStatus left the caller's zero-filled buffer untouched.
        let data = try SecureRandom.bytes(32)
        #expect(data.contains { $0 != 0 })
    }

    @Test func successiveDrawsDiffer() throws {
        var seen = Set<Data>()
        for _ in 0..<64 {
            seen.insert(try SecureRandom.bytes(16))
        }
        // 64 draws of 128 bits colliding does not happen; any constant or
        // cached buffer collapses this to 1.
        #expect(seen.count == 64)
    }

    @Test func optionalBytesMatchesThrowingVariant() throws {
        let a = SecureRandom.optionalBytes(24)
        let b = SecureRandom.optionalBytes(24)
        #expect(a?.count == 24)
        #expect(b?.count == 24)
        #expect(a != b)
    }

    /// NIP-44 v2 wire format is `"v2:" + base64url(nonce24 ‖ ciphertext ‖ tag)`,
    /// so the nonce can be read straight off the wire.
    private func nip44Nonce(_ content: String) throws -> Data {
        let body = try #require(content.split(separator: ":", maxSplits: 1).last.map(String.init))
        var b64 = body.replacingOccurrences(of: "-", with: "+")
                      .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        let raw = try #require(Data(base64Encoded: b64))
        #expect(raw.count > 24)
        return raw.prefix(24)
    }

    /// Assert on the **nonce itself**, not on ciphertext inequality.
    ///
    /// Ciphertext inequality is not evidence here: `createPrivateMessage` mints
    /// a fresh ephemeral key per message and `randomizedTimestamp()` perturbs
    /// the plaintext, so `first.content != second.content` holds even with a
    /// hardcoded constant nonce. Reading the 24 bytes out of the wire format is
    /// what actually fails against a cached or constant nonce.
    @Test func nip44NonceIsFreshPerMessage() throws {
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let plaintext = "same message, twice"

        var nonces = Set<Data>()
        var lastWrap: NostrEvent?
        for _ in 0..<8 {
            let wrap = try NostrProtocol.createPrivateMessage(
                content: plaintext,
                recipientPubkey: recipient.publicKeyHex,
                senderIdentity: sender
            )
            nonces.insert(try nip44Nonce(wrap.content))
            lastWrap = wrap
        }
        #expect(nonces.count == 8)
        #expect(!nonces.contains(Data(repeating: 0, count: 24)))

        // Freshness must not have broken correctness.
        let (out, _, _) = try NostrProtocol.decryptPrivateMessage(
            giftWrap: try #require(lastWrap),
            recipientIdentity: recipient
        )
        #expect(out == plaintext)
    }
}
