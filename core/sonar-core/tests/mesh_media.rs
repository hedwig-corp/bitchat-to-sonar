//! BLE-mesh media transport e2e (protocol level, no devices).
//!
//! Proves the Bluetooth path can carry a media-sized payload between two peers:
//! a blob is encrypted over a Noise XX session (the bitchat mesh link crypto),
//! the ciphertext is split into BLE-sized fragments (type 0x20), reassembled out
//! of order on the receiver, and decrypted — byte-for-byte. This is the
//! transport guarantee BLE media relies on (the same primitives the iOS
//! BLEService and Android MeshGatt drive), provable in-process without two
//! phones. The app-layer media message format over mesh is the remaining
//! Phase-2 wiring; the transport itself is shown here to carry media end-to-end.

use sonar_core::mesh::fragment::{Fragment, Reassembler};
use sonar_core::mesh::msg_type;
use sonar_core::noise::{NoiseHandshake, NoiseKeypair};

#[test]
fn media_survives_noise_and_fragmentation_over_the_mesh() {
    // 1. Establish a Noise XX session between two mesh peers (the link crypto).
    let a = NoiseKeypair::generate().expect("keypair a");
    let b = NoiseKeypair::generate().expect("keypair b");
    let mut ini = NoiseHandshake::initiator(&a.private).expect("initiator");
    let mut res = NoiseHandshake::responder(&b.private).expect("responder");
    res.read_message(&ini.write_message().unwrap()).unwrap(); // m1: ini → res
    ini.read_message(&res.write_message().unwrap()).unwrap(); // m2: res → ini
    res.read_message(&ini.write_message().unwrap()).unwrap(); // m3: ini → res
    let mut sender = ini.into_session().expect("sender session");
    let mut receiver = res.into_session().expect("receiver session");

    // 2. A media-sized blob (8 KB — far larger than a single BLE write).
    let image: Vec<u8> = (0..8192u32)
        .map(|i| (i.wrapping_mul(7) % 251) as u8)
        .collect();

    // 3. Sender: Noise-encrypt the media, then fragment the ciphertext into
    //    BLE-sized chunks (each becomes the payload of a 0x20 fragment packet).
    let ciphertext = sender.encrypt(&image).expect("encrypt media");
    assert_ne!(ciphertext, image, "the mesh link only carries ciphertext");
    let chunk_size = 400usize;
    let total = ciphertext.len().div_ceil(chunk_size) as u16;
    assert!(total > 1, "an 8 KB media payload must actually fragment");
    let fragment_id = [9u8; 8];
    let sender_id = [1u8; 8];
    let fragments: Vec<Fragment> = ciphertext
        .chunks(chunk_size)
        .enumerate()
        .map(|(i, chunk)| Fragment {
            fragment_id,
            index: i as u16,
            total,
            original_type: msg_type::NOISE_ENCRYPTED,
            chunk: chunk.to_vec(),
        })
        .collect();

    // 4. Receiver: reassemble (fragments arrive OUT OF ORDER) through the wire
    //    codec, then Noise-decrypt the reconstructed ciphertext.
    let mut reasm = Reassembler::new();
    let mut reassembled = None;
    for frag in fragments.iter().rev() {
        // Round-trip each fragment through its on-wire 0x20 payload form.
        let decoded = Fragment::decode_payload(&frag.encode_payload()).expect("decode fragment");
        assert_eq!(&decoded, frag);
        if let Some(done) = reasm.add(sender_id, &decoded) {
            reassembled = Some(done);
        }
    }
    let reassembled = reassembled.expect("all fragments arrived → reassembled");
    assert_eq!(
        reassembled, ciphertext,
        "reassembly reproduces the ciphertext"
    );

    let decrypted = receiver.decrypt(&reassembled).expect("decrypt media");
    assert_eq!(
        decrypted, image,
        "media survives Noise + fragmentation over the mesh, byte-for-byte"
    );
}
