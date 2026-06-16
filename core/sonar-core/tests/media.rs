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
use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};

/// A throwaway in-process Blossom server (BUD-01/02, content-addressed) for the
/// media e2e test. Speaks just enough HTTP/1.1: `PUT /upload` stores the body
/// under its sha256 and returns a `BlobDescriptor` JSON; `GET /<sha>` serves it.
/// Returns the base URL (e.g. `http://127.0.0.1:54321`).
fn spawn_mock_blossom() -> String {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock blossom");
    let port = listener.local_addr().unwrap().port();
    let base = format!("http://127.0.0.1:{port}");
    let base_for_thread = base.clone();
    let store: Arc<Mutex<HashMap<String, Vec<u8>>>> = Arc::new(Mutex::new(HashMap::new()));
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let store = store.clone();
            let base = base_for_thread.clone();
            std::thread::spawn(move || handle_blossom_conn(&mut stream, &store, &base));
        }
    });
    base
}

fn handle_blossom_conn(
    stream: &mut std::net::TcpStream,
    store: &Arc<Mutex<HashMap<String, Vec<u8>>>>,
    base: &str,
) {
    let mut buf = Vec::new();
    let mut tmp = [0u8; 16384];
    let header_end = loop {
        match stream.read(&mut tmp) {
            Ok(0) | Err(_) => return,
            Ok(n) => buf.extend_from_slice(&tmp[..n]),
        }
        if let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break pos;
        }
    };
    let head = String::from_utf8_lossy(&buf[..header_end]).to_string();
    let mut request_line = head.lines().next().unwrap_or("").split_whitespace();
    let method = request_line.next().unwrap_or("").to_string();
    let path = request_line.next().unwrap_or("").to_string();
    let content_length: usize = head
        .lines()
        .find_map(|l| {
            let lower = l.to_ascii_lowercase();
            lower
                .strip_prefix("content-length:")
                .map(|v| v.trim().parse::<usize>().unwrap_or(0))
        })
        .unwrap_or(0);
    let body_start = header_end + 4;
    while buf.len() < body_start + content_length {
        match stream.read(&mut tmp) {
            Ok(0) | Err(_) => break,
            Ok(n) => buf.extend_from_slice(&tmp[..n]),
        }
    }
    let body = buf[body_start..(body_start + content_length).min(buf.len())].to_vec();

    if method == "PUT" && path.ends_with("/upload") {
        use sha2::{Digest, Sha256};
        let sha = hex::encode(Sha256::digest(&body));
        store.lock().unwrap().insert(sha.clone(), body.clone());
        let json = format!(
            "{{\"url\":\"{base}/{sha}\",\"sha256\":\"{sha}\",\"size\":{},\"uploaded\":0}}",
            body.len()
        );
        let resp = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{json}",
            json.len()
        );
        let _ = stream.write_all(resp.as_bytes());
    } else if method == "GET" {
        let key = path.trim_start_matches('/');
        if let Some(blob) = store.lock().unwrap().get(key).cloned() {
            let header = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                blob.len()
            );
            let _ = stream.write_all(header.as_bytes());
            let _ = stream.write_all(&blob);
        } else {
            let _ = stream.write_all(
                b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            );
        }
    } else {
        let _ = stream.write_all(
            b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        );
    }
    let _ = stream.flush();
}

/// FULL e2e: iOS-like and Android-like clients (same core) exchange an image
/// over the White Noise protocol — real `send_media` (encrypt → Blossom upload →
/// publish over the relay) then receiver `sync` → imeta parse → download →
/// `decrypt_media_by_url`. This is the protocol-level proof that iOS↔Android
/// media works, since both apps drive this exact core path.
#[tokio::test]
async fn media_sends_over_white_noise_end_to_end() {
    let relay = MockRelay::run().await.expect("mock relay starts");
    let relay_url = relay.url().await;
    let blossom = spawn_mock_blossom();

    let ios = SonarClient::connect_in_memory(Identity::generate(), vec![relay_url.clone()])
        .await
        .expect("ios connects");
    let android = SonarClient::connect_in_memory(Identity::generate(), vec![relay_url.clone()])
        .await
        .expect("android connects");

    android
        .publish_key_package()
        .await
        .expect("android publishes kp");
    let ios_group = ios
        .start_dm(android.identity().public_key(), "ios & android")
        .await
        .expect("ios starts dm");
    android.sync().await.expect("android joins");
    let android_group = android.groups().expect("groups")[0].mls_group_id.clone();

    // iOS sends an "image" (generic mime → no image decoder dependency).
    let image = b"PNGish bytes -- iOS to Android encrypted media over White Noise".to_vec();
    ios.send_media(
        &ios_group,
        image.clone(),
        "photo.bin",
        "application/octet-stream",
        "from iOS",
        &blossom,
    )
    .await
    .expect("ios sends media");

    // Android receives the media message and the imeta reference.
    android.sync().await.expect("android syncs");
    let msgs = android.messages(&android_group).expect("android messages");
    let media_msg = msgs
        .iter()
        .find(|m| !m.media.is_empty())
        .expect("android sees a media message");
    assert!(!media_msg.mine);
    assert_eq!(media_msg.content, "from iOS");
    let url = media_msg.media[0].url.clone();
    assert!(
        url.starts_with(&blossom),
        "imeta url points at the Blossom server"
    );

    // Android downloads the ciphertext from Blossom and decrypts with the group key.
    let ciphertext = reqwest::get(&url)
        .await
        .expect("download")
        .bytes()
        .await
        .expect("bytes")
        .to_vec();
    assert_ne!(ciphertext, image, "Blossom only ever holds ciphertext");
    let decrypted = android
        .engine()
        .decrypt_media_by_url(&android_group, &url, &ciphertext)
        .expect("android decrypts");
    assert_eq!(
        decrypted, image,
        "iOS→Android media round-trips byte-for-byte"
    );

    // Reverse direction: Android → iOS.
    let reply = b"and back -- Android to iOS".to_vec();
    android
        .send_media(
            &android_group,
            reply.clone(),
            "reply.bin",
            "application/octet-stream",
            "from Android",
            &blossom,
        )
        .await
        .expect("android sends media");
    ios.sync().await.expect("ios syncs");
    let ios_view = ios.messages(&ios_group).expect("ios messages");
    let back = ios_view
        .iter()
        .find(|m| m.media.first().map(|r| r.url != url).unwrap_or(false))
        .expect("ios sees android's media");
    let url2 = back.media[0].url.clone();
    let ct2 = reqwest::get(&url2)
        .await
        .unwrap()
        .bytes()
        .await
        .unwrap()
        .to_vec();
    let dec2 = ios
        .engine()
        .decrypt_media_by_url(&ios_group, &url2, &ct2)
        .expect("ios decrypts");
    assert_eq!(dec2, reply, "Android→iOS media round-trips byte-for-byte");
}

/// `http_get` (via `fetch_media`) must refuse non-https URLs — SSRF guard. Uses
/// the mock (http) server: the download is rejected before any request.
#[tokio::test]
async fn fetch_media_refuses_non_https() {
    let relay = MockRelay::run().await.expect("relay");
    let url = relay.url().await;
    let client = SonarClient::connect_in_memory(Identity::generate(), vec![url])
        .await
        .expect("connect");
    // A fabricated group id is fine — the https check happens before any lookup.
    let gid = sonar_core::GroupId::from_slice(&[7u8; 32]);
    let err = client
        .fetch_media(&gid, "http://127.0.0.1:1/blob")
        .await
        .expect_err("non-https must be refused");
    assert!(
        err.to_string().contains("non-https"),
        "expected an https refusal, got: {err}"
    );
}

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
