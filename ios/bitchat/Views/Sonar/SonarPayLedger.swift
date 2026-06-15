//
// SonarPayLedger.swift
// bitchat
//
// ⚡PAY: the Sonar payment convention inside normal encrypted chat content
// (spec: docs/SONAR-PAYMENTS.md). A payment is a "sealed coin" message that
// rides the same rails as any DM (Bluetooth mesh or internet); actual sats
// settle over Lightning when the receiver claims it:
//
//   sender   →  ⚡PAY|1|<uuid>|<sats>          sealed coin appears in chat
//   receiver →  ⚡PAYCLAIM|1|<uuid>|<bolt12>   tap-to-claim, sends an offer
//   sender   →  ⚡PAYDONE|1|<uuid>             paid the offer, coin reveals
//
// Lines are only ever sent to Sonar-capable counterparts; on anything else
// (or an unknown version) they harmlessly render as plain text.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Combine
import Foundation

// MARK: - ⚡PAY codec

/// One ⚡PAY control line. Field separator is `|`; the bolt12 offer is the
/// last field of CLAIM so bech32 content never collides with the separator.
enum SonarPayMessage: Equatable {
    static let version = 1

    private static let payPrefix = "\u{26A1}PAY|"
    private static let claimPrefix = "\u{26A1}PAYCLAIM|"
    private static let donePrefix = "\u{26A1}PAYDONE|"

    /// Sealed coin: `⚡PAY|1|<uuid>|<sats>`.
    case pay(id: String, sats: Int64)
    /// Claim with a BOLT12 offer: `⚡PAYCLAIM|1|<uuid>|<bolt12offer>`.
    case claim(id: String, offer: String)
    /// Settled: `⚡PAYDONE|1|<uuid>`.
    case done(id: String)

    var id: String {
        switch self {
        case .pay(let id, _), .claim(let id, _), .done(let id): return id
        }
    }

    func encoded() -> String {
        switch self {
        case .pay(let id, let sats):
            return "\(Self.payPrefix)\(Self.version)|\(id)|\(sats)"
        case .claim(let id, let offer):
            return "\(Self.claimPrefix)\(Self.version)|\(id)|\(offer)"
        case .done(let id):
            return "\(Self.donePrefix)\(Self.version)|\(id)"
        }
    }

    /// Strict decode: nil for anything that isn't a well-formed v1 line
    /// (unknown versions fall back to plain text on purpose).
    static func decode(_ text: String) -> SonarPayMessage? {
        // Longest prefixes first: ⚡PAYCLAIM/⚡PAYDONE also start with ⚡PAY.
        if text.hasPrefix(claimPrefix) {
            let rest = text.dropFirst(claimPrefix.count)
            // version | uuid | offer (offer may itself never contain '|',
            // bech32 forbids it, but split conservatively anyway)
            let parts = rest.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3,
                  Int(parts[0]) == version,
                  isValidID(parts[1]),
                  !parts[2].isEmpty
            else { return nil }
            return .claim(id: String(parts[1]), offer: String(parts[2]))
        }
        if text.hasPrefix(donePrefix) {
            let rest = text.dropFirst(donePrefix.count)
            let parts = rest.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  Int(parts[0]) == version,
                  isValidID(parts[1])
            else { return nil }
            return .done(id: String(parts[1]))
        }
        if text.hasPrefix(payPrefix) {
            let rest = text.dropFirst(payPrefix.count)
            let parts = rest.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 3,
                  Int(parts[0]) == version,
                  isValidID(parts[1]),
                  let sats = Int64(parts[2]), sats > 0
            else { return nil }
            return .pay(id: String(parts[1]), sats: sats)
        }
        return nil
    }

    private static func isValidID(_ s: Substring) -> Bool {
        !s.isEmpty && s.count <= 64 && s.allSatisfy { $0.isHexDigit || $0 == "-" }
    }
}

// MARK: - Ledger

/// Local state of one payment, keyed by its uuid.
struct SonarPayEntry: Codable, Equatable {
    enum Direction: String, Codable {
        case outgoing
        case incoming
    }

    /// sealed → claiming (receiver sent the offer) / settling (sender is
    /// paying the offer) → claimed. Failures fall back to sealed.
    enum State: String, Codable {
        case sealed
        case claiming
        case settling
        case claimed
    }

    let id: String
    /// Conversation key the coin lives in (PeerID.id or "marmot:<groupId>").
    let peerKey: String
    let sats: Int64
    let direction: Direction
    var state: State
    /// Transport the sealed coin traveled over ("mesh"/"internet").
    let via: String
}

/// UserDefaults-persisted ledger of every ⚡PAY coin this device has sent
/// or received. Transitions are an explicit state machine so re-processing
/// the same control line (transcript replay after relaunch) is idempotent.
final class SonarPayLedger: ObservableObject {
    static let defaultsKey = "sonar.pay.ledger.v1"

    @Published private(set) var entries: [String: SonarPayEntry]

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = SonarPayLedger.defaultsKey) {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key),
           let stored = try? JSONDecoder().decode([String: SonarPayEntry].self, from: data) {
            entries = stored
        } else {
            entries = [:]
        }
    }

    func entry(for id: String) -> SonarPayEntry? {
        entries[id]
    }

    /// Records a new coin. Returns false (and changes nothing) when an
    /// entry with the same id already exists.
    @discardableResult
    func record(_ entry: SonarPayEntry) -> Bool {
        guard entries[entry.id] == nil else { return false }
        entries[entry.id] = entry
        persist()
        return true
    }

    /// Allowed transitions:
    ///   sealed   → claiming (receiver sent ⚡PAYCLAIM)
    ///   sealed   → settling (sender received ⚡PAYCLAIM, paying)
    ///   claiming → claimed  (receiver got ⚡PAYDONE)
    ///   settling → claimed  (sender's Lightning payment succeeded)
    ///   sealed   → claimed  (⚡PAYDONE raced ahead of local state)
    ///   claiming → sealed   (receiver's createOffer/send failed)
    ///   settling → sealed   (sender's Lightning payment failed)
    @discardableResult
    func transition(_ id: String, to newState: SonarPayEntry.State) -> Bool {
        guard var entry = entries[id] else { return false }
        let allowed: Bool
        switch (entry.state, newState) {
        case (.sealed, .claiming), (.sealed, .settling), (.sealed, .claimed),
             (.claiming, .claimed), (.settling, .claimed),
             (.claiming, .sealed), (.settling, .sealed):
            allowed = true
        default:
            allowed = false
        }
        guard allowed else { return false }
        entry.state = newState
        entries[id] = entry
        persist()
        return true
    }

    /// Emergency wipe: forget every payment.
    func wipe() {
        entries = [:]
        defaults.removeObject(forKey: key)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: key)
        }
    }
}
