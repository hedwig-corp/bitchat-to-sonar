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

    @Test func preservesFirstImportDuringPendingRouteReplacement() {
        let replacement = SNMarmotRouteReplacement(
            pendingId: "pending:npub1peer",
            realId: "marmot:group"
        )

        #expect(snPreservesMacAttachmentImport(
            conversationID: "pending:npub1peer",
            routeReplacement: replacement
        ))
        #expect(!snPreservesMacAttachmentImport(
            conversationID: "another-chat",
            routeReplacement: replacement
        ))
    }

    @Test func promotesOnlyVerifiedPDFsFromGenericMime() {
        let pdf = Data("%PDF-1.7\nreceipt".utf8)
        let fake = Data("not a pdf".utf8)

        #expect(snEffectiveAttachmentMime(
            declaredMime: "application/octet-stream",
            filename: "receipt.PDF",
            plaintext: pdf
        ) == "application/pdf")
        #expect(snIsVerifiedPDFAttachment(
            declaredMime: "application/octet-stream",
            filename: "receipt.PDF",
            plaintext: pdf
        ))
        #expect(snEffectiveAttachmentMime(
            declaredMime: "application/octet-stream",
            filename: "receipt.pdf",
            plaintext: fake
        ) == "application/octet-stream")
    }

    @Test func preservesExplicitMimeAndSanitizesPreviewFilename() {
        let pdf = Data("%PDF-1.7\nreceipt".utf8)

        #expect(snEffectiveAttachmentMime(
            declaredMime: "text/plain; charset=utf-8",
            filename: "receipt.pdf",
            plaintext: pdf
        ) == "text/plain")
        #expect(snSafeAttachmentFilename("../../receipt.pdf") == "receipt.pdf")
        #expect(snSafeAttachmentFilename("..") == "attachment")
    }
}
#endif
