//! Optional Signal sticker-pack import support.
//!
//! Signal's sticker creator derives an AES-CBC key and HMAC-SHA256 key from the
//! 32-byte pack key with HKDF-SHA256, zero salt, and info `Sticker Pack`. Each
//! downloaded attachment is `iv || ciphertext || mac`, where the MAC covers the
//! first two fields. The manifest is a protobuf containing title, author, cover,
//! and sticker `(id, emoji)` rows.

use std::collections::{BTreeMap, BTreeSet};

use aes::Aes256;
use base64::engine::general_purpose::{STANDARD as B64_STANDARD, URL_SAFE, URL_SAFE_NO_PAD};
use base64::Engine;
use cbc::cipher::{block_padding::Pkcs7, BlockDecryptMut, KeyIvInit};
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use prost::Message;
use sha2::Sha256;
use url::Url;

use crate::{sha256_hex, Result, StickerError};

const SIGNAL_PACK_ID_BYTES: usize = 16;
const SIGNAL_PACK_KEY_BYTES: usize = 32;
const HKDF_SALT: [u8; 32] = [0; 32];
const HKDF_INFO: &[u8] = b"Sticker Pack";
const AES_KEY_BYTES: usize = 32;
const MAC_KEY_BYTES: usize = 32;
const IV_BYTES: usize = 16;
const MAC_BYTES: usize = 32;
const MAX_MANIFEST_BYTES: usize = 512 * 1024;
const MAX_STICKER_BYTES: usize = 4 * 1024 * 1024;
const MAX_SIGNAL_STICKERS: usize = 200;

type Aes256CbcDec = cbc::Decryptor<Aes256>;
type HmacSha256 = Hmac<Sha256>;

/// Parsed `signal.art/addstickers` link material.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SignalPackLink {
    pub pack_id: String,
    /// Hex form retained locally only. Do not publish this in Nostr pack events.
    pub pack_key_hex: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ImportedSignalPack {
    pub pack_id: String,
    pub title: String,
    pub author: Option<String>,
    pub cover: Option<ImportedSignalSticker>,
    pub stickers: Vec<ImportedSignalSticker>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ImportedSignalSticker {
    pub id: u32,
    pub shortcode: String,
    pub emoji: Option<String>,
    pub mime: String,
    pub bytes: Vec<u8>,
    pub sha256: String,
}

#[derive(Clone, PartialEq, Message)]
struct SignalStickerPackProto {
    #[prost(string, optional, tag = "1")]
    title: Option<String>,
    #[prost(string, optional, tag = "2")]
    author: Option<String>,
    #[prost(message, optional, tag = "3")]
    cover: Option<SignalStickerProto>,
    #[prost(message, repeated, tag = "4")]
    stickers: Vec<SignalStickerProto>,
}

#[derive(Clone, PartialEq, Message)]
struct SignalStickerProto {
    #[prost(uint32, optional, tag = "1")]
    id: Option<u32>,
    #[prost(string, optional, tag = "2")]
    emoji: Option<String>,
}

impl SignalPackLink {
    pub fn parse(input: &str) -> Result<Self> {
        let url = Url::parse(input).map_err(|e| StickerError::Signal(format!("bad link: {e}")))?;
        let params = url.fragment().or_else(|| url.query()).ok_or_else(|| {
            StickerError::Signal("expected pack_id and pack_key in URL fragment or query".into())
        })?;
        let mut pack_id = None;
        let mut pack_key = None;
        for (key, value) in url::form_urlencoded::parse(params.as_bytes()) {
            match key.as_ref() {
                "pack_id" => pack_id = Some(value.into_owned()),
                "pack_key" => pack_key = Some(value.into_owned()),
                _ => {}
            }
        }
        let pack_id = normalize_pack_id(&pack_id.ok_or_else(|| {
            StickerError::Signal("missing pack_id in Signal sticker link".into())
        })?)?;
        let pack_key_hex = normalize_pack_key(&pack_key.ok_or_else(|| {
            StickerError::Signal("missing pack_key in Signal sticker link".into())
        })?)?;
        Ok(Self {
            pack_id,
            pack_key_hex,
        })
    }

    fn pack_key_bytes(&self) -> Result<[u8; SIGNAL_PACK_KEY_BYTES]> {
        let bytes = hex::decode(&self.pack_key_hex)
            .map_err(|e| StickerError::Signal(format!("pack_key must decode as 32 bytes: {e}")))?;
        bytes
            .try_into()
            .map_err(|_| StickerError::Signal("pack_key must decode as exactly 32 bytes".into()))
    }
}

pub async fn import_signal_pack(link: &str) -> Result<ImportedSignalPack> {
    let link = SignalPackLink::parse(link)?;
    let keys = derive_keys(&link.pack_key_bytes()?)?;
    let manifest_url = signal_manifest_url(&link.pack_id);
    let manifest_ciphertext = fetch_limited(&manifest_url, MAX_MANIFEST_BYTES).await?;
    let manifest_plaintext = decrypt_attachment(&manifest_ciphertext, &keys)?;
    let manifest = SignalStickerPackProto::decode(manifest_plaintext.as_slice())
        .map_err(|e| StickerError::Proto(format!("decode Signal sticker manifest: {e}")))?;
    let title = manifest
        .title
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or("Signal Sticker Pack")
        .to_owned();
    if manifest.stickers.is_empty() {
        return Err(StickerError::Signal("Signal pack has no stickers".into()));
    }
    if manifest.stickers.len() > MAX_SIGNAL_STICKERS {
        return Err(StickerError::Signal(format!(
            "Signal pack has too many stickers: {} > {MAX_SIGNAL_STICKERS}",
            manifest.stickers.len()
        )));
    }

    let mut emojis_by_id = BTreeMap::new();
    let mut ids = BTreeSet::new();
    for sticker in &manifest.stickers {
        let id = sticker
            .id
            .ok_or_else(|| StickerError::Signal("sticker missing id".into()))?;
        ids.insert(id);
        emojis_by_id.insert(id, normalize_optional_string(sticker.emoji.as_deref()));
    }
    if let Some(cover) = &manifest.cover {
        if let Some(id) = cover.id {
            ids.insert(id);
            emojis_by_id
                .entry(id)
                .or_insert_with(|| normalize_optional_string(cover.emoji.as_deref()));
        }
    }

    let mut assets = BTreeMap::new();
    for id in ids {
        let url = signal_sticker_url(&link.pack_id, id);
        let ciphertext = fetch_limited(&url, MAX_STICKER_BYTES).await?;
        let bytes = decrypt_attachment(&ciphertext, &keys)?;
        let mime = detect_sticker_mime(&bytes);
        let emoji = emojis_by_id.get(&id).cloned().flatten();
        assets.insert(id, imported_sticker(id, emoji, mime, bytes)?);
    }

    let mut stickers = Vec::with_capacity(manifest.stickers.len());
    for sticker in &manifest.stickers {
        let id = sticker
            .id
            .ok_or_else(|| StickerError::Signal("sticker missing id".into()))?;
        stickers.push(
            assets
                .get(&id)
                .cloned()
                .ok_or_else(|| StickerError::Signal(format!("missing sticker asset {id}")))?,
        );
    }
    let cover = manifest
        .cover
        .and_then(|cover| cover.id)
        .and_then(|id| assets.get(&id).cloned());

    Ok(ImportedSignalPack {
        pack_id: link.pack_id,
        title,
        author: normalize_optional_string(manifest.author.as_deref()),
        cover,
        stickers,
    })
}

fn imported_sticker(
    id: u32,
    emoji: Option<String>,
    mime: String,
    bytes: Vec<u8>,
) -> Result<ImportedSignalSticker> {
    Ok(ImportedSignalSticker {
        id,
        shortcode: format!("s{id}"),
        emoji,
        mime,
        sha256: sha256_hex(&bytes),
        bytes,
    })
}

fn normalize_pack_id(value: &str) -> Result<String> {
    let trimmed = value.trim();
    if trimmed.len() != SIGNAL_PACK_ID_BYTES * 2 || !trimmed.chars().all(|c| c.is_ascii_hexdigit())
    {
        return Err(StickerError::Signal(
            "pack_id must be 32 hex characters".into(),
        ));
    }
    Ok(trimmed.to_ascii_lowercase())
}

fn normalize_pack_key(value: &str) -> Result<String> {
    let trimmed = value.trim();
    if trimmed.len() == SIGNAL_PACK_KEY_BYTES * 2 && trimmed.chars().all(|c| c.is_ascii_hexdigit())
    {
        return Ok(trimmed.to_ascii_lowercase());
    }
    let decoded = B64_STANDARD
        .decode(trimmed)
        .or_else(|_| URL_SAFE.decode(trimmed))
        .or_else(|_| URL_SAFE_NO_PAD.decode(trimmed))
        .map_err(|e| StickerError::Signal(format!("pack_key is neither hex nor base64: {e}")))?;
    if decoded.len() != SIGNAL_PACK_KEY_BYTES {
        return Err(StickerError::Signal(format!(
            "pack_key must decode as {SIGNAL_PACK_KEY_BYTES} bytes"
        )));
    }
    Ok(hex::encode(decoded))
}

fn derive_keys(
    secret: &[u8; SIGNAL_PACK_KEY_BYTES],
) -> Result<([u8; AES_KEY_BYTES], [u8; MAC_KEY_BYTES])> {
    let hk = Hkdf::<Sha256>::new(Some(&HKDF_SALT), secret);
    let mut okm = [0u8; AES_KEY_BYTES + MAC_KEY_BYTES];
    hk.expand(HKDF_INFO, &mut okm)
        .map_err(|e| StickerError::Crypto(format!("derive Signal sticker keys: {e}")))?;
    let aes = okm[..AES_KEY_BYTES]
        .try_into()
        .expect("slice length is AES_KEY_BYTES");
    let mac = okm[AES_KEY_BYTES..]
        .try_into()
        .expect("slice length is MAC_KEY_BYTES");
    Ok((aes, mac))
}

fn decrypt_attachment(
    encrypted: &[u8],
    (aes_key, mac_key): &([u8; AES_KEY_BYTES], [u8; MAC_KEY_BYTES]),
) -> Result<Vec<u8>> {
    if encrypted.len() <= IV_BYTES + MAC_BYTES {
        return Err(StickerError::Crypto(
            "encrypted Signal sticker blob is too short".into(),
        ));
    }
    let (iv_and_ciphertext, provided_mac) = encrypted.split_at(encrypted.len() - MAC_BYTES);
    let (iv, ciphertext) = iv_and_ciphertext.split_at(IV_BYTES);
    let mut mac = HmacSha256::new_from_slice(mac_key)
        .map_err(|e| StickerError::Crypto(format!("HMAC init failed: {e}")))?;
    mac.update(iv_and_ciphertext);
    mac.verify_slice(provided_mac)
        .map_err(|_| StickerError::Crypto("Signal sticker HMAC verification failed".into()))?;
    let mut buf = ciphertext.to_vec();
    Aes256CbcDec::new_from_slices(aes_key, iv)
        .map_err(|e| StickerError::Crypto(format!("AES-CBC init failed: {e}")))?
        .decrypt_padded_mut::<Pkcs7>(&mut buf)
        .map(|plaintext| plaintext.to_vec())
        .map_err(|e| StickerError::Crypto(format!("AES-CBC decrypt failed: {e}")))
}

async fn fetch_limited(url: &str, max_bytes: usize) -> Result<Vec<u8>> {
    let client = reqwest::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(10))
        .timeout(std::time::Duration::from_secs(60))
        .build()
        .map_err(|e| StickerError::Http(e.to_string()))?;
    let resp = client
        .get(url)
        .send()
        .await
        .map_err(|e| StickerError::Http(format!("GET {url}: {e}")))?;
    if !resp.status().is_success() {
        return Err(StickerError::Http(format!(
            "GET {url}: HTTP {}",
            resp.status()
        )));
    }
    if let Some(len) = resp.content_length() {
        if len as usize > max_bytes {
            return Err(StickerError::Http(format!(
                "GET {url}: response too large ({len} bytes > {max_bytes})"
            )));
        }
    }
    let mut bytes = Vec::new();
    let mut resp = resp;
    while let Some(chunk) = resp
        .chunk()
        .await
        .map_err(|e| StickerError::Http(format!("read {url}: {e}")))?
    {
        if bytes.len() + chunk.len() > max_bytes {
            return Err(StickerError::Http(format!(
                "GET {url}: response too large (> {max_bytes} bytes)"
            )));
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(bytes)
}

fn signal_manifest_url(pack_id: &str) -> String {
    format!("https://cdn.signal.org/stickers/{pack_id}/manifest.proto")
}

fn signal_sticker_url(pack_id: &str, id: u32) -> String {
    format!("https://cdn.signal.org/stickers/{pack_id}/full/{id}")
}

fn detect_sticker_mime(bytes: &[u8]) -> String {
    if bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP") {
        "image/webp"
    } else if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        "image/png"
    } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        "image/gif"
    } else {
        "image/webp"
    }
    .to_owned()
}

fn normalize_optional_string(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(ToOwned::to_owned)
}

#[cfg(test)]
mod tests {
    use super::*;
    use cbc::cipher::{BlockEncryptMut, KeyIvInit};

    type Aes256CbcEnc = cbc::Encryptor<Aes256>;

    #[test]
    fn parses_signal_fragment_link_with_hex_key() {
        let link = SignalPackLink::parse(
            "https://signal.art/addstickers/#pack_id=ABCDEFabcdef1234567890abcdef1234&pack_key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        )
        .unwrap();
        assert_eq!(link.pack_id, "abcdefabcdef1234567890abcdef1234");
        assert_eq!(
            link.pack_key_hex,
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        );
    }

    #[test]
    fn parses_signal_fragment_link_with_base64_key() {
        let link = SignalPackLink::parse(
            "https://signal.art/addstickers/#pack_id=abcdefabcdef1234567890abcdef1234&pack_key=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        )
        .unwrap();
        assert_eq!(
            link.pack_key_hex,
            "0000000000000000000000000000000000000000000000000000000000000000"
        );
    }

    #[test]
    fn decrypt_rejects_tampered_mac() {
        let secret = [7u8; SIGNAL_PACK_KEY_BYTES];
        let keys = derive_keys(&secret).unwrap();
        let mut encrypted = encrypt_for_test(b"manifest", &keys);
        *encrypted.last_mut().unwrap() ^= 1;

        let err = decrypt_attachment(&encrypted, &keys).unwrap_err();
        assert!(err.to_string().contains("HMAC"));
    }

    #[test]
    fn decrypt_round_trips_test_attachment() {
        let secret = [3u8; SIGNAL_PACK_KEY_BYTES];
        let keys = derive_keys(&secret).unwrap();
        let encrypted = encrypt_for_test(b"hello sticker", &keys);

        assert_eq!(
            decrypt_attachment(&encrypted, &keys).unwrap(),
            b"hello sticker"
        );
    }

    fn encrypt_for_test(
        plaintext: &[u8],
        (aes_key, mac_key): &([u8; AES_KEY_BYTES], [u8; MAC_KEY_BYTES]),
    ) -> Vec<u8> {
        let iv = [9u8; IV_BYTES];
        let mut buf = plaintext.to_vec();
        let plaintext_len = buf.len();
        buf.resize(plaintext_len + IV_BYTES, 0);
        let ciphertext = Aes256CbcEnc::new_from_slices(aes_key, &iv)
            .unwrap()
            .encrypt_padded_mut::<Pkcs7>(&mut buf, plaintext_len)
            .unwrap()
            .to_vec();
        let mut out = Vec::with_capacity(IV_BYTES + ciphertext.len() + MAC_BYTES);
        out.extend_from_slice(&iv);
        out.extend_from_slice(&ciphertext);
        let mut mac = HmacSha256::new_from_slice(mac_key).unwrap();
        mac.update(&out);
        out.extend_from_slice(&mac.finalize().into_bytes());
        out
    }
}
