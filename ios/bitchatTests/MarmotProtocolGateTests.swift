//
// MarmotProtocolGateTests.swift
// bitchatTests
//
// Marmot v1 → v2 flag day: a v1 user must not type into a chat whose other
// side moved to MDK v0.14 and can no longer read it. Core decides from the
// contacts' KeyPackages and refuses the send; these pin what the iPhone and
// Mac chat screens show for that answer, through the store's real call site.
// This is free and unencumbered software released into the public domain.
//

import Foundation
import Testing
@testable import Sonar

struct MarmotProtocolGateTests {
    @Test
    func aContactOnMarmotV2ReplacesTheComposer() {
        #expect(snComposerGate(.blocked(updatedMemberHexes: ["aa"]), sendsOverMesh: false) == .updateRequired)
    }

    @Test
    func openUnknownAndPartlyUpdatedChatsKeepTheComposer() {
        #expect(snComposerGate(nil, sendsOverMesh: false) == .open)
        #expect(snComposerGate(.open, sendsOverMesh: false) == .open)
        #expect(
            snComposerGate(.partlyUpdated(updatedMemberHexes: ["aa", "bb"]), sendsOverMesh: false)
                == .partlyUpdated(count: 2)
        )
    }

    @Test
    func aLiveBluetoothLinkKeepsAMeshFoldedChatOpen() {
        #expect(snComposerGate(.blocked(updatedMemberHexes: ["aa"]), sendsOverMesh: true) == .open)
    }

    @Test
    func copyNamesThePeer() {
        #expect(SNMarmotGateCopy.updateRequired("Ana") == "Ana can't read messages from this version of Sonar. Update the app to keep chatting")
        #expect(SNMarmotGateCopy.partlyUpdatedBold(1) == "1 member is on a newer version")
        #expect(SNMarmotGateCopy.partlyUpdatedBold(3) == "3 members are on a newer version")
    }

    @Test @MainActor
    func coreRefusalReadsAsTheUpdateCopy() {
        let refusal = MarmotService.ServiceError.core(
            "the contact can't read messages from this version of Sonar: update the app to keep chatting"
        )
        #expect(MarmotChatModel.isPeerUpdatedSonar(refusal))
        #expect(MarmotChatModel.describe(refusal).contains("from this version of Sonar"))
        #expect(!MarmotChatModel.isPeerUpdatedSonar(MarmotService.ServiceError.core("relay timeout")))
    }

    /// The store call both chat screens read (`SonarDMScreen.composerGate`,
    /// `MacConversationPane.composerGate`).
    @Test @MainActor
    func theStoreGatesTheComposerFromTheModelsGate() {
        let (store, cleanup) = makeIsolatedSonarAppStore()
        defer { cleanup() }
        let chat = String(repeating: "ab", count: 32)
        #expect(store.composerGate(chat) == .open)
        store.marmot.setMarmotChatGateForTesting(
            conversationId: chat,
            .blocked(updatedMemberHexes: [String(repeating: "cd", count: 32)])
        )
        #expect(store.composerGate(chat) == .updateRequired)
        store.marmot.setMarmotChatGateForTesting(
            conversationId: chat,
            .partlyUpdated(updatedMemberHexes: ["cd"])
        )
        #expect(store.composerGate(chat) == .partlyUpdated(count: 1))
        store.marmot.setMarmotChatGateForTesting(conversationId: chat, nil)
        #expect(store.composerGate(chat) == .open)
    }
}
