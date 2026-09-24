//
// CashuWalletTestSupport.swift
// bitchatTests
//
// A fake `SonarCashuWalletProtocol` (the generated FFI protocol the real
// `SonarCashuWallet` conforms to) that records every call and the thread it
// ran on, plus small async helpers. Shared by the Cashu wallet test classes.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import SonarCore
import XCTest
@testable import Sonar

class FakeCashuNative: SonarCashuWalletProtocol, @unchecked Sendable {
    struct Call: Equatable {
        let name: String
        let onMainThread: Bool
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _listener: CashuWalletListener?
    private var _connected = false

    // Behaviour knobs (set before use; read under the lock).
    var connectError: Error?
    var confirmedSats: UInt64 = 0
    var pendingReceiveSats: UInt64 = 0
    var pendingSendSats: UInt64 = 0
    /// nil ⇒ `receiveOffer` throws NotConnected (no offer created yet).
    var offer: String? = "lno1fakeoffer"
    /// Fee reserve quoted for every prepare.
    var feeReserve: UInt64? = 0
    /// Status of the payment `send` returns.
    var sendStatus: WalletPaymentStatus = .complete
    var sendError: Error?
    var sendPreimage: String? = nil
    var lookupResult: WalletPayment?

    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }
    var listener: CashuWalletListener? { lock.lock(); defer { lock.unlock() }; return _listener }

    func count(_ name: String) -> Int { calls.filter { $0.name == name }.count }
    var mainThreadCalls: [Call] { calls.filter(\.onMainThread) }

    private(set) var preparedAmounts: [UInt64?] = []
    private(set) var sentPrepared: [WalletPreparedSend] = []

    func record(_ name: String) {
        lock.lock()
        _calls.append(Call(name: name, onMainThread: Thread.isMainThread))
        lock.unlock()
    }

    /// Deliver an event the way the Rust wallet does: from its own thread.
    func emit(_ event: CashuWalletEvent) {
        let target = listener
        DispatchQueue.global().async { target?.onEvent(event: event) }
    }

    // MARK: SonarCashuWalletProtocol

    func balance() throws -> WalletBalance {
        record("balance")
        guard isConnectedLocked() else { throw WalletFfiError.NotConnected }
        return WalletBalance(
            confirmedSats: confirmedSats,
            pendingReceiveSats: pendingReceiveSats,
            pendingSendSats: pendingSendSats
        )
    }

    func clearListener() {
        record("clearListener")
        lock.lock(); _listener = nil; lock.unlock()
    }

    func connect() throws {
        record("connect")
        if let connectError { throw connectError }
        lock.lock(); _connected = true; lock.unlock()
    }

    func disconnect() throws {
        record("disconnect")
        lock.lock(); _connected = false; lock.unlock()
    }

    func isConnected() -> Bool {
        record("isConnected")
        return isConnectedLocked()
    }

    private func isConnectedLocked() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _connected
    }

    func listPayments(limit: UInt32) throws -> [WalletPayment] {
        record("listPayments")
        return []
    }

    func lookupPayment(id: String) throws -> WalletPayment? {
        record("lookupPayment")
        return lookupResult
    }

    func parseDestination(input: String) throws -> WalletDestination {
        record("parseDestination")
        return WalletDestination(raw: input, kind: .bolt12Offer, amountSats: nil)
    }

    func prepareSend(destination: String, amountSats: UInt64?) throws -> WalletPreparedSend {
        record("prepareSend")
        lock.lock(); preparedAmounts.append(amountSats); lock.unlock()
        guard isConnectedLocked() else { throw WalletFfiError.NotConnected }
        return WalletPreparedSend(
            quoteId: "quote-\(preparedAmounts.count)",
            destination: destination,
            kind: .bolt12Offer,
            amountSats: amountSats ?? 0,
            feesSats: feeReserve
        )
    }

    func receiveInvoice(amountSats: UInt64, description: String?) throws -> WalletInvoice {
        record("receiveInvoice")
        return WalletInvoice(invoice: "lnbc\(amountSats)fake", paymentId: "mint-quote-\(amountSats)")
    }

    func receiveOffer() throws -> String {
        record("receiveOffer")
        guard let offer else { throw WalletFfiError.NotConnected }
        return offer
    }

    func send(prepared: WalletPreparedSend, note: String) throws -> WalletPayment {
        record("send")
        lock.lock(); sentPrepared.append(prepared); lock.unlock()
        if let sendError { throw sendError }
        return WalletPayment(
            id: prepared.quoteId,
            incoming: false,
            amountSats: prepared.amountSats,
            feesSats: prepared.feesSats,
            timestampSecs: 1_800_000_000,
            status: sendStatus,
            preimage: sendStatus == .complete ? sendPreimage : nil,
            note: note
        )
    }

    func setListener(listener: CashuWalletListener) {
        record("setListener")
        lock.lock(); _listener = listener; lock.unlock()
    }

    func sync() throws {
        record("sync")
    }

    func wipeLocalStorage() throws {
        record("wipeLocalStorage")
        guard !isConnectedLocked() else { throw WalletFfiError.Busy(reason: "connected") }
    }
}

/// Test fixtures shared by the Cashu wallet tests.
enum CashuTestFixtures {
    /// bech32 of 32 bytes of 0x01 / 0x02 — valid nsecs.
    static let nsecA = "nsec1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqstywftw"
    static let nsecB = "nsec1qgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqxjfw7x"
    /// sha256(nsec UTF-8)[:16] hex, computed independently (Python hashlib).
    static let accountIdA = "729f91314a1b93feea0af9c25311ae7e"
    static let accountIdB = "d0cd536a10d75d1c7df160208e544fe7"

    static func tempDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cashu-tests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func defaults() -> (UserDefaults, String) {
        let suite = "CashuWalletTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @MainActor
    static func service(
        native: FakeCashuNative,
        base: URL,
        defaults: UserDefaults,
        startsForeground: Bool = true
    ) -> CashuWalletService {
        CashuWalletService(
            makeNative: { _, _, _ in
                // The factory itself runs on the wallet queue; record it too.
                native.record("construct")
                return native
            },
            defaults: defaults,
            storageBase: { base },
            startsForeground: startsForeground,
            retryDelaysNanos: [30_000_000]
        )
    }
}

/// Poll `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func waitUntil(
    timeout: TimeInterval = 3,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("condition not met within \(timeout)s", file: file, line: line)
            return
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}
