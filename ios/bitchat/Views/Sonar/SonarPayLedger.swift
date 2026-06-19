//
// SonarPayLedger.swift
// bitchat
//
// ⚡PAY: the Sonar payment convention inside normal encrypted chat content
// (spec: docs/SONAR-PAYMENTS.md). Payments settle over Lightning first, then
// ride the same encrypted chat rails as receipt/control lines:
//
//   sender →  ⚡PAY|1|<uuid>|<sats>   payment receipt appears in chat
//   sender →  ⚡PAYDONE|1|<uuid>      confirms the Lightning payment settled
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

/// One ⚡PAY control line. Field separator is `|`.
enum SonarPayMessage: Equatable {
    static let version = 1

    private static let payPrefix = "\u{26A1}PAY|"
    private static let donePrefix = "\u{26A1}PAYDONE|"

    /// Payment receipt: `⚡PAY|1|<uuid>|<sats>`.
    case pay(id: String, sats: Int64)
    /// Settled: `⚡PAYDONE|1|<uuid>`.
    case done(id: String)

    var id: String {
        switch self {
        case .pay(let id, _), .done(let id): return id
        }
    }

    func encoded() -> String {
        switch self {
        case .pay(let id, let sats):
            return "\(Self.payPrefix)\(Self.version)|\(id)|\(sats)"
        case .done(let id):
            return "\(Self.donePrefix)\(Self.version)|\(id)"
        }
    }

    /// Strict decode: nil for anything that isn't a well-formed v1 line
    /// (unknown versions fall back to plain text on purpose).
    static func decode(_ text: String) -> SonarPayMessage? {
        // DONE also starts with "⚡PAY", so check it first.
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

    /// Direct receipts use sealed/pending → claimed. The claiming/settling cases
    /// remain decodeable for previously persisted rows from older builds.
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
    /// Transport the receipt traveled over ("mesh"/"internet").
    let via: String
}

/// UserDefaults-persisted ledger of every ⚡PAY coin this device has sent
/// or received. Transitions are an explicit state machine so re-processing
/// the same control line (transcript replay after relaunch) is idempotent.
final class SonarPayLedger: ObservableObject {
    static let defaultsKey = "sonar.pay.ledger.v1"

    @Published private(set) var entries: [String: SonarPayEntry]
    private var pendingDoneIDs = Set<String>()

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
        var stored = entry
        let doneWasPending = pendingDoneIDs.remove(entry.id) != nil
        if stored.direction == .incoming, doneWasPending {
            stored.state = .claimed
        }
        entries[entry.id] = stored
        persist()
        return true
    }

    /// Marks an incoming coin claimed, or remembers the DONE when relay order
    /// delivers it before the matching PAY line.
    @discardableResult
    func markIncomingClaimedOrPending(_ id: String) -> Bool {
        guard let entry = entries[id] else {
            pendingDoneIDs.insert(id)
            return false
        }
        guard entry.direction == .incoming else { return false }
        return transition(id, to: .claimed)
    }

    /// Allowed transitions: any pending receipt state can become claimed when
    /// ⚡PAYDONE arrives. Old claiming/settling rows can still complete.
    @discardableResult
    func transition(_ id: String, to newState: SonarPayEntry.State) -> Bool {
        guard var entry = entries[id] else { return false }
        let allowed: Bool
        switch (entry.state, newState) {
        case (.sealed, .claimed), (.claiming, .claimed), (.settling, .claimed):
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
        pendingDoneIDs = []
        defaults.removeObject(forKey: key)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: key)
        }
    }
}

// MARK: - Direct wallet payment activity

/// Local activity for direct wallet payments (Sonar metadata BOLT12 or Unify).
/// Unlike `SonarPayEntry`, this is not a claimable chat state machine: money is
/// paid directly by the wallet and the wallet payment id is the settlement link.
struct SonarPaymentActivity: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case sonarDirect
        case unifyNearby
        case walletIncoming
    }

    enum Direction: String, Codable {
        case outgoing
        case incoming
    }

    enum Status: String, Codable {
        case pending
        case paid
        case failed
    }

    let id: String
    let kind: Kind
    let peerKey: String
    let peerName: String
    let direction: Direction
    let sats: Int64
    let via: String
    let createdAt: Date
    let destinationHash: String?
    var status: Status
    var walletPaymentId: String?
    var feesSats: Int64?
    var settledAt: Date?
    var failure: String?

    init(
        id: String,
        kind: Kind,
        peerKey: String,
        peerName: String,
        direction: Direction,
        sats: Int64,
        via: String,
        createdAt: Date,
        destinationHash: String?,
        status: Status,
        walletPaymentId: String? = nil,
        feesSats: Int64? = nil,
        settledAt: Date? = nil,
        failure: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.peerKey = peerKey
        self.peerName = peerName
        self.direction = direction
        self.sats = sats
        self.via = via
        self.createdAt = createdAt
        self.destinationHash = destinationHash
        self.status = status
        self.walletPaymentId = walletPaymentId
        self.feesSats = feesSats
        self.settledAt = settledAt
        self.failure = failure
    }
}

final class SonarPaymentActivityLedger: ObservableObject {
    static let defaultsKey = "sonar.payment.activity.v1"

    @Published private(set) var entries: [String: SonarPaymentActivity]

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = SonarPaymentActivityLedger.defaultsKey) {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key),
           let stored = try? JSONDecoder().decode([String: SonarPaymentActivity].self, from: data) {
            entries = stored
        } else {
            entries = [:]
        }
    }

    var sorted: [SonarPaymentActivity] {
        entries.values.sorted {
            ($0.settledAt ?? $0.createdAt) > ($1.settledAt ?? $1.createdAt)
        }
    }

    func activities(peerKey: String) -> [SonarPaymentActivity] {
        sorted.filter { $0.peerKey == peerKey }
    }

    @discardableResult
    func recordPending(_ activity: SonarPaymentActivity) -> Bool {
        guard entries[activity.id] == nil else { return false }
        entries[activity.id] = activity
        persist()
        return true
    }

    @discardableResult
    func markPaid(_ id: String, payment: SonarWalletPayment) -> Bool {
        guard var entry = entries[id] else { return false }
        entry.status = .paid
        entry.walletPaymentId = payment.id
        entry.feesSats = payment.feesSats
        entry.settledAt = payment.timestamp
        entry.failure = nil
        entries[id] = entry
        persist()
        return true
    }

    @discardableResult
    func markFailed(_ id: String, message: String) -> Bool {
        guard var entry = entries[id] else { return false }
        entry.status = .failed
        entry.failure = message
        entry.settledAt = Date()
        entries[id] = entry
        persist()
        return true
    }

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
