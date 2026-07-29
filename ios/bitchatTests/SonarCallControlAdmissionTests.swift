//
// SonarCallControlAdmissionTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing

@testable import Sonar

/// #420 — a ☎CALL line is an ordinary group message, so without binding any
/// member of a group containing the victim could ring them with an OFFER
/// carrying the attacker's own address, or answer someone else's call (core's
/// `on_answer` overwrites the pin — the last answerer wins). Mirror of the
/// Compose `CallControlAdmissionTest`.
struct SonarCallControlAdmissionTests {

    private let peer = "peer"
    private let attacker = "attacker"

    @Test
    func groupMemberCannotRingYou() {
        #expect(!SonarCallControlAdmission.isAdmissible(
            kind: .offer,
            otherMemberKeys: [peer, attacker],
            structurallyDirect: false,
            senderKey: attacker,
            activeCallConversationId: nil,
            conversationId: "marmot:g"))
    }

    @Test
    func groupMemberCannotAnswerYourCall() {
        #expect(!SonarCallControlAdmission.isAdmissible(
            kind: .answer,
            otherMemberKeys: [peer, attacker],
            structurallyDirect: false,
            senderKey: attacker,
            activeCallConversationId: "marmot:g",
            conversationId: "marmot:g"))
    }

    @Test
    func directPeerCanOfferAndAnswer() {
        #expect(SonarCallControlAdmission.isAdmissible(
            kind: .offer,
            otherMemberKeys: [peer],
            structurallyDirect: false,
            senderKey: peer,
            activeCallConversationId: nil,
            conversationId: "marmot:dm"))
        #expect(SonarCallControlAdmission.isAdmissible(
            kind: .answer,
            otherMemberKeys: [peer],
            structurallyDirect: false,
            senderKey: peer,
            activeCallConversationId: "marmot:dm",
            conversationId: "marmot:dm"))
    }

    @Test
    func someoneElseInADirectChatCannotDriveIt() {
        #expect(!SonarCallControlAdmission.isAdmissible(
            kind: .offer,
            otherMemberKeys: [peer],
            structurallyDirect: false,
            senderKey: attacker,
            activeCallConversationId: nil,
            conversationId: "marmot:dm"))
    }

    @Test
    func controlFromAnotherConversationCannotSteerTheActiveCall() {
        #expect(!SonarCallControlAdmission.isAdmissible(
            kind: .end,
            otherMemberKeys: [peer],
            structurallyDirect: false,
            senderKey: peer,
            activeCallConversationId: "marmot:dm",
            conversationId: "marmot:other"))
        #expect(!SonarCallControlAdmission.isAdmissible(
            kind: .cancel,
            otherMemberKeys: [peer],
            structurallyDirect: false,
            senderKey: peer,
            activeCallConversationId: nil,
            conversationId: "marmot:dm"))
    }

    /// Mesh DMs are keyed by the peer: 2-party by construction, no roster and
    /// often no sender npub. Breaking these would break mesh calling outright.
    @Test
    func meshDmsStayCallableWithoutARoster() {
        #expect(SonarCallControlAdmission.isAdmissible(
            kind: .offer,
            otherMemberKeys: [],
            structurallyDirect: true,
            senderKey: "",
            activeCallConversationId: nil,
            conversationId: "abc"))
        #expect(SonarCallControlAdmission.isAdmissible(
            kind: .end,
            otherMemberKeys: [],
            structurallyDirect: true,
            senderKey: "",
            activeCallConversationId: "abc",
            conversationId: "abc"))
    }

    @Test
    func aRosterlessGroupConversationIsNotAdmissible() {
        // Fail closed rather than assume 2-party.
        #expect(!SonarCallControlAdmission.isAdmissible(
            kind: .offer,
            otherMemberKeys: [],
            structurallyDirect: false,
            senderKey: peer,
            activeCallConversationId: nil,
            conversationId: "marmot:g"))
    }

    @Test
    func duplicateRosterEntriesStillResolveToOnePeer() {
        #expect(SonarCallControlAdmission.isAdmissible(
            kind: .offer,
            otherMemberKeys: [peer, peer, ""],
            structurallyDirect: false,
            senderKey: peer,
            activeCallConversationId: nil,
            conversationId: "marmot:dm"))
    }
}
