//
// SonarVectorDump.swift
// Dumps byte-exact test vectors from the upstream bitchat encoders to JSON
// so a foreign (Rust) implementation can be checked against them.
//

import Testing
import Foundation
@testable import BitFoundation

/// Where the JSON lands: `SONAR_VECTOR_OUT` (set by
/// scripts/bitchat-vectors/regenerate.sh) or a file next to the package.
private let outputPath: String =
    ProcessInfo.processInfo.environment["SONAR_VECTOR_OUT"]
    ?? FileManager.default.currentDirectoryPath + "/sonar-bitchat-ios-vectors.json"

// MARK: - helpers

private func hx(_ d: Data?) -> Any { d.map { $0.hexEncodedString() } ?? NSNull() }
private func hx(_ d: Data) -> String { d.hexEncodedString() }
private func hxList(_ l: [Data]?) -> Any { l.map { $0.map { $0.hexEncodedString() } } ?? NSNull() }
private func bytes(_ s: String) -> Data { Data(hexString: s.replacingOccurrences(of: " ", with: ""))! }
private func rep(_ b: UInt8, _ n: Int) -> Data { Data(repeating: b, count: n) }
private func seq(_ n: Int, _ f: (Int) -> UInt8) -> Data { Data((0..<n).map(f)) }
private func ascii(_ s: String) -> Data { Data(s.utf8) }
private func repeatText(_ s: String, upTo n: Int) -> Data {
    var d = Data()
    while d.count < n { d.append(ascii(s)) }
    return Data(d.prefix(n))
}
private func repeatText(_ s: String, times: Int) -> Data {
    var d = Data()
    for _ in 0..<times { d.append(ascii(s)) }
    return d
}
private func be16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xff)]) }
private func be32(_ v: UInt32) -> Data { Data([UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]) }
private func be64(_ v: UInt64) -> Data { Data((0..<8).map { UInt8((v >> UInt64(56 - 8 * $0)) & 0xff) }) }

private final class Cases {
    var list: [[String: Any]] = []
    func add(_ name: String, _ kind: String, input: [String: Any], expected: [String: Any]) {
        list.append(["name": name, "kind": kind, "input": input, "expected": expected])
    }
}

// Shared payloads
private let zeros99 = rep(0, 99)
private let zeros100 = rep(0, 100)
private let unique100 = seq(100) { UInt8($0) }
private let compressMe300 = repeatText("compress-me", upTo: 300)
private let bytes256 = seq(256) { UInt8($0) }
private let mod512 = seq(512) { UInt8($0 % 256) }
private let fox1000 = repeatText("The quick brown fox jumps over the lazy dog. ", upTo: 1000)

// Hand-built raw frame (no padding) for reject vectors.
private func rawFrame(version: UInt8, type: UInt8, ttl: UInt8, ts: UInt64, flags: UInt8,
                      declaredLength: Int, sender: Data, recipient: Data? = nil, body: Data) -> Data {
    var d = Data([version, type, ttl])
    d.append(be64(ts))
    d.append(flags)
    if version == 2 { d.append(be32(UInt32(declaredLength))) } else { d.append(be16(UInt16(declaredLength))) }
    d.append(sender)
    if let r = recipient { d.append(r) }
    d.append(body)
    return d
}

struct SonarVectorDump {

    @Test func dumpVectors() throws {
        let c = Cases()

        // MARK: padding
        for (data, target) in [(ascii("abc"), 16), (ascii("abc"), 3), (ascii("abc"), 2), (ascii("abc"), 258), (ascii("abc"), 259), (Data(), 1), (Data(), 255), (Data(), 256), (rep(0xaa, 240), 256), (rep(0xaa, 100), 256), (rep(0xbb, 300), 512)] {
            let padded = MessagePadding.pad(data, toSize: target)
            c.add("pad_\(data.count)_to_\(target)", "padding",
                  input: ["data": hx(data), "target": target],
                  expected: ["padded": hx(padded)])
        }
        for size in [0, 10, 239, 240, 241, 495, 496, 497, 1000, 2032, 2033, 3000] {
            c.add("optimal_block_\(size)", "optimal_block_size",
                  input: ["size": size], expected: ["block": MessagePadding.optimalBlockSize(for: size)])
        }

        // MARK: unpad
        let unpadInputs: [(String, Data)] = [
            ("unpad_valid_abc_16", MessagePadding.pad(ascii("abc"), toSize: 16)),
            ("unpad_valid_hi_0202", bytes("68690202")),
            ("unpad_single_01", bytes("6869 01")),
            ("unpad_non_padded_0102030405", bytes("0102030405")),
            ("unpad_invalid_tail_01020303", bytes("01020303")),
            ("unpad_zero_last_byte", bytes("00000000")),
            ("unpad_length_exceeds_count", bytes("ff")),
            ("unpad_empty", Data()),
            ("unpad_all_pad_bytes_0404", bytes("04040404")),
        ]
        for (name, d) in unpadInputs {
            c.add(name, "unpad", input: ["data": hx(d)], expected: ["unpadded": hx(MessagePadding.unpad(d))])
        }

        // MARK: should_compress / compress
        let compressPayloads: [(String, Data)] = [
            ("zeros_99", zeros99), ("zeros_100", zeros100), ("unique_100", unique100),
            ("compress_me_300", compressMe300), ("bytes_0_255", bytes256), ("mod256_512", mod512),
        ]
        for (name, p) in compressPayloads {
            c.add("should_compress_\(name)", "should_compress", input: ["payload": hx(p)],
                  expected: ["result": CompressionUtil.shouldCompress(p)])
        }
        for (name, p) in compressPayloads + [("fox_1000", fox1000)] {
            c.add("compress_\(name)", "compress", input: ["payload": hx(p)],
                  expected: ["compressed": hx(CompressionUtil.compress(p))])
        }

        // MARK: packet_encode
        let senderA = bytes("1122334455667788")
        let recipB = bytes("8877665544332211")
        let bcast = bytes("ffffffffffffffff")
        let sigA0 = seq(64) { UInt8(0xA0 &+ UInt8($0)) }
        let sig22 = rep(0x22, 64)
        let route3 = [bytes("0102030405060708"), bytes("1112131415161718"), bytes("2122232425262728")]
        var announceAlice: Data? = nil
        if let a = AnnouncementPacket(nickname: "alice", noisePublicKey: rep(1, 32), signingPublicKey: rep(2, 32), directNeighbors: nil).encode() {
            announceAlice = a
        }
        var sonarAnnounce = bytes("01010102 20")
        sonarAnnounce.append(rep(0x42, 32)); sonarAnnounce.append(bytes("040103"))

        struct PE { let name: String; let p: BitchatPacket }
        var pe: [PE] = [
            PE(name: "v1_broadcast_hello", p: BitchatPacket(type: 0x02, senderID: senderA, recipientID: nil, timestamp: 1709600000000, payload: ascii("Hello mesh"), signature: nil, ttl: 7)),
            PE(name: "v1_recipient_signed", p: BitchatPacket(type: 0x02, senderID: senderA, recipientID: recipB, timestamp: 1709600000000, payload: ascii("Private signed"), signature: sigA0, ttl: 7)),
            PE(name: "v1_broadcast_sentinel_zeros100_compressed", p: BitchatPacket(type: 0x02, senderID: senderA, recipientID: bcast, timestamp: 1709600000000, payload: zeros100, signature: nil, ttl: 7)),
            PE(name: "v1_compress_me_300_signed", p: BitchatPacket(type: 0x02, senderID: senderA, recipientID: nil, timestamp: 1709600000000, payload: compressMe300, signature: sig22, ttl: 7)),
            PE(name: "v1_bytes_0_255_not_compressed", p: BitchatPacket(type: 0x02, senderID: senderA, recipientID: nil, timestamp: 1709600000000, payload: bytes256, signature: nil, ttl: 7)),
            PE(name: "v2_route3_route_test", p: BitchatPacket(type: 0x01, senderID: senderA, recipientID: bytes("2122232425262728"), timestamp: 1720000000000, payload: ascii("route-test"), signature: nil, ttl: 6, version: 2, route: route3)),
            PE(name: "v2_route3_compressed", p: BitchatPacket(type: 0x03, senderID: senderA, recipientID: nil, timestamp: 1740000000000, payload: repeatText("compress-me", times: 150), signature: nil, ttl: 7, version: 2, route: route3)),
            PE(name: "v1_rsr_flag", p: BitchatPacket(type: 0x02, senderID: senderA, recipientID: nil, timestamp: 1709600000000, payload: ascii("rsr"), signature: nil, ttl: 7, isRSR: true)),
            PE(name: "v2_type22_70000_recipient_signed", p: BitchatPacket(type: 0x22, senderID: senderA, recipientID: recipB, timestamp: 1709600000000, payload: seq(70000) { UInt8(($0 * 7) % 251) }, signature: sigA0, ttl: 7, version: 2)),
            PE(name: "v1_type53_sonar_announce", p: BitchatPacket(type: 0x53, senderID: senderA, recipientID: nil, timestamp: 1709600000000, payload: sonarAnnounce, signature: nil, ttl: 7)),
        ]
        if let a = announceAlice {
            pe.append(PE(name: "v1_type01_announce_alice", p: BitchatPacket(type: 0x01, senderID: senderA, recipientID: nil, timestamp: 1709600000000, payload: a, signature: nil, ttl: 7)))
        }
        pe.append(PE(name: "v1_zeros_65535_compressed", p: BitchatPacket(type: 0x02, senderID: senderA, recipientID: nil, timestamp: 1709600000000, payload: rep(0, 65535), signature: nil, ttl: 7)))
        pe.append(PE(name: "v1_zeros_65536_too_large", p: BitchatPacket(type: 0x02, senderID: senderA, recipientID: nil, timestamp: 1709600000000, payload: rep(0, 65536), signature: nil, ttl: 7)))
        // v1 with a route set: route must be ignored (v1 has no HAS_ROUTE).
        pe.append(PE(name: "v1_route_ignored", p: BitchatPacket(type: 0x02, senderID: senderA, recipientID: nil, timestamp: 1709600000000, payload: ascii("v1 route"), signature: nil, ttl: 7, version: 1, route: route3)))
        // v2 with no route: no HAS_ROUTE flag, 4-byte length.
        pe.append(PE(name: "v2_no_route", p: BitchatPacket(type: 0x02, senderID: senderA, recipientID: nil, timestamp: 1720000000000, payload: ascii("v2 plain"), signature: nil, ttl: 5, version: 2)))
        // Packet exactly at the pad threshold boundaries (payload sized so unpadded frame = 240 / 241 bytes).
        pe.append(PE(name: "v1_frame_240_bytes", p: BitchatPacket(type: 0x02, senderID: senderA, recipientID: nil, timestamp: 1709600000000, payload: seq(218) { UInt8($0) }, signature: nil, ttl: 7)))
        pe.append(PE(name: "v1_frame_241_bytes", p: BitchatPacket(type: 0x02, senderID: senderA, recipientID: nil, timestamp: 1709600000000, payload: seq(219) { UInt8($0) }, signature: nil, ttl: 7)))
        // Frame far below 256 after a big uncompressible jump: 2048-16 .. above 2048 -> padding skipped (>255 needed) or no bucket.
        pe.append(PE(name: "v1_frame_above_2048_unpadded", p: BitchatPacket(type: 0x02, senderID: senderA, recipientID: nil, timestamp: 1709600000000, payload: seq(2100) { UInt8(($0 * 7) % 251) }, signature: nil, ttl: 7)))
        pe.append(PE(name: "v1_frame_1030_pad_more_than_255_skipped", p: BitchatPacket(type: 0x02, senderID: senderA, recipientID: nil, timestamp: 1709600000000, payload: seq(1008) { UInt8(($0 * 7) % 251) }, signature: nil, ttl: 7)))
        // Short sender id (4 bytes) gets zero padded to 8; long signature truncated to 64.
        pe.append(PE(name: "v1_short_sender_long_sig", p: BitchatPacket(type: 0x02, senderID: bytes("aabbccdd"), recipientID: nil, timestamp: 1709600000000, payload: ascii("short"), signature: rep(0x11, 70), ttl: 7)))

        for e in pe {
            let p = e.p
            var input: [String: Any] = [
                "version": Int(p.version), "type": Int(p.type), "ttl": Int(p.ttl), "timestamp": p.timestamp,
                "sender_id": hx(p.senderID), "recipient_id": hx(p.recipientID), "route": hxList(p.route),
                "payload": hx(p.payload), "signature": hx(p.signature), "is_rsr": p.isRSR,
            ]
            input["should_compress"] = CompressionUtil.shouldCompress(p.payload)
            var expected: [String: Any] = [:]
            let padded = BinaryProtocol.encode(p, padding: true)
            let unpadded = BinaryProtocol.encode(p, padding: false)
            expected["padded"] = hx(padded)
            expected["unpadded"] = hx(unpadded)
            if let padded, let unpadded {
                expected["signing_preimage"] = hx(p.toBinaryDataForSigning())
                let decoded = BinaryProtocol.decode(padded)
                #expect(decoded != nil, "decode failed for \(e.name)")
                expected["decoded_payload"] = hx(decoded?.payload)
                expected["decoded_flags"] = Int(unpadded[11])
                if let decoded {
                    #expect(decoded.payload == p.payload, "payload roundtrip \(e.name)")
                    expected["decoded_route"] = hxList(decoded.route)
                    expected["decoded_is_rsr"] = decoded.isRSR
                    expected["decoded_ttl"] = Int(decoded.ttl)
                    expected["decoded_recipient_id"] = hx(decoded.recipientID)
                    expected["decoded_signature"] = hx(decoded.signature)
                    expected["decoded_sender_id"] = hx(decoded.senderID)
                }
                // Unpadded frames must decode too.
                #expect(BinaryProtocol.decode(unpadded)?.payload == p.payload, "unpadded decode \(e.name)")
            }
            c.add(e.name, "packet_encode", input: input, expected: expected)
        }

        // MARK: packet_decode_reject
        let ts: UInt64 = 1709600000000
        var rejects: [(String, Data)] = []
        rejects.append(("truncated_header_10_bytes", Data(BinaryProtocol.encode(pe[0].p, padding: false)!.prefix(10))))
        var v3 = BinaryProtocol.encode(pe[0].p, padding: false)!; v3[0] = 3
        rejects.append(("version_3", v3))
        rejects.append(("declared_length_exceeds_data", rawFrame(version: 1, type: 0x02, ttl: 7, ts: ts, flags: 0, declaredLength: 0xffff, sender: senderA, body: rep(0x41, 10))))
        rejects.append(("compressed_flag_payload_length_1", rawFrame(version: 1, type: 0x02, ttl: 7, ts: ts, flags: 0x04, declaredLength: 1, sender: senderA, body: Data([0x00]))))
        rejects.append(("v2_announce_payload_5000_over_cap", rawFrame(version: 2, type: 0x01, ttl: 7, ts: ts, flags: 0, declaredLength: 5000, sender: senderA, body: rep(0x41, 5000))))
        rejects.append(("v1_fragment_payload_1300_over_cap", rawFrame(version: 1, type: 0x20, ttl: 7, ts: ts, flags: 0, declaredLength: 1300, sender: senderA, body: rep(0x41, 1300))))
        rejects.append(("compressed_flag_payload_length_2_no_body", rawFrame(version: 1, type: 0x02, ttl: 7, ts: ts, flags: 0x04, declaredLength: 2, sender: senderA, body: be16(10))))
        rejects.append(("compressed_impossible_ratio", rawFrame(version: 1, type: 0x02, ttl: 7, ts: ts, flags: 0x04, declaredLength: 3, sender: senderA, body: be16(65535) + Data([0x00]))))
        rejects.append(("has_recipient_flag_but_missing_recipient", rawFrame(version: 1, type: 0x02, ttl: 7, ts: ts, flags: 0x01, declaredLength: 0, sender: senderA, body: Data())))
        rejects.append(("has_signature_flag_but_short_signature", rawFrame(version: 1, type: 0x02, ttl: 7, ts: ts, flags: 0x02, declaredLength: 2, sender: senderA, body: bytes("6869") + rep(0xaa, 63))))
        rejects.append(("v2_route_flag_count_3_only_2_hops", rawFrame(version: 2, type: 0x02, ttl: 7, ts: ts, flags: 0x08, declaredLength: 0, sender: senderA, body: Data([3]) + route3[0] + route3[1])))
        rejects.append(("v2_announce_compressed_declares_5000", rawFrame(version: 2, type: 0x01, ttl: 7, ts: ts, flags: 0x04, declaredLength: 4 + CompressionUtil.compress(rep(0, 5000))!.count, sender: senderA, body: be32(5000) + CompressionUtil.compress(rep(0, 5000))!)))
        rejects.append(("version_0", rawFrame(version: 0, type: 0x02, ttl: 7, ts: ts, flags: 0, declaredLength: 2, sender: senderA, body: bytes("6869"))))
        for (name, d) in rejects {
            let decoded = BinaryProtocol.decode(d)
            #expect(decoded == nil, "expected reject for \(name)")
            c.add(name, "packet_decode_reject", input: ["bytes": hx(d)], expected: ["decodes": decoded != nil])
        }
        // Controls (asserted, not emitted): at-cap frames must decode.
        #expect(BinaryProtocol.decode(rawFrame(version: 1, type: 0x20, ttl: 7, ts: ts, flags: 0, declaredLength: 1280, sender: senderA, body: rep(0x41, 1280))) != nil)
        #expect(BinaryProtocol.decode(rawFrame(version: 2, type: 0x01, ttl: 7, ts: ts, flags: 0, declaredLength: 4096, sender: senderA, body: rep(0x41, 4096))) != nil)
        // Extra accept vectors: v1 with HAS_ROUTE flag set is ignored (no route bytes are read).
        let v1RouteFlag = rawFrame(version: 1, type: 0x02, ttl: 7, ts: ts, flags: 0x08, declaredLength: 2, sender: senderA, body: bytes("6869"))
        if let d = BinaryProtocol.decode(v1RouteFlag) {
            c.add("v1_has_route_flag_ignored", "packet_decode_accept", input: ["bytes": hx(v1RouteFlag)],
                  expected: ["decodes": true, "payload": hx(d.payload), "route": hxList(d.route), "flags": 0x08])
        }
        // v2 HAS_ROUTE with count 0 -> route nil.
        let v2Route0 = rawFrame(version: 2, type: 0x02, ttl: 7, ts: ts, flags: 0x08, declaredLength: 2, sender: senderA, body: Data([0]) + bytes("6869"))
        if let d = BinaryProtocol.decode(v2Route0) {
            c.add("v2_has_route_flag_count_0", "packet_decode_accept", input: ["bytes": hx(v2Route0)],
                  expected: ["decodes": true, "payload": hx(d.payload), "route": hxList(d.route)])
        }
        // Trailing garbage after a complete frame is accepted when it is not valid padding.
        let trailing = BinaryProtocol.encode(pe[0].p, padding: false)! + bytes("deadbeef00")
        if let d = BinaryProtocol.decode(trailing) {
            c.add("trailing_bytes_after_frame_accepted", "packet_decode_accept", input: ["bytes": hx(trailing)],
                  expected: ["decodes": true, "payload": hx(d.payload)])
        } else {
            c.add("trailing_bytes_after_frame_rejected", "packet_decode_reject", input: ["bytes": hx(trailing)], expected: ["decodes": false])
        }
        // Frame with 2-byte length field but payload shorter than declared by exactly the padding -> decode after unpad
        // (already covered by padded vectors). Also a frame whose padding bytes look like a longer payload:
        let padded0 = BinaryProtocol.encode(pe[0].p, padding: true)!
        c.add("padded_frame_decodes_after_unpad", "packet_decode_accept", input: ["bytes": hx(padded0)],
              expected: ["decodes": BinaryProtocol.decode(padded0) != nil, "payload": hx(BinaryProtocol.decode(padded0)?.payload)])

        // MARK: peer_id
        for key in [rep(1, 32), rep(0xff, 32), seq(32) { UInt8($0) }] {
            let pid = PeerID(publicKey: key)
            c.add("peer_id_\(hx(key).prefix(8))", "peer_id", input: ["noise_public_key": hx(key)],
                  expected: ["peer_id": pid.id, "bare": pid.bare, "sha256": key.sha256Fingerprint()])
        }

        // MARK: capabilities
        for raw: UInt64 in [0, 1, 0x100, 0x300, 0x7ff, 0x10000, 0xffffffffffffffff] {
            c.add("caps_encode_\(String(raw, radix: 16))", "capabilities", input: ["raw": raw],
                  expected: ["encoded": hx(PeerCapabilities(rawValue: raw).encoded())])
        }
        for enc in ["", "00", "0001", "0003", "ffffffffffffffffff", "0000", "ff", "0100000000000000"] {
            let d = enc.isEmpty ? Data() : bytes(enc)
            c.add("caps_decode_\(enc.isEmpty ? "empty" : enc)", "capabilities", input: ["encoded": enc],
                  expected: ["raw": PeerCapabilities(encoded: d).rawValue, "reencoded": hx(PeerCapabilities(encoded: d).encoded())])
        }

        // MARK: announce_tlv
        struct AN { let nick: String; let noise: Data; let sign: Data; let nb: [Data]?; let caps: UInt64?; let geo: String? }
        let ans: [AN] = [
            AN(nick: "alice", noise: rep(1, 32), sign: rep(2, 32), nb: nil, caps: nil, geo: nil),
            AN(nick: "bob", noise: rep(3, 32), sign: rep(4, 32), nb: [bytes("0102030405060708"), bytes("1112131415161718")], caps: 0x100, geo: nil),
            AN(nick: "carol", noise: rep(5, 32), sign: rep(6, 32), nb: nil, caps: 0x301, geo: "u4pruyd"),
            AN(nick: String(repeating: "x", count: 255), noise: rep(7, 32), sign: rep(8, 32), nb: nil, caps: nil, geo: nil),
            AN(nick: String(repeating: "x", count: 256), noise: rep(7, 32), sign: rep(8, 32), nb: nil, caps: nil, geo: nil),
            AN(nick: "dave", noise: rep(9, 32), sign: rep(10, 32), nb: [], caps: 0, geo: nil),
            AN(nick: "erin", noise: rep(11, 32), sign: rep(12, 32), nb: (0..<12).map { rep(UInt8(0x30 + $0), 8) }, caps: nil, geo: nil),
            AN(nick: "frank", noise: rep(13, 32), sign: rep(14, 32), nb: [bytes("01020304")], caps: nil, geo: "toolonggeohash"),
            AN(nick: "", noise: rep(15, 32), sign: rep(16, 32), nb: nil, caps: nil, geo: ""),
            AN(nick: "héllo😀", noise: rep(17, 32), sign: rep(18, 32), nb: nil, caps: 0xffffffffffffffff, geo: "9q8yy"),
        ]
        for (i, a) in ans.enumerated() {
            let pkt = AnnouncementPacket(nickname: a.nick, noisePublicKey: a.noise, signingPublicKey: a.sign, directNeighbors: a.nb,
                                         capabilities: a.caps.map { PeerCapabilities(rawValue: $0) }, bridgeGeohash: a.geo)
            let enc = pkt.encode()
            var exp: [String: Any] = ["encoded": hx(enc)]
            if let enc, let dec = AnnouncementPacket.decode(from: enc) {
                exp["roundtrip"] = ["nickname": dec.nickname, "noise_public_key": hx(dec.noisePublicKey), "signing_public_key": hx(dec.signingPublicKey),
                                    "direct_neighbors": hxList(dec.directNeighbors), "capabilities": dec.capabilities.map { $0.rawValue } ?? NSNull(),
                                    "bridge_geohash": dec.bridgeGeohash ?? NSNull()] as [String: Any]
            }
            c.add("announce_\(i)_\(a.nick.prefix(5))", "announce_tlv",
                  input: ["nickname": a.nick, "noise_public_key": hx(a.noise), "signing_public_key": hx(a.sign),
                          "direct_neighbors": hxList(a.nb), "capabilities": a.caps ?? NSNull(), "bridge_geohash": a.geo ?? NSNull()],
                  expected: exp)
        }

        // MARK: announce_decode
        func annDecodeCase(_ name: String, _ d: Data) {
            var exp: [String: Any] = ["decodes": false]
            if let dec = AnnouncementPacket.decode(from: d) {
                exp = ["decodes": true, "nickname": dec.nickname, "noise_public_key": hx(dec.noisePublicKey), "signing_public_key": hx(dec.signingPublicKey),
                       "direct_neighbors": hxList(dec.directNeighbors), "capabilities": dec.capabilities.map { $0.rawValue } ?? NSNull(),
                       "bridge_geohash": dec.bridgeGeohash ?? NSNull()]
            }
            c.add(name, "announce_decode", input: ["bytes": hx(d)], expected: exp)
        }
        let nickTLV = bytes("0105") + ascii("alice")
        let noiseTLV = bytes("0220") + rep(1, 32)
        let signTLV = bytes("0320") + rep(2, 32)
        annDecodeCase("announce_unknown_tlv_7f_skipped", nickTLV + bytes("7f03aabbcc") + noiseTLV + signTLV)
        annDecodeCase("announce_missing_signing_key", nickTLV + noiseTLV)
        annDecodeCase("announce_tlv_length_overrun", nickTLV + noiseTLV + bytes("0320") + rep(2, 31))
        annDecodeCase("announce_trailing_single_byte_ignored", nickTLV + noiseTLV + signTLV + bytes("05"))
        annDecodeCase("announce_duplicate_nickname_last_wins", nickTLV + bytes("0103") + ascii("bob") + noiseTLV + signTLV)
        annDecodeCase("announce_neighbors_not_multiple_of_8_ignored", nickTLV + noiseTLV + signTLV + bytes("0404 01020304"))
        annDecodeCase("announce_geohash_13_bytes_ignored", nickTLV + noiseTLV + signTLV + bytes("060d") + ascii("abcdefghijklm"))
        annDecodeCase("announce_caps_9_bytes", nickTLV + noiseTLV + signTLV + bytes("0509 010000000000000000"))
        annDecodeCase("announce_empty_caps_tlv", nickTLV + noiseTLV + signTLV + bytes("0500"))
        annDecodeCase("announce_empty", Data())
        annDecodeCase("announce_noise_key_16_bytes_accepted", nickTLV + bytes("0210") + rep(1, 16) + signTLV)

        // MARK: peer_state_tlv
        let aps = AuthenticatedPeerStatePacket(capabilities: PeerCapabilities(rawValue: 0x100), signingPublicKey: rep(7, 32))
        let apsEnc = aps.encode()
        c.add("peer_state_encode_0x100", "peer_state_tlv", input: ["capabilities": 0x100, "signing_public_key": hx(rep(7, 32))],
              expected: ["encoded": hx(apsEnc)])
        c.add("peer_state_encode_0", "peer_state_tlv", input: ["capabilities": 0, "signing_public_key": hx(rep(7, 32))],
              expected: ["encoded": hx(AuthenticatedPeerStatePacket(capabilities: [], signingPublicKey: rep(7, 32)).encode())])
        c.add("peer_state_encode_bad_key_len", "peer_state_tlv", input: ["capabilities": 1, "signing_public_key": hx(rep(7, 31))],
              expected: ["encoded": hx(AuthenticatedPeerStatePacket(capabilities: PeerCapabilities(rawValue: 1), signingPublicKey: rep(7, 31)).encode())])
        func apsDecode(_ name: String, _ d: Data) {
            var exp: [String: Any] = ["decodes": false]
            if let dec = AuthenticatedPeerStatePacket.decode(from: d) {
                exp = ["decodes": true, "capabilities": dec.capabilities.rawValue, "signing_public_key": hx(dec.signingPublicKey)]
            }
            c.add(name, "peer_state_tlv", input: ["bytes": hx(d)], expected: exp)
        }
        let apsKeyTLV = bytes("0220") + rep(7, 32)
        apsDecode("peer_state_decode_encoded", apsEnc!)
        apsDecode("peer_state_decode_version_2_rejects", bytes("02") + bytes("0102 0001") + apsKeyTLV)
        apsDecode("peer_state_decode_nonminimal_caps_rejects", bytes("01") + bytes("0103 000100") + apsKeyTLV)
        apsDecode("peer_state_decode_unknown_tlv_7f", bytes("01") + bytes("0102 0001") + bytes("7f02 aabb") + apsKeyTLV)
        apsDecode("peer_state_decode_duplicate_caps_rejects", bytes("01") + bytes("0101 01") + bytes("0101 01") + apsKeyTLV)
        apsDecode("peer_state_decode_missing_key_rejects", bytes("01") + bytes("0101 01"))
        apsDecode("peer_state_decode_empty_caps_rejects", bytes("01") + bytes("0100") + apsKeyTLV)
        apsDecode("peer_state_decode_trailing_byte_rejects", bytes("01") + bytes("0101 01") + apsKeyTLV + bytes("01"))
        apsDecode("peer_state_decode_caps_9_bytes_rejects", bytes("01") + bytes("0109 010000000000000000") + apsKeyTLV)
        apsDecode("peer_state_decode_key_31_rejects", bytes("01") + bytes("0101 01") + bytes("021f") + rep(7, 31))

        // MARK: private_message_tlv
        for (id, content) in [("m1", "hi"), ("550e8400-e29b-41d4-a716-446655440000", String(repeating: "a", count: 255)), ("m", ""), ("m2", String(repeating: "a", count: 256)), ("", ""), ("ü", "€😀")] {
            let enc = PrivateMessagePacket(messageID: id, content: content).encode()
            var exp: [String: Any] = ["encoded": hx(enc)]
            if let enc, let dec = PrivateMessagePacket.decode(from: enc) {
                exp["roundtrip"] = ["message_id": dec.messageID, "content": dec.content]
            }
            c.add("pm_encode_\(id.prefix(8))_\(content.utf8.count)", "private_message_tlv",
                  input: ["message_id": id, "content": content], expected: exp)
        }
        func pmDecode(_ name: String, _ d: Data) {
            var exp: [String: Any] = ["decodes": false]
            if let dec = PrivateMessagePacket.decode(from: d) {
                exp = ["decodes": true, "message_id": dec.messageID, "content": dec.content]
            }
            c.add(name, "private_message_tlv", input: ["bytes": hx(d)], expected: exp)
        }
        let pmBase = PrivateMessagePacket(messageID: "m1", content: "hi").encode()!
        pmDecode("pm_decode_base", pmBase)
        pmDecode("pm_decode_unknown_tlv_04_appended", pmBase + bytes("0401aa"))
        pmDecode("pm_decode_unknown_tlv_04_prepended", bytes("0401aa") + pmBase)
        pmDecode("pm_decode_missing_content", bytes("0002") + ascii("m1"))
        pmDecode("pm_decode_length_overrun", bytes("0002") + ascii("m1") + bytes("0105") + ascii("hi"))
        pmDecode("pm_decode_trailing_single_byte", pmBase + bytes("00"))
        pmDecode("pm_decode_content_first", bytes("0102") + ascii("hi") + bytes("0002") + ascii("m1"))

        // MARK: noise_payload
        for (t, d) in [(NoisePayloadType.privateMessage, bytes("0001")), (.delivered, bytes("6d31")), (.readReceipt, Data()), (.privateFile, bytes("ff")), (.authenticatedPeerState, bytes("01"))] {
            c.add("noise_payload_encode_\(String(t.rawValue, radix: 16))", "noise_payload", input: ["type": Int(t.rawValue), "data": hx(d)],
                  expected: ["encoded": hx(NoisePayload(type: t, data: d).encode())])
        }
        for raw: UInt8 in [0x09, 0x20, 0x01, 0x04, 0x05, 0x21, 0x12, 0x00, 0xff] {
            let d = Data([raw]) + bytes("aabb")
            let dec = NoisePayload.decode(d)
            c.add("noise_payload_decode_\(String(raw, radix: 16))", "noise_payload", input: ["bytes": hx(d)],
                  expected: dec.map { ["decodes": true, "type": Int($0.type.rawValue), "data": hx($0.data)] as [String: Any] } ?? ["decodes": false])
        }
        c.add("noise_payload_decode_empty", "noise_payload", input: ["bytes": ""], expected: ["decodes": NoisePayload.decode(Data()) != nil])

        // MARK: file_packet_tlv
        struct FP { let name: String?; let size: UInt64?; let mime: String?; let content: Data }
        let fps: [FP] = [
            FP(name: "a.txt", size: nil, mime: "text/plain", content: ascii("hi")),
            FP(name: "sample.jpg", size: 4096, mime: "image/jpeg", content: seq(4096) { UInt8($0 % 251) }),
            FP(name: nil, size: nil, mime: nil, content: bytes("010203")),
            FP(name: "empty.bin", size: nil, mime: "application/octet-stream", content: Data()),
            FP(name: "big.bin", size: UInt64(FileTransferLimits.maxPayloadBytes) + 1, mime: nil, content: bytes("01")),
            FP(name: "mismatch.bin", size: 10, mime: "x/y", content: bytes("0102")),
        ]
        for (i, f) in fps.enumerated() {
            let enc = BitchatFilePacket(fileName: f.name, fileSize: f.size, mimeType: f.mime, content: f.content).encode()
            var exp: [String: Any] = ["encoded": hx(enc)]
            if let enc {
                if let dec = BitchatFilePacket.decode(enc) {
                    exp["roundtrip"] = ["file_name": dec.fileName ?? NSNull(), "file_size": dec.fileSize ?? NSNull(), "mime_type": dec.mimeType ?? NSNull(), "content": hx(dec.content)] as [String: Any]
                } else {
                    exp["roundtrip"] = NSNull()
                }
            }
            c.add("file_packet_\(i)_\(f.name ?? "noname")", "file_packet_tlv",
                  input: ["file_name": f.name ?? NSNull(), "file_size": f.size ?? NSNull(), "mime_type": f.mime ?? NSNull(), "content": hx(f.content)],
                  expected: exp)
        }
        func fpDecode(_ name: String, _ d: Data) {
            var exp: [String: Any] = ["decodes": false]
            if let dec = BitchatFilePacket.decode(d) {
                exp = ["decodes": true, "file_name": dec.fileName ?? NSNull(), "file_size": dec.fileSize ?? NSNull(), "mime_type": dec.mimeType ?? NSNull(), "content": hx(dec.content)]
            }
            c.add(name, "file_packet_tlv", input: ["bytes": hx(d)], expected: exp)
        }
        let fpBase = BitchatFilePacket(fileName: "a.txt", fileSize: nil, mimeType: "text/plain", content: ascii("hi")).encode()!
        fpDecode("file_decode_base", fpBase)
        // unknown TLV 0x05 with 2-byte length inserted before content
        let nameTLV = bytes("01 0005") + ascii("a.txt")
        let sizeTLV = bytes("02 0004 00000002")
        let mimeTLV = bytes("03 000a") + ascii("text/plain")
        let contentTLV = bytes("04 00000002") + ascii("hi")
        fpDecode("file_decode_unknown_tlv_05_inserted", nameTLV + sizeTLV + bytes("05 0003 aabbcc") + mimeTLV + contentTLV)
        fpDecode("file_decode_legacy_size_8_content_len_2", nameTLV + bytes("02 0008 0000000000000002") + mimeTLV + bytes("04 0002") + ascii("hi"))
        fpDecode("file_decode_no_content_rejects", nameTLV + sizeTLV + mimeTLV)
        fpDecode("file_decode_two_content_tlvs_concatenate", nameTLV + sizeTLV + contentTLV + bytes("04 00000003") + ascii("!!!"))
        fpDecode("file_decode_size_over_limit_rejects", bytes("02 0004 00100001") + contentTLV)
        fpDecode("file_decode_content_only", contentTLV)
        fpDecode("file_decode_truncated_length", nameTLV + bytes("04 0000"))

        // MARK: fragment_payload (upstream BLEOutboundFragmentPlanner with a fixed fragment id)
        let fragID = bytes("0102030405060708")
        let bigPayload = seq(1000) { UInt8($0 % 256) } // ratio 1.0 -> never compressed
        let fragCases: [(String, BitchatPacket, Bool, Int?, PeerID?)] = [
            ("fragment_v1_1000_chunk400_unpadded", BitchatPacket(type: 0x02, senderID: senderA, recipientID: nil, timestamp: 1709600000000, payload: bigPayload, signature: nil, ttl: 7), false, 400, nil),
            ("fragment_v1_directed_chunk300_padded", BitchatPacket(type: 0x11, senderID: senderA, recipientID: recipB, timestamp: 1709600000000, payload: bigPayload, signature: nil, ttl: 7), true, 300, nil),
            ("fragment_v1_directed_peer_override", BitchatPacket(type: 0x02, senderID: senderA, recipientID: nil, timestamp: 1709600000000, payload: bigPayload, signature: nil, ttl: 7), false, 500, PeerID(hexData: recipB)),
            ("fragment_v2_route_default_chunk", BitchatPacket(type: 0x02, senderID: senderA, recipientID: nil, timestamp: 1720000000000, payload: bigPayload, signature: nil, ttl: 7, version: 2, route: route3), false, nil, nil),
        ]
        for (name, pkt, pad, maxChunk, directed) in fragCases {
            let req = BLEOutboundFragmentTransferRequest(packet: pkt, pad: pad, maxChunk: maxChunk, directedPeer: directed, transferId: nil)
            guard let plan = BLEOutboundFragmentPlanner.makePlan(for: req, defaultChunkSize: 469, bleMaxMTU: 512, fragmentID: fragID) else {
                c.add(name, "fragment_payload", input: ["note": "plan nil"], expected: ["plan": NSNull()]); continue
            }
            let full = pkt.toBinaryData(padding: pad)!
            let frags: [[String: Any]] = plan.fragmentPackets.map { f in
                ["payload": hx(f.payload), "version": Int(f.version), "type": Int(f.type), "ttl": Int(f.ttl),
                 "recipient_id": hx(f.recipientID), "route": hxList(f.route), "timestamp": f.timestamp,
                 "encoded_unpadded": hx(BinaryProtocol.encode(f, padding: false)), "encoded_padded": hx(BinaryProtocol.encode(f, padding: true))]
            }
            c.add(name, "fragment_payload",
                  input: ["fragment_id": hx(fragID), "pad": pad, "max_chunk": maxChunk ?? NSNull(), "directed_peer": directed?.id ?? NSNull(),
                          "default_chunk_size": 469, "ble_max_mtu": 512,
                          "packet": ["version": Int(pkt.version), "type": Int(pkt.type), "ttl": Int(pkt.ttl), "timestamp": pkt.timestamp,
                                     "sender_id": hx(pkt.senderID), "recipient_id": hx(pkt.recipientID), "route": hxList(pkt.route), "payload": hx(pkt.payload)] as [String: Any]],
                  expected: ["full_data": hx(full), "chunk_size": plan.chunkSize, "fragment_version": Int(plan.fragmentVersion),
                             "total_fragments": plan.totalFragments, "fragments": frags])
        }

        // MARK: write
        let doc: [String: Any] = [
            "source": "permissionlesstech/bitchat@30c58eee localPackages/BitFoundation + bitchat/Protocols",
            "generator": "swift test SonarVectorDump",
            "cases": c.list,
        ]
        let json = try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(atPath: (outputPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try json.write(to: URL(fileURLWithPath: outputPath))
        var perKind: [String: Int] = [:]
        for k in c.list { perKind[k["kind"] as! String, default: 0] += 1 }
        print("SONAR_VECTORS_WRITTEN \(outputPath) cases=\(c.list.count) perKind=\(perKind.sorted { $0.key < $1.key })")
    }
}
