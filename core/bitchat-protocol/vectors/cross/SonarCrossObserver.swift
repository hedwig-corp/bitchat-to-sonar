//
// SonarCrossObserver.swift
// Runs inside permissionlesstech/bitchat's BitFoundationTests (installed by
// scripts/bitchat-vectors/cross-replay.sh, next to fresh copies of the
// app-target codecs). Feeds every neutral operation produced by
// scripts/bitchat-vectors/cross.py to the real iOS codec and writes what it
// returned. It judges nothing: cross.py compares the outputs with the codec
// that produced the vectors and classifies every difference.
//
// SONAR_CROSS_OPS     colon-separated list of ops files
// SONAR_CROSS_OUT_DIR results land here as results-<source>.json
//

import Foundation
import Testing
@testable import BitFoundation

private func hx(_ d: Data?) -> Any { d.map { $0.hexEncodedString() } ?? NSNull() }
private func nul(_ v: Any?) -> Any { v ?? NSNull() }

private func expand(_ s: String) -> Data? {
    if s.hasPrefix("repeat:") {
        let parts = s.dropFirst(7).split(separator: "*", maxSplits: 1)
        guard parts.count == 2, let b = UInt8(parts[0], radix: 16), let n = Int(parts[1]) else { return nil }
        return Data(repeating: b, count: n)
    }
    return s.isEmpty ? Data() : Data(hexString: s)
}

private struct Input {
    let raw: [String: Any]
    func has(_ k: String) -> Bool { raw[k] != nil && !(raw[k] is NSNull) }
    func hex(_ k: String) -> Data? { (raw[k] as? String).flatMap(expand) }
    func str(_ k: String) -> String? { raw[k] as? String }
    func int(_ k: String) -> Int? { (raw[k] as? NSNumber)?.intValue }
    func bool(_ k: String) -> Bool? { (raw[k] as? NSNumber)?.boolValue }
    /// 64-bit values travel as decimal strings.
    func u64(_ k: String) -> UInt64? { (raw[k] as? String).flatMap { UInt64($0) } }
    func hexList(_ k: String) -> [Data]? { (raw[k] as? [String])?.compactMap(expand) }
}

private struct Unsupported: Error { let why: String }

private func packet(_ i: Input) throws -> BitchatPacket {
    guard let type = i.int("type"), let sender = i.hex("sender"), let ts = i.u64("timestamp"),
          let payload = i.hex("payload"), let ttl = i.int("ttl"), let version = i.int("version") else {
        throw Unsupported(why: "incomplete packet fields")
    }
    return BitchatPacket(type: UInt8(type), senderID: sender, recipientID: i.hex("recipient"), timestamp: ts,
                         payload: payload, signature: i.hex("signature"), ttl: UInt8(ttl),
                         version: UInt8(version), route: i.hexList("route"), isRSR: i.bool("is_rsr") ?? false)
}

private func runOp(_ op: String, _ i: Input) throws -> [String: Any] {
    switch op {
    case "compress_decision":
        return ["result": CompressionUtil.shouldCompress(i.hex("payload")!)]
    case "compress":
        return ["compressed": hx(CompressionUtil.compress(i.hex("payload")!))]
    case "inflate":
        return ["payload": hx(CompressionUtil.decompress(i.hex("stream")!, originalSize: i.int("size")!))]
    case "pad":
        return ["padded": hx(MessagePadding.pad(i.hex("data")!, toSize: i.int("target")!))]
    case "unpad":
        return ["unpadded": hx(MessagePadding.unpad(i.hex("data")!))]
    case "block":
        return ["block": MessagePadding.optimalBlockSize(for: i.int("size")!)]
    case "packet_encode":
        let p = try packet(i)
        return ["padded": hx(BinaryProtocol.encode(p, padding: true)),
                "unpadded": hx(BinaryProtocol.encode(p, padding: false)),
                "preimage": hx(p.toBinaryDataForSigning())]
    case "packet_decode":
        guard let d = BinaryProtocol.decode(i.hex("bytes")!) else { return ["decodes": false] }
        return ["decodes": true, "version": Int(d.version), "type": Int(d.type), "ttl": Int(d.ttl),
                "timestamp": String(d.timestamp), "sender": hx(d.senderID), "recipient": hx(d.recipientID),
                "route": nul(d.route?.map { $0.hexEncodedString() }), "payload": hx(d.payload),
                "signature": hx(d.signature),
                // The verify path: what a receiver checks the signature against.
                "preimage": hx(d.toBinaryDataForSigning()),
                // The relay path: what a receiver forwards.
                "reencoded_unpadded": hx(BinaryProtocol.encode(d, padding: false)),
                "reencoded_padded": hx(BinaryProtocol.encode(d, padding: true))]
    case "peer_id":
        return ["peer_id": PeerID(publicKey: i.hex("key")!).id]
    case "caps_encode":
        return ["encoded": hx(PeerCapabilities(rawValue: i.u64("raw")!).encoded())]
    case "caps_decode":
        let c = PeerCapabilities(encoded: i.hex("bytes")!)
        return ["raw": String(c.rawValue), "reencoded": hx(c.encoded())]
    case "announce_encode":
        let a = AnnouncementPacket(nickname: i.str("nickname")!, noisePublicKey: i.hex("noise")!,
                                   signingPublicKey: i.hex("signing")!, directNeighbors: i.hexList("neighbors"),
                                   capabilities: i.u64("caps").map { PeerCapabilities(rawValue: $0) },
                                   bridgeGeohash: i.str("geohash"))
        return ["encoded": hx(a.encode())]
    case "announce_decode":
        guard let a = AnnouncementPacket.decode(from: i.hex("bytes")!) else { return ["decodes": false] }
        return ["decodes": true, "nickname": a.nickname, "noise": hx(a.noisePublicKey), "signing": hx(a.signingPublicKey),
                "caps": nul(a.capabilities.map { String($0.rawValue) }),
                "neighbors": nul(a.directNeighbors?.map { $0.hexEncodedString() }),
                "geohash": nul(a.bridgeGeohash), "reencoded": hx(a.encode())]
    case "peer_state_encode":
        let p = AuthenticatedPeerStatePacket(capabilities: PeerCapabilities(rawValue: i.u64("caps")!),
                                             signingPublicKey: i.hex("signing")!)
        return ["encoded": hx(p.encode())]
    case "peer_state_decode":
        guard let p = AuthenticatedPeerStatePacket.decode(from: i.hex("bytes")!) else { return ["decodes": false] }
        return ["decodes": true, "caps": String(p.capabilities.rawValue), "signing": hx(p.signingPublicKey)]
    case "pm_encode":
        return ["encoded": hx(PrivateMessagePacket(messageID: i.str("message_id")!, content: i.str("content")!).encode())]
    case "pm_decode":
        guard let p = PrivateMessagePacket.decode(from: i.hex("bytes")!) else { return ["decodes": false] }
        return ["decodes": true, "message_id": p.messageID, "content": p.content]
    case "noise_encode":
        guard let t = NoisePayloadType(rawValue: UInt8(i.int("type")!)) else {
            throw Unsupported(why: "NoisePayloadType \(i.int("type")!) unknown to this build")
        }
        return ["encoded": hx(NoisePayload(type: t, data: i.hex("data")!).encode())]
    case "noise_decode":
        guard let p = NoisePayload.decode(i.hex("bytes")!) else { return ["decodes": false] }
        return ["decodes": true, "type": Int(p.type.rawValue), "data": hx(p.data), "reencoded": hx(p.encode())]
    case "file_encode":
        let f = BitchatFilePacket(fileName: i.str("name"), fileSize: i.u64("size"), mimeType: i.str("mime"),
                                  content: i.hex("content")!)
        return ["encoded": hx(f.encode())]
    case "file_decode":
        guard let f = BitchatFilePacket.decode(i.hex("bytes")!) else { return ["decodes": false] }
        return ["decodes": true, "name": nul(f.fileName), "size": nul(f.fileSize.map { String($0) }),
                "mime": nul(f.mimeType), "content": hx(f.content), "reencoded": hx(f.encode())]
    case "fragment_decode":
        // iOS parses fragments from the packet's payload (BLEFragmentHeader); the
        // carrier packet's other fields do not take part in the parse.
        let carrier = BitchatPacket(type: 0x20, senderID: Data(repeating: 0x11, count: 8), recipientID: nil,
                                    timestamp: 0, payload: i.hex("payload")!, signature: nil, ttl: 1)
        guard let h = BLEFragmentHeader(packet: carrier) else { return ["decodes": false] }
        return ["decodes": true, "fragment_id": String(format: "%016llx", h.key.id), "index": h.index,
                "total": h.total, "type": Int(h.originalType), "data": hx(h.fragmentData)]
    case "fragment_encode":
        // iOS builds fragment payloads inline in BLEOutboundFragmentPlanner; there
        // is no standalone encoder to call. Its output is covered by the
        // fragment_decode ops generated from the iOS planner vectors.
        throw Unsupported(why: "no standalone fragment-payload encoder on iOS")
    default:
        throw Unsupported(why: "unknown op \(op)")
    }
}

@Suite("Sonar cross-replay observer")
struct SonarCrossObserver {
    @Test func observe() throws {
        let env = ProcessInfo.processInfo.environment
        guard let list = env["SONAR_CROSS_OPS"], let outDir = env["SONAR_CROSS_OUT_DIR"] else { return }
        for path in list.split(separator: ":").map(String.init) {
            let data = try #require(FileManager.default.contents(atPath: path), "cannot read \(path)")
            let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let source = root["source"] as? String ?? "unknown"
            let ops = try #require(root["ops"] as? [[String: Any]])
            var results: [[String: Any]] = []
            for op in ops {
                let id = op["id"] as? String ?? "?"
                let name = op["op"] as? String ?? "?"
                let input = Input(raw: op["in"] as? [String: Any] ?? [:])
                do {
                    results.append(["id": id, "out": try runOp(name, input)])
                } catch let u as Unsupported {
                    results.append(["id": id, "unsupported": u.why])
                } catch {
                    results.append(["id": id, "error": "\(error)"])
                }
            }
            let out: [String: Any] = ["observer": "ios", "source": source, "results": results]
            let bytes = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
            let dest = URL(fileURLWithPath: outDir).appendingPathComponent("results-\(source).json")
            try bytes.write(to: dest)
            print("CROSS observer=ios source=\(source) ops=\(ops.count) -> \(dest.path)")
        }
    }
}
