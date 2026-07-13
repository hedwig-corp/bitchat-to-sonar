//
// SonarDesktopFileDropTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(macOS)
import Foundation
import Testing
@testable import Sonar

struct SonarDesktopFileDropTests {
    @Test func acceptsDMFileWithoutAPreexistingRoute() {
        let file = URL(fileURLWithPath: "/tmp/sonar-drop-test.txt")

        #expect(snAcceptsMacFileDrop(isChannel: false, urls: [file]))
    }

    @Test func rejectsChannelAndNonFileURLs() {
        let file = URL(fileURLWithPath: "/tmp/sonar-drop-test.txt")
        let web = URL(string: "https://example.com/file.txt")!

        #expect(!snAcceptsMacFileDrop(isChannel: true, urls: [file]))
        #expect(!snAcceptsMacFileDrop(isChannel: false, urls: [web]))
    }

    @Test func plansSecureChatForFreshSonarPeer() {
        #expect(snAttachmentRoutePlan(
            hasExistingRoute: false,
            pendingNpub: nil,
            resolvedNpub: "npub1peer"
        ) == .startSecureChat(npub: "npub1peer"))
        #expect(snAttachmentRoutePlan(
            hasExistingRoute: true,
            pendingNpub: nil,
            resolvedNpub: nil
        ) == .ready)
        #expect(snAttachmentRoutePlan(
            hasExistingRoute: false,
            pendingNpub: nil,
            resolvedNpub: nil
        ) == .unavailable)
    }
}
#endif
