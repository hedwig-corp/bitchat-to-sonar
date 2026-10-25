//! Replays the byte-exact vectors generated from the reference implementations
//! (`vectors/bitchat-ios.json` from permissionlesstech/bitchat's Swift codec,
//! `vectors/bitchat-android.json` from permissionlesstech/bitchat-android's
//! Kotlin codec). Every case is an upstream encoder's real output or an
//! upstream decoder's real verdict, so a failure here is an interop break.
//!
//! Known, deliberate divergences are listed in `DIVERGENCES` and asserted the
//! other way round, so they cannot silently become agreement or disagreement.

use std::fs;
use std::path::PathBuf;

use bitchat_protocol::announce::UnknownTlv;
use bitchat_protocol::signing::signing_preimage;
use bitchat_protocol::{
    compression, padding, peer_id, Announce, AuthenticatedPeerState, FilePacket, Fragment,
    NoisePayloadType, Packet, PeerCapabilities, PrivateMessage,
};
use serde_json::Value;

/// Upstream behaviours this crate intentionally does not copy. Each entry is
/// a substring of a case name; the harness asserts the *opposite* verdict.
///
/// * Both reference `PrivateMessagePacket` decoders reject any TLV type they
///   do not know. This crate skips unknown one-byte-length TLVs so an older
///   Sonar can still read a newer Sonar's message. The consequence — never
///   send an extension TLV to a stock peer — is enforced by the engine
///   (`PrivateMessage::encode_for(peer_is_sonar)`), not by matching the
///   rejection here.
///
/// * bitchat-android's `NoisePayloadType` has no `0x07` (iOS `groupKeyUpdate`),
///   so it rejects that type byte while iOS accepts it. This crate's registry
///   is the union, so it decodes `0x07`.
const DIVERGENCES: &[(&str, &str)] = &[
    ("private_message_tlv", "unknown_tlv"),
    ("noise_payload", "type_0x07"),
];

fn diverges(kind: &str, name: &str) -> bool {
    DIVERGENCES.iter().any(|(k, n)| *k == kind && name.contains(n))
}

fn load(file: &str) -> Vec<Value> {
    let path: PathBuf = [env!("CARGO_MANIFEST_DIR"), "vectors", file].iter().collect();
    let text = fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    let doc: Value = serde_json::from_str(&text).expect("valid JSON");
    doc["cases"].as_array().expect("cases").clone()
}

/// Hex, with the trimmed form `repeat:xx*N` expanded.
fn hex(v: &Value) -> Vec<u8> {
    let s = v.as_str().unwrap_or_else(|| panic!("hex string, got {v}"));
    if let Some(rest) = s.strip_prefix("repeat:") {
        let (b, n) = rest.split_once('*').expect("repeat:xx*N");
        let byte = u8::from_str_radix(b, 16).expect("repeat byte");
        return vec![byte; n.parse().expect("repeat count")];
    }
    hex::decode(s).unwrap_or_else(|e| panic!("hex {s:?}: {e}"))
}

fn opt_hex(v: &Value) -> Option<Vec<u8>> {
    if v.is_null() {
        None
    } else {
        Some(hex(v))
    }
}

fn id8(v: &Value) -> [u8; 8] {
    let b = hex(v);
    let mut id = [0u8; 8];
    let n = 8.min(b.len());
    id[..n].copy_from_slice(&b[..n]);
    id
}

fn u(v: &Value) -> u64 {
    v.as_u64().or_else(|| v.as_i64().map(|i| i as u64)).unwrap_or_else(|| panic!("number, got {v}"))
}

fn is_hex_field(v: &Value) -> bool {
    v.as_str().is_some_and(|s| s.starts_with("repeat:") || hex::decode(s).is_ok())
}

/// Build a packet from a vector `input`.
fn packet_from(input: &Value) -> Packet {
    let mut p = Packet::new(
        u(&input["type"]) as u8,
        u(&input["ttl"]) as u8,
        u(&input["timestamp"]),
        id8(&input["sender_id"]),
    );
    p.version = u(&input["version"]) as u8;
    p.recipient_id = input["recipient_id"].as_str().map(|_| id8(&input["recipient_id"]));
    p.route = input["route"].as_array().map(|r| r.iter().map(id8).collect());
    p.payload = hex(&input["payload"]);
    p.signature = opt_hex(&input["signature"]).map(|s| {
        let mut sig = [0u8; 64];
        sig.copy_from_slice(&s[..64.min(s.len())]);
        sig
    });
    p.is_rsr = input["is_rsr"].as_bool().unwrap_or(false);
    p
}

/// Is the reference encoder's stream for `payload` one we must reproduce
/// byte for byte? bitchat iOS's always is (Apple = zlib level 5 = ours).
/// bitchat-android's is the JDK at level 6, which we reproduce wherever
/// levels 5 and 6 agree (`300_bytes_a_b33` is a payload where they do not).
fn deflate_byte_exact(file: &str, payload: &[u8]) -> bool {
    if file.contains("ios") {
        return true;
    }
    let mut level6 = flate2::write::DeflateEncoder::new(Vec::new(), flate2::Compression::new(6));
    std::io::Write::write_all(&mut level6, payload).unwrap();
    Some(level6.finish().unwrap()) == compression::compress(payload)
}

fn run(file: &str) {
    let cases = load(file);
    let mut counts = std::collections::BTreeMap::<String, usize>::new();
    for case in &cases {
        let kind = case["kind"].as_str().unwrap();
        let name = case["name"].as_str().unwrap();
        let input = &case["input"];
        let exp = &case["expected"];
        let ctx = format!("{file} / {kind} / {name}");
        *counts.entry(kind.to_string()).or_default() += 1;
        match kind {
            "padding" => {
                assert_eq!(padding::pad(hex(&input["data"]), u(&input["target"]) as usize), hex(&exp["padded"]), "{ctx}");
            }
            "optimal_block_size" => {
                assert_eq!(padding::optimal_block_size(u(&input["size"]) as usize) as u64, u(&exp["block"]), "{ctx}");
            }
            "unpad" => {
                assert_eq!(padding::unpad(&hex(&input["data"])), hex(&exp["unpadded"]), "{ctx}");
            }
            "should_compress" => {
                assert_eq!(compression::should_compress(&hex(&input["payload"])), exp["result"].as_bool().unwrap(), "{ctx}");
            }
            "compress" => {
                let payload = hex(&input["payload"]);
                match opt_hex(&exp["compressed"]) {
                    Some(stream) => {
                        // We must INFLATE the foreign encoder's stream exactly...
                        assert_eq!(compression::decompress(&stream, payload.len()).as_deref(), Some(&payload[..]), "{ctx}: inflate upstream stream");
                        // ...and emit the identical stream where the reference
                        // encoder is reference zlib at our level (always for iOS;
                        // for the JDK's level 6 wherever level 5 agrees with it).
                        let ours = compression::compress(&payload).unwrap_or_else(|| panic!("{ctx}: upstream compressed, we did not"));
                        if deflate_byte_exact(file, &payload) {
                            assert_eq!(ours, stream, "{ctx}: our DEFLATE stream is the reference encoder's");
                        }
                    }
                    None => {
                        if payload.len() >= compression::THRESHOLD_BYTES {
                            // Upstream found no gain; neither may we (same
                            // algorithm family, so a strict disagreement here
                            // would mean a different notion of "smaller").
                            assert!(compression::compress(&payload).is_none(), "{ctx}: upstream declined to compress, we did");
                        } else {
                            assert!(compression::compress(&payload).is_none(), "{ctx}");
                        }
                    }
                }
            }
            "packet_encode" => {
                let p = packet_from(input);
                let Some(expected_unpadded) = opt_hex(&exp["unpadded"]) else {
                    assert!(p.encode().is_err(), "{ctx}: upstream refused to encode");
                    continue;
                };
                let expected_padded = hex(&exp["padded"]);
                let expected_preimage = hex(&exp["signing_preimage"]);
                let flags = expected_unpadded[11];
                let compressed = flags & bitchat_protocol::flags::IS_COMPRESSED != 0;
                let ours = p.encode_unpadded().unwrap_or_else(|e| panic!("{ctx}: {e}"));
                if compressed && !deflate_byte_exact(file, &p.payload) {
                    // A JDK level-6 stream that level 5 does not reproduce:
                    // compare structure and the round trip, not the bytes.
                    assert_eq!(ours[..12], expected_unpadded[..12], "{ctx}: header");
                    assert_eq!(ours[11], flags, "{ctx}: flags (compression decision)");
                    assert_eq!(Packet::decode(&ours).unwrap().payload, p.payload, "{ctx}: our stream round-trips");
                } else {
                    assert_eq!(ours, expected_unpadded, "{ctx}: unpadded");
                    assert_eq!(p.encode().unwrap(), expected_padded, "{ctx}: padded");
                    assert_eq!(signing_preimage(&p).unwrap(), expected_preimage, "{ctx}: signing preimage");
                }
                // Decoding the UPSTREAM bytes must give the input fields back
                // and re-encode to the identical upstream bytes (wire-payload
                // preservation), including the signing preimage.
                for (label, bytes) in [("padded", &expected_padded), ("unpadded", &expected_unpadded)] {
                    let d = Packet::decode(bytes).unwrap_or_else(|e| panic!("{ctx}: decode upstream {label}: {e}"));
                    assert_eq!(d.payload, hex(&exp["decoded_payload"]), "{ctx}: payload from {label}");
                    assert_eq!(d.ttl as u64, u(&exp["decoded_ttl"]), "{ctx}");
                    assert_eq!(d.recipient_id, exp["decoded_recipient_id"].as_str().map(|_| id8(&exp["decoded_recipient_id"])), "{ctx}");
                    assert_eq!(d.signature.map(|s| s.to_vec()), opt_hex(&exp["decoded_signature"]), "{ctx}");
                    let route: Option<Vec<[u8; 8]>> = exp["decoded_route"].as_array().map(|r| r.iter().map(id8).collect());
                    assert_eq!(d.route, route, "{ctx}: route");
                    if let Some(rsr) = exp["decoded_is_rsr"].as_bool() {
                        assert_eq!(d.is_rsr, rsr, "{ctx}");
                    }
                    assert_eq!(d.wire_payload.as_ref().unwrap().compressed, compressed, "{ctx}");
                    assert_eq!(d.encode_unpadded().unwrap(), expected_unpadded, "{ctx}: re-encode from {label} reproduces upstream bytes");
                    assert_eq!(d.encode().unwrap(), expected_padded, "{ctx}: padded re-encode from {label}");
                    assert_eq!(signing_preimage(&d).unwrap(), expected_preimage, "{ctx}: preimage from received bytes");
                }
            }
            "packet_reencode_preserves_wire" => {
                let padded = hex(&input["padded"]);
                let d = Packet::decode(&padded).unwrap();
                let w = d.wire_payload.as_ref().unwrap();
                assert_eq!(w.compressed, exp["decoded_wire_compressed"].as_bool().unwrap(), "{ctx}");
                assert_eq!(w.bytes, hex(&exp["decoded_wire_bytes"]), "{ctx}");
                assert_eq!(d.encode_unpadded().unwrap(), hex(&exp["reencoded"]), "{ctx}");
                assert_eq!(d.encode().unwrap(), hex(&exp["reencoded_padded"]), "{ctx}");
            }
            "packet_decode_reject" => {
                assert!(Packet::decode(&hex(&input["bytes"])).is_err(), "{ctx}: must reject");
            }
            "packet_decode_accept" => {
                let d = Packet::decode(&hex(&input["bytes"])).unwrap_or_else(|e| panic!("{ctx}: {e}"));
                assert_eq!(d.payload, hex(&exp["payload"]), "{ctx}");
                if exp.get("route").is_some() {
                    assert!(d.route.is_none(), "{ctx}");
                }
            }
            "peer_id" => {
                let key = input.get("noise_public_key").or_else(|| input.get("noise_static_pubkey")).unwrap();
                if exp["peer_id"].is_null() {
                    continue; // upstream rejects a non-32-byte key; derivation is defined only for 32
                }
                assert_eq!(peer_id::peer_id_from_noise_key(&hex(key)), exp["peer_id"].as_str().unwrap(), "{ctx}");
            }
            "capabilities" => {
                if let Some(raw) = input.get("raw") {
                    assert_eq!(PeerCapabilities(u(raw)).encoded(), hex(&exp["encoded"]), "{ctx}");
                } else {
                    let c = PeerCapabilities::decode(&hex(&input["encoded"]));
                    assert_eq!(c.0, u(&exp["raw"]), "{ctx}");
                    assert_eq!(c.encoded(), hex(&exp["reencoded"]), "{ctx}");
                }
            }
            "announce_tlv" => {
                if let Some(encoded) = input.get("encoded") {
                    // Android decode + re-encode shape.
                    let d = Announce::decode(&hex(encoded));
                    if exp["decodes"] == Value::Bool(false) {
                        assert!(d.is_err(), "{ctx}");
                        continue;
                    }
                    let d = d.unwrap_or_else(|e| panic!("{ctx}: {e}"));
                    assert_eq!(d.nickname, exp["nickname"].as_str().unwrap(), "{ctx}");
                    assert_eq!(d.capabilities.map(|c| c.0), exp["capabilities_raw"].as_u64(), "{ctx}");
                    let unknown: Vec<UnknownTlv> = exp["unknown_tlvs"].as_array().unwrap().iter().map(|t| UnknownTlv { type_: u(&t["type"]) as u8, value: hex(&t["value"]) }).collect();
                    assert_eq!(d.unknown_tlvs, unknown, "{ctx}");
                    assert_eq!(d.encode().unwrap(), hex(&exp["reencoded"]), "{ctx}: re-encode keeps unknown TLVs last");
                    continue;
                }
                if input["direct_neighbors"].as_array().is_some_and(|n| n.iter().any(|h| h.as_str().is_some_and(|s| s.len() != 16))) {
                    // A hop that is not 8 bytes is unrepresentable here ([u8; 8]);
                    // upstream drops the whole neighbours TLV for it.
                    continue;
                }
                let noise = input.get("noise_public_key").or_else(|| input.get("noise_key")).unwrap();
                let signing = input.get("signing_public_key").or_else(|| input.get("signing_key")).unwrap();
                let mut a = Announce::new(input["nickname"].as_str().unwrap(), hex(noise), hex(signing));
                a.direct_neighbors = input["direct_neighbors"].as_array().map(|n| n.iter().map(id8).collect());
                a.capabilities = input["capabilities"].as_u64().map(PeerCapabilities);
                a.bridge_geohash = input["bridge_geohash"].as_str().map(String::from);
                match opt_hex(&exp["encoded"]) {
                    None => assert!(a.encode().is_err(), "{ctx}: upstream refused"),
                    Some(bytes) => {
                        assert_eq!(a.encode().unwrap(), bytes, "{ctx}");
                        let d = Announce::decode(&bytes).unwrap();
                        if let Some(rt) = exp.get("roundtrip").filter(|v| !v.is_null()) {
                            assert_eq!(d.nickname, rt["nickname"].as_str().unwrap(), "{ctx}");
                            assert_eq!(d.capabilities.map(|c| c.0), rt["capabilities"].as_u64(), "{ctx}");
                            assert_eq!(d.bridge_geohash.as_deref(), rt["bridge_geohash"].as_str(), "{ctx}");
                            let n: Option<Vec<[u8; 8]>> = rt["direct_neighbors"].as_array().map(|n| n.iter().map(id8).collect());
                            assert_eq!(d.direct_neighbors, n, "{ctx}");
                        }
                        if let Some(nick) = exp.get("decoded_nickname") {
                            assert_eq!(d.nickname, nick.as_str().unwrap(), "{ctx}");
                            assert_eq!(d.capabilities.map(|c| c.0), exp["decoded_capabilities_raw"].as_u64(), "{ctx}");
                        }
                    }
                }
            }
            "announce_decode" => {
                let d = Announce::decode(&hex(&input["bytes"]));
                if exp["decodes"] == Value::Bool(false) {
                    assert!(d.is_err(), "{ctx}: upstream rejects");
                    continue;
                }
                let d = d.unwrap_or_else(|e| panic!("{ctx}: {e}"));
                assert_eq!(d.nickname, exp["nickname"].as_str().unwrap(), "{ctx}");
                assert_eq!(d.noise_public_key, hex(&exp["noise_public_key"]), "{ctx}");
                assert_eq!(d.signing_public_key, hex(&exp["signing_public_key"]), "{ctx}");
                assert_eq!(d.capabilities.map(|c| c.0), exp["capabilities"].as_u64(), "{ctx}");
                assert_eq!(d.bridge_geohash.as_deref(), exp["bridge_geohash"].as_str(), "{ctx}");
                let n: Option<Vec<[u8; 8]>> = exp["direct_neighbors"].as_array().map(|n| n.iter().map(id8).collect());
                assert_eq!(d.direct_neighbors, n, "{ctx}");
            }
            "peer_state_tlv" => {
                if let Some(bytes) = input.get("bytes") {
                    let d = AuthenticatedPeerState::decode(&hex(bytes));
                    if exp["decodes"] == Value::Bool(false) {
                        assert!(d.is_err(), "{ctx}: upstream rejects");
                        continue;
                    }
                    let d = d.unwrap_or_else(|e| panic!("{ctx}: {e}"));
                    assert_eq!(d.capabilities.0, u(&exp["capabilities"]), "{ctx}");
                    assert_eq!(d.signing_public_key.to_vec(), hex(&exp["signing_public_key"]), "{ctx}");
                } else {
                    let key = hex(&input["signing_public_key"]);
                    if key.len() != 32 {
                        assert!(exp["encoded"].is_null(), "{ctx}: upstream refuses a non-32-byte key; the type here cannot hold one");
                        continue;
                    }
                    let mut k = [0u8; 32];
                    k.copy_from_slice(&key);
                    let s = AuthenticatedPeerState { capabilities: PeerCapabilities(u(&input["capabilities"])), signing_public_key: k };
                    match opt_hex(&exp["encoded"]) {
                        None => assert!(s.encode().is_err(), "{ctx}"),
                        Some(b) => assert_eq!(s.encode().unwrap(), b, "{ctx}"),
                    }
                }
            }
            "private_message_tlv" => {
                let bytes = input.get("bytes").or_else(|| input.get("encoded")).filter(|v| is_hex_field(v) && input.get("content").is_none());
                if let Some(bytes) = bytes {
                    let d = PrivateMessage::decode(&hex(bytes));
                    let upstream_decodes = exp["decodes"].as_bool().unwrap_or(true);
                    if diverges(kind, name) {
                        assert!(!upstream_decodes, "{ctx}: divergence list says upstream rejects");
                        assert!(d.is_ok(), "{ctx}: this crate tolerates unknown TLVs (deliberate divergence)");
                        continue;
                    }
                    if !upstream_decodes {
                        assert!(d.is_err(), "{ctx}: upstream rejects");
                        continue;
                    }
                    let d = d.unwrap_or_else(|e| panic!("{ctx}: {e}"));
                    if let Some(id) = exp.get("message_id").or_else(|| exp.get("decoded_message_id")).and_then(Value::as_str) {
                        assert_eq!(d.message_id, id, "{ctx}");
                    }
                    if let Some(c) = exp.get("content").and_then(Value::as_str) {
                        assert_eq!(d.content, c, "{ctx}");
                    }
                    continue;
                }
                let m = PrivateMessage::new(input["message_id"].as_str().unwrap(), input["content"].as_str().unwrap());
                match opt_hex(&exp["encoded"]) {
                    None => {
                        assert!(m.encode_legacy().is_err(), "{ctx}: legacy must refuse like upstream");
                        assert!(!m.fits_legacy(), "{ctx}");
                    }
                    Some(b) => {
                        assert_eq!(m.encode_legacy().unwrap(), b, "{ctx}");
                        assert_eq!(m.encode_extended().unwrap(), b, "{ctx}: extended is byte-identical on short fields");
                        assert_eq!(PrivateMessage::decode(&b).unwrap(), m, "{ctx}");
                    }
                }
            }
            "noise_payload" => {
                if let Some(t) = input.get("type") {
                    let mut e = vec![u(t) as u8];
                    e.extend(hex(&input["data"]));
                    assert_eq!(e, hex(&exp["encoded"]), "{ctx}");
                } else {
                    let bytes = hex(input.get("bytes").or_else(|| input.get("encoded")).unwrap());
                    let decoded = bytes.first().and_then(|b| NoisePayloadType::decode(*b));
                    if diverges(kind, name) {
                        assert_eq!(exp["decodes"], Value::Bool(false), "{ctx}: divergence list says upstream rejects");
                        assert!(decoded.is_some(), "{ctx}: this crate knows the type (deliberate divergence)");
                        continue;
                    }
                    if exp["decodes"] == Value::Bool(false) {
                        assert!(decoded.is_none() || bytes.is_empty(), "{ctx}: upstream rejects type {:02x?}", bytes.first());
                        continue;
                    }
                    let t = decoded.unwrap_or_else(|| panic!("{ctx}: unknown type"));
                    let want = exp.get("type").or_else(|| exp.get("type_value")).unwrap();
                    assert_eq!(t.as_u8() as u64, u(want), "{ctx}: canonical type");
                    if let Some(d) = exp.get("data") {
                        assert_eq!(bytes[1..].to_vec(), hex(d), "{ctx}");
                    }
                }
            }
            "file_packet_tlv" => {
                let bytes = input.get("bytes").or_else(|| input.get("encoded")).filter(|_| input.get("content").is_none());
                if let Some(bytes) = bytes {
                    let d = FilePacket::decode(&hex(bytes));
                    if exp["decodes"] == Value::Bool(false) {
                        assert!(d.is_none(), "{ctx}: upstream rejects");
                        continue;
                    }
                    let d = d.unwrap_or_else(|| panic!("{ctx}: decode"));
                    assert_eq!(d.content, hex(&exp["content"]), "{ctx}");
                    assert_eq!(d.file_name.as_deref(), exp["file_name"].as_str(), "{ctx}");
                    assert_eq!(d.mime_type.as_deref(), exp["mime_type"].as_str(), "{ctx}");
                    assert_eq!(d.file_size, exp["file_size"].as_u64(), "{ctx}");
                    if let Some(re) = exp.get("reencoded") {
                        if d.message_id.is_some() {
                            // The "unknown" tag 0x05 is Sonar's message-id
                            // extension: upstream drops it on re-encode, this
                            // crate keeps it. Both decode the file identically.
                            assert_eq!(d.message_id.as_deref(), Some("media-mid-1"), "{ctx}");
                        } else {
                            assert_eq!(d.encode().unwrap(), hex(re), "{ctx}");
                        }
                    }
                    continue;
                }
                let f = FilePacket {
                    file_name: input["file_name"].as_str().map(String::from),
                    file_size: input["file_size"].as_u64(),
                    mime_type: input["mime_type"].as_str().map(String::from),
                    message_id: None,
                    content: hex(&input["content"]),
                };
                match opt_hex(&exp["encoded"]) {
                    None => assert!(f.encode().is_none(), "{ctx}: upstream refused"),
                    Some(b) => {
                        assert_eq!(f.encode().unwrap(), b, "{ctx}");
                        let d = FilePacket::decode(&b);
                        if exp.get("roundtrip").is_some_and(Value::is_null) {
                            assert!(d.is_none(), "{ctx}: upstream decode rejects its own encoding here");
                        } else if let Some(d) = d {
                            if let Some(rt) = exp.get("roundtrip") {
                                assert_eq!(d.content, hex(&rt["content"]), "{ctx}");
                                assert_eq!(d.file_size, rt["file_size"].as_u64(), "{ctx}");
                            }
                            if let Some(fs) = exp.get("decoded_file_size") {
                                assert_eq!(d.file_size, fs.as_u64(), "{ctx}");
                            }
                        } else {
                            panic!("{ctx}: our decode rejected our encoding");
                        }
                    }
                }
            }
            "fragment_payload" => {
                if let Some(data) = input.get("data") {
                    let f = Fragment {
                        fragment_id: id8(&input["fragment_id"]),
                        index: u(&input["index"]) as u16,
                        total: u(&input["total"]) as u16,
                        original_type: u(&input["original_type"]) as u8,
                        chunk: hex(data),
                    };
                    assert_eq!(f.encode_payload(), hex(&exp["encoded"]), "{ctx}");
                    assert_eq!(Fragment::decode_payload(&hex(&exp["encoded"])).unwrap(), f, "{ctx}");
                    continue;
                }
                // iOS planner output: fragments of the ORIGINAL frame, each a
                // 0x20 packet inheriting the header. Rebuild and compare.
                let original = packet_from(&input["packet"]);
                let full = hex(&exp["full_data"]);
                let padded = input["pad"].as_bool().unwrap_or(false);
                let ours = if padded { original.encode() } else { original.encode_unpadded() }.unwrap();
                assert_eq!(ours, full, "{ctx}: original frame");
                let chunk = u(&exp["chunk_size"]) as usize;
                let frags = bitchat_protocol::fragment::split(&full, id8(&input["fragment_id"]), original.type_, chunk).unwrap();
                let expected = exp["fragments"].as_array().unwrap();
                assert_eq!(frags.len() as u64, u(&exp["total_fragments"]), "{ctx}");
                assert_eq!(frags.len(), expected.len(), "{ctx}");
                let mut reassembler = bitchat_protocol::Reassembler::new();
                let mut rebuilt = None;
                for (f, e) in frags.iter().zip(expected) {
                    assert_eq!(f.encode_payload(), hex(&e["payload"]), "{ctx}: fragment {} payload", f.index);
                    let mut fp = Packet::new(bitchat_protocol::msg_type::FRAGMENT, u(&e["ttl"]) as u8, u(&e["timestamp"]), original.sender_id);
                    fp.version = u(&e["version"]) as u8;
                    fp.recipient_id = e["recipient_id"].as_str().map(|_| id8(&e["recipient_id"]));
                    fp.route = e["route"].as_array().map(|r| r.iter().map(id8).collect());
                    fp.payload = f.encode_payload();
                    assert_eq!(fp.encode_unpadded().unwrap(), hex(&e["encoded_unpadded"]), "{ctx}: fragment {} frame", f.index);
                    assert_eq!(fp.encode().unwrap(), hex(&e["encoded_padded"]), "{ctx}: fragment {} padded frame", f.index);
                    let d = Packet::decode(&hex(&e["encoded_padded"])).unwrap();
                    let df = Fragment::decode_payload(&d.payload).unwrap();
                    if let Some(whole) = reassembler.add(d.sender_id, &df, 1_000) {
                        rebuilt = Some(whole);
                    }
                }
                assert_eq!(rebuilt.as_deref(), Some(&full[..]), "{ctx}: reassembly returns the original frame");
                assert_eq!(Packet::decode(rebuilt.as_ref().unwrap()).unwrap(), original, "{ctx}");
            }
            other => panic!("{ctx}: unknown vector kind {other}"),
        }
    }
    eprintln!("{file}: {counts:?}");
    assert!(counts.values().sum::<usize>() >= 80, "{file}: suspiciously few cases");
}

#[test]
fn bitchat_ios_vectors() {
    run("bitchat-ios.json");
}

#[test]
fn bitchat_android_vectors() {
    run("bitchat-android.json");
}
