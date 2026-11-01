import Foundation

// RelayDecision encapsulates a single relay scheduling choice.
struct RelayDecision {
    let shouldRelay: Bool
    let newTTL: UInt8
    let delayMs: Int
}

/// Keeps physical-link authentication separate from identities carried through
/// that link by the mesh. Every packet type authenticates its claimed sender at
/// the protocol layer, not by the link it arrived on: announces, Sonar profiles,
/// public messages and files are signed and checked against the pinned key, a
/// Noise handshake must match the sender's static key, Noise ciphertext only
/// opens with that sender's session, and a leave is verified before it evicts.
/// So a relayed packet from another sender is a relay candidate rather than an
/// attempt to impersonate the direct neighbour, as in upstream bitchat
/// (`BLEIngressLinkRegistry`).
struct MeshLinkSenderPolicy {
    static func preservesSigningIdentity(existing: Data?, announced: Data) -> Bool {
        existing == nil || existing == announced
    }

    /// Whether a packet from someone other than the link peer can have come
    /// through the link peer as a relay.
    ///
    /// - REQUEST_SYNC is never relayed: it asks the link peer to replay its
    ///   store to whoever the sender claims to be.
    /// - A relay decrements the TTL before forwarding, so a full-TTL packet
    ///   from someone else is not a relay.
    /// - TTL 0 is a sync reply. A flagged one (RSR) is checked against the link
    ///   peer's request (`RequestSyncManager`), not against its original
    ///   author; stock bitchat-android sends its replies unflagged (SPEC §12.1),
    ///   and those get the ordinary timestamp check.
    /// - Our own packet comes back only as a flagged reply. `isSelfEcho` drops
    ///   the TTL > 0 copies, and an unflagged TTL-0 copy would be shown as sent
    ///   by us without a signature check (`handleMessage`).
    static func allowsRelayedPacket(type: UInt8, ttl: UInt8, isRSR: Bool, senderIsSelf: Bool) -> Bool {
        guard type != MessageType.requestSync.rawValue,
              ttl < TransportConfig.messageTTLDefault else { return false }
        return !senderIsSelf || (ttl == 0 && isRSR)
    }

    static func isSelfEcho(senderIsSelf: Bool, ttl: UInt8) -> Bool {
        senderIsSelf && ttl > 0
    }

    /// What a packet from `claimed` may do on a bound link.
    enum Ingress: Equatable {
        /// From an identity the link already speaks for.
        case trusted
        /// Relayed by the link peer: validated as its claimed sender, or, for
        /// a sync reply, against the link peer's request.
        case relayed
        /// A full-TTL announce from an identity the link does not speak for
        /// yet. Two mesh apps on one device share its radio, so this is the
        /// other app, provided its signature verifies (the caller checks).
        case candidateDirectIdentity
        case reject
    }

    static func ingress(claimed: PeerID, link: MeshLinkIdentities, type: UInt8, ttl: UInt8, isRSR: Bool, senderIsSelf: Bool) -> Ingress {
        ingress(carriedByLink: link.carries(claimed), type: type, ttl: ttl, isRSR: isRSR, senderIsSelf: senderIsSelf)
    }

    /// The same decision for a link bound to a single identity (a peripheral).
    static func ingress(carriedByLink: Bool, type: UInt8, ttl: UInt8, isRSR: Bool, senderIsSelf: Bool) -> Ingress {
        if carriedByLink { return .trusted }
        if type == MessageType.announce.rawValue, ttl == TransportConfig.messageTTLDefault {
            return .candidateDirectIdentity
        }
        if allowsRelayedPacket(type: type, ttl: ttl, isRSR: isRSR, senderIsSelf: senderIsSelf) { return .relayed }
        return .reject
    }
}

/// The identities one BLE link speaks for.
///
/// A link usually carries one app, but two mesh apps on one device (Sonar
/// beside stock bitchat on Android, Sonar.app beside a bitchat build on a Mac)
/// share the device's radio: iOS sees one CBCentral writing both apps'
/// packets. The first full-TTL announce binds the link (`primary`, never
/// rebound, see #244); a further identity joins only after its own signed
/// full-TTL announce verifies.
struct MeshLinkIdentities {
    let primary: PeerID
    /// When each identity last announced at full TTL on this link.
    private(set) var lastDirectAnnounce: [PeerID: Date]

    init(primary: PeerID, at date: Date) {
        self.primary = primary
        self.lastDirectAnnounce = [primary: date]
    }

    func carries(_ peerID: PeerID) -> Bool {
        peerID == primary || lastDirectAnnounce[peerID] != nil
    }

    /// More than one app has announced directly on this link.
    var isShared: Bool { lastDirectAnnounce.keys.contains { $0 != primary } }

    /// Every identity that has announced directly on this link, `primary` first.
    var identities: [PeerID] {
        [primary] + lastDirectAnnounce.keys.filter { $0 != primary }.sorted { $0.id < $1.id }
    }

    mutating func noteDirectAnnounce(from peerID: PeerID, at date: Date) {
        lastDirectAnnounce[peerID] = date
    }

    /// Whether the link still vouches that `peerID` is directly reachable. A
    /// link that carries one app vouches for as long as it is up. On a shared
    /// link each identity has to keep announcing: the radio link outlives a
    /// co-located app that quit, so without this the quit app stays online.
    func vouches(for peerID: PeerID, now: Date, window: TimeInterval) -> Bool {
        guard carries(peerID) else { return false }
        guard isShared else { return true }
        guard let last = lastDirectAnnounce[peerID] else { return false }
        return now.timeIntervalSince(last) <= window
    }

    func vouchedPeers(now: Date, window: TimeInterval) -> Set<PeerID> {
        Set(lastDirectAnnounce.keys.filter { vouches(for: $0, now: now, window: window) })
    }
}

// RelayController centralizes flood control policy for relays.
struct RelayController {
    static func decide(ttl: UInt8,
                       senderIsSelf: Bool,
                       isEncrypted: Bool,
                       isDirectedEncrypted: Bool,
                       isFragment: Bool,
                       isDirectedFragment: Bool,
                       isHandshake: Bool,
                       isAnnounce: Bool,
                       degree: Int,
                       highDegreeThreshold: Int) -> RelayDecision {
        let ttlCap = min(ttl, TransportConfig.messageTTLDefault)

        // Suppress obvious non-relays
        if ttlCap <= 1 || senderIsSelf {
            return RelayDecision(shouldRelay: false, newTTL: ttlCap, delayMs: 0)
        }

        // For session-critical or directed traffic, be deterministic and reliable
        if isHandshake || isDirectedFragment || isDirectedEncrypted {
            // Always relay with no TTL cap for these types
            let newTTL = ttlCap &- 1
            // Slight jitter to desynchronize without adding too much latency
            // Tighter for faster multi-hop handshakes and directed DMs
            let delayRange: ClosedRange<Int> = isHandshake ? 10...35 : 20...60
            let delayMs = Int.random(in: delayRange)
            return RelayDecision(shouldRelay: true, newTTL: newTTL, delayMs: delayMs)
        }

        if isFragment {
            let ttlLimit = min(ttlCap, TransportConfig.bleFragmentRelayTtlCap)
            guard ttlLimit > 1 else {
                return RelayDecision(shouldRelay: false, newTTL: ttlLimit, delayMs: 0)
            }
            let newTTL = ttlLimit &- 1
            let delayMs = Int.random(in: TransportConfig.bleFragmentRelayMinDelayMs...TransportConfig.bleFragmentRelayMaxDelayMs)
            return RelayDecision(shouldRelay: true, newTTL: newTTL, delayMs: delayMs)
        }

        // TTL clamping for broadcast
        // - Dense graphs: keep lower but still allow multi-hop bridging
        // - Announces get a bit more headroom
        let ttlLimit: UInt8 = {
            if degree >= highDegreeThreshold {
                return max(UInt8(2), min(ttlCap, UInt8(5)))
            }
            let preferred = UInt8(isAnnounce ? 7 : 6)
            return max(UInt8(2), min(ttlCap, preferred))
        }()
        let newTTL = ttlLimit &- 1

        // Wider jitter window to allow duplicate suppression to win more often
        // For sparse graphs (<=2), relay quickly to avoid cancellation races
        let delayMs: Int
        switch degree {
        case 0...2: delayMs = Int.random(in: 10...40)
        case 3...5: delayMs = Int.random(in: 60...150)
        case 6...9: delayMs = Int.random(in: 80...180)
        default:    delayMs = Int.random(in: 100...220)
        }
        return RelayDecision(shouldRelay: true, newTTL: newTTL, delayMs: delayMs)
    }
}
