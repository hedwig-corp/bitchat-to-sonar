//! MIP-05 push token encryption and registration.
//!
//! Encrypts APNS/FCM device tokens to the transponder's secp256k1 public key
//! and publishes the result inside a NIP-59 gift wrap addressed to the server.

use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{ChaCha20Poly1305, Nonce};
use ::hkdf::Hkdf;
use nostr::nips::nip44;
use nostr::prelude::*;

use crate::Error;

const MIP05_SALT: &[u8] = b"mip05-v1";
const MIP05_INFO: &[u8] = b"mip05-token-encryption";
const MIP05_PLAINTEXT_LEN: usize = 1024;
const MIP05_KIND: u16 = 446;

#[repr(u8)]
#[derive(Clone, Copy)]
pub enum PushPlatform {
    Apns = 0x01,
    Fcm = 0x02,
}

/// Encrypt a device token per the MIP-05 spec.
///
/// Output: ephemeral_pubkey(32) || nonce(12) || ciphertext+tag(1040)
///
/// Uses x-only (Nostr-style) 32-byte pubkeys since both client and
/// transponder derive keys via NIP-44 ConversationKey.
pub fn encrypt_token(
    platform: PushPlatform,
    token: &[u8],
    server_pubkey: &PublicKey,
) -> Result<Vec<u8>, Error> {
    if token.is_empty() || token.len() > MIP05_PLAINTEXT_LEN - 3 {
        return Err(Error::InvalidInput(
            "push token must be 1..1021 bytes".into(),
        ));
    }

    // Build the 1024-byte plaintext: platform(1) + token_len(2 BE) + token + random padding.
    let mut plaintext = Vec::with_capacity(MIP05_PLAINTEXT_LEN);
    plaintext.push(platform as u8);
    let token_len = token.len() as u16;
    plaintext.push((token_len >> 8) as u8);
    plaintext.push((token_len & 0xFF) as u8);
    plaintext.extend_from_slice(token);
    let pad_len = MIP05_PLAINTEXT_LEN - plaintext.len();
    let mut pad = vec![0u8; pad_len];
    getrandom::getrandom(&mut pad)
        .map_err(|e| Error::InvalidInput(format!("rng failed: {e}")))?;
    plaintext.extend_from_slice(&pad);

    // Generate ephemeral secp256k1 keypair for ECDH.
    let ephemeral = Keys::generate();
    let ephemeral_pk_bytes = ephemeral.public_key().to_bytes();

    // ECDH via NIP-44's ConversationKey (secp256k1 shared point).
    let conv_key = nip44::v2::ConversationKey::derive(ephemeral.secret_key(), server_pubkey)
        .map_err(|e| Error::InvalidInput(format!("ECDH failed: {e}")))?;

    // MIP-05 uses its own HKDF params, not NIP-44's.
    let hk = Hkdf::<sha2::Sha256>::new(Some(MIP05_SALT), conv_key.as_bytes());
    let mut sym_key = [0u8; 32];
    hk.expand(MIP05_INFO, &mut sym_key)
        .map_err(|e| Error::InvalidInput(format!("HKDF expand failed: {e}")))?;

    // ChaCha20-Poly1305 encrypt.
    let cipher = ChaCha20Poly1305::new_from_slice(&sym_key)
        .map_err(|e| Error::InvalidInput(format!("cipher init failed: {e}")))?;
    let mut nonce_bytes = [0u8; 12];
    getrandom::getrandom(&mut nonce_bytes)
        .map_err(|e| Error::InvalidInput(format!("rng failed: {e}")))?;
    let nonce = Nonce::from_slice(&nonce_bytes);
    let ciphertext = cipher
        .encrypt(nonce, plaintext.as_ref())
        .map_err(|e| Error::InvalidInput(format!("encrypt failed: {e}")))?;

    // Output: ephemeral_pubkey(32) || nonce(12) || ciphertext+tag(1040)
    let mut out = Vec::with_capacity(32 + 12 + ciphertext.len());
    out.extend_from_slice(&ephemeral_pk_bytes);
    out.extend_from_slice(&nonce_bytes);
    out.extend_from_slice(&ciphertext);
    Ok(out)
}

/// Build the kind:446 rumor and NIP-59 gift-wrap it to the transponder.
pub async fn build_push_registration_event(
    sender_keys: &Keys,
    platform: PushPlatform,
    token: &[u8],
    server_pubkey: &PublicKey,
) -> Result<Event, Error> {
    let encrypted = encrypt_token(platform, token, server_pubkey)?;
    let content = hex::encode(&encrypted);

    let rumor = EventBuilder::new(Kind::Custom(MIP05_KIND), &content)
        .build(sender_keys.public_key());

    let gift = EventBuilder::gift_wrap(sender_keys, server_pubkey, rumor, []).await?;
    Ok(gift)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encrypt_token_output_length() {
        let server = Keys::generate();
        let token = b"0123456789abcdef0123456789abcdef";

        let blob = encrypt_token(PushPlatform::Apns, token, &server.public_key()).unwrap();
        // 32 (x-only pubkey) + 12 (nonce) + 1024 (ciphertext) + 16 (tag) = 1084
        assert_eq!(blob.len(), 32 + 12 + MIP05_PLAINTEXT_LEN + 16);
    }

    #[test]
    fn encrypt_token_rejects_empty() {
        let server = Keys::generate();
        assert!(encrypt_token(PushPlatform::Apns, b"", &server.public_key()).is_err());
    }

    #[test]
    fn encrypt_token_rejects_too_large() {
        let server = Keys::generate();
        let token = vec![0xABu8; 1022];
        assert!(encrypt_token(PushPlatform::Fcm, &token, &server.public_key()).is_err());
    }

    #[test]
    fn decrypt_round_trip() {
        let server = Keys::generate();
        let token = b"apns_device_token_hex_here";

        let blob = encrypt_token(PushPlatform::Apns, token, &server.public_key()).unwrap();

        // Decrypt: extract ephemeral x-only pubkey, derive shared secret, decrypt.
        let ephemeral_pk = PublicKey::from_slice(&blob[..32]).unwrap();
        let nonce_bytes = &blob[32..44];
        let ciphertext = &blob[44..];

        let conv_key =
            nip44::v2::ConversationKey::derive(server.secret_key(), &ephemeral_pk).unwrap();
        let hk = Hkdf::<sha2::Sha256>::new(Some(MIP05_SALT), conv_key.as_bytes());
        let mut sym_key = [0u8; 32];
        hk.expand(MIP05_INFO, &mut sym_key).unwrap();

        let cipher = ChaCha20Poly1305::new_from_slice(&sym_key).unwrap();
        let nonce = Nonce::from_slice(nonce_bytes);
        let plaintext = cipher.decrypt(nonce, ciphertext).unwrap();

        assert_eq!(plaintext.len(), MIP05_PLAINTEXT_LEN);
        assert_eq!(plaintext[0], PushPlatform::Apns as u8);
        let len = ((plaintext[1] as usize) << 8) | (plaintext[2] as usize);
        assert_eq!(len, token.len());
        assert_eq!(&plaintext[3..3 + len], token);
    }

    #[tokio::test]
    async fn build_gift_wrap_produces_kind_1059() {
        let sender = Keys::generate();
        let server = Keys::generate();
        let token = b"test_token";

        let event = build_push_registration_event(
            &sender,
            PushPlatform::Apns,
            token,
            &server.public_key(),
        )
        .await
        .unwrap();

        assert_eq!(event.kind, Kind::GiftWrap);
    }
}
