//
// SonarSpendableBalance.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Fee-aware spendable-balance policy (#141). Mirror of Compose
/// `chat.bitchat.sonar.wallet.SpendableBalance` — keep the constants and the
/// three functions in step (Cross-Platform Feature Rule).
///
/// The pay sheet's `Max` used to set the amount to the full wallet balance,
/// but Breez needs sender-side fees ON TOP of the receiver amount, so the
/// send failed locally with `InsufficientFunds(message: "Cannot pay: not
/// enough funds")` — a raw SDK string, after the user had committed.
///
/// Two layers, because the exact fee is only knowable from a
/// `prepareSendPayment` against a specific destination, and `Max` must stay
/// instant (no network on a tap — local-first):
///
/// 1. `maxSendable` — an instant, conservative reserve so the default `Max`
///    amount can actually settle.
/// 2. `insufficientAfterFee` — the pre-send check once a real prepared fee is
///    known, so the user gets our message instead of a raw Breez error.
enum SonarSpendableBalance {

    /// Floor for the reserve: covers the smallest realistic Lightning fee.
    static let minFeeReserveSats: Int64 = 10

    /// Ceiling: a large balance should not withhold an absurd amount.
    static let maxFeeReserveSats: Int64 = 1_000

    /// Proportional part of the reserve, in basis points (0.5%). Lightning
    /// routing fees are largely proportional, so the reserve tracks the
    /// amount rather than being a flat guess.
    static let feeReserveBps: Int64 = 50

    /// Sats withheld from a `Max` send so fees have somewhere to come from.
    static func feeReserve(balanceSats: Int64) -> Int64 {
        guard balanceSats > 0 else { return 0 }
        let proportional = balanceSats * feeReserveBps / 10_000
        return min(max(proportional, minFeeReserveSats), maxFeeReserveSats)
    }

    /// The amount `Max` should propose: balance minus the fee reserve, never
    /// negative. 0 means "nothing is safely sendable" — the UI hides `Max`
    /// rather than proposing an amount that cannot settle.
    static func maxSendable(balanceSats: Int64) -> Int64 {
        guard balanceSats > 0 else { return 0 }
        return max(balanceSats - feeReserve(balanceSats: balanceSats), 0)
    }

    /// Pre-send check against a REAL prepared fee: true when the send cannot
    /// settle, so the caller blocks with a clear message instead of handing
    /// Breez a doomed payment.
    static func insufficientAfterFee(amountSats: Int64, feeSats: Int64, balanceSats: Int64) -> Bool {
        amountSats > 0 && amountSats + feeSats > balanceSats
    }

    /// User-facing copy for the blocked case — replaces the raw
    /// `InsufficientFunds(message: "Cannot pay: not enough funds")` string.
    static func insufficientMessage(amountSats: Int64, feeSats: Int64, balanceSats: Int64) -> String {
        "Amount plus fee (\(amountSats) + \(feeSats) sats) exceeds your balance of \(balanceSats) sats."
    }
}
