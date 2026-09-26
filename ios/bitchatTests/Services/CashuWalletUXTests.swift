//
// CashuWalletUXTests.swift
// bitchatTests
//
// Pins the non-UI logic behind the wallet UX round (Receive / Send on the
// wallet screen, the Receive sheet, fee-before-confirm, footer copy) at the
// call sites the views use:
//  - the fee quote: `SonarAppStore.feeQuoter(wallet:destination:)` →
//    `CashuWallet.quoteFee` → `CashuWalletService.quoteFee` → FFI
//    `prepareSend` (off main, typed errors, nothing spent, quote discarded);
//  - the fee line state machine the pay sheet's `.task` runs (`SNFeeQuote`);
//  - the receive invoice: `CashuWallet.receiveInvoice` → FFI
//    `receiveInvoice` (off main, typed errors);
//  - the pay sheet footer (`SNPaySheet.directNote`, the property its footer
//    `Text` renders) for invoice / offer / named destinations;
//  - the Receive sheet's copy decisions (`SNReceiveSheetCopy`).
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import SonarCore
import XCTest
@testable import Sonar

@MainActor
final class CashuWalletUXTests: XCTestCase {
    private var base: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        base = try CashuTestFixtures.tempDirectory("ux")
        (defaults, suite) = CashuTestFixtures.defaults()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: Fee quote facade

    /// The store's quoter returns the mint's fee reserve from `prepareSend`,
    /// runs every FFI call off the main thread, and spends nothing. The quote
    /// is discarded: the send that follows prepares again.
    func testFeeQuoteReturnsTheMintFeeReserveOffMainAndSpendsNothing() async throws {
        let native = FakeCashuNative()
        native.confirmedSats = 5_000
        native.feeReserve = 7
        let (service, wallet) = try await openWallet(native)

        let quote = SonarAppStore.feeQuoter(wallet: wallet, destination: "  lno1peeroffer  ")
        let fee = try await quote(500)

        XCTAssertEqual(fee, 7)
        XCTAssertEqual(native.preparedAmounts, [500])
        XCTAssertEqual(native.count("send"), 0, "a quote must never pay")
        XCTAssertEqual(native.mainThreadCalls, [], "FFI calls ran on the main thread")

        _ = try await wallet.send(destination: "lno1peeroffer", amountSats: 500, note: nil, feeFromAmount: false, maxFeeSats: nil)
        XCTAssertEqual(native.preparedAmounts, [500, 500], "send prepares again; the quote is never reused")
        XCTAssertEqual(native.sentPrepared.map(\.quoteId), ["quote-2"])
        await releaseQuietly(service)
    }

    /// A BOLT11 invoice speaks for its own amount: the quote passes none,
    /// exactly like the send path (they share `walletAmount`).
    func testFeeQuoteLetsAnInvoiceSpeakForItsOwnAmount() async throws {
        let native = FakeCashuNative()
        native.feeReserve = 3
        let (service, wallet) = try await openWallet(native)

        let fee = try await SonarAppStore.feeQuoter(wallet: wallet, destination: "lnbc5u1pinvoice")(500)
        XCTAssertEqual(fee, 3)
        XCTAssertEqual(native.preparedAmounts, [nil])

        XCTAssertEqual(SonarAppStore.walletAmount(forDestination: "LNBC5U1PINVOICE", sats: 500), 0)
        XCTAssertEqual(SonarAppStore.walletAmount(forDestination: "lntb1pinvoice", sats: 500), 0)
        XCTAssertEqual(SonarAppStore.walletAmount(forDestination: "lno1offer", sats: 500), 500)
        XCTAssertEqual(SonarAppStore.walletAmount(forDestination: "alice@example.com", sats: 500), 500)
        await releaseQuietly(service)
    }

    /// Typed errors cross the seam unchanged; a disconnected wallet answers
    /// `.mintOffline` WITHOUT the quote connecting on its own.
    func testFeeQuoteMapsTypedErrors() async throws {
        let native = FakeCashuNative()
        let service = CashuTestFixtures.service(native: native, base: base, defaults: defaults)
        await assertThrows(.notOpen) { _ = try await service.quoteFee(destination: "lno1x", amountSats: 1) }

        await service.open(nsec: CashuTestFixtures.nsecA)
        await waitUntil { service.connectivity == .online }

        await assertThrows(.invalidInput("missing destination or amount")) {
            _ = try await service.quoteFee(destination: "   ", amountSats: 1)
        }
        XCTAssertEqual(native.count("prepareSend"), 0, "a bad input never reaches the mint")

        native.prepareError = WalletFfiError.InvalidDestination(reason: "bad offer")
        await assertThrows(.invalidDestination("bad offer")) {
            _ = try await service.quoteFee(destination: "lno1x", amountSats: 1)
        }
        native.prepareError = WalletFfiError.Unsupported(reason: "onchain")
        await assertThrows(.unsupported("onchain")) {
            _ = try await service.quoteFee(destination: "bc1q", amountSats: 1)
        }
        native.prepareError = nil

        service.setForeground(false)
        await waitUntil { native.count("disconnect") >= 1 && service.connectivity == .offline }
        let connects = native.count("connect")
        await assertThrows(.mintOffline) { _ = try await service.quoteFee(destination: "lno1x", amountSats: 1) }
        XCTAssertEqual(native.count("connect"), connects, "the quote must not connect by itself")
        XCTAssertEqual(native.mainThreadCalls, [])
        await releaseQuietly(service)
    }

    /// Wallets without a quote (unconfigured, legacy Breez via the protocol
    /// default) throw, so the sheet shows no fee line.
    func testWalletsWithoutAQuoteThrow() async {
        do {
            _ = try await UnconfiguredWallet().quoteFee(destination: "lno1x", amountSats: 1)
            XCTFail("expected a throw")
        } catch {}
    }

    // MARK: Fee line (what the pay sheet's task does)

    func testFeeLineShowsTheQuotedFee() async {
        let state = await SNFeeQuote.resolve(sats: 500, quote: { _ in 7 }, debounceNanos: 0)
        XCTAssertEqual(state, .quoted(7))
        XCTAssertEqual(SNFeeQuote.line(.quoted(7), money: sonarFormatSats), "Network fee: up to 7 sats")
        XCTAssertEqual(SNFeeQuote.line(.checking, money: sonarFormatSats), "Checking the fee\u{2026}")
        XCTAssertNil(SNFeeQuote.line(.hidden, money: sonarFormatSats))
    }

    func testFeeLineHidesOnError() async {
        let state = await SNFeeQuote.resolve(
            sats: 500,
            quote: { _ in throw CashuWalletError.mintOffline },
            debounceNanos: 0
        )
        XCTAssertEqual(state, .hidden)
    }

    /// No amount or no quoter: nothing to check, the mint is never asked.
    func testFeeLineNeedsAnAmountAndAQuoter() async {
        let asked = Recorder()
        let quote: SNFeeQuoter = { sats in asked.values.append(sats); return 1 }

        XCTAssertEqual(SNFeeQuote.initialState(sats: 500, quote: quote), .checking)
        XCTAssertEqual(SNFeeQuote.initialState(sats: 0, quote: quote), .hidden)
        XCTAssertEqual(SNFeeQuote.initialState(sats: 500, quote: nil), .hidden)
        let noAmount = await SNFeeQuote.resolve(sats: 0, quote: quote, debounceNanos: 0)
        XCTAssertEqual(noAmount, .hidden)
        let noQuoter = await SNFeeQuote.resolve(sats: 500, quote: nil, debounceNanos: 0)
        XCTAssertEqual(noQuoter, .hidden)
        XCTAssertEqual(asked.values, [])
    }

    // MARK: Fee consent (maintainer review, #614)

    /// The fee on screen is the most the send may pay; with a quoter but no
    /// fee on screen the user agreed to none (any fee is asked about again);
    /// with no quoter (legacy wallet) no fee was ever shown — no ceiling.
    func testTheConsentedCeilingIsTheFeeOnScreen() {
        XCTAssertEqual(SNFeeQuote.consentedCeiling(.quoted(3), hasQuoter: true), 3)
        XCTAssertEqual(SNFeeQuote.consentedCeiling(.quoted(0), hasQuoter: true), 0)
        XCTAssertEqual(SNFeeQuote.consentedCeiling(.hidden, hasQuoter: true), 0)
        XCTAssertEqual(SNFeeQuote.consentedCeiling(.checking, hasQuoter: true), 0)
        XCTAssertNil(SNFeeQuote.consentedCeiling(.hidden, hasQuoter: false))
        XCTAssertNil(SNFeeQuote.consentedCeiling(.quoted(3), hasQuoter: false))
    }

    /// Send waits only while the fee is being checked — never on a failed
    /// quote (that send asks again instead), never without a quoter.
    func testSendWaitsOnlyWhileTheFeeIsChecking() {
        XCTAssertTrue(SNFeeQuote.blocksSend(.checking, hasQuoter: true))
        XCTAssertFalse(SNFeeQuote.blocksSend(.quoted(3), hasQuoter: true))
        XCTAssertFalse(SNFeeQuote.blocksSend(.hidden, hasQuoter: true))
        XCTAssertFalse(SNFeeQuote.blocksSend(.checking, hasQuoter: false))
    }

    /// A contact pay on the primary wallet always has a quoter, even before
    /// the contact's offer is cached: the quote then fails, the sheet shows
    /// no fee, and the send consents to none — instead of the old "no quoter,
    /// no ceiling" that paid any fee unseen. The legacy wallet has none.
    func testAContactSheetOnThePrimaryWalletAlwaysQuotes() async throws {
        let (store, cleanup) = makeIsolatedSonarAppStore()
        defer { cleanup() }
        let quoter = try XCTUnwrap(store.feeQuoter(forContact: "no-offer-cached-yet"))
        XCTAssertNil(store.feeQuoter(forContact: "no-offer-cached-yet", source: .legacy))
        do {
            _ = try await quoter(500)
            XCTFail("no offer cached: the quote must fail (fee line hidden)")
        } catch {}
        let state = await SNFeeQuote.resolve(sats: 500, quote: quoter, debounceNanos: 0)
        XCTAssertEqual(state, .hidden)
        XCTAssertEqual(SNFeeQuote.consentedCeiling(state ?? .checking, hasQuoter: true), 0)
    }

    /// The debounce: an amount the user typed past (its task cancelled by
    /// the next keypad tap) never reaches the mint and never overwrites the
    /// newer quote.
    func testSupersededAmountIsNeverQuoted() async {
        let asked = Recorder()
        let quote: SNFeeQuoter = { sats in asked.values.append(sats); return 1 }
        let task = Task { @MainActor in
            await SNFeeQuote.resolve(sats: 100, quote: quote, debounceNanos: 2_000_000_000)
        }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertEqual(asked.values, [])
    }

    // MARK: Receive invoice facade

    func testReceiveInvoiceRunsOffMain() async throws {
        let native = FakeCashuNative()
        let (service, wallet) = try await openWallet(native)

        let issued = try await wallet.receiveInvoice(amountSats: 2_100, description: nil)
        XCTAssertEqual(issued, SonarReceiveInvoice(invoice: "lnbc2100fake", paymentId: "mint-quote-2100"))
        XCTAssertEqual(native.count("receiveInvoice"), 1)
        XCTAssertEqual(native.mainThreadCalls, [], "FFI calls ran on the main thread")
        await releaseQuietly(service)
    }

    /// FFI failures become the typed wallet errors (and their existing
    /// user-facing copy); a zero amount never reaches the FFI.
    func testReceiveInvoiceMapsTypedErrors() async throws {
        let native = FakeCashuNative()
        let service = CashuTestFixtures.service(native: native, base: base, defaults: defaults)
        let wallet = CashuWallet(keychain: MockKeychain(), service: service)
        await assertThrows(.notOpen) { _ = try await wallet.receiveInvoice(amountSats: 10, description: nil) }

        await service.open(nsec: CashuTestFixtures.nsecA)
        await waitUntil { service.connectivity == .online }

        await assertThrows(.invalidInput("amount must be greater than zero")) {
            _ = try await wallet.receiveInvoice(amountSats: 0, description: nil)
        }
        XCTAssertEqual(native.count("receiveInvoice"), 0)

        native.receiveInvoiceError = WalletFfiError.Network(reason: "no route")
        do {
            _ = try await wallet.receiveInvoice(amountSats: 10, description: nil)
            XCTFail("expected mint offline")
        } catch {
            XCTAssertEqual(error as? CashuWalletError, .mintOffline)
            XCTAssertEqual(error.localizedDescription, CashuWalletError.mintOffline.errorDescription)
        }
        native.receiveInvoiceError = WalletFfiError.Unsupported(reason: "bolt11 disabled")
        await assertThrows(.unsupported("bolt11 disabled")) {
            _ = try await wallet.receiveInvoice(amountSats: 10, description: nil)
        }
        native.receiveInvoiceError = WalletFfiError.Backend(reason: "mint said no")
        await assertThrows(.backend("mint said no")) {
            _ = try await wallet.receiveInvoice(amountSats: 10, description: nil)
        }
        XCTAssertEqual(native.mainThreadCalls, [])
        await releaseQuietly(service)
    }

    // MARK: Pay sheet footer (the property the footer Text renders)

    func testPaySheetFooterNamesInvoicesAndOffersNotPeople() {
        let invoice = "lnbc5u1p4tg7qqpp5examplexyz"
        XCTAssertEqual(footer(destination: invoice), "Pays this Lightning invoice.")
        XCTAssertEqual(footer(destination: invoice.uppercased()), "Pays this Lightning invoice.")
        XCTAssertEqual(footer(destination: "lntb10u1ptestnet"), "Pays this Lightning invoice.")
        XCTAssertEqual(footer(destination: "lno1qcp4256ypqpq86q2pucnq42ngssx"), "Pays this Bolt12 offer.")

        // Named destinations keep the person copy.
        XCTAssertEqual(
            footer(destination: "alice@example.com"),
            "Pays alice\u{2019}s wallet directly. No claim step."
        )
        XCTAssertEqual(footer(destination: nil, name: "Bob"), "Pays Bob\u{2019}s wallet directly. No claim step.")
        XCTAssertEqual(
            footer(destination: nil, name: "Bob", transport: .mesh),
            "Chat can stay on Bluetooth. The payment goes straight to Bob\u{2019}s wallet."
        )
    }

    /// What the send picker hands the sheet: a pasted or scanned URI
    /// resolves to its rail first, so the footer names the rail.
    func testFooterForPickerAndScannedDestinations() throws {
        let pasted = try XCTUnwrap(SNExternalDestination(input: "lightning:LNBC5U1PINVOICE"))
        XCTAssertEqual(footer(destination: pasted.destination), "Pays this Lightning invoice.")
        let scanned = SNScannedKind("bitcoin:bc1qexample?lno=lno1qcpofferfromuri")
        XCTAssertEqual(footer(destination: scanned.destination), "Pays this Bolt12 offer.")
        let address = try XCTUnwrap(SNExternalDestination(input: "carol@pay.example"))
        XCTAssertEqual(footer(destination: address.destination), "Pays carol\u{2019}s wallet directly. No claim step.")
    }

    /// QA found the fee line reading "Network fee: up to CHF 0.00" for a
    /// 1-sat reserve: it followed the fiat display. The sheet's line is
    /// always sats, whatever the money display is.
    func testPaySheetFeeLineIsAlwaysInSats() {
        XCTAssertEqual(SNFeeQuote.sheetLine(.quoted(4)), "Network fee: up to \(sonarFormatSats(4))")
        XCTAssertEqual(SNFeeQuote.sheetLine(.quoted(1_234)), "Network fee: up to \(sonarFormatSats(1_234))")
        XCTAssertTrue(SNFeeQuote.sheetLine(.quoted(4))?.hasSuffix(" sats") == true)
        XCTAssertEqual(SNFeeQuote.sheetLine(.checking), "Checking the fee\u{2026}")
        XCTAssertNil(SNFeeQuote.sheetLine(.hidden))
    }

    // MARK: Receive sheet copy

    func testReceivedLineOnlyForSettledIncomingPayments() {
        // A locale-free formatter: the simulator's region picks the grouping.
        let money: (Int64) -> String = { "\($0) sats" }
        func payment(incoming: Bool, status: SonarWalletPayment.Status, sats: Int64 = 1_000) -> SonarWalletPayment {
            SonarWalletPayment(id: "p", amountSats: sats, isIncoming: incoming, timestamp: Date(), note: nil, status: status)
        }
        XCTAssertEqual(
            SNReceiveSheetCopy.receivedLine(payment(incoming: true, status: .complete), money: money),
            "Received 1000 sats"
        )
        XCTAssertNil(SNReceiveSheetCopy.receivedLine(payment(incoming: true, status: .pending), money: money))
        XCTAssertNil(SNReceiveSheetCopy.receivedLine(payment(incoming: true, status: .failed), money: money))
        XCTAssertNil(SNReceiveSheetCopy.receivedLine(payment(incoming: false, status: .complete), money: money))
    }

    /// A paid one-time invoice leaves the sheet; only ITS payment does that
    /// (matched by id, never by amount).
    func testOnlyTheShownInvoicesPaymentRetiresIt() {
        func payment(id: String, incoming: Bool = true, status: SonarWalletPayment.Status = .complete) -> SonarWalletPayment {
            SonarWalletPayment(id: id, amountSats: 210, isIncoming: incoming, timestamp: Date(), note: nil, status: status)
        }
        XCTAssertTrue(SNReceiveSheetCopy.paysShownInvoice(payment(id: "q1"), paymentId: "q1"))
        // Same amount to the reusable address: a different payment.
        XCTAssertFalse(SNReceiveSheetCopy.paysShownInvoice(payment(id: "offer-q:tx"), paymentId: "q1"))
        XCTAssertFalse(SNReceiveSheetCopy.paysShownInvoice(payment(id: "q1", status: .pending), paymentId: "q1"))
        XCTAssertFalse(SNReceiveSheetCopy.paysShownInvoice(payment(id: "q1", incoming: false), paymentId: "q1"))
        XCTAssertFalse(SNReceiveSheetCopy.paysShownInvoice(payment(id: "q1"), paymentId: nil))
    }

    func testReceiveCaptionAndAmountEntry() {
        let money: (Int64) -> String = { "\($0) sats" }
        XCTAssertEqual(
            SNReceiveSheetCopy.caption(invoiceSats: nil, money: money),
            "Anyone can pay this address \u{2014} any amount, as often as they like."
        )
        XCTAssertEqual(
            SNReceiveSheetCopy.caption(invoiceSats: 2_100, money: money),
            "One-time invoice for 2100 sats. It can be paid once."
        )
        XCTAssertEqual(SNReceiveSheetCopy.sanitizedAmount("00२1a2,5"), "125")
        XCTAssertEqual(SNReceiveSheetCopy.sanitizedAmount("0"), "")
        XCTAssertEqual(SNReceiveSheetCopy.sanitizedAmount("12345678901"), "123456789")
    }

    func testInvoiceErrorsNeverUseSendCopy() {
        XCTAssertEqual(
            SNReceiveSheetCopy.invoiceError(WalletFfiError.Network(reason: "down")),
            "Mint offline \u{2014} retrying"
        )
        XCTAssertEqual(
            SNReceiveSheetCopy.invoiceError(CashuWalletError.notOpen),
            "Your wallet is still starting. Try again in a moment."
        )
        XCTAssertEqual(
            SNReceiveSheetCopy.invoiceError(WalletFfiError.Busy(reason: "connecting")),
            "Your wallet is busy. Try again in a moment."
        )
        for error: Error in [
            WalletFfiError.Backend(reason: "mint said no"),
            WalletFfiError.InvalidInput(reason: "amount"),
            CashuWalletError.paymentInFlight,
        ] {
            XCTAssertEqual(SNReceiveSheetCopy.invoiceError(error), "Couldn't create the invoice. Try again.")
        }
    }

    // MARK: BOLT11 amounts

    /// QA: a `lnbc2100n` invoice (210 sats) showed as 211 sats in the send
    /// sheet and was recorded as 211 in the ledger — `Double` read it as
    /// 210.00000000000003 and rounded up. Mirrors Compose `Bolt11AmountTest`.
    func testBolt11WholeSatAmountsAreExact() {
        XCTAssertEqual(SNScannedKind.bolt11AmountSats("lnbc2100n1p4tfqn0dqq"), 210)
        for sats in Int64(1)...10_000 {
            XCTAssertEqual(SNScannedKind.bolt11AmountSats("lnbc\(sats * 10)n1pabc"), sats, "\(sats * 10)n")
        }
        XCTAssertEqual(SNScannedKind.bolt11AmountSats("lnbc21u1p3k9abcdef"), 2_100)
        XCTAssertEqual(SNScannedKind.bolt11AmountSats("lnbc2500u1pabc"), 250_000)
        XCTAssertEqual(SNScannedKind.bolt11AmountSats("lnbc20m1pabc"), 2_000_000)
        XCTAssertEqual(SNScannedKind.bolt11AmountSats("lnbc11pabc"), 100_000_000)
        // A sub-sat remainder still rounds up (never underpay).
        XCTAssertEqual(SNScannedKind.bolt11AmountSats("lnbc15n1pabc"), 2)
        XCTAssertEqual(SNScannedKind.bolt11AmountSats("lnbc10p1pabc"), 1)
        XCTAssertEqual(SNScannedKind.bolt11AmountSats("lnbc123456789n1pabc"), 12_345_679)
    }

    func testBolt11NoAmountCases() {
        XCTAssertNil(SNScannedKind.bolt11AmountSats("lnbc1pabcdef"))
        XCTAssertNil(SNScannedKind.bolt11AmountSats("lnbc0u1pabc"))
        XCTAssertNil(SNScannedKind.bolt11AmountSats("lnbc5x1pabc"))
        XCTAssertNil(SNScannedKind.bolt11AmountSats("lnbc99999999999999999m1pabc"))
        XCTAssertNil(SNScannedKind.bolt11AmountSats(""))
    }

    // MARK: Helpers

    private func openWallet(_ native: FakeCashuNative) async throws -> (CashuWalletService, CashuWallet) {
        let service = CashuTestFixtures.service(native: native, base: base, defaults: defaults)
        let wallet = CashuWallet(keychain: MockKeychain(), service: service)
        await service.open(nsec: CashuTestFixtures.nsecA)
        await waitUntil { service.connectivity == .online }
        return (service, wallet)
    }

    private func footer(destination: String?, name: String? = nil, transport: SNVia = .internet) -> String {
        SNPaySheet(
            peerName: name ?? SNExternalDestination.displayName(destination ?? ""),
            balance: 10_000,
            transport: transport,
            money: sonarFormatSats,
            fiatText: { _ in nil },
            destination: destination,
            onClose: {},
            onSend: { _, _ in }
        ).directNote
    }

    private func assertThrows(
        _ expected: CashuWalletError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? CashuWalletError, expected, file: file, line: line)
        }
    }

    private func releaseQuietly(_ service: CashuWalletService) async {
        try? await service.release()
    }
}

/// Records what a quoter was asked (a reference shared with the closure).
@MainActor
private final class Recorder {
    var values: [Int64] = []
}
