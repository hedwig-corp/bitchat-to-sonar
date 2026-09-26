//
// CashuWalletServiceTests.swift
// bitchatTests
//
// Pins the host-side money rules of the Cashu wallet (`CashuWalletService`,
// `CashuWallet`, `SonarWalletPaymentReconciler`) against a fake FFI wallet:
// threading, offline open, offer stability, Pending handling, typed
// insufficient funds, and the consented fee ceiling (the fee the pay sheet
// showed is the most a send pays; `Try again` re-asks with the new fee).
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Combine
import Foundation
import SonarCore
import XCTest
@testable import Sonar

@MainActor
final class CashuWalletServiceTests: XCTestCase {
    private var base: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        base = try CashuTestFixtures.tempDirectory("service")
        (defaults, suite) = CashuTestFixtures.defaults()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: Threading

    /// Every FFI call — construct, listener, offer, connect, sync, balance,
    /// prepare, send, lookup, disconnect, wipe — runs off the main thread.
    func testFFIIsNeverCalledOnTheMainThread() async throws {
        let native = FakeCashuNative()
        native.confirmedSats = 5_000
        native.feeReserve = 2
        let service = CashuTestFixtures.service(native: native, base: base, defaults: defaults)

        await service.open(nsec: CashuTestFixtures.nsecA)
        await waitUntil { service.connectivity == .online && service.balance?.isLive == true }
        _ = try await service.send(destination: "lno1payee", amountSats: 100, note: "t", feeFromAmount: false, maxFeeSats: nil)
        _ = await service.lookupPayment(id: "quote-1")
        _ = try await service.receiveInvoice(amountSats: 21, description: nil)
        service.setForeground(false)
        await waitUntil { native.count("disconnect") >= 1 }
        let wiped = await service.wipeAll()
        XCTAssertTrue(wiped)

        let names = Set(native.calls.map(\.name))
        for expected in ["construct", "setListener", "receiveOffer", "connect", "sync", "balance",
                         "prepareSend", "send", "lookupPayment", "receiveInvoice", "disconnect",
                         "clearListener", "wipeLocalStorage"] {
            XCTAssertTrue(names.contains(expected), "\(expected) was never called")
        }
        XCTAssertEqual(native.mainThreadCalls, [], "FFI calls ran on the main thread")
    }

    // MARK: Offline open

    /// The mint is unreachable, but the offer already exists on disk: open
    /// publishes it without a connect, and the service reports offline.
    func testOfflineOpenPublishesTheOfferFromDisk() async throws {
        let native = FakeCashuNative()
        native.connectError = WalletFfiError.Network(reason: "no route")
        native.offer = "lno1fromdisk"
        let service = CashuTestFixtures.service(native: native, base: base, defaults: defaults)
        let wallet = CashuWallet(keychain: keychainWith(CashuTestFixtures.nsecA), service: service)

        wallet.start()
        await waitUntil { service.connectivity == .offline }
        XCTAssertEqual(wallet.cachedReceiveOffer, "lno1fromdisk")
        XCTAssertEqual(service.receiveOffer, "lno1fromdisk")
        XCTAssertEqual(defaults.string(forKey: CashuWalletService.offerKey(CashuTestFixtures.accountIdA)), "lno1fromdisk")
        await service.releaseQuietly()
    }

    /// Nothing on disk answers (first offer not created yet) and the mint is
    /// down: the per-account cached offer from the last run is still
    /// published at open, before any FFI call answers.
    func testOfflineOpenPublishesTheCachedOffer() async throws {
        defaults.set("lno1cached", forKey: CashuWalletService.offerKey(CashuTestFixtures.accountIdA))
        defaults.set(
            ["confirmed": NSNumber(value: 4_200), "pendingReceive": NSNumber(value: 0), "pendingSend": NSNumber(value: 0)],
            forKey: CashuWalletService.balanceKey(CashuTestFixtures.accountIdA)
        )
        let native = FakeCashuNative()
        native.connectError = WalletFfiError.Timeout
        native.offer = nil
        let service = CashuTestFixtures.service(native: native, base: base, defaults: defaults)
        let wallet = CashuWallet(keychain: keychainWith(CashuTestFixtures.nsecA), service: service)

        wallet.start()
        await waitUntil { service.accountId != nil }
        XCTAssertEqual(wallet.cachedReceiveOffer, "lno1cached")
        XCTAssertEqual(wallet.state, .ready(balanceSats: 4_200), "cached balance shown until the mint answers")
        XCTAssertEqual(wallet.balanceDetail?.isLive, false)
        await waitUntil { service.connectivity == .offline }
        XCTAssertEqual(wallet.cachedReceiveOffer, "lno1cached", "an offline failure must not unpublish the offer")
        await service.releaseQuietly()
    }

    // MARK: Offer stability

    /// Connect, sync and repeated refreshes keep ONE offer: the publisher the
    /// store uses to republish the descriptor / re-claim the handle fires once.
    func testOfferIsStableAcrossRefreshes() async throws {
        let native = FakeCashuNative()
        native.offer = "lno1stable"
        let service = CashuTestFixtures.service(native: native, base: base, defaults: defaults)
        let wallet = CashuWallet(keychain: keychainWith(CashuTestFixtures.nsecA), service: service)
        var published: [String?] = []
        let sub = wallet.receiveOfferPublisher.sink { published.append($0) }
        defer { sub.cancel() }

        wallet.start()
        await waitUntil { service.connectivity == .online }
        await service.refreshOffer()
        native.emit(.synced)
        native.emit(.connected)
        try await Task.sleep(nanoseconds: 200_000_000)
        await service.refreshOffer()

        XCTAssertEqual(published.compactMap { $0 }, ["lno1stable"])
        XCTAssertGreaterThanOrEqual(native.count("receiveOffer"), 3)
        let offer = try await wallet.createOffer()
        XCTAssertEqual(offer, "lno1stable")
        await service.releaseQuietly()
    }

    // MARK: Pending

    /// A send the mint answers `Pending` is surfaced as pending (not failed),
    /// and the later `PaymentSent(Complete)` event for the SAME id completes
    /// the activity row — with no second send and no second quote.
    func testPendingSendIsCompletedByTheLaterEventWithoutASecondSend() async throws {
        let native = FakeCashuNative()
        native.confirmedSats = 10_000
        native.feeReserve = 3
        native.sendStatus = .pending
        let service = CashuTestFixtures.service(native: native, base: base, defaults: defaults)
        let wallet = CashuWallet(keychain: keychainWith(CashuTestFixtures.nsecA), service: service)
        let (ledger, ledgerSuite) = freshLedger()
        defer { UserDefaults(suiteName: ledgerSuite)?.removePersistentDomain(forName: ledgerSuite) }
        var receipts = Set<String>()
        let updates = UpdateLog()
        let stream = wallet.paymentUpdates()
        let updateTask = Task { @MainActor in
            for await update in stream { updates.items.append(update) }
        }
        defer { updateTask.cancel() }

        wallet.start()
        await waitUntil { service.connectivity == .online }
        ledger.recordPending(chatActivity(id: "act-1", sats: 2_100))

        // The store's send path: wallet.send, then the reconciler.
        let result = try await wallet.send(destination: "lno1peer", amountSats: 2_100, note: "Sonar payment act-1", feeFromAmount: false, maxFeeSats: nil)
        XCTAssertEqual(result.status, .pending)
        let first = SonarWalletPaymentReconciler.applySendResult(
            result, activityId: "act-1", ledger: ledger, hasReceipt: { receipts.contains($0) }
        )
        XCTAssertEqual(first, .pending(activityId: "act-1"))
        XCTAssertEqual(ledger.entries["act-1"]?.status, .pending, "pending must not be recorded as failed")
        XCTAssertEqual(ledger.entries["act-1"]?.walletPaymentId, result.id)

        // Later: the wallet's watcher reports the outcome for the same id.
        let preimage = String(repeating: "ab", count: 32)
        native.emit(.paymentSent(payment: WalletPayment(
            id: result.id, incoming: false, amountSats: 2_100, feesSats: 1,
            timestampSecs: 1_800_000_100, status: .complete, preimage: preimage, note: nil
        )))
        await waitUntil { updates.items.contains { $0.id == result.id && $0.status == .complete } }
        let completion = updates.items.last { $0.id == result.id }!
        let second = SonarWalletPaymentReconciler.applyUpdate(completion, ledger: ledger, hasReceipt: { receipts.contains($0) })
        XCTAssertEqual(second, .paid(activityId: "act-1", receiptDue: true), "PAY + PAYDONE are owed now")
        XCTAssertEqual(ledger.entries["act-1"]?.status, .paid)
        XCTAssertEqual(ledger.entries["act-1"]?.preimage, preimage, "PAYDONE carries the preimage")

        // The receipt is recorded; a repeated event is a no-op.
        receipts.insert("act-1")
        XCTAssertEqual(
            SonarWalletPaymentReconciler.applyUpdate(completion, ledger: ledger, hasReceipt: { receipts.contains($0) }),
            .none
        )
        XCTAssertEqual(native.count("send"), 1, "a Pending send must never be sent again")
        XCTAssertEqual(native.count("prepareSend"), 1, "no second quote either")
        XCTAssertEqual(wallet.latestPaymentUpdate(id: result.id)?.status, .complete)
        await service.releaseQuietly()
    }

    /// A send the wallet reported failed, whose melt the mint then paid (an
    /// ambiguous confirm): the later Complete for the same wallet payment
    /// settles the row as paid and owes the chat receipt; the row must not
    /// keep saying "you were not charged". A later failure never un-pays it.
    func testASendReportedFailedIsPaidByALaterCompleteForItsWalletPayment() {
        let (ledger, ledgerSuite) = freshLedger()
        defer { UserDefaults(suiteName: ledgerSuite)?.removePersistentDomain(forName: ledgerSuite) }
        var receipts = Set<String>()
        ledger.recordPending(chatActivity(id: "act-f", sats: 900))
        func payment(_ id: String, _ status: SonarWalletPayment.Status) -> SonarWalletPayment {
            SonarWalletPayment(
                id: id, amountSats: 900, isIncoming: false, timestamp: Date(), note: nil,
                feesSats: 1, preimage: status == .complete ? String(repeating: "cd", count: 32) : nil,
                status: status
            )
        }

        let first = SonarWalletPaymentReconciler.applySendResult(
            payment("quote-f", .failed), activityId: "act-f", ledger: ledger, hasReceipt: { receipts.contains($0) }
        )
        XCTAssertEqual(first, .failed(activityId: "act-f"))
        XCTAssertEqual(ledger.entries["act-f"]?.walletPaymentId, "quote-f", "the failed payment stays findable")

        XCTAssertEqual(
            SonarWalletPaymentReconciler.applyUpdate(payment("quote-other", .complete), ledger: ledger, hasReceipt: { receipts.contains($0) }),
            .none,
            "another payment's outcome"
        )
        let late = SonarWalletPaymentReconciler.applyUpdate(
            payment("quote-f", .complete), ledger: ledger, hasReceipt: { receipts.contains($0) }
        )
        XCTAssertEqual(late, .paid(activityId: "act-f", receiptDue: true), "PAY + PAYDONE are owed now")
        XCTAssertEqual(ledger.entries["act-f"]?.status, .paid)
        XCTAssertNil(ledger.entries["act-f"]?.failure)

        receipts.insert("act-f")
        XCTAssertEqual(
            SonarWalletPaymentReconciler.applyUpdate(payment("quote-f", .failed), ledger: ledger, hasReceipt: { receipts.contains($0) }),
            .none
        )
        XCTAssertEqual(ledger.entries["act-f"]?.status, .paid, "paid is final")
    }

    /// The outcome event can land BEFORE the send's own Pending result is
    /// handled; the wallet must report the terminal state for that id, never
    /// downgrade it back to Pending.
    func testLatePendingResultNeverDowngradesAnEarlierOutcome() async throws {
        let native = FakeCashuNative()
        native.confirmedSats = 10_000
        let service = CashuTestFixtures.service(native: native, base: base, defaults: defaults)
        await service.open(nsec: CashuTestFixtures.nsecA)
        await waitUntil { service.connectivity == .online }

        native.emit(.paymentSent(payment: WalletPayment(
            id: "quote-1", incoming: false, amountSats: 500, feesSats: 0,
            timestampSecs: 1, status: .complete, preimage: nil, note: nil
        )))
        await waitUntil { service.latestUpdate(id: "quote-1")?.status == .complete }
        native.sendStatus = .pending
        let result = try await service.send(destination: "lno1peer", amountSats: 500, note: "", feeFromAmount: false, maxFeeSats: nil)
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(service.latestUpdate(id: "quote-1")?.status, .complete)
        await service.releaseQuietly()
    }

    // MARK: Insufficient funds

    /// amount + the mint's REAL fee reserve > balance ⇒ the typed error with
    /// the existing "amount + fee exceeds balance" copy, and nothing is sent.
    func testInsufficientFundsIsTypedFromTheQuotedFee() async throws {
        let native = FakeCashuNative()
        native.confirmedSats = 1_000
        native.feeReserve = 20
        let service = CashuTestFixtures.service(native: native, base: base, defaults: defaults)
        await service.open(nsec: CashuTestFixtures.nsecA)
        await waitUntil { service.connectivity == .online }

        do {
            _ = try await service.send(destination: "lno1peer", amountSats: 990, note: "", feeFromAmount: false, maxFeeSats: nil)
            XCTFail("expected insufficient funds")
        } catch let error as CashuWalletError {
            XCTAssertEqual(error, .insufficientFunds(amountSats: 990, feeSats: 20, balanceSats: 1_000))
            XCTAssertEqual(
                error.errorDescription,
                SonarSpendableBalance.insufficientMessage(amountSats: 990, feeSats: 20, balanceSats: 1_000)
            )
        }
        XCTAssertEqual(native.count("send"), 0)
        await service.releaseQuietly()
    }

    /// The FFI's own `InsufficientFunds` stays typed across the seam.
    func testFfiInsufficientFundsStaysTyped() async throws {
        let native = FakeCashuNative()
        native.confirmedSats = 10_000
        native.sendError = WalletFfiError.InsufficientFunds
        let service = CashuTestFixtures.service(native: native, base: base, defaults: defaults)
        await service.open(nsec: CashuTestFixtures.nsecA)
        await waitUntil { service.connectivity == .online }

        do {
            _ = try await service.send(destination: "lno1peer", amountSats: 100, note: "", feeFromAmount: false, maxFeeSats: nil)
            XCTFail("expected insufficient funds")
        } catch let error as CashuWalletError {
            XCTAssertEqual(error, .insufficientFunds(amountSats: nil, feeSats: nil, balanceSats: nil))
        }
        XCTAssertEqual(CashuWalletError(WalletFfiError.Network(reason: "x")), .mintOffline)
        XCTAssertEqual(CashuWalletError(WalletFfiError.NotConnected), .mintOffline)
        XCTAssertEqual(CashuWalletError(WalletFfiError.Timeout), .mintOffline)
        await service.releaseQuietly()
    }

    /// Cashu `Max`: prepare at the full balance, subtract the quoted fee
    /// reserve, prepare again — the payee gets balance − fee.
    func testMaxTakesTheFeeOutOfTheAmount() async throws {
        let native = FakeCashuNative()
        native.confirmedSats = 1_000
        native.feeReserve = 20
        let service = CashuTestFixtures.service(native: native, base: base, defaults: defaults)
        await service.open(nsec: CashuTestFixtures.nsecA)
        await waitUntil { service.connectivity == .online }

        let paid = try await service.send(destination: "lno1peer", amountSats: 1_000, note: "", feeFromAmount: true, maxFeeSats: nil)
        XCTAssertEqual(native.preparedAmounts, [1_000, 980])
        XCTAssertEqual(native.sentPrepared.map(\.amountSats), [980])
        XCTAssertEqual(paid.amountSats, 980)
        await service.releaseQuietly()
    }

    // MARK: The fee the user consented to (maintainer review, #614)

    private let feeChanged40 = "The network fee is now up to \(sonarFormatSats(40)). Nothing was sent — try again to pay it."

    /// The sheet showed "up to 3 sats"; by the time Send runs, the mint's fee
    /// reserve for the fresh quote is 40. The send must refuse with the NEW
    /// fee and never reach the spending call, even though the balance covers it.
    func testAFeeAboveTheConsentedCeilingIsRefusedWithTheNewFeeAndNothingIsSent() async throws {
        let native = FakeCashuNative()
        native.confirmedSats = 10_000
        native.feeReserve = 40
        let service = CashuTestFixtures.service(native: native, base: base, defaults: defaults)
        await service.open(nsec: CashuTestFixtures.nsecA)
        await waitUntil { service.connectivity == .online }

        do {
            _ = try await service.send(destination: "lno1peer", amountSats: 500, note: "", feeFromAmount: false, maxFeeSats: 3)
            XCTFail("expected the fee change to be refused")
        } catch let error as CashuWalletError {
            XCTAssertEqual(error, .feeChanged(feeSats: 40))
            XCTAssertEqual(error.errorDescription, feeChanged40)
        }
        XCTAssertEqual(native.count("send"), 0, "nothing is spent above the consented fee")
        await service.releaseQuietly()
    }

    func testAFeeAtOrBelowTheConsentedCeilingPays() async throws {
        let native = FakeCashuNative()
        native.confirmedSats = 10_000
        native.feeReserve = 3
        let service = CashuTestFixtures.service(native: native, base: base, defaults: defaults)
        await service.open(nsec: CashuTestFixtures.nsecA)
        await waitUntil { service.connectivity == .online }

        _ = try await service.send(destination: "lno1peer", amountSats: 500, note: "", feeFromAmount: false, maxFeeSats: 3)
        _ = try await service.send(destination: "lno1peer", amountSats: 500, note: "", feeFromAmount: false, maxFeeSats: 10)
        XCTAssertEqual(native.count("send"), 2, "a fee at or below what was shown pays")
        await service.releaseQuietly()
    }

    /// No fee was on screen (quote failed / hidden): ceiling 0, so any fee
    /// needs a fresh consent — and a free payment needs none.
    func testAZeroCeilingRefusesAnyFee() async throws {
        let native = FakeCashuNative()
        native.confirmedSats = 10_000
        native.feeReserve = 1
        let service = CashuTestFixtures.service(native: native, base: base, defaults: defaults)
        await service.open(nsec: CashuTestFixtures.nsecA)
        await waitUntil { service.connectivity == .online }

        do {
            _ = try await service.send(destination: "lno1peer", amountSats: 500, note: "", feeFromAmount: false, maxFeeSats: 0)
            XCTFail("expected the fee change to be refused")
        } catch let error as CashuWalletError {
            XCTAssertEqual(error, .feeChanged(feeSats: 1))
        }
        XCTAssertEqual(native.count("send"), 0)
        native.feeReserve = 0
        _ = try await service.send(destination: "lno1peer", amountSats: 500, note: "", feeFromAmount: false, maxFeeSats: 0)
        XCTAssertEqual(native.count("send"), 1)
        await service.releaseQuietly()
    }

    /// Max: the ceiling applies to the fee of the RE-prepared quote that is
    /// actually paid.
    func testMaxChecksTheCeilingAgainstTheFeeItWouldPay() async throws {
        let native = FakeCashuNative()
        native.confirmedSats = 1_000
        native.feeReserve = 25
        let service = CashuTestFixtures.service(native: native, base: base, defaults: defaults)
        await service.open(nsec: CashuTestFixtures.nsecA)
        await waitUntil { service.connectivity == .online }

        do {
            _ = try await service.send(destination: "lno1peer", amountSats: 1_000, note: "", feeFromAmount: true, maxFeeSats: 5)
            XCTFail("expected the fee change to be refused")
        } catch let error as CashuWalletError {
            XCTAssertEqual(error, .feeChanged(feeSats: 25))
        }
        XCTAssertEqual(native.count("send"), 0)
        let paid = try await service.send(destination: "lno1peer", amountSats: 1_000, note: "", feeFromAmount: true, maxFeeSats: 25)
        XCTAssertEqual(paid.amountSats, 975)
        XCTAssertEqual(native.sentPrepared.map(\.amountSats), [975])
        await service.releaseQuietly()
    }

    /// The REAL store call sites: a destination payment begun with the fee the
    /// sheet showed (3) fails with nothing sent when the mint now wants 40;
    /// the status screen states the new fee; `Try again` (tapped after
    /// reading it) holds the retry to THAT fee — a further rise is refused
    /// again — and the fee the user read is paid.
    func testADestinationPaymentAboveTheConsentedFeeFailsAndTryAgainPaysTheNewFee() async throws {
        let native = FakeCashuNative()
        native.confirmedSats = 10_000
        native.feeReserve = 40
        let service = CashuTestFixtures.service(native: native, base: base, defaults: defaults)
        let wallet = CashuWallet(keychain: MockKeychain(), service: service)
        await service.open(nsec: CashuTestFixtures.nsecA)
        // `.online` is published before the first balance read lands, and the
        // store refuses a destination payment until the wallet is `.ready`.
        await waitUntil { service.connectivity == .online && service.balance?.isLive == true }
        let (store, cleanup) = makeIsolatedSonarAppStore(wallet: wallet)
        defer { cleanup() }

        let id = try XCTUnwrap(store.beginDestinationPayment("lno1destination", sats: 500, displayName: "Dest", maxFeeSats: 3))
        await waitUntil { store.paymentActivityLedger.entries[id]?.status == .failed }
        XCTAssertEqual(native.count("send"), 0, "nothing is spent above the fee the user saw")
        XCTAssertEqual(store.paymentActivityLedger.entries[id]?.failure, feeChanged40)
        let status = try XCTUnwrap(store.paymentStatus(id))
        XCTAssertEqual(status.phase, .failedSafe)
        XCTAssertEqual(status.feeChangedSats, 40)
        XCTAssertEqual(SNPayStatusCopy.hint(for: status), feeChanged40, "the status screen states the new fee")
        XCTAssertTrue(status.canRetry)

        native.feeReserve = 41
        let retry1 = try XCTUnwrap(store.retryDestinationPayment(id))
        await waitUntil { store.paymentActivityLedger.entries[retry1]?.status == .failed }
        XCTAssertEqual(native.count("send"), 0, "the retry's ceiling is the 40 the user read, not anything")
        XCTAssertEqual(store.paymentStatus(retry1)?.feeChangedSats, 41)

        let retry2 = try XCTUnwrap(store.retryDestinationPayment(retry1))
        await waitUntil { store.paymentActivityLedger.entries[retry2]?.status == .paid }
        XCTAssertEqual(native.count("send"), 1)
        XCTAssertEqual(native.sentPrepared.map(\.amountSats), [500])
        XCTAssertNil(store.paymentStatus(retry2)?.feeChangedSats)
        await service.releaseQuietly()
    }

    /// A fee-inclusive `Max` refused for its fee stays a `Max` on `Try again`
    /// (else it could never fit the balance).
    func testTryAgainAfterAFeeChangeKeepsAMaxSendAMaxSend() async throws {
        let native = FakeCashuNative()
        native.confirmedSats = 1_000
        native.feeReserve = 20
        let service = CashuTestFixtures.service(native: native, base: base, defaults: defaults)
        let wallet = CashuWallet(keychain: MockKeychain(), service: service)
        await service.open(nsec: CashuTestFixtures.nsecA)
        // `.online` is published before the first balance read lands, and the
        // store refuses a destination payment until the wallet is `.ready`.
        await waitUntil { service.connectivity == .online && service.balance?.isLive == true }
        let (store, cleanup) = makeIsolatedSonarAppStore(wallet: wallet)
        defer { cleanup() }

        let id = try XCTUnwrap(store.beginDestinationPayment(
            "lno1destination", sats: 1_000, displayName: "Dest", maxFeeSats: 5, feeFromAmount: true
        ))
        await waitUntil { store.paymentActivityLedger.entries[id]?.status == .failed }
        XCTAssertEqual(native.count("send"), 0)
        let retry = try XCTUnwrap(store.retryDestinationPayment(id))
        await waitUntil { store.paymentActivityLedger.entries[retry]?.status == .paid }
        XCTAssertEqual(native.sentPrepared.map(\.amountSats), [980], "the fee still comes out of the amount")
        await service.releaseQuietly()
    }

    // MARK: Helpers

    private func keychainWith(_ nsec: String) -> MockKeychain {
        let keychain = MockKeychain()
        _ = keychain.saveIdentityKey(Data(nsec.utf8), forKey: SonarAccountKeyExport.marmotNsecKey)
        return keychain
    }

    private func freshLedger() -> (SonarPaymentActivityLedger, String) {
        let suite = "CashuWalletServiceTests.ledger.\(UUID().uuidString)"
        return (SonarPaymentActivityLedger(defaults: UserDefaults(suiteName: suite)!), suite)
    }

    private func chatActivity(id: String, sats: Int64) -> SonarPaymentActivity {
        SonarPaymentActivity(
            id: id, kind: .sonarDirect, peerKey: "peer-1", peerName: "Alice",
            direction: .outgoing, sats: sats, via: "internet", createdAt: Date(),
            destinationHash: "h", status: .pending
        )
    }
}

/// Collects updates from the wallet stream (a reference, so the collecting
/// task and the test body share it on the main actor).
@MainActor
private final class UpdateLog {
    var items: [SonarWalletPayment] = []
}

private extension CashuWalletService {
    /// Test teardown: release without caring about the in-flight guard.
    func releaseQuietly() async {
        try? await release()
    }
}
