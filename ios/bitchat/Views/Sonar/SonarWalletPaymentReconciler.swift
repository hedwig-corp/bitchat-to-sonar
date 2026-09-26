//
// SonarWalletPaymentReconciler.swift
// bitchat
//
// Folds wallet payment results and later wallet updates into the payment
// activity ledger — the one place a Cashu `Pending` send becomes paid or
// failed. `SonarAppStore` calls it from every send path and from its wallet
// update subscription; tests drive the same functions.
//
// Rules:
//  - `pending` is in flight, never failed. The row keeps `pending` and
//    records the wallet payment id; nothing is ever re-sent.
//  - A later update with the same wallet id finishes the row.
//  - `paid` is final. `failed` is final too, except that a later update
//    saying the same wallet payment COMPLETED moves it to paid: the money
//    left, and the row must not keep saying "you were not charged".
//  - Idempotent: the send's own result and the event for the same outcome
//    can arrive in either order; the second one is a no-op.
//  - A chat ⚡PAY receipt is due exactly once, after the payment completes
//    (PAY + PAYDONE carry the preimage together).
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Foundation

@MainActor
enum SonarWalletPaymentReconciler {
    enum Outcome: Equatable {
        /// Nothing this ledger tracks changed.
        case none
        /// Still in flight.
        case pending(activityId: String)
        /// Settled. `receiptDue`: send the chat ⚡PAY + PAYDONE now.
        case paid(activityId: String, receiptDue: Bool)
        case failed(activityId: String)
    }

    /// peerKey of payments that do not belong to a chat.
    static let walletPeerKey = "wallet"

    /// The wallet's `send` returned for `activityId`.
    ///
    /// `adoptWalletAmount`: the send let the wallet take the fee out of the
    /// amount (Cashu `Max`), so the amount the wallet reports is what the
    /// payee actually gets — record that, and put it on the chat receipt.
    @discardableResult
    static func applySendResult(
        _ payment: SonarWalletPayment,
        activityId: String,
        ledger: SonarPaymentActivityLedger,
        hasReceipt: (String) -> Bool,
        adoptWalletAmount: Bool = false
    ) -> Outcome {
        let adopted: Int64? = adoptWalletAmount && payment.amountSats > 0 ? payment.amountSats : nil
        switch payment.status {
        case .complete:
            if let adopted {
                ledger.markHandedToWallet(activityId, walletPaymentId: payment.id, sats: adopted)
            }
            ledger.markPaid(activityId, payment: payment)
            return .paid(activityId: activityId, receiptDue: receiptDue(activityId, ledger: ledger, hasReceipt: hasReceipt))
        case .pending:
            ledger.markHandedToWallet(activityId, walletPaymentId: payment.id, sats: adopted)
            return .pending(activityId: activityId)
        case .failed:
            ledger.markFailed(
                activityId,
                message: String(localized: "Payment failed — you were not charged."),
                walletPaymentId: payment.id
            )
            return .failed(activityId: activityId)
        }
    }

    /// A later update from the wallet (event, catch-up, or history lookup).
    @discardableResult
    static func applyUpdate(
        _ update: SonarWalletPayment,
        ledger: SonarPaymentActivityLedger,
        hasReceipt: (String) -> Bool
    ) -> Outcome {
        guard !update.isIncoming,
              let activityId = ledger.activityId(forWalletPayment: update.id),
              let entry = ledger.entries[activityId]
        else { return .none }
        switch entry.status {
        case .paid:
            // Already settled (by the send result or an earlier event). Only
            // a receipt that was never recorded is still owed.
            let due = receiptDue(activityId, ledger: ledger, hasReceipt: hasReceipt)
            return due ? .paid(activityId: activityId, receiptDue: true) : .none
        case .failed:
            // Reported failed, then paid (an ambiguous send the mint went on
            // to pay). A later failure changes nothing.
            guard update.status == .complete else { return .none }
            SecureLogger.warning(
                "wallet payment \(update.id) was reported failed, then paid: settling it as paid",
                category: .session
            )
            ledger.markPaid(activityId, payment: update)
            return .paid(activityId: activityId, receiptDue: receiptDue(activityId, ledger: ledger, hasReceipt: hasReceipt))
        case .pending:
            break
        }
        switch update.status {
        case .pending:
            return .pending(activityId: activityId)
        case .complete:
            ledger.markPaid(activityId, payment: update)
            return .paid(activityId: activityId, receiptDue: receiptDue(activityId, ledger: ledger, hasReceipt: hasReceipt))
        case .failed:
            ledger.markFailed(activityId, message: String(localized: "Payment failed — you were not charged."))
            return .failed(activityId: activityId)
        }
    }

    /// A chat payment that settled and whose receipt was never recorded.
    static func receiptDue(
        _ activityId: String,
        ledger: SonarPaymentActivityLedger,
        hasReceipt: (String) -> Bool
    ) -> Bool {
        guard let entry = ledger.entries[activityId],
              entry.status == .paid,
              entry.kind == .sonarDirect,
              entry.direction == .outgoing,
              entry.peerKey != walletPeerKey
        else { return false }
        return !hasReceipt(activityId)
    }
}
