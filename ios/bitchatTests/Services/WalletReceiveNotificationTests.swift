//
// WalletReceiveNotificationTests.swift
// bitchatTests
//
// A payment from outside Sonar (another wallet paying the receive offer or a
// one-time invoice) has no chat line, so nothing announced it: the money just
// appeared in the wallet. These drive the real store with a wallet that
// reports payments.
//

import Combine
import XCTest
@testable import Sonar

/// A wallet whose payment updates the test scripts.
private final class ScriptedPaymentsWallet: SonarWalletProviding {
    private var continuation: AsyncStream<SonarWalletPayment>.Continuation?
    private lazy var stream = AsyncStream<SonarWalletPayment> { self.continuation = $0 }

    var state: SonarWalletState { .ready(balanceSats: 0) }
    var statePublisher: AnyPublisher<SonarWalletState, Never> {
        Just(state).eraseToAnyPublisher()
    }

    func send(destination: String, amountSats: Int64, note: String?, feeFromAmount: Bool, maxFeeSats: Int64?) async throws -> SonarWalletPayment {
        throw UnconfiguredWallet.WalletError.notConfigured
    }

    func createOffer() async throws -> String { "lno1scripted" }

    func paymentUpdates() -> AsyncStream<SonarWalletPayment> { stream }

    func emit(_ payment: SonarWalletPayment) {
        _ = stream
        continuation?.yield(payment)
    }
}

@MainActor
final class WalletReceiveNotificationTests: XCTestCase {
    private func payment(_ id: String, sats: Int64, incoming: Bool, status: SonarWalletPayment.Status) -> SonarWalletPayment {
        SonarWalletPayment(id: id, amountSats: sats, isIncoming: incoming, timestamp: Date(), note: nil, status: status)
    }

    func testAnOutsidePaymentIsAnnouncedOnceWhenItSettles() async throws {
        let wallet = ScriptedPaymentsWallet()
        let (store, cleanup) = makeIsolatedSonarAppStore(wallet: wallet)
        defer { cleanup() }
        var posted: [SonarLocalNotification] = []
        store.postLocalNotification = { posted.append($0) }
        store.walletReceiveGraceNanos = 100_000_000

        // The activity ledger persists in the test host's defaults: fresh ids
        // keep an earlier run's rows from reading as already announced.
        let run = UUID().uuidString
        wallet.emit(payment("\(run):rx", sats: 2_100, incoming: true, status: .complete))
        wallet.emit(payment("\(run):rx", sats: 2_100, incoming: true, status: .complete)) // a replay
        wallet.emit(payment("\(run):pending", sats: 40, incoming: true, status: .pending))
        wallet.emit(payment("\(run):tx", sats: 90, incoming: false, status: .complete))    // our own send

        let deadline = Date().addingTimeInterval(3)
        while store.paymentActivityLedger.entries["wallet-\(run):rx"] == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertNotNil(store.paymentActivityLedger.entries["wallet-\(run):rx"], "premise: the receive was recorded")
        XCTAssertEqual(posted.map(\.title), ["Payment received"], "exactly one banner, for the settled receive")
        XCTAssertEqual(posted.first?.body, "\(sonarFormatSats(2_100)) received.")
    }

    /// A chat ⚡PAY is announced by its chat line; the wallet cannot link the
    /// receive to it (the payer pays the public offer), so without pairing
    /// every chat payment raised a second "Payment received" banner.
    func testAChatPaymentIsAnnouncedByItsChatLineOnly() async throws {
        let wallet = ScriptedPaymentsWallet()
        let (store, cleanup) = makeIsolatedSonarAppStore(wallet: wallet)
        defer { cleanup() }
        var posted: [SonarLocalNotification] = []
        store.postLocalNotification = { posted.append($0) }
        store.walletReceiveGraceNanos = 300_000_000
        let run = UUID().uuidString
        let group = "group-\(run)"

        func until(_ what: String, _ done: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(3)
            while !done(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            XCTAssertTrue(done(), "premise: \(what)")
        }
        // ⚡PAY ids are hex (a UUID is): anything else is not a receipt.
        func chatPay(_ receipt: String, sats: Int64) async throws {
            store.marmot.messagesByGroup[group, default: []].append(MarmotService.MarmotMessage(
                id: "\(run)-m-\(receipt)",
                senderNpub: "npub1peer",
                content: SonarPayMessage.pay(id: "\(run)-\(receipt)", sats: sats).encoded(),
                createdAt: Date(),
                isMine: false,
                media: []
            ))
            try await until("⚡PAY \(receipt) recorded") { store.payLedger.entries["\(run)-\(receipt)"] != nil }
        }
        func receive(_ id: String, sats: Int64) async throws {
            wallet.emit(payment("\(run):\(id)", sats: sats, incoming: true, status: .complete))
            try await until("receive \(id) recorded") {
                store.paymentActivityLedger.entries["wallet-\(run):\(id)"] != nil
            }
        }

        // The chat line lands first, then the wallet mints the payment.
        try await chatPay("a1", sats: 210)
        try await receive("rx1", sats: 210)
        // The wallet sees the payment before the chat line arrives.
        try await receive("rx2", sats: 350)
        try await chatPay("a2", sats: 350)
        // A payment no chat line announced still gets its banner.
        try await receive("rx3", sats: 777)
        try await Task.sleep(nanoseconds: 900_000_000)

        XCTAssertEqual(
            posted.map(\.body),
            ["\(sonarFormatSats(777)) received."],
            "only the payment no chat line announced gets a wallet banner"
        )
    }

    func testAReceiptSilencesOneFreshReceiveOfItsAmountOnly() async throws {
        var now = Date()
        var announced: [String] = []
        let announcer = SonarReceiveAnnouncer(
            graceNanos: { 100_000_000 },
            now: { now },
            announce: { id, _ in announced.append(id) }
        )
        announcer.chatReceipt(id: "old", sats: 21, sentAt: now.addingTimeInterval(-SonarReceiveAnnouncer.lookback - 1))
        announcer.chatReceipt(id: "other", sats: 22, sentAt: now)
        announcer.chatReceipt(id: "twice", sats: 30, sentAt: now)
        announcer.chatReceipt(id: "twice", sats: 30, sentAt: now)
        announcer.chatReceipt(id: "aging", sats: 40, sentAt: now)
        announcer.walletReceive(paymentId: "p1", sats: 21)
        announcer.walletReceive(paymentId: "p2", sats: 30)
        announcer.walletReceive(paymentId: "p3", sats: 30)
        now = now.addingTimeInterval(SonarReceiveAnnouncer.lookback + 1)
        announcer.walletReceive(paymentId: "p4", sats: 40)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(announced.isEmpty, "each receive waits for its chat line first")
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(announced.sorted(), ["p1", "p3", "p4"])
    }

    func testTheBannerRespectsTheNotificationSettings() {
        var prefs = SonarLocalNotificationPrefs()
        prefs.showPaymentAmount = false
        XCTAssertEqual(
            SonarLocalNotificationRouter.walletReceive(paymentId: "q", sats: 5, prefs: prefs)?.body,
            "Open Sonar to view the payment."
        )
        prefs.enabled = false
        XCTAssertNil(SonarLocalNotificationRouter.walletReceive(paymentId: "q", sats: 5, prefs: prefs))
    }
}
