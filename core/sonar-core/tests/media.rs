//! Encrypted media (Marmot MIP-04) round-trip.
//!
//! Proves the crypto + `imeta` protocol path end-to-end between two parties that
//! share an MLS group: the sender encrypts with the group key, the receiver
//! parses the `imeta` tag off the decrypted message and decrypts the ciphertext
//! with the SAME group exporter secret. The Blossom HTTP upload/download is thin
//! glue exercised separately on-device; here we hand the ciphertext directly so
//! the test stays network-free and deterministic (mirrors `e2e.rs`).

use nostr_relay_builder::MockRelay;
use sonar_core::client::SonarClient;
use sonar_core::identity::Identity;

#[tokio::test]
async fn media_round_trips_through_the_group_key() {
    let relay = MockRelay::run().await.expect("mock relay starts");
    let relay_url = relay.url().await;

    let alice = SonarClient::connect_in_memory(Identity::generate(), vec![relay_url.clone()])
        .await
        .expect("alice connects");
    let bob = SonarClient::connect_in_memory(Identity::generate(), vec![relay_url.clone()])
        .await
        .expect("bob connects");

    // Establish the group (relay only used for the welcome handshake).
    bob.publish_key_package().await.expect("bob publishes kp");
    let alice_group = alice
        .start_dm(bob.identity().public_key(), "alice & bob")
        .await
        .expect("alice starts dm");
    bob.sync().await.expect("bob joins via welcome");
    let bob_group = bob.groups().expect("bob groups")[0].mls_group_id.clone();

    // Alice attaches a file. Generic mime so the test doesn't depend on an image
    // decoder — the crypto path is identical for any bytes.
    let plaintext = b"the cake is a lie -- attached as an encrypted blob".to_vec();
    let mime = "application/octet-stream";
    let filename = "secret.bin";

    let upload = alice
        .engine()
        .encrypt_media(&alice_group, &plaintext, mime, filename)
        .expect("alice encrypts media");
    // Ciphertext differs from plaintext and carries the MIP-04 metadata.
    assert_ne!(upload.encrypted_data, plaintext);
    assert_eq!(upload.mime_type, mime);
    assert_eq!(upload.filename, filename);

    // The URL a Blossom server WOULD return (server/<sha256 of ciphertext>).
    let url = format!(
        "https://blossom.test/{}",
        hex::encode(upload.encrypted_hash)
    );

    let event = alice
        .engine()
        .create_media_event(&alice_group, &upload, &url, "here's a file")
        .expect("alice builds media event");

    // Record for the sender, then hand the 445 to the receiver (stands in for the
    // relay leg, already covered by the text e2e test).
    alice
        .engine()
        .process_incoming(&event)
        .await
        .expect("alice records her own media msg");
    bob.engine()
        .process_incoming(&event)
        .await
        .expect("bob decrypts the media msg");

    // Bob sees the message with the media reference parsed off the imeta tag.
    let bob_msgs = bob.messages(&bob_group).expect("bob messages");
    let media_msg = bob_msgs
        .iter()
        .find(|m| !m.media.is_empty())
        .expect("bob sees a media message");
    assert!(!media_msg.mine);
    assert_eq!(media_msg.content, "here's a file");
    assert_eq!(media_msg.media.len(), 1);
    let r = &media_msg.media[0];
    assert_eq!(r.url, url);
    assert_eq!(r.mime_type, mime);
    assert_eq!(r.filename, filename);

    // Bob decrypts the ciphertext with the group key resolved from the imeta tag.
    let decrypted = bob
        .engine()
        .decrypt_media_by_url(&bob_group, &url, &upload.encrypted_data)
        .expect("bob decrypts the blob");
    assert_eq!(decrypted, plaintext, "round-trips byte-for-byte");

    // Tampered ciphertext must fail (hash / AEAD verification), not return garbage.
    let mut tampered = upload.encrypted_data.clone();
    tampered[0] ^= 0xFF;
    assert!(
        bob.engine()
            .decrypt_media_by_url(&bob_group, &url, &tampered)
            .is_err(),
        "tampered media must be rejected"
    );

    // An unknown URL is a clean error, not a panic.
    assert!(bob
        .engine()
        .decrypt_media_by_url(
            &bob_group,
            "https://blossom.test/nope",
            &upload.encrypted_data
        )
        .is_err());
}
