import Foundation

// RelayDecision encapsulates a single relay scheduling choice.
struct RelayDecision {
    let shouldRelay: Bool
    let newTTL: UInt8
    let delayMs: Int
}

/// Keeps physical-link authentication separate from identities carried through
/// that link by the mesh. Announce and Sonar profile packets authenticate their
/// claimed sender at the protocol layer, so a decremented-TTL copy is a valid
/// relay candidate rather than an attempt to impersonate the direct neighbour.
struct MeshLinkSenderPolicy {
    static func preservesSigningIdentity(existing: Data?, announced: Data) -> Bool {
        existing == nil || existing == announced
    }

    static func allowsRelayedIdentityPacket(type: UInt8, ttl: UInt8) -> Bool {
        guard ttl > 0, ttl < TransportConfig.messageTTLDefault else { return false }
        return type == MessageType.announce.rawValue || type == SonarAnnouncePacket.packetType
    }

    static func isSelfEcho(senderIsSelf: Bool, ttl: UInt8) -> Bool {
        senderIsSelf && ttl > 0
    }

    /// What a packet from `claimed` may do on a bound link.
    enum Ingress: Equatable {
        /// From an identity the link already speaks for.
        case trusted
        /// A relayed announce or Sonar profile: validated as its claimed sender.
        case relayedIdentity
        /// A full-TTL announce from an identity the link does not speak for
        /// yet. Two mesh apps on one device share its radio, so this is the
        /// other app, provided its signature verifies (the caller checks).
        case candidateDirectIdentity
        case reject
    }

    static func ingress(claimed: PeerID, link: MeshLinkIdentities, type: UInt8, ttl: UInt8) -> Ingress {
        if link.carries(claimed) { return .trusted }
        if type == MessageType.announce.rawValue, ttl == TransportConfig.messageTTLDefault {
            return .candidateDirectIdentity
        }
        if allowsRelayedIdentityPacket(type: type, ttl: ttl) { return .relayedIdentity }
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
