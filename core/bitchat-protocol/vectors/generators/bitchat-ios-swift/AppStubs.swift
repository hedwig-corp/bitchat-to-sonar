import Foundation
import BitFoundation

enum NoisePayloadType: UInt8 {
    // Messages and status
    case privateMessage = 0x01      // Private chat message
    case readReceipt = 0x02         // Message was read
    case delivered = 0x03           // Message was delivered
    // Private groups (0x04/0x05 reserved by other features)
    case groupInvite = 0x06         // Creator-signed group state (invite)
    case groupKeyUpdate = 0x07      // Creator-signed group state (key rotation / roster update)
    // Live voice (push-to-talk)
    case voiceFrame = 0x08          // One live voice-burst packet (see VoiceBurstPacket)
    // Finalized private media. `0x20` is the value already deployed by the
    // Android client. The complete BitchatFilePacket is encrypted inside
    // Noise before the outer noiseEncrypted packet is fragmented.
    case privateFile = 0x20
    // Versioned peer state authenticated by the surrounding Noise session.
    // This is intentionally distinct from the public announce: announce
    // capabilities are discovery hints, while this payload proves possession
    // of the advertised Noise static key before downgrade state is pinned.
    case authenticatedPeerState = 0x21
    // Verification (QR-based OOB binding)
    case verifyChallenge = 0x10     // Verification challenge
    case verifyResponse  = 0x11     // Verification response
    // Transitive verification (web of trust)
    case vouch = 0x12               // Batch of vouch attestations

    /// #1434 briefly used 0x09 before release. Accept it while prerelease
    /// builds age out, but never emit it. Decoders canonicalize both values to
    /// `.privateFile` so the compatibility alias cannot leak into app logic.
    static let prereleasePrivateFileRawValue: UInt8 = 0x09

    static func decoded(rawValue: UInt8) -> NoisePayloadType? {
        rawValue == prereleasePrivateFileRawValue ? .privateFile : Self(rawValue: rawValue)
    }

    static func isPrivateFile(rawValue: UInt8?) -> Bool {
        guard let rawValue else { return false }
        return rawValue == privateFile.rawValue || rawValue == prereleasePrivateFileRawValue
    }

    var description: String {
        switch self {
        case .privateMessage: return "privateMessage"
        case .readReceipt: return "readReceipt"
        case .delivered: return "delivered"
        case .groupInvite: return "groupInvite"
        case .groupKeyUpdate: return "groupKeyUpdate"
        case .voiceFrame: return "voiceFrame"
        case .privateFile: return "privateFile"
        case .authenticatedPeerState: return "authenticatedPeerState"
        case .verifyChallenge: return "verifyChallenge"
        case .verifyResponse: return "verifyResponse"
        case .vouch: return "vouch"
        }
    }
}

// Minimal stubs so the upstream fragment planner compiles inside the package test target.
struct BLEOutboundFragmentTransferRequest {
    let packet: BitchatPacket
    let pad: Bool
    let maxChunk: Int?
    let directedPeer: PeerID?
    let transferId: String?
    let requireDirectPeerLink: Bool
    let requireNoiseAuthenticatedPeerLink: Bool
    init(packet: BitchatPacket, pad: Bool, maxChunk: Int?, directedPeer: PeerID?, transferId: String?,
         requireDirectPeerLink: Bool = false, requireNoiseAuthenticatedPeerLink: Bool = false) {
        self.packet = packet; self.pad = pad; self.maxChunk = maxChunk; self.directedPeer = directedPeer
        self.transferId = transferId; self.requireDirectPeerLink = requireDirectPeerLink
        self.requireNoiseAuthenticatedPeerLink = requireNoiseAuthenticatedPeerLink
    }
}
enum TransportConfig {
    static let bleFragmentSpacingMs: Int = 30
    static let bleFragmentSpacingDirectedMs: Int = 25
}
