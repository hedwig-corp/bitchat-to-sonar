//
// PaymentPendingRowTests.swift
// bitchatTests
//
// A chat payment shows in the transcript from the moment the wallet is asked
// to pay, as a "Sending to …" bubble, in both chat kinds (docs/CHAT-TYPES.md):
// a pure White Noise/Marmot chat and a mesh-folded one. These drive the real
// `dmMsgs` call site over the real payment ledger, the way `sendPay` records
// a payment before the wallet send.
//
// This is free and unencumbered software released into the public domain.
//

import Foundation
import Testing
@testable import Sonar

@MainActor
@Suite(.serialized)
struct PaymentPendingRowTests {
    private static let me = "npub1ownaccount"
    private static let peer = "npub1peeraccount"

    private static func pending(_ id: String, peerKey: String) -> SonarPaymentActivity {
        SonarPaymentActivity(
            id: id,
            kind: .sonarDirect,
            peerKey: peerKey,
            peerName: "Peer",
            direction: .outgoing,
            sats: 1_000,
            via: SNVia.internet.rawValue,
            createdAt: Date(),
            destinationHash: "deadbeef",
            status: .pending
        )
    }

    private static func payRow(_ rows: [SNMessage], id: String) -> SNMessage? {
        rows.first { $0.pay?.id == id }
    }

    @Test
    func aPendingPaymentShowsAsSendingInAMarmotChat() {
        let (store, cleanup) = makeIsolatedSonarAppStore()
        defer { cleanup() }
        store.marmot.npub = Self.me
        store.marmot.groups = [
            MarmotService.MarmotGroup(id: "g1", name: "", memberNpubs: [Self.me, Self.peer])
        ]
        let chatId = SonarAppStore.marmotIDPrefix + "g1"
        store.paymentActivityLedger.recordPending(Self.pending("pay-marmot", peerKey: chatId))

        let row = Self.payRow(store.dmMsgs(chatId), id: "pay-marmot")
        #expect(row?.mine == true)
        #expect(row?.pay?.direct == true)
        #expect(row?.pay?.state == .settling, "an unsettled payment renders as Sending, not Paid")
        #expect(row?.pay?.failed == false)
    }

    @Test
    func aPendingPaymentShowsAsSendingInAMeshFoldedChat() {
        let (store, cleanup) = makeIsolatedSonarAppStore()
        defer { cleanup() }
        // A mesh conversation id: a Noise fingerprint, no Marmot group behind it.
        let chatId = "a1b2c3d4e5f60718"
        store.paymentActivityLedger.recordPending(Self.pending("pay-mesh", peerKey: chatId))

        let row = Self.payRow(store.dmMsgs(chatId), id: "pay-mesh")
        #expect(row?.mine == true)
        #expect(row?.pay?.direct == true)
        #expect(row?.pay?.state == .settling)
    }

    @Test
    func aFailedPaymentKeepsItsBubbleMarkedFailed() {
        let (store, cleanup) = makeIsolatedSonarAppStore()
        defer { cleanup() }
        let chatId = "a1b2c3d4e5f60718"
        store.paymentActivityLedger.recordPending(Self.pending("pay-failed", peerKey: chatId))
        store.paymentActivityLedger.markFailed("pay-failed", message: "mint refused")

        let row = Self.payRow(store.dmMsgs(chatId), id: "pay-failed")
        #expect(row?.pay?.failed == true)
    }
}
