//
// PaymentOfferFreshnessTests.swift
// bitchatTests
//
// Sonar's wallet changed on 2026-09-27. A contact's relay descriptor is a
// replaceable event, so an install that has not run since still advertises
// its old Breez offer, and a melt to it hangs until the mint gives up. The
// payer refetches once and then explains instead of paying. These drive the
// real sheet and send call sites over the isolated store, whose relay-less
// MarmotService makes every refetch fail, exactly like relays that still hold
// the old event.
//
// This is free and unencumbered software released into the public domain.
//

import Combine
import Foundation
import Testing
@testable import Sonar

/// A ready wallet that must never be asked to pay.
private final class ArmedWallet: SonarWalletProviding {
    private(set) var sendCalls = 0
    let state: SonarWalletState = .ready(balanceSats: 5_000)
    var statePublisher: AnyPublisher<SonarWalletState, Never> { Just(state).eraseToAnyPublisher() }

    func send(
        destination: String,
        amountSats: Int64,
        note: String?,
        feeFromAmount: Bool,
        maxFeeSats: Int64?
    ) async throws -> SonarWalletPayment {
        sendCalls += 1
        throw UnconfiguredWallet.WalletError.notConfigured
    }

    func createOffer() async throws -> String { "lno1armed" }
}

@MainActor
@Suite(.serialized)
struct PaymentOfferFreshnessTests {
    private static let me = "npub1ownaccount"
    private static let peer = "npub1peeraccount"
    private static let cutover = MarmotService.SonarDescriptor.paymentOfferCutover

    private static func descriptor(offer: String?, publishedAt: Date) -> MarmotService.SonarDescriptor {
        MarmotService.SonarDescriptor(
            schema: 2, calls: true, media: ["voice", "video"], signaling: ["marmot"],
            transports: ["iroh"], callIdentity: "iroh-hkdf-sonar-call-iroh-v1",
            bolt12Offer: offer, paymentReceipts: ["sonar.payment.receipt.v1"],
            publishedAt: publishedAt
        )
    }

    private static func legacy() -> MarmotService.SonarDescriptor {
        descriptor(offer: "lno1pqpsrplegacy", publishedAt: cutover.addingTimeInterval(-13 * 86_400))
    }

    private static func current() -> MarmotService.SonarDescriptor {
        descriptor(offer: "lno1pgqpp5current", publishedAt: cutover.addingTimeInterval(7 * 86_400))
    }

    /// A store with one White Noise chat with `peer`, whose descriptor is cached.
    private static func store(
        descriptor: MarmotService.SonarDescriptor,
        wallet: SonarWalletProviding = UnconfiguredWallet()
    ) -> (SonarAppStore, String, () -> Void) {
        let (store, cleanup) = makeIsolatedSonarAppStore(wallet: wallet)
        store.marmot.npub = me
        store.marmot.groups = [MarmotService.MarmotGroup(id: "g1", name: "", memberNpubs: [me, peer])]
        store.marmot.sonarDescriptorsByNpub[peer] = descriptor
        return (store, SonarAppStore.marmotIDPrefix + "g1", cleanup)
    }

    @Test
    func anOfferPublishedBeforeTheWalletSwitchIsLegacy() {
        #expect(Self.legacy().hasLegacyPaymentOffer)
        #expect(Self.descriptor(offer: "lno1x", publishedAt: Self.cutover.addingTimeInterval(-1)).hasLegacyPaymentOffer)
        #expect(!Self.current().hasLegacyPaymentOffer)
        #expect(!Self.descriptor(offer: "lno1x", publishedAt: Self.cutover).hasLegacyPaymentOffer)
        #expect(!Self.descriptor(offer: nil, publishedAt: .distantPast).hasLegacyPaymentOffer)
    }

    @Test
    func theSheetDoesNotOpenOnAnOfferTheRelaysStillHoldFromTheOldWallet() async {
        let (store, chatId, cleanup) = Self.store(descriptor: Self.legacy())
        defer { cleanup() }
        #expect(store.paymentCapable(chatId), "the row still shows: the message explains")
        let message = await store.paymentDetailsUnavailableMessage(chatId)
        #expect(message == SonarAppStore.legacyPaymentOfferMessage)
    }

    @Test
    func theSheetOpensOnACurrentOffer() async {
        let (store, chatId, cleanup) = Self.store(descriptor: Self.current())
        defer { cleanup() }
        let message = await store.paymentDetailsUnavailableMessage(chatId)
        #expect(message == nil)
    }

    @Test
    func aSendToALegacyOfferIsRefusedBeforeTheWalletAndLeavesNoPendingRow() async {
        let wallet = ArmedWallet()
        let (store, chatId, cleanup) = Self.store(descriptor: Self.legacy(), wallet: wallet)
        defer { cleanup() }
        let recordedBefore = store.paymentActivityLedger.activities(peerKey: chatId).count
        let message = await store.sendPay(chatId, sats: 1_000, maxFeeSats: nil)
        #expect(message == SonarAppStore.legacyPaymentOfferMessage)
        #expect(wallet.sendCalls == 0, "nothing reaches the wallet")
        #expect(
            store.paymentActivityLedger.activities(peerKey: chatId).count == recordedBefore,
            "no Sending bubble for a payment that never started"
        )
    }

    @Test
    func thePickerLeavesOutAContactWithOnlyALegacyOffer() {
        let (legacyStore, _, cleanupLegacy) = Self.store(descriptor: Self.legacy())
        defer { cleanupLegacy() }
        #expect(legacyStore.payableContacts.isEmpty)

        let (currentStore, chatId, cleanupCurrent) = Self.store(descriptor: Self.current())
        defer { cleanupCurrent() }
        #expect(currentStore.payableContacts.map(\.id) == [chatId])
    }
}
