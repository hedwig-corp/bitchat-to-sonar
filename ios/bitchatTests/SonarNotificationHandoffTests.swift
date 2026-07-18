//
// SonarNotificationHandoffTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
@testable import Sonar

struct SonarNotificationHandoffTests {

    @Test func conversationIdPrefersSonarConversationKey() {
        let userInfo: [AnyHashable: Any] = [
            SonarNotificationKeys.conversationId: "mesh:peer",
            SonarNotificationKeys.peerID: "other",
        ]
        #expect(SonarNotificationHandoff.conversationId(from: userInfo) == "mesh:peer")
    }

    @Test func conversationIdFallsBackToPeerID() {
        let userInfo: [AnyHashable: Any] = [
            SonarNotificationKeys.peerID: "peer-1",
        ]
        #expect(SonarNotificationHandoff.conversationId(from: userInfo) == "peer-1")
    }

    @Test func conversationIdIgnoresBlankValues() {
        let userInfo: [AnyHashable: Any] = [
            SonarNotificationKeys.conversationId: "   ",
            SonarNotificationKeys.peerID: "",
        ]
        #expect(SonarNotificationHandoff.conversationId(from: userInfo) == nil)
    }

    @Test func matchesOnlyListedConversationIds() {
        let userInfo: [AnyHashable: Any] = [
            SonarNotificationKeys.conversationId: "chat-a",
        ]
        #expect(SonarNotificationHandoff.matches(userInfo: userInfo, conversationIds: ["chat-a", "chat-b"]))
        #expect(!SonarNotificationHandoff.matches(userInfo: userInfo, conversationIds: ["chat-b"]))
        #expect(!SonarNotificationHandoff.matches(userInfo: [:], conversationIds: ["chat-a"]))
    }

    @Test func blankConversationIdIsIgnored() {
        #expect(SonarNotificationHandoff.conversationId(from: [
            SonarNotificationKeys.conversationId: "\n\t",
        ]) == nil)
    }
}
