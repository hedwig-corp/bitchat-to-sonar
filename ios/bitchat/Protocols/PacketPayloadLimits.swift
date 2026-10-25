//
// PacketPayloadLimits.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Per-type ceilings on a decoded payload, checked before any allocation.
///
/// Mirrors `limits` in `core/bitchat-protocol/src/types.rs` (SPEC.md §11)
/// byte for byte, which in turn mirrors upstream bitchat iOS's
/// `PacketPayloadLimits`. One frame-wide cap is not enough: a ~1 KB compressed
/// frame may declare a megabyte, and a large frame can arrive as small
/// fragments. The cross-replay vectors (`core/bitchat-protocol/vectors/cross/`)
/// pin that Sonar iOS, Sonar Android and stock bitchat iOS give the same
/// verdict on over-cap frames.
enum PacketPayloadLimits {
    /// Largest `originalSize / compressedSize` a compressed payload may
    /// declare: DEFLATE's theoretical maximum is 1032:1.
    static let maxDeflateRatio = 1032

    private static let fragmentBytes = 1_280
    private static let controlBytes = 4 * 1024
    private static let requestSyncBytes = 8 * 1024
    private static let envelopeBytes = 64 * 1024
    private static let twiceV1FrameBytes = 128 * 1024

    /// Largest decoded payload for a packet of `type`, compressed or not.
    /// Unknown types (including Sonar's `0x53`) get the generic message cap.
    static func maxPayloadBytes(forType type: UInt8) -> Int {
        switch type {
        case 0x22, 0x11: // fileTransfer, noiseEncrypted
            return FileTransferLimits.maxFramedFileBytes
        case 0x02, 0x25: // message, groupMessage
            return twiceV1FrameBytes
        case 0x04, 0x28: // courierEnvelope, nostrCarrier
            return envelopeBytes
        case 0x21: // requestSync
            return requestSyncBytes
        case 0x20: // fragment
            return fragmentBytes
        case 0x01, 0x2C, 0x03, 0x23, 0x24, 0x29, 0x10, 0x26, 0x27:
            // announce, announceV2, leave, boardPost, prekeyBundle,
            // voiceFrame, noiseHandshake, ping, pong
            return controlBytes
        default:
            return twiceV1FrameBytes
        }
    }
}
