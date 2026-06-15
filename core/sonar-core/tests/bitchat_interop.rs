//! bitchat ↔ Sonar BLE-media interop, at the wire-format level.
//!
//! These tests lock Sonar's mesh file transfer to bitchat's EXACT bytes
//! (`BitchatFilePacket` + 0x22 fileTransfer + 0x20 fragmentation), so a Sonar
//! user and a stock-bitchat user can exchange images / voice notes / files over
//! Bluetooth. The byte-vector test is the canonical interop anchor: Sonar must
//! produce the identical bytes bitchat's Swift encoder produces.

use sonar_core::mesh::fragment::{Fragment, Reassembler};
use sonar_core::mesh::file_packet::{fragment, FilePacket};
use sonar_core::mesh::msg_type;
use sonar_core::noise::{NoiseHandshake, NoiseKeypair};

/// Sonar's `FilePacket.encode()` must equal the bytes bitchat's
/// `BitchatFilePacket.encode()` emits for the same input — hand-derived from the
/// vendored Swift TLV (`bitchat/Protocols/BitchatFilePacket.swift`).
#[test]
fn file_packet_encodes_byte_for_byte_like_bitchat() {
    let packet = FilePacket {
        file_name: Some("a.txt".to_string()),
        file_size: None, // → resolved to content.len()
        mime_type: Some("text/plain".to_string()),
        content: b"hi".to_vec(),
    };
    // TLV order: fileName(0x01,u16 len) | fileSize(0x02,u16=4,u32) |
    //            mimeType(0x03,u16 len) | content(0x04,u32 len)
    let expected: Vec<u8> = vec![
        0x01, 0x00, 0x05, b'a', b'.', b't', b'x', b't', // fileName "a.txt"
        0x02, 0x00, 0x04, 0x00, 0x00, 0x00, 0x02, // fileSize = 2 (u32 BE)
        0x03, 0x00, 0x0a, b't', b'e', b'x', b't', b'/', b'p', b'l', b'a', b'i', b'n', // mime
        0x04, 0x00, 0x00, 0x00, 0x02, b'h', b'i', // content "hi" (u32 len)
    ];
    assert_eq!(packet.encode().expect("encode"), expected);

    // And Sonar decodes those exact bytes back to the same fields.
    let decoded = FilePacket::decode(&expected).expect("decode bitchat bytes");
    assert_eq!(decoded.file_name.as_deref(), Some("a.txt"));
    assert_eq!(decoded.file_size, Some(2));
    assert_eq!(decoded.mime_type.as_deref(), Some("text/plain"));
    assert_eq!(decoded.content, b"hi");
}

/// Mirrors bitchat's `BitchatFilePacketTests.testRoundTripPreservesFields`.
#[test]
fn file_packet_round_trip_preserves_fields() {
    let content: Vec<u8> = (0..4096u32).map(|i| (i % 251) as u8).collect();
    let packet = FilePacket {
        file_name: Some("sample.jpg".to_string()),
        file_size: Some(content.len() as u64),
        mime_type: Some("image/jpeg".to_string()),
        content: content.clone(),
    };
    let encoded = packet.encode().expect("encode");
    let decoded = FilePacket::decode(&encoded).expect("decode");
    assert_eq!(decoded.file_name.as_deref(), Some("sample.jpg"));
    assert_eq!(decoded.file_size, Some(content.len() as u64));
    assert_eq!(decoded.mime_type.as_deref(), Some("image/jpeg"));
    assert_eq!(decoded.content, content);
}

/// Mirrors bitchat's `testDecodeFallsBackToContentSizeWhenFileSizeMissing`.
#[test]
fn file_size_defaults_to_content_len_when_absent() {
    let content = vec![0x7Fu8; 1024];
    let packet = FilePacket {
        file_name: None,
        file_size: None,
        mime_type: None,
        content: content.clone(),
    };
    let decoded = FilePacket::decode(&packet.encode().unwrap()).expect("decode");
    assert_eq!(decoded.file_size, Some(1024));
    assert_eq!(decoded.content, content);
}

/// bitchat's decoder tolerates LEGACY encodings (8-byte fileSize, 2-byte content
/// length). Sonar must decode a legacy-framed packet a bitchat peer might send.
#[test]
fn decodes_legacy_8byte_filesize_and_2byte_content() {
    // fileSize legacy (0x02, len 8, u64=3) + content legacy (0x04, u16 len 3).
    let legacy: Vec<u8> = vec![
        0x02, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, // fileSize u64=3
        0x04, 0x00, 0x03, b'a', b'b', b'c', // content "abc" (2-byte len)
    ];
    let decoded = FilePacket::decode(&legacy).expect("decode legacy");
    assert_eq!(decoded.file_size, Some(3));
    assert_eq!(decoded.content, b"abc");
}

/// A file too big for one mesh packet (payload length is u16) must ride as
/// bitchat-compatible 0x20 fragments and reassemble + decode intact.
#[test]
fn large_file_packet_fragments_and_reassembles() {
    let content: Vec<u8> = (0..200_000u32).map(|i| (i.wrapping_mul(31) % 255) as u8).collect();
    let packet = FilePacket {
        file_name: Some("big.bin".to_string()),
        file_size: Some(content.len() as u64),
        mime_type: Some("application/octet-stream".to_string()),
        content,
    };
    let encoded = packet.encode().expect("encode"); // > 65535 → must fragment
    assert!(encoded.len() > u16::MAX as usize);

    let frags: Vec<Fragment> = fragment(&encoded, [7u8; 8], msg_type::FILE_TRANSFER, 400).expect("fragment");
    assert!(frags.len() > 1);
    assert!(frags.iter().all(|f| f.original_type == msg_type::FILE_TRANSFER));

    // Reassemble out of order, through the on-wire 0x20 payload codec.
    let mut reasm = Reassembler::new();
    let sender = [1u8; 8];
    let mut whole = None;
    for f in frags.iter().rev() {
        let decoded = Fragment::decode_payload(&f.encode_payload()).expect("decode frag");
        if let Some(done) = reasm.add(sender, &decoded) {
            whole = Some(done);
        }
    }
    let whole = whole.expect("reassembled");
    assert_eq!(whole, encoded);
    assert_eq!(FilePacket::decode(&whole).unwrap(), packet);
}

/// Hardening: the reassembler rejects an oversized `total` (a malicious BLE peer
/// could otherwise force a large pre-allocation from one tiny packet), and
/// `fragment()` refuses input that can't fit bitchat's u16 fragment count — no
/// panic.
#[test]
fn reassembler_and_fragment_reject_abusive_inputs() {
    use sonar_core::mesh::fragment::MAX_FRAGMENTS;

    // A single fragment claiming total > MAX_FRAGMENTS is dropped, not allocated.
    let mut reasm = Reassembler::new();
    let evil = Fragment {
        fragment_id: [0xAB; 8],
        index: 0,
        total: u16::MAX,
        original_type: msg_type::FILE_TRANSFER,
        chunk: vec![0u8; 4],
    };
    assert!(reasm.add([1u8; 8], &evil).is_none());

    // fragment() never panics: chunk_size 0 and too-many-fragments both → None.
    assert!(fragment(b"data", [1u8; 8], msg_type::FILE_TRANSFER, 0).is_none());
    let huge = vec![0u8; (MAX_FRAGMENTS as usize + 1) * 2];
    assert!(fragment(&huge, [1u8; 8], msg_type::FILE_TRANSFER, 1).is_none());

    // A valid (total == MAX_FRAGMENTS) stream still works.
    let ok = fragment(&vec![7u8; MAX_FRAGMENTS as usize], [2u8; 8], msg_type::FILE_TRANSFER, 1)
        .expect("at-limit fragmentation is allowed");
    assert_eq!(ok.len(), MAX_FRAGMENTS as usize);
}

/// Full mesh path: a file packet survives a Noise XX link + fragmentation +
/// reassembly + decode, byte-for-byte — the protocol guarantee for sending a
/// file to a bitchat peer over Bluetooth.
#[test]
fn file_survives_noise_and_fragmentation_over_the_mesh() {
    let a = NoiseKeypair::generate().unwrap();
    let b = NoiseKeypair::generate().unwrap();
    let mut ini = NoiseHandshake::initiator(&a.private).unwrap();
    let mut res = NoiseHandshake::responder(&b.private).unwrap();
    res.read_message(&ini.write_message().unwrap()).unwrap();
    ini.read_message(&res.write_message().unwrap()).unwrap();
    res.read_message(&ini.write_message().unwrap()).unwrap();
    let mut sender = ini.into_session().unwrap();
    let mut receiver = res.into_session().unwrap();

    let image: Vec<u8> = (0..9000u32).map(|i| (i % 256) as u8).collect();
    let packet = FilePacket {
        file_name: Some("photo.jpg".to_string()),
        file_size: Some(image.len() as u64),
        mime_type: Some("image/jpeg".to_string()),
        content: image.clone(),
    };
    let plain = packet.encode().unwrap();
    let ciphertext = sender.encrypt(&plain).unwrap();

    let frags = fragment(&ciphertext, [9u8; 8], msg_type::FILE_TRANSFER, 350).expect("fragment");
    let mut reasm = Reassembler::new();
    let mut got = None;
    for f in frags.iter().rev() {
        let d = Fragment::decode_payload(&f.encode_payload()).unwrap();
        if let Some(done) = reasm.add([1u8; 8], &d) {
            got = Some(done);
        }
    }
    let reassembled = got.expect("reassembled ciphertext");
    let decrypted = receiver.decrypt(&reassembled).unwrap();
    let received = FilePacket::decode(&decrypted).expect("decode received file");
    assert_eq!(received, packet);
    assert_eq!(received.content, image);
}
