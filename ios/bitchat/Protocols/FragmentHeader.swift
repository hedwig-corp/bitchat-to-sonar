//
// FragmentHeader.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// The header of a bitchat fragment payload (packet type 0x20):
/// `fragmentID(8) | index u16 BE | total u16 BE | originalType(1) | data`.
///
/// Receive-side parse used by `BLEService`; the wire format is owned by
/// `core/bitchat-protocol` (SPEC.md §8.4) and pinned against both reference
/// clients by the cross-replay vectors
/// (`core/bitchat-protocol/vectors/cross/`). Upstream bitchat iOS has the
/// same parse as `BLEFragmentHeader`.
struct FragmentHeader: Equatable {
    /// Fragment id, big-endian, as the 8 leading payload bytes.
    let fragmentID: UInt64
    let index: Int
    let total: Int
    let originalType: UInt8
    let fragmentData: Data

    static let headerBytes = 13
    /// Upper bound on `total`: a fragment claiming more is a DoS attempt.
    static let maxTotal = 10_000

    /// The fragment payload `BLEService` sends: header followed by this
    /// fragment's slice of the encoded frame.
    static func encodePayload(fragmentID: Data, index: Int, total: Int, originalType: UInt8, data: Data) -> Data {
        var payload = Data()
        payload.reserveCapacity(headerBytes + data.count)
        payload.append(fragmentID)
        payload.append(contentsOf: withUnsafeBytes(of: UInt16(index).bigEndian) { Data($0) })
        payload.append(contentsOf: withUnsafeBytes(of: UInt16(total).bigEndian) { Data($0) })
        payload.append(originalType)
        payload.append(data)
        return payload
    }

    /// Nil when the payload is shorter than the header or the index/total
    /// pair is impossible (`total` 0 or over `maxTotal`, `index >= total`).
    init?(payload: Data) {
        guard payload.count >= Self.headerBytes else { return nil }
        let bytes = [UInt8](payload.prefix(Self.headerBytes))
        var id: UInt64 = 0
        for b in bytes[0..<8] { id = (id << 8) | UInt64(b) }
        let index = Int((UInt16(bytes[8]) << 8) | UInt16(bytes[9]))
        let total = Int((UInt16(bytes[10]) << 8) | UInt16(bytes[11]))
        guard total > 0 && total <= Self.maxTotal && index >= 0 && index < total else { return nil }
        self.fragmentID = id
        self.index = index
        self.total = total
        self.originalType = bytes[12]
        self.fragmentData = Data(payload.dropFirst(Self.headerBytes))
    }
}
