//
// SonarReceiveAnnouncer.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Announces each wallet receive once. A chat payment is already announced
/// by its ⚡PAY line, and the wallet cannot tell it from a payment made
/// outside Sonar: the payer pays the public offer, so nothing links the
/// payment to the receipt. They are paired by amount instead, one receipt to
/// one receive, and the chat line stays the only notification (Signal's
/// model: the payment message is the notification). Mirrors Compose
/// `ReceiveAnnouncer`.
///
/// - A receipt that arrives first silences the next receive of its amount
///   within `lookback` (the payee's wallet only mints in the foreground, so
///   it can land hours after the push-delivered ⚡PAY).
/// - A receive that arrives first waits the grace for its receipt, then
///   announces.
///
/// Feed `chatReceipt` only receipts the pay ledger records for the first
/// time: a transcript replayed after a restart must not silence a new
/// outside payment. Receives come deduplicated by payment id.
@MainActor
final class SonarReceiveAnnouncer {
    /// How long a receive waits for its ⚡PAY: covers a chat line delivered
    /// over the relays after the wallet saw the payment.
    static let defaultGraceNanos: UInt64 = 30_000_000_000
    static let lookback: TimeInterval = 24 * 60 * 60
    private static let maxSeen = 256

    private struct Receipt {
        let sats: Int64
        let sentAt: Date
    }

    private struct Waiting {
        let paymentId: String
        let sats: Int64
        let task: Task<Void, Never>
    }

    private let graceNanos: () -> UInt64
    private let now: () -> Date
    private let announce: (_ paymentId: String, _ sats: Int64) -> Void
    private var seenReceipts: [String] = []
    private var receipts: [Receipt] = []
    private var waiting: [Waiting] = []

    init(
        graceNanos: @escaping () -> UInt64 = { SonarReceiveAnnouncer.defaultGraceNanos },
        now: @escaping () -> Date = Date.init,
        announce: @escaping (_ paymentId: String, _ sats: Int64) -> Void
    ) {
        self.graceNanos = graceNanos
        self.now = now
        self.announce = announce
    }

    /// An incoming ⚡PAY receipt for `sats`, sent at `sentAt`.
    func chatReceipt(id: String, sats: Int64, sentAt: Date) {
        guard sats > 0,
              now().timeIntervalSince(sentAt) <= Self.lookback,
              !seenReceipts.contains(id)
        else { return }
        seenReceipts.append(id)
        if seenReceipts.count > Self.maxSeen { seenReceipts.removeFirst() }
        if let index = waiting.firstIndex(where: { $0.sats == sats }) {
            waiting.remove(at: index).task.cancel()
        } else {
            receipts.append(Receipt(sats: sats, sentAt: sentAt))
            if receipts.count > Self.maxSeen { receipts.removeFirst() }
        }
    }

    /// A settled incoming wallet payment, seen for the first time.
    func walletReceive(paymentId: String, sats: Int64) {
        let oldest = now().addingTimeInterval(-Self.lookback)
        receipts.removeAll { $0.sentAt < oldest }
        if let index = receipts.firstIndex(where: { $0.sats == sats }) {
            receipts.remove(at: index)
            return
        }
        guard !waiting.contains(where: { $0.paymentId == paymentId }) else { return }
        let grace = graceNanos()
        // Main-actor isolated: it cannot run before it is registered below.
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: grace)
            guard !Task.isCancelled,
                  let self,
                  let index = self.waiting.firstIndex(where: { $0.paymentId == paymentId })
            else { return }
            self.waiting.remove(at: index)
            self.announce(paymentId, sats)
        }
        waiting.append(Waiting(paymentId: paymentId, sats: sats, task: task))
    }
}
