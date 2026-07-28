//
// SonarPaymentStatus.swift
// bitchat
//
// The state machine behind the external-payment status screen, 1:1 with the
// design's `paystatus.jsx` (design/handoff/project/sonar/paystatus.jsx +
// `Sonar Payment Status.html`). Direction D — "resumable status" — is the one
// that shipped: a dismissible status card plus a live wallet row that keeps
// updating after you leave the screen.
//
// The design frames the brief as: every state must answer *what is happening*,
// *where is my money*, and *what do I do next* — "failed" is never enough on
// its own. So the copy tables below are the product, not decoration, and they
// are reproduced verbatim (parameterized only on the payee and the amount).
//
// The Compose mirror is
// `apps/sonar/composeApp/src/commonMain/kotlin/chat/bitchat/sonar/wallet/PaymentStatus.kt`
// — the two files must stay in step (Cross-Platform Feature Rule).
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Where an outgoing external payment is, from the payer's point of view.
///
/// Five of the seven are driven by the real wallet today; see
/// `SonarAppStore.paymentStatus(_:)` for the derivation and
/// `docs/SONAR-PAYMENTS.md` for the two that are not.
enum SNPayPhase: String, Equatable, CaseIterable {
    /// Handed to us, not yet handed to the wallet.
    case resolving
    /// In flight inside the wallet.
    case paying
    /// Still in flight, past the point where that is normal.
    case slow
    /// Settled, proof held.
    case sent
    /// Rejected before any money moved.
    case failedSafe
    /// Money left and came back.
    case refunded
    /// We cannot see the outcome (process died mid-send).
    case unknown

    /// paystatus.jsx `live` — a spinner rather than a terminal glyph.
    var isLive: Bool { self == .resolving || self == .paying || isWarn }
    var isGood: Bool { self == .sent }
    var isBad: Bool { self == .failedSafe || self == .refunded }
    var isWarn: Bool { self == .slow || self == .unknown }

    /// paystatus.jsx `PCT`, 0…1. Failure fills the bar in the danger colour
    /// rather than leaving it empty, so the row still reads as concluded.
    var progress: Double {
        switch self {
        case .resolving: return 0.12
        case .paying: return 0.58
        case .slow: return 0.70
        case .sent: return 1.0
        case .failedSafe, .refunded: return 1.0
        case .unknown: return 0.72
        }
    }
}

/// paystatus.jsx `MONEY[].tone` — the money line is tinted by where the sats
/// are, not by whether the payment "succeeded".
enum SNPayMoneyTone: Equatable {
    case safe
    case flight
    case good
    case warn
}

/// A payment as the status screen and the home strip see it. Assembled by
/// `SonarAppStore.paymentStatus(_:)` from the persisted activity ledger plus
/// whatever the in-process send knows.
struct SNPaymentStatus: Equatable, Identifiable {
    let id: String
    let payeeName: String
    let sats: Int64
    let phase: SNPayPhase
    /// Seconds since the send was accepted; drives "Sending · 6s".
    let elapsedSeconds: Int
    /// Settlement proof, when the wallet handed one back.
    let preimage: String?
    /// Whether we still hold the destination needed to re-send. Destinations
    /// are only ever hashed in the ledger, so this is false after a relaunch.
    let canRetry: Bool
}

/// An external payment this process is sending right now.
///
/// Everything terminal lives in `SonarPaymentActivityLedger`; this only carries
/// the part of the design's state machine the ledger has no business persisting
/// — which live sub-phase we are in, and when the send started.
struct SNLivePayment: Equatable {
    let id: String
    let payeeName: String
    let sats: Int64
    let startedAt: Date
    /// False only in the window between the user confirming and us calling the
    /// wallet. That window is the one place `Cancel` can honestly work.
    var handedToWallet: Bool

    /// Lightning normally settles in well under a second. Past this it is worth
    /// telling the user the first route did not answer, rather than leaving a
    /// spinner that says nothing.
    static let slowAfter: TimeInterval = 20

    func phase(now: Date) -> SNPayPhase {
        guard handedToWallet else { return .resolving }
        return now.timeIntervalSince(startedAt) >= Self.slowAfter ? .slow : .paying
    }

    func elapsedSeconds(now: Date) -> Int {
        Int(max(0, now.timeIntervalSince(startedAt)))
    }
}

/// The once-a-second tick behind "Sending · 6s" and the paying → slow flip.
///
/// Deliberately its own `ObservableObject` rather than a `@Published` on
/// `SonarAppStore`: a store-level publish invalidates *every* view bound to the
/// store, so a 1 Hz tick would re-render the whole app for as long as a payment
/// is in flight. Only the two views that show elapsed time observe this
/// (Signal-Comparable Performance Rule). Compose gets the same granularity for
/// free — `paymentClock` there is snapshot state, so only composables that read
/// it recompose.
final class SNPaymentClock: ObservableObject {
    @Published private(set) var tick: Int = 0

    func advance() { tick &+= 1 }
}

// MARK: - Copy

/// One action button in the status card (paystatus.jsx `acts`).
struct SNPayAction: Equatable, Identifiable {
    enum Kind: Equatable {
        /// `.rs-act.pri` — filled accent.
        case primary
        /// `.rs-act.dim` — text2 label on the plain surface.
        case dim
        /// `.rs-act` — plain surface, full-strength label.
        case plain
    }

    enum Effect: Equatable {
        /// Leave the screen; the payment keeps running.
        case dismiss
        /// Copy the settlement proof.
        case copyProof
        /// Re-send the same amount to the same destination.
        case retry
    }

    let label: String
    let kind: Kind
    let effect: Effect

    var id: String { label }
}

/// The design's copy tables. Kept as one namespace so the Compose mirror can be
/// diffed against it line by line.
enum SNPayStatusCopy {

    /// Grouped amount without a unit, so it can be composed into a sentence
    /// ("2,100 sats in flight"). `sonarFormatSats` already appends "sats".
    static func amount(_ sats: Int64) -> String { sonarGroupedSats(sats) }

    /// paystatus.jsx `HEAD` — headline plus the sentence under it.
    static func headline(_ phase: SNPayPhase, payee: String, sats: Int64) -> String {
        switch phase {
        case .resolving: return "Finding \(payee)"
        case .paying: return "Sending \(amount(sats)) sats"
        case .slow: return "Taking longer than usual"
        case .sent: return "Paid \(payee)"
        case .failedSafe: return "Couldn\u{2019}t send"
        case .refunded: return "Payment came back"
        case .unknown: return "Still confirming"
        }
    }

    static func hint(_ phase: SNPayPhase, payee: String, sats: Int64) -> String {
        switch phase {
        case .resolving:
            return "Reading the code and checking the destination is payable."
        case .paying:
            return "Your payment is hopping through the Lightning network."
        case .slow:
            return "The first route didn\u{2019}t answer. Trying another \u{2014} this can take a minute."
        case .sent:
            return "They received \(amount(sats)) sats. You have cryptographic proof of payment."
        case .failedSafe:
            return "No route to \(payee) right now. You were not charged."
        case .refunded:
            return "\(payee) didn\u{2019}t accept in time, so the sats returned to you."
        case .unknown:
            return "We can\u{2019}t see the result yet. Lightning settles or refunds on its own "
                + "\u{2014} we\u{2019}ll tell you which."
        }
    }

    /// paystatus.jsx `MONEY` — the single most important line on the screen.
    static func money(_ phase: SNPayPhase, sats: Int64) -> (tone: SNPayMoneyTone, text: String) {
        switch phase {
        case .resolving:
            return (.safe, "Nothing sent yet \u{2014} your sats are still yours")
        case .paying:
            return (.flight, "\(amount(sats)) sats in flight \u{2014} not yet settled")
        case .slow:
            return (.warn, "Still in flight \u{2014} held, not lost")
        case .sent:
            return (.good, "\(amount(sats)) sats delivered \u{00B7} proof received")
        case .failedSafe:
            return (.safe, "Nothing left your wallet \u{2014} balance unchanged")
        case .refunded:
            return (.good, "\(amount(sats)) sats returned to your balance")
        case .unknown:
            return (.warn, "Sats reserved \u{2014} we\u{2019}ll confirm or refund automatically")
        }
    }

    /// paystatus.jsx `rowTxt` — the "In your wallet" row's status line.
    static func walletRow(_ phase: SNPayPhase, elapsedSeconds: Int) -> String {
        switch phase {
        case .resolving: return "Resolving destination\u{2026}"
        case .paying: return "Sending \u{00B7} \(elapsed(elapsedSeconds))"
        case .slow: return "Still trying \u{00B7} \(elapsed(elapsedSeconds))"
        case .sent: return "Sent \u{00B7} proof stored"
        case .failedSafe: return "Not sent \u{00B7} not charged"
        case .refunded: return "Refunded to balance"
        case .unknown: return "Confirming \u{00B7} \(elapsed(elapsedSeconds))"
        }
    }

    /// The design writes elapsed time as "6s" / "48s" / "2m".
    static func elapsed(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        return clamped < 60 ? "\(clamped)s" : "\(clamped / 60)m"
    }

    /// paystatus.jsx `acts`.
    ///
    /// One deliberate deviation: the design's `Cancel` / `Cancel payment` is
    /// dropped once the payment has been handed to the wallet. A Lightning
    /// payment in flight cannot be recalled, and a button that claims otherwise
    /// is exactly the dishonesty this screen exists to remove. `resolving` is
    /// before the hand-off, so its Cancel is real and stays.
    static func actions(_ status: SNPaymentStatus) -> [SNPayAction] {
        switch status.phase {
        case .resolving:
            return [SNPayAction(label: "Cancel", kind: .dim, effect: .dismiss)]
        case .paying:
            return [SNPayAction(label: "Hide \u{2014} keeps sending", kind: .dim, effect: .dismiss)]
        case .slow:
            return [SNPayAction(label: "Keep waiting", kind: .primary, effect: .dismiss)]
        case .sent:
            var out: [SNPayAction] = []
            if status.preimage?.isEmpty == false {
                out.append(SNPayAction(label: "Copy proof", kind: .primary, effect: .copyProof))
            }
            out.append(SNPayAction(label: "Done", kind: out.isEmpty ? .primary : .plain, effect: .dismiss))
            return out
        case .failedSafe:
            guard status.canRetry else {
                return [SNPayAction(label: "Done", kind: .primary, effect: .dismiss)]
            }
            return [
                SNPayAction(label: "Try again", kind: .primary, effect: .retry),
                SNPayAction(label: "Not now", kind: .dim, effect: .dismiss)
            ]
        case .refunded:
            guard status.canRetry else {
                return [SNPayAction(label: "Done", kind: .primary, effect: .dismiss)]
            }
            return [
                SNPayAction(label: "Try again", kind: .primary, effect: .retry),
                SNPayAction(label: "Done", kind: .plain, effect: .dismiss)
            ]
        case .unknown:
            return [SNPayAction(label: "Hide \u{2014} we\u{2019}ll notify you", kind: .primary, effect: .dismiss)]
        }
    }

    /// paystatus.jsx `HOME` — the H1 pinned strip above the home list.
    static func homeStrip(
        _ phase: SNPayPhase, payee: String, sats: Int64
    ) -> (title: String, sub: String) {
        switch phase {
        case .resolving:
            return ("Preparing payment", "\(payee) \u{00B7} checking destination")
        case .paying:
            return ("Sending \(amount(sats)) sats", "\(payee) \u{00B7} tap for details")
        case .slow:
            return ("Taking longer than usual", "\(payee) \u{00B7} still in flight")
        case .sent:
            return ("Sent \(amount(sats)) sats", "\(payee) \u{00B7} proof stored")
        case .failedSafe:
            return ("Payment didn\u{2019}t go through", "\(payee) \u{00B7} you weren\u{2019}t charged")
        case .refunded:
            return ("Payment refunded", "\(payee) \u{00B7} \(amount(sats)) sats returned")
        case .unknown:
            return ("Confirming payment", "\(payee) \u{00B7} we\u{2019}ll notify you")
        }
    }
}
