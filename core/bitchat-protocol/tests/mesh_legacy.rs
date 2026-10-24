//! The protocol tests that lived in `sonar-core/src/mesh.rs` before the codec
//! moved into this crate, kept verbatim where the API allowed so the behaviour
//! they pinned (fragment reassembler budgets and lifetimes, TLV round trips,
//! sign/verify) is still pinned by the same names.
#![allow(unused_imports)]

use bitchat_protocol::fragment::{self, Fragment, Reassembler};
use bitchat_protocol::file_packet::{self, FilePacket};
use bitchat_protocol::private_message::{encode_private_message_plaintext, split_noise_plaintext};
use bitchat_protocol::packet::{encrypted_packet, handshake_packet};
use bitchat_protocol::signing::{ed25519_verify, sign_packet, verify_packet};
use bitchat_protocol::padding::{optimal_block_size, pad, unpad};
use bitchat_protocol::peer_id::peer_id_from_noise_key;
use bitchat_protocol::{msg_type, noise_payload, Announce, MeshSigner, Packet, PrivateMessage, BROADCAST_RECIPIENT};

/// An optional extension TLV must never be able to destroy the payload it
/// rides on. A peer (or a future version) emitting a malformed 0x05 must
/// cost the delivery receipt only — the media still has to arrive.
#[test]
fn malformed_optional_message_id_degrades_instead_of_dropping_the_file() {

    let good = FilePacket {
        file_name: Some("photo.jpg".into()),
        file_size: Some(3),
        mime_type: Some("image/jpeg".into()),
        message_id: Some("mid-1".into()),
        content: vec![1, 2, 3],
    };
    let encoded = good.encode().expect("encode");
    let round = FilePacket::decode(&encoded).expect("decode");
    assert_eq!(round.message_id.as_deref(), Some("mid-1"));
    assert_eq!(round.content, vec![1, 2, 3]);

    // Hand-build a packet whose 0x05 value is invalid UTF-8, then one whose
    // 0x05 value is empty. Both must decode with the content intact.
    for bad_value in [vec![0xff, 0xfe], Vec::new()] {
        let mut raw: Vec<u8> = Vec::new();
        raw.push(0x03);
        raw.extend_from_slice(&(10u16).to_be_bytes());
        raw.extend_from_slice(b"image/jpeg");
        raw.push(0x05);
        raw.extend_from_slice(&(bad_value.len() as u16).to_be_bytes());
        raw.extend_from_slice(&bad_value);
        raw.push(0x04);
        raw.extend_from_slice(&(3u32).to_be_bytes());
        raw.extend_from_slice(&[1, 2, 3]);

        let decoded = FilePacket::decode(&raw)
            .expect("a malformed optional message id must not drop the file");
        assert_eq!(decoded.content, vec![1, 2, 3]);
        assert_eq!(decoded.message_id, None, "no receipt, but the media survives");
        assert_eq!(decoded.mime_type.as_deref(), Some("image/jpeg"));
    }

    // Encoding is symmetric: an unusable id is skipped, not fatal.
    let empty_id = FilePacket { message_id: Some(String::new()), ..good.clone() };
    let encoded_empty = empty_id.encode().expect("an empty id must not fail the send");
    assert_eq!(FilePacket::decode(&encoded_empty).unwrap().message_id, None);

    let oversized = FilePacket {
        message_id: Some("x".repeat(u16::MAX as usize + 1)),
        ..good.clone()
    };
    let encoded_oversized = oversized.encode().expect("an oversized id must not fail the send");
    assert_eq!(FilePacket::decode(&encoded_oversized).unwrap().message_id, None);
}
const TLV_NICKNAME: u8 = 0x01;
const PM_TLV_MESSAGE_ID: u8 = 0x00;
const PM_TLV_CONTENT_LONG: u8 = 0x03;

#[test]
fn packet_roundtrip_broadcast_no_sig() {
    let mut p = Packet::new(
        msg_type::MESSAGE,
        7,
        0x0102030405060708,
        [1, 2, 3, 4, 5, 6, 7, 8],
    );
    p.payload = b"hello mesh".to_vec();
    let wire = p.encode().unwrap();
    let back = Packet::decode(&wire).unwrap();
    assert_eq!(back, p);
}

#[test]
fn packet_roundtrip_with_recipient_and_signature() {
    let mut p = Packet::new(msg_type::NOISE_ENCRYPTED, 3, 42, [9; 8]);
    p.recipient_id = Some([0xAB; 8]);
    p.payload = vec![0u8; 200];
    p.signature = Some([0x5A; 64]);
    let wire = p.encode().unwrap();
    let back = Packet::decode(&wire).unwrap();
    assert_eq!(back, p);
    assert_eq!(back.recipient_id, Some([0xAB; 8]));
    assert_eq!(back.signature, Some([0x5A; 64]));
}

#[test]
fn header_byte_layout_is_exact() {
    // Anchor the v1 header against the documented Swift layout.
    let p = Packet::new(0x02, 0x07, 0x0011223344556677, [0xAA; 8]);
    let raw = p.encode_unpadded().unwrap();
    assert_eq!(raw[0], 1, "version");
    assert_eq!(raw[1], 0x02, "type");
    assert_eq!(raw[2], 0x07, "ttl");
    assert_eq!(
        &raw[3..11],
        &[0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77],
        "timestamp BE"
    );
    assert_eq!(raw[11], 0, "flags (no recipient/sig)");
    assert_eq!(&raw[12..14], &[0x00, 0x00], "payload length BE");
    assert_eq!(&raw[14..22], &[0xAA; 8], "sender id");
}

#[test]
fn padding_matches_swift_rules() {
    // 50-byte data → +16 = 66 → block 256 → pad to 256.
    assert_eq!(optimal_block_size(50), 256);
    let padded = pad(vec![0u8; 50], 256);
    assert_eq!(padded.len(), 256);
    assert_eq!(*padded.last().unwrap(), (256 - 50) as u8);
    assert_eq!(unpad(&padded), vec![0u8; 50]);

    // Gap > 255 → no padding (Swift returns unchanged).
    assert_eq!(optimal_block_size(241), 512); // 241+16=257 → 512
    let not_padded = pad(vec![0u8; 241], 512); // gap 271 > 255
    assert_eq!(not_padded.len(), 241);
}

#[test]
fn unpad_leaves_non_padded_data() {
    let data = vec![1, 2, 3, 9]; // last=9 but only 4 bytes → invalid run
    assert_eq!(unpad(&data), data);
}

#[test]
fn announce_roundtrip_and_tolerant_decode() {
    let mut a = Announce::new("softsignal", vec![0x11; 32], vec![0x22; 32]);
    a.direct_neighbors = Some(vec![[1; 8], [2; 8]]);
    let enc = a.encode().unwrap();
    assert_eq!(Announce::decode(&enc).unwrap(), a);

    // Unknown TLV in the middle is skipped.
    let mut with_unknown = Vec::new();
    with_unknown.push(0x09u8); // unknown type
    with_unknown.push(3u8);
    with_unknown.extend_from_slice(&[1, 2, 3]);
    with_unknown.extend_from_slice(&enc);
    let back = Announce::decode(&with_unknown).unwrap();
    assert_eq!(back.nickname, "softsignal");
}

#[test]
fn announce_missing_required_field_is_none() {
    // Only a nickname TLV — missing keys → None.
    let only_nick = vec![TLV_NICKNAME, 3, b'a', b'b', b'c'];
    assert!(Announce::decode(&only_nick).is_err());
}

#[test]
fn peer_id_is_16_hex_chars() {
    let id = peer_id_from_noise_key(&[0u8; 32]);
    assert_eq!(id.len(), 16);
    assert!(id.chars().all(|c| c.is_ascii_hexdigit()));
}

fn signed_announce_packet(signer: &MeshSigner) -> Packet {
    let announce = Announce::new("softsignal", vec![0x11; 32], signer.public_key().to_vec());
    let mut p = Packet::new(msg_type::ANNOUNCE, 7, 1_700_000_000_000, [0xCA; 8]);
    p.payload = announce.encode().unwrap();
    sign_packet(&mut p, signer).unwrap();
    p
}

#[test]
fn announce_sign_and_verify_roundtrip() {
    let signer = MeshSigner::generate().unwrap();
    let p = signed_announce_packet(&signer);
    // Verifies against the signer's public key (the one in the TLV).
    assert!(verify_packet(&p, &signer.public_key()));
}

#[test]
fn signature_survives_wire_roundtrip_and_ttl_change() {
    let signer = MeshSigner::generate().unwrap();
    let mut p = signed_announce_packet(&signer);
    // A relay decrements ttl; the signature (ttl=0 canonical) must still verify.
    let wire = p.encode().unwrap();
    let mut received = Packet::decode(&wire).unwrap();
    received.ttl = 3; // simulate relay
    assert!(verify_packet(&received, &signer.public_key()));
    p.ttl = 1;
    assert!(verify_packet(&p, &signer.public_key()));
}

#[test]
fn tampered_payload_or_wrong_key_fails() {
    let signer = MeshSigner::generate().unwrap();
    let other = MeshSigner::generate().unwrap();
    let mut p = signed_announce_packet(&signer);
    assert!(
        !verify_packet(&p, &other.public_key()),
        "wrong key rejected"
    );
    p.payload[0] ^= 0xFF; // tamper
    assert!(!verify_packet(&p, &signer.public_key()), "tamper rejected");
}

#[test]
fn seed_roundtrip_is_stable() {
    let signer = MeshSigner::generate().unwrap();
    let seed = signer.seed();
    let restored = MeshSigner::from_seed(&seed);
    assert_eq!(signer.public_key(), restored.public_key());
    let msg = b"deterministic";
    // Ed25519 is deterministic → same signer, same signature.
    assert_eq!(signer.sign(msg), restored.sign(msg));
}

#[test]
fn ed25519_verify_rejects_malformed_inputs() {
    assert!(
        !ed25519_verify(&[0u8; 10], b"x", &[0u8; 64]),
        "bad pubkey len"
    );
    assert!(!ed25519_verify(&[0u8; 32], b"x", &[0u8; 10]), "bad sig len");
}

#[test]
fn private_message_tlv_roundtrip() {
    let pm = PrivateMessage {
        message_id: "abc-123".into(),
        content: "ciao mesh".into(),
        reply_to: None,
    };
    let enc = pm.encode_extended().unwrap();
    // First TLV is messageID (0x00), then content (0x01).
    assert_eq!(enc[0], PM_TLV_MESSAGE_ID);
    assert_eq!(PrivateMessage::decode(&enc).unwrap(), pm);
}

#[test]
fn private_message_tlv_long_content_roundtrip() {
    let pm = PrivateMessage {
        message_id: "call-offer".into(),
        content: "x".repeat(700),
        reply_to: None,
    };
    let enc = pm.encode_extended().unwrap();
    assert_eq!(enc[0], PM_TLV_MESSAGE_ID);
    assert_eq!(enc[2 + "call-offer".len()], PM_TLV_CONTENT_LONG);
    assert_eq!(PrivateMessage::decode(&enc).unwrap(), pm);
}

#[test]
fn private_message_tolerant_of_unknown_tlv() {
    let pm = PrivateMessage {
        message_id: "m1".into(),
        content: "hello".into(),
        reply_to: None,
    };
    let mut data = pm.encode_extended().unwrap();
    // Append two unknown short TLVs (1-byte length): decoder skips both.
    data.push(0x10);
    data.push(3);
    data.extend_from_slice(&[0xAA, 0xBB, 0xCC]);
    data.push(0x11);
    data.push(2);
    data.extend_from_slice(&[0xDD, 0xEE]);
    let decoded = PrivateMessage::decode(&data).unwrap();
    assert_eq!(decoded, pm);
}

#[test]
fn private_message_reply_to_tlv_roundtrip() {
    let pm = PrivateMessage {
        message_id: "child".into(),
        content: "ok".into(),
        reply_to: Some("parent-mid".into()),
    };
    let enc = pm.encode_extended().unwrap();
    assert_eq!(PrivateMessage::decode(&enc).unwrap(), pm);
    // Old decoder path: content+id still present if 0x04 is skipped.
    let without_reply = PrivateMessage {
        message_id: "child".into(),
        content: "ok".into(),
        reply_to: None,
    };
    assert_eq!(
        PrivateMessage::decode(&without_reply.encode_extended().unwrap())
            .unwrap()
            .reply_to,
        None
    );
}

#[test]
fn noise_private_message_plaintext_framing() {
    let pm = PrivateMessage {
        message_id: "id".into(),
        content: "hi".into(),
        reply_to: None,
    };
    let plain = encode_private_message_plaintext(&pm, true).unwrap();
    let (t, rest) = split_noise_plaintext(&plain).unwrap();
    assert_eq!(t, noise_payload::PRIVATE_MESSAGE);
    assert_eq!(PrivateMessage::decode(rest).unwrap(), pm);
}

#[test]
fn noise_packets_are_directed_with_right_types() {
    let hs = handshake_packet([1; 8], [2; 8], 1, 0, vec![0xAB; 48]);
    assert_eq!(hs.type_, msg_type::NOISE_HANDSHAKE);
    assert_eq!(hs.recipient_id, Some([2; 8]));
    let enc = encrypted_packet([1; 8], [2; 8], 1, 0, vec![0xCD; 80]);
    assert_eq!(enc.type_, msg_type::NOISE_ENCRYPTED);
    assert_eq!(enc.recipient_id, Some([2; 8]));
    // Wire round-trips preserve everything.
    assert_eq!(Packet::decode(&hs.encode().unwrap()).unwrap(), hs);
    assert_eq!(Packet::decode(&enc.encode().unwrap()).unwrap(), enc);
}

#[test]
fn fragment_payload_byte_layout_and_roundtrip() {
    let f = fragment::Fragment {
        fragment_id: [0xF0, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7],
        index: 0x0102,
        total: 0x0304,
        original_type: msg_type::NOISE_ENCRYPTED,
        chunk: vec![1, 2, 3, 4],
    };
    let p = f.encode_payload();
    assert_eq!(&p[0..8], &f.fragment_id);
    assert_eq!(&p[8..10], &[0x01, 0x02], "index BE");
    assert_eq!(&p[10..12], &[0x03, 0x04], "total BE");
    assert_eq!(p[12], msg_type::NOISE_ENCRYPTED, "original type");
    assert_eq!(fragment::Fragment::decode_payload(&p).unwrap(), f);
}

#[test]
fn fragment_reassembly_completes_in_order_and_out_of_order() {
    let id = [9u8; 8];
    let sender = [7u8; 8];
    let original = b"the original encoded packet bytes".to_vec();
    // Split into 3 chunks.
    let chunks: Vec<&[u8]> = original.chunks(12).collect();
    let total = chunks.len() as u16;
    let frags: Vec<fragment::Fragment> = chunks
        .iter()
        .enumerate()
        .map(|(i, c)| fragment::Fragment {
            fragment_id: id,
            index: i as u16,
            total,
            original_type: msg_type::MESSAGE,
            chunk: c.to_vec(),
        })
        .collect();

    let mut r = fragment::Reassembler::new();
    // Feed out of order: 2, 0, 1.
    assert!(r.add(sender, &frags[2], 0).is_none());
    assert!(r.add(sender, &frags[0], 0).is_none());
    let done = r.add(sender, &frags[1], 0).unwrap();
    assert_eq!(done, original);
}

/// One stuck opening fragment per bucket slot. Total on-wire cost is ~14
/// bytes × MAX_BUCKETS, unauthenticated.
fn park_streams(r: &mut fragment::Reassembler, count: usize, now_ms: u64) {
    for i in 0..count {
        let stuck = fragment::Fragment {
            fragment_id: (i as u64).to_be_bytes(),
            index: 0,
            total: 2, // never completed: index 1 never arrives
            original_type: msg_type::MESSAGE,
            chunk: vec![0u8; 4],
        };
        assert!(r.add([0xEE; 8], &stuck, now_ms).is_none());
    }
}

fn two_part_stream(id_byte: u8) -> [fragment::Fragment; 2] {
    let make = |index| fragment::Fragment {
        fragment_id: [id_byte; 8],
        index,
        total: 2,
        original_type: msg_type::MESSAGE,
        chunk: vec![id_byte; 3],
    };
    [make(0), make(1)]
}

/// The per-stream cap bounds ONE stream; the reassembler must also bound
/// the sum. Without a global budget, MAX_BUCKETS streams each approaching
/// MAX_STREAM_BYTES hold ~287 MiB alive — a jetsam kill, and reachable by
/// an attacker who refreshes each bucket inside its lifetime.
#[test]
fn total_buffered_bytes_stay_within_the_global_budget() {
    let mut r = fragment::Reassembler::new();
    // 64 KiB per fragment, 16 indices per stream => each stream walks
    // toward the 1 MiB per-stream cap. Feed far more streams than the
    // global budget can hold, all inside the protect window.
    let chunk = vec![0xAB; 64 * 1024];
    let mut now = 0u64;
    for stream in 0..64u64 {
        for index in 0..16u16 {
            let frag = fragment::Fragment {
                fragment_id: stream.to_be_bytes(),
                index,
                total: 64, // never completes
                original_type: msg_type::MESSAGE,
                chunk: chunk.clone(),
            };
            // Advance past the protect window so reclaim has candidates;
            // stay well inside the absolute lifetime.
            now += fragment::STREAM_EVICT_PROTECT_MS + 1;
            let _ = r.add([0xEE; 8], &frag, now);
            assert!(
                r.buffered_bytes() <= fragment::MAX_TOTAL_STREAM_BYTES,
                "buffered {} exceeded the global budget {}",
                r.buffered_bytes(),
                fragment::MAX_TOTAL_STREAM_BYTES
            );
        }
    }
}

/// A legitimate transfer must not be starved by the global budget: while
/// one stream is actively transmitting, the reclaim path takes bytes from
/// idle buckets rather than from the live stream.
#[test]
fn global_budget_reclaims_idle_streams_not_the_live_one() {
    let mut r = fragment::Reassembler::new();
    let chunk = vec![0xCD; 64 * 1024];
    // Park several fat idle streams.
    let mut now = 0u64;
    for stream in 0..16u64 {
        for index in 0..8u16 {
            let frag = fragment::Fragment {
                fragment_id: stream.to_be_bytes(),
                index,
                total: 64,
                original_type: msg_type::MESSAGE,
                chunk: chunk.clone(),
            };
            let _ = r.add([0xEE; 8], &frag, now);
        }
    }
    now += fragment::STREAM_EVICT_PROTECT_MS + 1;

    // A legitimate 4-part stream now transmits back to back. Every part
    // must be admitted: reclaim frees the idle buckets instead.
    let live_id = 0xFFFF_FFFFu64.to_be_bytes();
    let mut completed = None;
    for index in 0..4u16 {
        let frag = fragment::Fragment {
            fragment_id: live_id,
            index,
            total: 4,
            original_type: msg_type::MESSAGE,
            chunk: chunk.clone(),
        };
        now += 5; // actively transmitting, inside the protect window
        completed = r.add([0x77; 8], &frag, now);
    }
    let bytes = completed.expect("an actively transmitting stream must complete");
    assert_eq!(bytes.len(), 4 * chunk.len());
}

/// #416: 256 parked streams used to occupy every bucket forever — the
/// capacity guard then dropped every future stream from every legitimate
/// peer for the process lifetime. Expiry + protected-age eviction must
/// reclaim them, and refusal is only ever a bounded (≤ protect window)
/// admission stall — never a permanent veto.
#[test]
fn parked_streams_expire_and_reassembly_recovers() {
    let mut r = fragment::Reassembler::new();
    park_streams(&mut r, fragment::MAX_BUCKETS, 1_000);

    // While EVERY parked stream is inside the protect window, a newcomer
    // is refused — evicting a possibly-live bucket is the attack surface
    // (#422 precedent). The refused fragment is lost, not retried; the
    // absolute lifetime is what ends a sustained flood.
    let [first, second] = two_part_stream(0xA1);
    assert!(r.add([0x11; 8], &first, 1_500).is_none());
    assert_eq!(
        r.stored_chunks(),
        fragment::MAX_BUCKETS,
        "a fresh full table refuses the newcomer instead of evicting"
    );

    // Once the stalest bucket ages past the protect window, the newcomer
    // is admitted by evicting it — capacity is never a permanent veto.
    let now = 1_000 + fragment::STREAM_EVICT_PROTECT_MS;
    assert!(r.add([0x11; 8], &first, now).is_none());
    let done = r
        .add([0x11; 8], &second, now)
        .expect("a full-but-stale table must admit a new legitimate stream");
    assert_eq!(done, [vec![0xA1; 3], vec![0xA1; 3]].concat());

    // Past the idle timeout the parked streams are swept wholesale and a
    // fresh stream completes without evicting anything live.
    let later = 1_000 + fragment::STREAM_IDLE_TIMEOUT_MS;
    let [first, second] = two_part_stream(0xB2);
    assert!(r.add([0x22; 8], &first, later).is_none());
    assert!(r.add([0x22; 8], &second, later).is_some());
}

/// The engine tick sweeps parked streams so their memory is released even
/// when no new fragment ever arrives. Asserted on `stored_chunks`, not on
/// `add` returning `None` — refusal at capacity returns `None` too, which
/// is how a no-op `sweep` once survived this suite (mutation finding).
#[test]
fn sweep_reclaims_idle_streams() {
    let mut r = fragment::Reassembler::new();
    park_streams(&mut r, fragment::MAX_BUCKETS, 0);
    assert_eq!(r.stored_chunks(), fragment::MAX_BUCKETS);
    r.sweep(fragment::STREAM_IDLE_TIMEOUT_MS);
    assert_eq!(r.stored_chunks(), 0, "idle streams must actually be swept");

    // All slots are free again: MAX_BUCKETS new streams are admitted
    // without touching the eviction path.
    let now = fragment::STREAM_IDLE_TIMEOUT_MS;
    park_streams(&mut r, fragment::MAX_BUCKETS, now);
    assert_eq!(r.stored_chunks(), fragment::MAX_BUCKETS);
}

/// Doze resumes must not rewind the absolute lifetime. Android's tick
/// handler is suppressed by Doze while the engine clock keeps advancing,
/// so a bucket refreshed once per short awake period would otherwise
/// survive indefinitely across screen-off cycles.
#[test]
fn repeated_doze_resumes_cannot_extend_a_stream_forever() {
    let mut r = fragment::Reassembler::new();
    let [first, _second] = two_part_stream(0xF6);
    assert!(r.add([0x66; 8], &first, 0).is_none());

    // Simulate 20 screen-off cycles: each one is a long resume gap, and
    // the attacker touches the bucket once while we are awake.
    let mut now = 0u64;
    for _ in 0..20 {
        let gap = 10 * fragment::STREAM_IDLE_TIMEOUT_MS;
        now += gap;
        r.reseed(gap, now);
        let _ = r.add([0x66; 8], &first, now);
    }
    r.sweep(now);
    assert_eq!(
        r.stored_chunks(),
        0,
        "the absolute lifetime must be monotonic across doze resumes"
    );
}

/// The absolute lifetime ceiling: a bucket kept "fresh" by trickled
/// duplicates still dies at STREAM_MAX_LIFETIME_MS.
#[test]
fn refresh_cannot_extend_a_stream_forever() {
    let mut r = fragment::Reassembler::new();
    let [first, _second] = two_part_stream(0xD4);
    assert!(r.add([0x44; 8], &first, 0).is_none());
    // Keep touching the same fragment to refresh last_touch…
    let mut now = 0;
    while now < fragment::STREAM_MAX_LIFETIME_MS {
        now += fragment::STREAM_IDLE_TIMEOUT_MS / 2;
        let _ = r.add([0x44; 8], &first, now);
    }
    r.sweep(now);
    assert_eq!(
        r.stored_chunks(),
        0,
        "refreshing must not extend a stream past the absolute lifetime"
    );
}

/// A protected (recently active) stream survives eviction pressure; the
/// attacker's own parked buckets are what get evicted once they age.
#[test]
fn active_stream_survives_eviction_pressure() {
    let mut r = fragment::Reassembler::new();
    // The victim's stream starts first (oldest start time)…
    let victim = [0x77; 8];
    let chunks: Vec<&[u8]> = b"legitimate payload".chunks(6).collect();
    let total = chunks.len() as u16;
    let frags: Vec<fragment::Fragment> = chunks
        .iter()
        .enumerate()
        .map(|(i, c)| fragment::Fragment {
            fragment_id: [0x55; 8],
            index: i as u16,
            total,
            original_type: msg_type::MESSAGE,
            chunk: c.to_vec(),
        })
        .collect();
    assert!(r.add(victim, &frags[0], 100).is_none());
    // …then the attacker parks MAX_BUCKETS - 1 streams (table now full).
    park_streams(&mut r, fragment::MAX_BUCKETS - 1, 200);
    // While everything is fresh a newcomer is refused (bounded stall)…
    let [first, second] = two_part_stream(0xC3);
    assert!(r.add([0x33; 8], &first, 400).is_none());
    // …and the victim keeps transmitting, refreshing its bucket.
    let refresh = 200 + fragment::STREAM_EVICT_PROTECT_MS;
    assert!(r.add(victim, &frags[1], refresh).is_none());
    // Now the attacker's parked buckets are past the protect window while
    // the victim's is fresh: the newcomer evicts a PARKED bucket.
    let now = refresh + 50;
    assert!(r.add([0x33; 8], &first, now).is_none());
    assert!(r.add([0x33; 8], &second, now).is_some());
    // The victim's stream still completes.
    let done = r
        .add(victim, &frags[2], now + 50)
        .expect("an actively transmitting stream must survive table pressure");
    assert_eq!(done, b"legitimate payload".to_vec());
}

/// Doze recovery must not resurrect the dead: a freeze re-seeds streams
/// that were LIVE when we froze, but a bucket already parked past its
/// bounds before the freeze must still expire. Stamping every bucket to
/// `now` (the first cut) let an attacker's parked streams outlive both
/// the idle timeout and the absolute lifetime on any host whose ticks
/// Doze suppresses — i.e. every Android phone in a pocket.
#[test]
fn reseed_shifts_ages_instead_of_resurrecting_parked_streams() {
    let mut r = fragment::Reassembler::new();
    // Parked long ago, already past the idle timeout when we froze.
    park_streams(&mut r, 4, 0);
    // A stream that was live moments before the freeze.
    let [first, second] = two_part_stream(0xE5);
    let live_at = fragment::STREAM_IDLE_TIMEOUT_MS;
    assert!(r.add([0x55; 8], &first, live_at).is_none());

    // Freeze, then resume: the gap is OUR downtime.
    let gap = 5 * fragment::STREAM_IDLE_TIMEOUT_MS;
    let now = live_at + gap;
    r.reseed(gap, now);

    r.sweep(now);
    assert_eq!(
        r.stored_chunks(),
        1,
        "only the pre-freeze-live stream survives; parked ones still expire"
    );
    // And the survivor can still complete.
    assert!(r.add([0x55; 8], &second, now + 10).is_some());
}

/// iOS `assemblyLimit` mirror: a stream whose cumulative bytes exceed a
/// maximal framed file is hostile — the whole bucket is dropped, not
/// buffered further.
#[test]
fn stream_exceeding_the_byte_cap_is_dropped() {
    let mut r = fragment::Reassembler::new();
    let chunk = vec![0u8; 200_000];
    let total = 8u16;
    let mut admitted = 0;
    for i in 0..total {
        let f = fragment::Fragment {
            fragment_id: [0xAB; 8],
            index: i,
            total,
            original_type: msg_type::MESSAGE,
            chunk: chunk.clone(),
        };
        if r.add([0x66; 8], &f, 0).is_none() && r.stored_chunks() == 0 && i > 0 {
            break;
        }
        admitted += 1;
    }
    assert!(
        (admitted as usize) * 200_000 <= fragment::MAX_STREAM_BYTES,
        "admitted {admitted} chunks — cap must fire before exceeding MAX_STREAM_BYTES"
    );
    assert_eq!(
        r.stored_chunks(),
        0,
        "an over-cap stream is dropped wholesale, not kept partially"
    );
}

/// #416 secondary amplification: a single ~14-byte fragment claiming
/// `total = MAX_FRAGMENTS` must not reserve thousands of slots. Storage is
/// sparse — one stored chunk per fragment actually received.
#[test]
fn forged_total_does_not_preallocate() {
    let mut r = fragment::Reassembler::new();
    let evil = fragment::Fragment {
        fragment_id: [0xDD; 8],
        index: 0,
        total: fragment::MAX_FRAGMENTS,
        original_type: msg_type::MESSAGE,
        chunk: vec![0u8; 4],
    };
    assert!(r.add([0x44; 8], &evil, 0).is_none());
    assert_eq!(
        r.stored_chunks(),
        1,
        "sparse storage: memory tracks received fragments, not claimed total"
    );
}
