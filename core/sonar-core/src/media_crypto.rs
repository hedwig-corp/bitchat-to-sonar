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

use cgka_traits::app_components::{
    BLOSSOM_LOCATOR_KIND_V1, ENCRYPTED_MEDIA_FORMAT_V1, ENCRYPTED_MEDIA_FORMAT_V2,
};

use crate::{Error, Result};

/// Scheme new uploads are sealed with: MDK 0.9's `encrypted-media-v2`, the
/// format White Noise sends, parses and requires in its groups.
pub const DEFAULT_SCHEME_VERSION: &str = ENCRYPTED_MEDIA_FORMAT_V2;
/// The MIP-04 label Sonar sealed with before the MDK 0.9 format, and the
/// label of every row stored before rows kept their scheme version.
pub const LEGACY_SCHEME_VERSION: &str = "mip04-v2";

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
    /// Label the blob was sealed with; picks the imeta layout.
    pub scheme_version: String,
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
        LEGACY_SCHEME_VERSION => Ok(LEGACY_SCHEME_VERSION.as_bytes()),
        ENCRYPTED_MEDIA_FORMAT_V1 => Ok(ENCRYPTED_MEDIA_FORMAT_V1.as_bytes()),
        ENCRYPTED_MEDIA_FORMAT_V2 => Ok(ENCRYPTED_MEDIA_FORMAT_V2.as_bytes()),
        other => Err(Error::Media(format!(
            "unknown encryption scheme version: {other}"
        ))),
    }
}

fn is_http_token_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&byte)
}

/// MDK 0.9's `canonical_media_type_v2`: the type/subtype, lowercased, without
/// parameters. The value feeds the key and the AAD, so sender and receiver
/// must agree on it byte for byte.
fn canonical_media_type_v2(value: &str) -> Result<String> {
    let media_type = value
        .split(';')
        .next()
        .unwrap_or_default()
        .trim_matches(|c| matches!(c, '\u{0009}' | '\u{000a}' | '\u{000c}' | '\u{000d}' | ' '))
        .to_ascii_lowercase();
    let mut segments = media_type.split('/');
    let type_ = segments.next().unwrap_or_default();
    let subtype = segments.next().unwrap_or_default();
    if type_.is_empty()
        || subtype.is_empty()
        || segments.next().is_some()
        || type_.len() > 64
        || subtype.len() > 64
        || media_type.len() > 128
        || !type_.bytes().all(is_http_token_byte)
        || !subtype.bytes().all(is_http_token_byte)
    {
        return Err(Error::Media(format!(
            "media type {value:?} is not a canonical MIME type"
        )));
    }
    Ok(media_type)
}

/// V2 file names are 1..=255 bytes without NUL.
fn v2_file_name(filename: &str) -> String {
    if filename.is_empty() {
        return "file".to_owned();
    }
    let cleaned: String = filename.chars().filter(|c| *c != '\0').collect();
    if cleaned.len() <= 255 {
        return cleaned;
    }
    let mut end = 255;
    while !cleaned.is_char_boundary(end) {
        end -= 1;
    }
    cleaned[..end].to_owned()
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

/// Per-file key: HKDF-Expand of the epoch's media exporter secret.
pub fn derive_file_key(
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
    encrypt_with_scheme(
        exporter_secret,
        data,
        mime,
        filename,
        DEFAULT_SCHEME_VERSION,
    )
}

/// Encrypt under an explicit scheme. Only tests seal with the MIP-04 label,
/// to stand in for blobs an 0.8 install uploaded.
pub fn encrypt_with_scheme(
    exporter_secret: &[u8],
    data: &[u8],
    mime: &str,
    filename: &str,
    scheme_version: &str,
) -> Result<EncryptedMediaUpload> {
    if exporter_secret.len() < 32 {
        return Err(Error::Media(
            "encrypted-media exporter secret too short".into(),
        ));
    }
    let (mime, filename) = if scheme_version == LEGACY_SCHEME_VERSION {
        (mime.to_owned(), filename.to_owned())
    } else {
        (canonical_media_type_v2(mime)?, v2_file_name(filename))
    };
    let (mime, filename) = (&mime, &filename);
    let original_hash = sha256(data);
    let nonce = random_nonce()?;
    let key = derive_file_key(
        &exporter_secret[..32],
        scheme_version,
        &original_hash,
        mime,
        filename,
    )?;
    let cipher = ChaCha20Poly1305::new_from_slice(&key)
        .map_err(|e| Error::Media(format!("Failed to create cipher: {e}")))?;
    let label = scheme_label(scheme_version)?;
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
        scheme_version: scheme_version.to_owned(),
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
    decrypt_with_file_key(&key, ciphertext, reference)
}

/// Decrypt with a per-file key stored when the message was sent or received.
pub fn decrypt_with_file_key(
    key: &[u8; 32],
    ciphertext: &[u8],
    reference: &MediaReference,
) -> Result<Vec<u8>> {
    let cipher = ChaCha20Poly1305::new_from_slice(key)
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

/// Build the `imeta` tag for an upload, in the layout of its scheme.
pub fn create_imeta_tag(upload: &EncryptedMediaUpload, uploaded_url: &str) -> Tag {
    if upload.scheme_version == LEGACY_SCHEME_VERSION {
        return create_legacy_imeta_tag(upload, uploaded_url);
    }
    // MDK 0.9 layout (marmot-app `imeta_tag`). White Noise rejects the whole
    // tag when it carries `blurhash`, so previews ride on `thumbhash` only.
    // `duration`/`waveform` are Sonar voice-note fields other clients skip.
    let mut tag_values = vec![
        format!("v {}", upload.scheme_version),
        format!("locator {BLOSSOM_LOCATOR_KIND_V1} {uploaded_url}"),
        format!("ciphertext_sha256 {}", hex::encode(upload.encrypted_hash)),
        format!("plaintext_sha256 {}", hex::encode(upload.original_hash)),
        format!("nonce {}", hex::encode(upload.nonce)),
        format!("m {}", upload.mime_type),
        format!("filename {}", upload.filename),
    ];
    if let Some((width, height)) = upload.dimensions {
        tag_values.push(format!("dim {width}x{height}"));
    }
    if let Some(ref thumbhash) = upload.thumbhash {
        tag_values.push(format!("thumbhash {thumbhash}"));
    }
    push_voice_fields(upload, &mut tag_values);
    Tag::custom(TagKind::Custom("imeta".into()), tag_values)
}

fn push_voice_fields(upload: &EncryptedMediaUpload, tag_values: &mut Vec<String>) {
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
}

/// The MIP-04 `mip04-v2` field set, for uploads sealed before the MDK 0.9
/// format (a staged upload resumed after an update).
fn create_legacy_imeta_tag(upload: &EncryptedMediaUpload, uploaded_url: &str) -> Tag {
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
    push_voice_fields(upload, &mut tag_values);
    tag_values.push(format!("x {}", hex::encode(upload.original_hash)));
    tag_values.push(format!("n {}", hex::encode(upload.nonce)));
    tag_values.push(format!("v {LEGACY_SCHEME_VERSION}"));
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

/// Parse an `imeta` tag into a [`MediaReference`]: the MDK 0.9 layout that
/// White Noise and current Sonar send, or the MIP-04 `mip04-v2` layout.
pub fn parse_imeta_tag(tag: &Tag) -> Result<MediaReference> {
    if tag.kind() != TagKind::Custom("imeta".into()) {
        return Err(Error::Media("not an imeta tag".into()));
    }
    let fields = field_map(tag);
    if fields.contains_key("plaintext_sha256") || fields.contains_key("locator") {
        return parse_encrypted_media_tag(tag, &fields);
    }
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

/// MDK 0.9 `imeta` (`encrypted-media-v1`/`-v2`). The first `blossom-v1`
/// locator is the fetch URL; other locator kinds are not fetchable here.
fn parse_encrypted_media_tag(
    tag: &Tag,
    fields: &std::collections::HashMap<String, String>,
) -> Result<MediaReference> {
    for field in tag.as_slice().iter().skip(1) {
        if field == "blurhash" || field.starts_with("blurhash ") {
            return Err(Error::Media(
                "encrypted media uses thumbhash, not blurhash".into(),
            ));
        }
    }
    let url = tag
        .as_slice()
        .iter()
        .skip(1)
        .filter_map(|field| field.strip_prefix("locator "))
        .filter_map(|rest| rest.split_once(' '))
        .find(|(kind, _)| *kind == BLOSSOM_LOCATOR_KIND_V1)
        .map(|(_, value)| value.to_owned())
        .ok_or_else(|| Error::Media("imeta has no blossom-v1 locator".into()))?;
    let required = |name: &str| {
        fields
            .get(name)
            .filter(|value| !value.is_empty())
            .cloned()
            .ok_or_else(|| Error::Media(format!("imeta missing {name}")))
    };
    let scheme_version = required("v")?;
    let _ = scheme_label(&scheme_version)?;
    let original_hash = hex_32(&required("plaintext_sha256")?)?;
    let _ = hex_32(&required("ciphertext_sha256")?)?;
    let nonce = hex_12(&required("nonce")?)?;
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
        mime_type: required("m")?,
        filename: required("filename")?,
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

    fn fields(tag: &Tag) -> Vec<String> {
        tag.as_slice()[1..].to_vec()
    }

    /// New uploads use MDK 0.9's `encrypted-media-v2` layout, the one White
    /// Noise parses (marmot-app `media_attachment_from_imeta_tag`): locator,
    /// both hashes, `nonce`, and never `blurhash`, which makes White Noise
    /// reject the whole tag.
    #[test]
    fn new_uploads_use_the_layout_white_noise_parses() {
        let mut upload = encrypt_for_upload(&[0x33u8; 32], b"pixels", " Image/PNG; q=1", "p.png")
            .expect("encrypt");
        upload.blurhash = Some("LEHV6nWB2yk8".into());
        upload.thumbhash = Some("1QcSHQRnh493V4dIh4eXh1h4kJUI".into());
        let url = "https://blossom.example/blob";
        let tag = create_imeta_tag(&upload, url);
        let fields = fields(&tag);
        assert_eq!(fields[0], "v encrypted-media-v2");
        assert!(fields.contains(&format!("locator blossom-v1 {url}")));
        assert!(fields.contains(&format!(
            "ciphertext_sha256 {}",
            hex::encode(sha256(&upload.encrypted_data))
        )));
        assert!(fields.contains(&format!(
            "plaintext_sha256 {}",
            hex::encode(sha256(b"pixels"))
        )));
        assert!(fields.contains(&"m image/png".to_owned()), "canonical type");
        assert!(fields.iter().any(|f| f.starts_with("thumbhash ")));
        for legacy in ["blurhash", "url ", "x ", "n "] {
            assert!(
                !fields.iter().any(|f| f.starts_with(legacy)),
                "{legacy} must not appear in a v2 tag"
            );
        }
        let parsed = parse_imeta_tag(&tag).expect("parse");
        assert_eq!(parsed.url, url);
        assert_eq!(
            decrypt_from_download(&[0x33u8; 32], &upload.encrypted_data, &parsed).unwrap(),
            b"pixels"
        );
    }

    /// A tag in White Noise's field order (as `imeta_tag` emits it) parses:
    /// the fetch URL is the `blossom-v1` locator.
    #[test]
    fn a_white_noise_tag_parses() {
        let secret = [0x44u8; 32];
        let upload = encrypt_for_upload(&secret, b"from wn", "image/png", "wn.png").unwrap();
        let url = "https://cdn.divine.video/3b788da3102d97b0a86b42fb96f6a7f5.bin";
        let tag = Tag::custom(
            TagKind::Custom("imeta".into()),
            [
                "v encrypted-media-v2".to_owned(),
                "locator blossom-v2 https://elsewhere.example/x".to_owned(),
                format!("locator blossom-v1 {url}"),
                format!("ciphertext_sha256 {}", hex::encode(upload.encrypted_hash)),
                format!("plaintext_sha256 {}", hex::encode(upload.original_hash)),
                format!("nonce {}", hex::encode(upload.nonce)),
                "m image/png".to_owned(),
                "filename wn.png".to_owned(),
                "dim 20x20".to_owned(),
                "thumbhash 1QcSHQRnh493V4dIh4eXh1h4kJUI".to_owned(),
            ],
        );
        let parsed = parse_imeta_tag(&tag).expect("parse a White Noise tag");
        assert_eq!(parsed.url, url);
        assert_eq!(parsed.dimensions, Some((20, 20)));
        assert_eq!(parsed.scheme_version, ENCRYPTED_MEDIA_FORMAT_V2);
        assert_eq!(
            decrypt_from_download(&secret, &upload.encrypted_data, &parsed).unwrap(),
            b"from wn"
        );
    }

    /// Blobs an 0.8 install sealed, and uploads staged before the MDK 0.9
    /// format, keep the MIP-04 layout and still open.
    #[test]
    fn mip04_uploads_keep_their_layout_and_open() {
        let secret = [0x55u8; 32];
        let upload = encrypt_with_scheme(
            &secret,
            b"old",
            "image/jpeg",
            "old.jpg",
            LEGACY_SCHEME_VERSION,
        )
        .unwrap();
        let tag = create_imeta_tag(&upload, "https://blossom.example/old");
        let fields = fields(&tag);
        assert!(fields.contains(&"v mip04-v2".to_owned()));
        assert!(fields.contains(&"url https://blossom.example/old".to_owned()));
        let parsed = parse_imeta_tag(&tag).expect("parse legacy");
        assert_eq!(parsed.scheme_version, LEGACY_SCHEME_VERSION);
        assert_eq!(
            decrypt_from_download(&secret, &upload.encrypted_data, &parsed).unwrap(),
            b"old"
        );
    }
}
