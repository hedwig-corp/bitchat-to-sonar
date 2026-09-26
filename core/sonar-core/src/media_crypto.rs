//! MIP-04 v2 encrypted-media helpers owned by sonar-core.
//!
//! MDK 0.9 removed `mdk_core::encrypted_media`. Sonar still needs the same
//! `EncryptedMediaUpload` / `MediaReference` shape and imeta fields so
//! Compose/iOS keep working. Key derivation uses
//! `MLS-Exporter("marmot", "encrypted-media", 32)` via the session exporter
//! cache (`marmot/encrypted-media`), then HKDF-Expand for the per-file key.

use ::hkdf::Hkdf;
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Nonce};
use nostr::prelude::*;
use sha2::{Digest, Sha256};

use crate::{Error, Result};

/// MIP-04 v2 scheme label, stored in imeta `v`.
pub const DEFAULT_SCHEME_VERSION: &str = "mip04-v2";

/// Session exporter cache key matching MDK 0.9
/// `GROUP_ENCRYPTED_MEDIA_EXPORTER_CACHE_KEY`.
pub const ENCRYPTED_MEDIA_EXPORTER_LABEL: &str = "marmot/encrypted-media";

/// Encrypted media ready for Blossom upload.
#[derive(Debug, Clone)]
pub struct EncryptedMediaUpload {
    pub encrypted_data: Vec<u8>,
    pub original_hash: [u8; 32],
    pub encrypted_hash: [u8; 32],
    pub mime_type: String,
    pub filename: String,
    pub original_size: u64,
    pub encrypted_size: u64,
    pub dimensions: Option<(u32, u32)>,
    pub blurhash: Option<String>,
    pub thumbhash: Option<String>,
    pub duration_ms: Option<u64>,
    pub waveform: Option<Vec<u8>>,
    pub nonce: [u8; 12],
}

/// Reference to an encrypted blob, parsed from an imeta tag.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MediaReference {
    pub url: String,
    pub original_hash: [u8; 32],
    pub mime_type: String,
    pub filename: String,
    pub dimensions: Option<(u32, u32)>,
    pub duration_ms: Option<u64>,
    pub waveform: Option<Vec<u8>>,
    pub scheme_version: String,
    pub nonce: [u8; 12],
}

fn scheme_label(version: &str) -> Result<&'static [u8]> {
    match version {
        "mip04-v2" => Ok(b"mip04-v2"),
        other => Err(Error::Media(format!(
            "unknown encryption scheme version: {other}"
        ))),
    }
}

fn build_hkdf_context(
    scheme_label: &[u8],
    file_hash: &[u8; 32],
    mime_type: &str,
    filename: &str,
    suffix: &[u8],
) -> Vec<u8> {
    let mut context = Vec::new();
    context.extend_from_slice(scheme_label);
    context.push(0x00);
    context.extend_from_slice(file_hash);
    context.push(0x00);
    context.extend_from_slice(mime_type.as_bytes());
    context.push(0x00);
    context.extend_from_slice(filename.as_bytes());
    context.push(0x00);
    context.extend_from_slice(suffix);
    context
}

fn build_aad(
    scheme_label: &[u8],
    file_hash: &[u8; 32],
    mime_type: &str,
    filename: &str,
) -> Vec<u8> {
    let mut aad = Vec::new();
    aad.extend_from_slice(scheme_label);
    aad.push(0x00);
    aad.extend_from_slice(file_hash);
    aad.push(0x00);
    aad.extend_from_slice(mime_type.as_bytes());
    aad.push(0x00);
    aad.extend_from_slice(filename.as_bytes());
    aad
}

fn derive_file_key(
    exporter_secret: &[u8],
    scheme_version: &str,
    original_hash: &[u8; 32],
    mime_type: &str,
    filename: &str,
) -> Result<[u8; 32]> {
    let label = scheme_label(scheme_version)?;
    let context = build_hkdf_context(label, original_hash, mime_type, filename, b"key");
    let hk = Hkdf::<Sha256>::from_prk(exporter_secret)
        .map_err(|e| Error::Media(format!("Invalid HKDF PRK: {e}")))?;
    let mut key = [0u8; 32];
    hk.expand(&context, &mut key)
        .map_err(|e| Error::Media(format!("Key derivation failed: {e}")))?;
    Ok(key)
}

fn sha256(data: &[u8]) -> [u8; 32] {
    Sha256::digest(data).into()
}

fn random_nonce() -> Result<[u8; 12]> {
    let mut nonce = [0u8; 12];
    getrandom::getrandom(&mut nonce)?;
    Ok(nonce)
}

/// Encrypt `data` with the group exporter secret (32 bytes).
pub fn encrypt_for_upload(
    exporter_secret: &[u8],
    data: &[u8],
    mime: &str,
    filename: &str,
) -> Result<EncryptedMediaUpload> {
    if exporter_secret.len() < 32 {
        return Err(Error::Media(
            "encrypted-media exporter secret too short".into(),
        ));
    }
    let original_hash = sha256(data);
    let nonce = random_nonce()?;
    let key = derive_file_key(
        &exporter_secret[..32],
        DEFAULT_SCHEME_VERSION,
        &original_hash,
        mime,
        filename,
    )?;
    let cipher = ChaCha20Poly1305::new_from_slice(&key)
        .map_err(|e| Error::Media(format!("Failed to create cipher: {e}")))?;
    let label = scheme_label(DEFAULT_SCHEME_VERSION)?;
    let aad = build_aad(label, &original_hash, mime, filename);
    let encrypted_data = cipher
        .encrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: data,
                aad: &aad,
            },
        )
        .map_err(|e| Error::Media(format!("Encryption failed: {e}")))?;
    let encrypted_hash = sha256(&encrypted_data);
    Ok(EncryptedMediaUpload {
        encrypted_size: encrypted_data.len() as u64,
        original_size: data.len() as u64,
        encrypted_data,
        original_hash,
        encrypted_hash,
        mime_type: mime.to_owned(),
        filename: filename.to_owned(),
        dimensions: None,
        blurhash: None,
        thumbhash: None,
        duration_ms: None,
        waveform: None,
        nonce,
    })
}

/// Decrypt ciphertext using a parsed [`MediaReference`] and exporter secret.
pub fn decrypt_from_download(
    exporter_secret: &[u8],
    ciphertext: &[u8],
    reference: &MediaReference,
) -> Result<Vec<u8>> {
    if exporter_secret.len() < 32 {
        return Err(Error::Media(
            "encrypted-media exporter secret too short".into(),
        ));
    }
    let key = derive_file_key(
        &exporter_secret[..32],
        &reference.scheme_version,
        &reference.original_hash,
        &reference.mime_type,
        &reference.filename,
    )?;
    let cipher = ChaCha20Poly1305::new_from_slice(&key)
        .map_err(|e| Error::Media(format!("Failed to create cipher: {e}")))?;
    let label = scheme_label(&reference.scheme_version)?;
    let aad = build_aad(
        label,
        &reference.original_hash,
        &reference.mime_type,
        &reference.filename,
    );
    let plaintext = cipher
        .decrypt(
            Nonce::from_slice(&reference.nonce),
            Payload {
                msg: ciphertext,
                aad: &aad,
            },
        )
        .map_err(|e| Error::Media(format!("Decryption failed: {e}")))?;
    let got = sha256(&plaintext);
    if got != reference.original_hash {
        return Err(Error::Media("hash verification failed".into()));
    }
    Ok(plaintext)
}

/// Build an `imeta` tag matching the previous MDK MIP-04 field set.
pub fn create_imeta_tag(upload: &EncryptedMediaUpload, uploaded_url: &str) -> Tag {
    let mut tag_values = vec![
        format!("url {uploaded_url}"),
        format!("m {}", upload.mime_type),
        format!("filename {}", upload.filename),
    ];
    if let Some((width, height)) = upload.dimensions {
        tag_values.push(format!("dim {width}x{height}"));
    }
    if let Some(ref blurhash) = upload.blurhash {
        tag_values.push(format!("blurhash {blurhash}"));
    }
    if let Some(ref thumbhash) = upload.thumbhash {
        tag_values.push(format!("thumbhash {thumbhash}"));
    }
    if let Some(duration_ms) = upload.duration_ms {
        let secs = duration_ms as f64 / 1000.0;
        tag_values.push(format!("duration {secs}"));
    }
    if let Some(ref waveform) = upload.waveform {
        let joined = waveform
            .iter()
            .map(|s| s.to_string())
            .collect::<Vec<_>>()
            .join(",");
        tag_values.push(format!("waveform {joined}"));
    }
    tag_values.push(format!("x {}", hex::encode(upload.original_hash)));
    tag_values.push(format!("n {}", hex::encode(upload.nonce)));
    tag_values.push(format!("v {DEFAULT_SCHEME_VERSION}"));
    Tag::custom(TagKind::Custom("imeta".into()), tag_values)
}

fn field_map(tag: &Tag) -> std::collections::HashMap<String, String> {
    let mut map = std::collections::HashMap::new();
    for value in tag.as_slice().iter().skip(1) {
        if let Some((key, rest)) = value.split_once(' ') {
            map.insert(key.to_owned(), rest.to_owned());
        }
    }
    map
}

/// Parse an `imeta` tag into a [`MediaReference`].
pub fn parse_imeta_tag(tag: &Tag) -> Result<MediaReference> {
    if tag.kind() != TagKind::Custom("imeta".into()) {
        return Err(Error::Media("not an imeta tag".into()));
    }
    let fields = field_map(tag);
    let url = fields
        .get("url")
        .cloned()
        .ok_or_else(|| Error::Media("imeta missing url".into()))?;
    let mime_type = fields
        .get("m")
        .cloned()
        .ok_or_else(|| Error::Media("imeta missing m".into()))?;
    let filename = fields
        .get("filename")
        .cloned()
        .ok_or_else(|| Error::Media("imeta missing filename".into()))?;
    let original_hash = hex_32(
        fields
            .get("x")
            .ok_or_else(|| Error::Media("imeta missing x".into()))?,
    )?;
    let nonce = hex_12(
        fields
            .get("n")
            .ok_or_else(|| Error::Media("imeta missing n".into()))?,
    )?;
    let scheme_version = fields
        .get("v")
        .cloned()
        .ok_or_else(|| Error::Media("imeta missing v".into()))?;
    let _ = scheme_label(&scheme_version)?;
    let dimensions = fields.get("dim").and_then(|d| {
        let (w, h) = d.split_once('x')?;
        Some((w.parse().ok()?, h.parse().ok()?))
    });
    let duration_ms = fields.get("duration").and_then(|d| {
        d.parse::<f64>()
            .ok()
            .map(|secs| (secs * 1000.0).round() as u64)
    });
    let waveform = fields.get("waveform").map(|w| {
        w.split(',')
            .filter_map(|s| s.parse::<u8>().ok())
            .collect::<Vec<_>>()
    });
    Ok(MediaReference {
        url,
        original_hash,
        mime_type,
        filename,
        dimensions,
        duration_ms,
        waveform,
        scheme_version,
        nonce,
    })
}

fn hex_32(s: &str) -> Result<[u8; 32]> {
    let bytes = hex::decode(s).map_err(|e| Error::Media(format!("imeta x: {e}")))?;
    bytes
        .try_into()
        .map_err(|_| Error::Media("imeta x must be 32 bytes".into()))
}

fn hex_12(s: &str) -> Result<[u8; 12]> {
    let bytes = hex::decode(s).map_err(|e| Error::Media(format!("imeta n: {e}")))?;
    bytes
        .try_into()
        .map_err(|_| Error::Media("imeta n must be 12 bytes".into()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encrypt_decrypt_roundtrip() {
        let secret = [0x11u8; 32];
        let upload =
            encrypt_for_upload(&secret, b"hello media", "image/jpeg", "a.jpg").expect("encrypt");
        assert_eq!(upload.original_size, 11);
        assert!(!upload.encrypted_data.is_empty());
        let tag = create_imeta_tag(&upload, "https://blossom.example/blob");
        let reference = parse_imeta_tag(&tag).expect("parse imeta");
        let plain =
            decrypt_from_download(&secret, &upload.encrypted_data, &reference).expect("decrypt");
        assert_eq!(plain, b"hello media");
        assert_eq!(reference.scheme_version, DEFAULT_SCHEME_VERSION);
        assert_eq!(reference.mime_type, "image/jpeg");
        assert_eq!(reference.filename, "a.jpg");
    }

    #[test]
    fn imeta_roundtrip_preserves_display_fields() {
        let mut upload =
            encrypt_for_upload(&[0x22u8; 32], b"abc", "audio/ogg", "v.ogg").expect("encrypt");
        upload.duration_ms = Some(1500);
        upload.waveform = Some(vec![0, 50, 100]);
        upload.dimensions = Some((320, 240));
        let tag = create_imeta_tag(&upload, "https://example/x");
        let parsed = parse_imeta_tag(&tag).expect("parse");
        assert_eq!(parsed.duration_ms, Some(1500));
        assert_eq!(parsed.waveform, Some(vec![0, 50, 100]));
        assert_eq!(parsed.dimensions, Some((320, 240)));
    }
}
