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

    /// Max on ecash that pays input fees is not one subtraction away. The
    /// figures are from #666 QA against cdk-mintd 0.18.1 (1000 ppk, 61
    /// proofs, BOLT12 offer). 1,530 sats quoted 95. 1,530 - 95 = 1,435 then
    /// quoted 97, two sats over the balance: the mint charges per output
    /// proof too, and 1,435 splits into more of them. 1,434 quoted 89 and
    /// paid. Max must pay an amount the fees allow, not refuse. Mirror of
    /// `CashuWalletEngineTest.maxStillPaysWhenTheReducedAmountQuotesAHigherFee`.
    func testMaxStillPaysWhenTheReducedAmountQuotesAHigherFee() async throws {
        let native = FakeCashuNative()
        native.confirmedSats = 1_530
        native.nextFees = [95, 97, 89]
        let service = CashuTestFixtures.service(native: native, base: base, defaults: defaults)
        await service.open(nsec: CashuTestFixtures.nsecA)
        await waitUntil { service.connectivity == .online }

        _ = try await service.send(destination: "lno1peer", amountSats: 1_530, note: "", feeFromAmount: true, maxFeeSats: 95)
        XCTAssertEqual(native.sentPrepared.count, 1, "exactly one payment")
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

    /// The incident's figures (2026-10-13): 12,027 sats with a 240-sat
    /// reserve from 12,287. The reserve alone fits; the mint's input fees on
    /// the ecash spent (now part of `feesSats`) do not. Refused up front with
    /// the real figures, nothing spent.
    func testTheWholeFeeNotJustTheReserveIsCheckedAgainstTheBalance() async throws {
        let native = FakeCashuNative()
        native.confirmedSats = 12_287
        native.feeReserve = 240 + 53
        let service = CashuTestFixtures.service(native: native, base: base, defaults: defaults)
        await service.open(nsec: CashuTestFixtures.nsecA)
        await waitUntil { service.connectivity == .online }

        do {
            _ = try await service.send(destination: "lnbc12027", amountSats: 12_027, note: "", feeFromAmount: false, maxFeeSats: 293)
            XCTFail("expected a shortfall")
        } catch let error as CashuWalletError {
            XCTAssertEqual(error, .insufficientFunds(amountSats: 12_027, feeSats: 293, balanceSats: 12_287))
        }
        XCTAssertEqual(native.count("send"), 0)
        await service.releaseQuietly()
    }

    /// The fee the user agreed to travels into the spending call.
    func testTheAgreedFeeTravelsIntoTheSpendingCall() async throws {
        let native = FakeCashuNative()
        native.confirmedSats = 10_000
        native.feeReserve = 3
        let service = CashuTestFixtures.service(native: native, base: base, defaults: defaults)
        await service.open(nsec: CashuTestFixtures.nsecA)
        await waitUntil { service.connectivity == .online }

        _ = try await service.send(destination: "lno1peer", amountSats: 500, note: "", feeFromAmount: false, maxFeeSats: 10)
        _ = try await service.send(destination: "lno1peer", amountSats: 500, note: "", feeFromAmount: false, maxFeeSats: nil)
        XCTAssertEqual(native.sentPrepared.map(\.feesSats), [10, nil], "no ceiling stays no ceiling")
        await service.releaseQuietly()
    }

    /// A quote that expired unsent is priced again, through every check, and
    /// the fresh quote pays — once.
    func testAQuoteThatExpiresUnsentIsRequotedAndTheFreshQuotePays() async throws {
        let native = FakeCashuNative()
        native.confirmedSats = 10_000
        native.feeReserve = 3
        native.sendErrors = [WalletFfiError.QuoteExpired]
        let service = CashuTestFixtures.service(native: native, base: base, defaults: defaults)
        await service.open(nsec: CashuTestFixtures.nsecA)
        await waitUntil { service.connectivity == .online }

        let paid = try await service.send(destination: "lno1peer", amountSats: 500, note: "", feeFromAmount: false, maxFeeSats: 3)
        XCTAssertEqual(paid.id, "quote-2", "the payment is the fresh quote's")
        XCTAssertEqual(native.preparedAmounts, [500, 500], "same amount")
        XCTAssertEqual(native.sentPrepared.map(\.quoteId), ["quote-1", "quote-2"])
        await service.releaseQuietly()
    }

    /// A fresh quote is held to the fee the user already agreed to.
    func testARequoteAboveTheAgreedFeeStopsWithTheNewFee() async throws {
        let native = FakeCashuNative()
        native.confirmedSats = 10_000
        native.nextFees = [3, 40]
        native.sendErrors = [WalletFfiError.QuoteExpired]
        let service = CashuTestFixtures.service(native: native, base: base, defaults: defaults)
        await service.open(nsec: CashuTestFixtures.nsecA)
        await waitUntil { service.connectivity == .online }

        do {
            _ = try await service.send(destination: "lno1peer", amountSats: 500, note: "", feeFromAmount: false, maxFeeSats: 3)
            XCTFail("expected the dearer fresh quote to be refused")
        } catch let error as CashuWalletError {
            XCTAssertEqual(error, .feeChanged(feeSats: 40))
        }
        XCTAssertEqual(native.count("send"), 1, "only the expired quote reached send")
        await service.releaseQuietly()
    }

    /// Re-quoting is bounded and ends in its own typed refusal.
    func testRequotingIsBoundedAndEndsInATypedQuoteExpired() async throws {
        let native = FakeCashuNative()
        native.confirmedSats = 10_000
        native.feeReserve = 3
        native.sendErrors = Array(repeating: WalletFfiError.QuoteExpired, count: 5)
        let service = CashuTestFixtures.service(native: native, base: base, defaults: defaults)
        await service.open(nsec: CashuTestFixtures.nsecA)
        await waitUntil { service.connectivity == .online }

        do {
            _ = try await service.send(destination: "lno1peer", amountSats: 500, note: "", feeFromAmount: false, maxFeeSats: 3)
            XCTFail("expected QuoteExpired")
        } catch let error as CashuWalletError {
            XCTAssertEqual(error, .quoteExpired)
            XCTAssertNotEqual(error.errorDescription, CashuWalletError.backend("x").errorDescription)
        }
        XCTAssertEqual(native.count("send"), 1 + CashuWalletService.maxRequotes)
        await service.releaseQuietly()
    }

    /// The core's two "nothing was sent" refusals map to their own typed
    /// errors, never to `.backend` ("Payment failed").
    func testQuoteExpiredAndFeeChangedMapToTheirTypedErrors() {
        XCTAssertEqual(CashuWalletError(WalletFfiError.FeeChanged(feesSats: 55)), .feeChanged(feeSats: 55))
        XCTAssertEqual(CashuWalletError(WalletFfiError.QuoteExpired), .quoteExpired)
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

    /// QA-165 on the status screen, through the REAL store call sites: 500
    /// sats plus a 40-sat fee on a 520-sat balance is refused before anything
    /// is sent, and the screen states the shortfall with its figures, not "No
    /// route", which blames the payee (Compose
    /// `aDestinationPaymentShortOfItsFeeStatesTheShortfallOnTheStatusScreen`).
    func testADestinationPaymentShortOfItsFeeStatesTheShortfallOnTheStatusScreen() async throws {
        let native = FakeCashuNative()
        native.confirmedSats = 520
        native.feeReserve = 40
        let service = CashuTestFixtures.service(native: native, base: base, defaults: defaults)
        let wallet = CashuWallet(keychain: MockKeychain(), service: service)
        await service.open(nsec: CashuTestFixtures.nsecA)
        await waitUntil { service.connectivity == .online && service.balance?.isLive == true }
        let (store, cleanup) = makeIsolatedSonarAppStore(wallet: wallet)
        defer { cleanup() }

        let id = try XCTUnwrap(store.beginDestinationPayment("lno1destination", sats: 500, displayName: "Dest", maxFeeSats: 40))
        await waitUntil { store.paymentActivityLedger.entries[id]?.status == .failed }
        XCTAssertEqual(native.count("send"), 0, "nothing is sent")
        let shortfall = SonarSpendableBalance.insufficientMessage(amountSats: 500, feeSats: 40, balanceSats: 520)
        XCTAssertEqual(store.paymentActivityLedger.entries[id]?.failure, shortfall)
        let status = try XCTUnwrap(store.paymentStatus(id))
        XCTAssertEqual(status.phase, .failedSafe)
        XCTAssertEqual(status.insufficientFundsText, shortfall)
        XCTAssertNil(status.feeChangedSats)
        XCTAssertEqual(SNPayStatusCopy.hint(for: status), shortfall, "the status screen states the shortfall")

        // A send that then fits pays, and its row carries no shortfall.
        native.confirmedSats = 10_000
        let retry = try XCTUnwrap(store.retryDestinationPayment(id))
        await waitUntil { store.paymentActivityLedger.entries[retry]?.status == .paid }
        XCTAssertNil(store.paymentStatus(retry)?.insufficientFundsText)
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

    /// An invoice with no amount is paid with the amount typed on the sheet:
    /// the Cashu wallet quotes it as an amountless melt, and `Max` works on
    /// it too (QA-165's Max step). Only the old wallet refuses one — Breez
    /// cannot set an invoice's amount. Mirrors Compose
    /// `WalletAppStateTest.anAmountlessInvoiceIsPaidWithTheTypedAmount`.
    func testAnAmountlessInvoiceIsPaidWithTheTypedAmount() async throws {
        let native = FakeCashuNative()
        native.confirmedSats = 10_000
        native.feeReserve = 9
        let service = CashuTestFixtures.service(native: native, base: base, defaults: defaults)
        let wallet = CashuWallet(keychain: MockKeychain(), service: service)
        await service.open(nsec: CashuTestFixtures.nsecA)
        await waitUntil { service.connectivity == .online && service.balance?.isLive == true }
        let (store, cleanup) = makeIsolatedSonarAppStore(wallet: wallet)
        defer { cleanup() }
        let invoice = "lnbc1pamountlessinvoice"

        let id = try XCTUnwrap(store.beginDestinationPayment(invoice, sats: 700, displayName: "Invoice", maxFeeSats: 9))
        await waitUntil { store.paymentActivityLedger.entries[id]?.status == .paid }
        XCTAssertEqual(native.preparedAmounts, [700])
        XCTAssertEqual(native.sentPrepared.map(\.amountSats), [700])

        let max = try XCTUnwrap(store.beginDestinationPayment(
            invoice, sats: 10_000, displayName: "Invoice", maxFeeSats: 9, feeFromAmount: true
        ))
        await waitUntil { store.paymentActivityLedger.entries[max]?.status == .paid }
        XCTAssertEqual(native.sentPrepared.map(\.amountSats), [700, 9_991], "Max takes the fee out of the balance")

        XCTAssertNil(store.beginDestinationPayment(invoice, sats: 700, displayName: "Invoice", maxFeeSats: nil, source: .legacy))
        XCTAssertEqual(store.toast, SonarAppStore.amountlessInvoiceMessage)
        XCTAssertEqual(native.sentPrepared.count, 2, "the old wallet is refused before anything is sent")
        await service.releaseQuietly()
    }

    // MARK: Unify nearby sends

    /// A store whose Cashu wallet is ready, and a Unify receiver serving `uri`.
    private func unifyStore(
        _ native: FakeCashuNative,
        serving uri: String
    ) async -> (SonarAppStore, CashuWalletService, () -> Void) {
        let service = CashuTestFixtures.service(native: native, base: base, defaults: defaults)
        let wallet = CashuWallet(keychain: MockKeychain(), service: service)
        await service.open(nsec: CashuTestFixtures.nsecA)
        await waitUntil { service.connectivity == .online && service.balance?.isLive == true }
        let (store, cleanup) = makeIsolatedSonarAppStore(wallet: wallet)
        await waitUntil {
            if case .ready = store.walletState { return true }
            return false
        }
        store.unifyPaymentURIReader = { _ in uri }
        return (store, service, cleanup)
    }

    private func waitForUnifyPhase(
        _ store: SonarAppStore,
        _ matches: @escaping (SonarAppStore.UnifyPayPhase) -> Bool
    ) async {
        await waitUntil { store.unifyPay.map { matches($0.phase) } ?? false }
    }

    /// A Unify receiver's request can name its own amount. It used to be paid
    /// the moment it was read over Bluetooth, with the amount never on screen.
    /// It now waits on a confirm step, and Send pays exactly that request.
    func testAUnifyRequestThatNamesItsAmountIsPaidOnlyAfterConfirming() async throws {
        let native = FakeCashuNative()
        native.confirmedSats = 10_000
        native.feeReserve = 2
        let (store, service, cleanup) = await unifyStore(
            native, serving: "bitcoin:?lno=lno1unifyoffer&amount=0.000005"
        )
        defer { cleanup() }

        store.sendSatsToUnify("unify:peer-1")
        await waitForUnifyPhase(store) { if case .confirm = $0 { return true }; return false }
        XCTAssertEqual(store.unifyPay?.phase, .confirm(destination: "lno1unifyoffer", sats: 500))
        XCTAssertEqual(native.count("send"), 0, "nothing is paid before Send")
        let quote = try XCTUnwrap(store.feeQuoter(destination: "lno1unifyoffer"))
        let fee = try await quote(500)
        XCTAssertEqual(fee, 2, "the confirm step prices this request")

        store.confirmUnifyAmount("unify:peer-1", destination: "lno1unifyoffer", sats: 500, maxFeeSats: fee)
        await waitForUnifyPhase(store) { if case .sent = $0 { return true }; return false }
        XCTAssertEqual(native.sentPrepared.map(\.amountSats), [500])
        await service.releaseQuietly()
    }

    /// The fee on the Unify sheet is the most the send pays. A higher reserve
    /// at send time is refused with nothing spent and the new fee stated; the
    /// fee read again from the sheet is then paid.
    func testAUnifySendAboveTheFeeOnScreenIsRefusedWithTheNewFee() async throws {
        let native = FakeCashuNative()
        native.confirmedSats = 10_000
        native.feeReserve = 40
        let (store, service, cleanup) = await unifyStore(native, serving: "lightning:lno1unifyoffer")
        defer { cleanup() }

        store.sendSatsToUnify("unify:peer-1")
        await waitForUnifyPhase(store) { if case .amount = $0 { return true }; return false }
        store.confirmUnifyAmount("unify:peer-1", destination: "lno1unifyoffer", sats: 500, maxFeeSats: 3)
        await waitForUnifyPhase(store) { if case .failed = $0 { return true }; return false }
        XCTAssertEqual(store.unifyPay?.phase, .failed(feeChanged40))
        XCTAssertEqual(native.count("send"), 0, "nothing is spent above the fee the user saw")

        store.confirmUnifyAmount("unify:peer-1", destination: "lno1unifyoffer", sats: 500, maxFeeSats: 40)
        await waitForUnifyPhase(store) { if case .sent = $0 { return true }; return false }
        XCTAssertEqual(native.sentPrepared.map(\.amountSats), [500])
        await service.releaseQuietly()
    }

    /// What the Unify sheet shows for a request: a BOLT11 invoice speaks for
    /// its own amount (the URI's `amount` does not override it); an
    /// amountless invoice and an offer take the URI's amount or ask for one.
    func testAUnifyRequestIsShownWithTheAmountThatWillBePaid() {
        typealias Parsed = UnifyBIP321.Parsed
        XCTAssertEqual(
            SonarAppStore.unifyPayPhase(for: Parsed(lightning: "lnbc2500n1pinvoice", amountSats: 999)),
            .confirm(destination: "lnbc2500n1pinvoice", sats: 250)
        )
        XCTAssertEqual(
            SonarAppStore.unifyPayPhase(for: Parsed(lightning: "lnbc1pinvoice", amountSats: 500)),
            .confirm(destination: "lnbc1pinvoice", sats: 500)
        )
        XCTAssertEqual(
            SonarAppStore.unifyPayPhase(for: Parsed(lightning: "lnbc1pinvoice", amountSats: nil)),
            .amount(destination: "lnbc1pinvoice")
        )
        XCTAssertEqual(
            SonarAppStore.unifyPayPhase(for: Parsed(lightning: "lno1offer", amountSats: 700)),
            .confirm(destination: "lno1offer", sats: 700)
        )
        XCTAssertEqual(
            SonarAppStore.unifyPayPhase(for: Parsed(lightning: "lno1offer", amountSats: nil)),
            .amount(destination: "lno1offer")
        )
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
