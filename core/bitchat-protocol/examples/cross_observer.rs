//! Cross-replay observer for this crate — the codec Sonar Android ships.
//!
//! Feeds every neutral operation produced by `scripts/bitchat-vectors/cross.py
//! ops` to the crate and writes what it returned, exactly like the Swift and
//! Kotlin observers do for the reference clients. It judges nothing: `cross.py
//! compare` holds the results against the producing codec and the ledger.
//!
//! ```text
//! cargo run -q -p bitchat-protocol --example cross_observer -- <out-dir> <ops.json>...
//! ```
//! writes `<out-dir>/results-<source>.json` per ops file.

use bitchat_protocol::announce::{Announce, PeerCapabilities};
use bitchat_protocol::packet::PaddingPolicy;
use bitchat_protocol::{
    compression, padding, peer_id, signing, AuthenticatedPeerState, FilePacket, Fragment,
    NoisePayloadType, Packet, PrivateMessage,
};
use serde_json::{json, Map, Value};

struct Unsupported(String);

fn hexd(s: &str) -> Vec<u8> {
    if let Some(rest) = s.strip_prefix("repeat:") {
        let (b, n) = rest.split_once('*').expect("repeat:xx*N");
        return vec![u8::from_str_radix(b, 16).expect("hex byte"); n.parse().expect("count")];
    }
    hex::decode(s).expect("hex")
}

fn h(b: impl AsRef<[u8]>) -> Value {
    Value::String(hex::encode(b))
}

fn ho(b: Option<impl AsRef<[u8]>>) -> Value {
    b.map(h).unwrap_or(Value::Null)
}

struct In<'a>(&'a Map<String, Value>);

impl In<'_> {
    fn present(&self, k: &str) -> Option<&Value> {
        self.0.get(k).filter(|v| !v.is_null())
    }
    fn bytes(&self, k: &str) -> Option<Vec<u8>> {
        self.present(k).and_then(Value::as_str).map(hexd)
    }
    fn str(&self, k: &str) -> Option<String> {
        self.present(k).and_then(Value::as_str).map(str::to_owned)
    }
    fn int(&self, k: &str) -> Option<i64> {
        self.present(k).and_then(Value::as_i64)
    }
    /// 64-bit values travel as decimal strings.
    fn u64(&self, k: &str) -> Option<u64> {
        self.present(k)
            .and_then(Value::as_str)
            .map(|s| s.parse().expect("u64"))
    }
    fn ids(&self, k: &str) -> Option<Vec<[u8; 8]>> {
        self.present(k).and_then(Value::as_array).map(|a| {
            a.iter()
                .map(|v| id8(&hexd(v.as_str().expect("hex"))))
                .collect::<Option<Vec<_>>>()
        })?
    }
}

fn id8(b: &[u8]) -> Option<[u8; 8]> {
    b.try_into().ok()
}

fn packet(i: &In) -> Result<Packet, Unsupported> {
    let sender =
        id8(&i.bytes("sender").unwrap()).ok_or(Unsupported("sender id is not 8 bytes".into()))?;
    let mut p = Packet::new(
        i.int("type").unwrap() as u8,
        i.int("ttl").unwrap() as u8,
        i.u64("timestamp").unwrap(),
        sender,
    );
    p.version = i.int("version").unwrap() as u8;
    p.recipient_id = match i.bytes("recipient") {
        Some(r) => Some(id8(&r).ok_or(Unsupported("recipient id is not 8 bytes".into()))?),
        None => None,
    };
    p.route = i.ids("route");
    p.payload = i.bytes("payload").unwrap();
    p.signature = match i.bytes("signature") {
        Some(s) => Some(
            s.try_into()
                .map_err(|_| Unsupported("signature is not 64 bytes".into()))?,
        ),
        None => None,
    };
    p.is_rsr = i
        .present("is_rsr")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    Ok(p)
}

fn observe(op: &str, i: &In) -> Result<Value, Unsupported> {
    Ok(match op {
        "compress_decision" => {
            json!({"result": compression::should_compress(&i.bytes("payload").unwrap())})
        }
        "compress" => {
            json!({"compressed": ho(compression::compress(&i.bytes("payload").unwrap()))})
        }
        "inflate" => {
            json!({"payload": ho(compression::decompress(&i.bytes("stream").unwrap(), i.int("size").unwrap() as usize))})
        }
        "pad" => {
            json!({"padded": h(padding::pad(i.bytes("data").unwrap(), i.int("target").unwrap() as usize))})
        }
        "unpad" => json!({"unpadded": h(padding::unpad(&i.bytes("data").unwrap()))}),
        "block" => json!({"block": padding::optimal_block_size(i.int("size").unwrap() as usize)}),
        "packet_encode" => {
            let p = packet(i)?;
            json!({
                "padded": ho(p.encode_with(PaddingPolicy::Always).ok()),
                "unpadded": ho(p.encode_unpadded().ok()),
                "preimage": ho(signing::signing_preimage(&p).ok()),
            })
        }
        "packet_decode" => match Packet::decode(&i.bytes("bytes").unwrap()) {
            Err(_) => json!({"decodes": false}),
            Ok(d) => json!({
                "decodes": true, "version": d.version, "type": d.type_, "ttl": d.ttl,
                "timestamp": d.timestamp.to_string(), "sender": h(d.sender_id), "recipient": ho(d.recipient_id),
                "route": d.route.as_ref().map(|r| r.iter().map(h).collect::<Vec<_>>()),
                "payload": h(&d.payload), "signature": ho(d.signature),
                // The verify path: what a receiver checks the signature against.
                "preimage": ho(signing::signing_preimage(&d).ok()),
                // The relay path: what a receiver forwards.
                "reencoded_unpadded": ho(d.encode_unpadded().ok()),
                "reencoded_padded": ho(d.encode_with(PaddingPolicy::Always).ok()),
            }),
        },
        "peer_id" => json!({"peer_id": peer_id::peer_id_from_noise_key(&i.bytes("key").unwrap())}),
        "caps_encode" => json!({"encoded": h(PeerCapabilities(i.u64("raw").unwrap()).encoded())}),
        "caps_decode" => {
            let c = PeerCapabilities::decode(&i.bytes("bytes").unwrap());
            json!({"raw": c.0.to_string(), "reencoded": h(c.encoded())})
        }
        "announce_encode" => {
            let mut a = Announce::new(
                i.str("nickname").unwrap(),
                i.bytes("noise").unwrap(),
                i.bytes("signing").unwrap(),
            );
            a.capabilities = i.u64("caps").map(PeerCapabilities);
            a.direct_neighbors = i.ids("neighbors");
            a.bridge_geohash = i.str("geohash");
            json!({"encoded": ho(a.encode().ok())})
        }
        "announce_decode" => match Announce::decode(&i.bytes("bytes").unwrap()) {
            Err(_) => json!({"decodes": false}),
            Ok(a) => json!({
                "decodes": true, "nickname": a.nickname, "noise": h(&a.noise_public_key),
                "signing": h(&a.signing_public_key), "caps": a.capabilities.map(|c| c.0.to_string()),
                "neighbors": a.direct_neighbors.as_ref().map(|n| n.iter().map(h).collect::<Vec<_>>()),
                "geohash": a.bridge_geohash, "reencoded": ho(a.encode().ok()),
            }),
        },
        "peer_state_encode" => {
            let key: Option<[u8; 32]> = i.bytes("signing").unwrap().try_into().ok();
            let enc = key.and_then(|k| {
                AuthenticatedPeerState {
                    capabilities: PeerCapabilities(i.u64("caps").unwrap()),
                    signing_public_key: k,
                }
                .encode()
                .ok()
            });
            json!({"encoded": ho(enc)})
        }
        "peer_state_decode" => match AuthenticatedPeerState::decode(&i.bytes("bytes").unwrap()) {
            Err(_) => json!({"decodes": false}),
            Ok(p) => {
                json!({"decodes": true, "caps": p.capabilities.0.to_string(), "signing": h(p.signing_public_key)})
            }
        },
        "pm_encode" => {
            let m = PrivateMessage::new(i.str("message_id").unwrap(), i.str("content").unwrap());
            // What goes to a stock peer is the reference encoding; the extended one
            // is only for verified Sonar peers (and equal whenever it fits).
            json!({"encoded": ho(m.encode_legacy().ok()), "encoded_extended": ho(m.encode_extended().ok())})
        }
        "pm_decode" => match PrivateMessage::decode(&i.bytes("bytes").unwrap()) {
            Err(_) => json!({"decodes": false}),
            Ok(m) => json!({"decodes": true, "message_id": m.message_id, "content": m.content}),
        },
        "noise_encode" => {
            let t = NoisePayloadType::decode(i.int("type").unwrap() as u8).ok_or_else(|| {
                Unsupported(format!(
                    "NoisePayloadType {} unknown",
                    i.int("type").unwrap()
                ))
            })?;
            let mut out = vec![t.as_u8()];
            out.extend(i.bytes("data").unwrap());
            json!({"encoded": h(out)})
        }
        "noise_decode" => {
            let b = i.bytes("bytes").unwrap();
            match b
                .split_first()
                .and_then(|(t, rest)| NoisePayloadType::decode(*t).map(|t| (t, rest)))
            {
                None => json!({"decodes": false}),
                Some((t, rest)) => {
                    let mut re = vec![t.as_u8()];
                    re.extend_from_slice(rest);
                    json!({"decodes": true, "type": t.as_u8(), "data": h(rest), "reencoded": h(re)})
                }
            }
        }
        "file_encode" => {
            let f = FilePacket {
                file_name: i.str("name"),
                file_size: i.u64("size"),
                mime_type: i.str("mime"),
                message_id: None,
                content: i.bytes("content").unwrap(),
            };
            json!({"encoded": ho(f.encode())})
        }
        "file_decode" => match FilePacket::decode(&i.bytes("bytes").unwrap()) {
            None => json!({"decodes": false}),
            Some(f) => json!({
                "decodes": true, "name": f.file_name, "size": f.file_size.map(|s| s.to_string()),
                "mime": f.mime_type, "content": h(&f.content), "reencoded": ho(f.encode()),
            }),
        },
        "fragment_encode" => {
            let f = Fragment {
                fragment_id: id8(&i.bytes("fragment_id").unwrap())
                    .ok_or(Unsupported("fragment id is not 8 bytes".into()))?,
                index: i.int("index").unwrap() as u16,
                total: i.int("total").unwrap() as u16,
                original_type: i.int("type").unwrap() as u8,
                chunk: i.bytes("data").unwrap(),
            };
            json!({"encoded": h(f.encode_payload())})
        }
        "fragment_decode" => match Fragment::decode_payload(&i.bytes("payload").unwrap()) {
            None => json!({"decodes": false}),
            Some(f) => json!({
                "decodes": true, "fragment_id": h(f.fragment_id), "index": f.index, "total": f.total,
                "type": f.original_type, "data": h(&f.chunk),
            }),
        },
        other => return Err(Unsupported(format!("unknown op {other}"))),
    })
}

fn main() {
    let mut args = std::env::args().skip(1);
    let out_dir = args
        .next()
        .expect("usage: cross_observer <out-dir> <ops.json>...");
    for path in args {
        let root: Value = serde_json::from_str(&std::fs::read_to_string(&path).expect("read ops"))
            .expect("ops json");
        let source = root["source"].as_str().unwrap_or("unknown").to_owned();
        let ops = root["ops"].as_array().expect("ops array");
        let results: Vec<Value> = ops
            .iter()
            .map(|op| {
                let id = op["id"].clone();
                let input = op["in"].as_object().cloned().unwrap_or_default();
                let name = op["op"].as_str().unwrap_or("?").to_owned();
                // A panic inside the codec is a result, not a crash of the run.
                match std::panic::catch_unwind(|| observe(&name, &In(&input))) {
                    Ok(Ok(out)) => json!({"id": id, "out": out}),
                    Ok(Err(Unsupported(why))) => json!({"id": id, "unsupported": why}),
                    Err(_) => json!({"id": id, "error": "panicked"}),
                }
            })
            .collect();
        let dest = format!("{out_dir}/results-{source}.json");
        let body = json!({"observer": "sonar-rust", "source": source, "results": results});
        std::fs::write(&dest, serde_json::to_vec(&body).expect("encode")).expect("write results");
        println!(
            "CROSS observer=sonar-rust source={source} ops={} -> {dest}",
            ops.len()
        );
    }
}
