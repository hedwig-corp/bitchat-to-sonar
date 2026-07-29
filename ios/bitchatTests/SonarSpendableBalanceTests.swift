//
// SonarSpendableBalanceTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing

@testable import Sonar

/// #141 — `Max` proposed the whole balance, so the send failed locally with a
/// raw `InsufficientFunds` after the user had committed. Mirror of Compose
/// `SpendableBalanceTest`; both must stay in step.
struct SonarSpendableBalanceTests {

    @Test
    func maxLeavesRoomForFees() {
        for balance in [Int64(1_000), 50_000, 1_000_000] {
            let max = SonarSpendableBalance.maxSendable(balanceSats: balance)
            #expect(max < balance)
            #expect(max == balance - SonarSpendableBalance.feeReserve(balanceSats: balance))
        }
    }

    @Test
    func reserveIsClamped() {
        #expect(SonarSpendableBalance.feeReserve(balanceSats: 1_000)
                == SonarSpendableBalance.minFeeReserveSats)
        #expect(SonarSpendableBalance.feeReserve(balanceSats: 100_000_000)
                == SonarSpendableBalance.maxFeeReserveSats)
        #expect(SonarSpendableBalance.feeReserve(balanceSats: 100_000) == 500)
    }

    @Test
    func dustBalancesOfferNothing() {
        #expect(SonarSpendableBalance.maxSendable(
            balanceSats: SonarSpendableBalance.minFeeReserveSats) == 0)
        #expect(SonarSpendableBalance.maxSendable(balanceSats: 5) == 0)
        #expect(SonarSpendableBalance.maxSendable(balanceSats: 0) == 0)
        #expect(SonarSpendableBalance.maxSendable(balanceSats: -1) == 0)
    }

    @Test
    func preSendCheckUsesTheRealFee() {
        // Exactly affordable: allowed (boundary).
        #expect(!SonarSpendableBalance.insufficientAfterFee(
            amountSats: 990, feeSats: 10, balanceSats: 1_000))
        #expect(SonarSpendableBalance.insufficientAfterFee(
            amountSats: 991, feeSats: 10, balanceSats: 1_000))
        // The original report: Max == balance with any fee at all.
        #expect(SonarSpendableBalance.insufficientAfterFee(
            amountSats: 1_000, feeSats: 1, balanceSats: 1_000))
        #expect(!SonarSpendableBalance.insufficientAfterFee(
            amountSats: 0, feeSats: 10, balanceSats: 1_000))
    }

    /// The proposed max must survive its own pre-send check at a plausible fee.
    @Test
    func proposedMaxSurvivesTheCheck() {
        for balance in [Int64(1_000), 20_000, 500_000, 10_000_000] {
            let max = SonarSpendableBalance.maxSendable(balanceSats: balance)
            if max <= 0 { continue }
            let plausibleFee = SonarSpendableBalance.feeReserve(balanceSats: balance)
            #expect(!SonarSpendableBalance.insufficientAfterFee(
                amountSats: max, feeSats: plausibleFee, balanceSats: balance))
        }
    }

    /// The two platform policies must agree — the constants are the contract.
    @Test
    func constantsMatchTheComposeMirror() {
        #expect(SonarSpendableBalance.minFeeReserveSats == 10)
        #expect(SonarSpendableBalance.maxFeeReserveSats == 1_000)
        #expect(SonarSpendableBalance.feeReserveBps == 50)
    }
}
