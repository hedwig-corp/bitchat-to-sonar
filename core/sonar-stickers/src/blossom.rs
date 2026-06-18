use sha2::{Digest, Sha256};
use url::Url;

pub fn is_allowed_sticker_mime(value: &str) -> bool {
    matches!(
        value.to_ascii_lowercase().as_str(),
        "image/webp" | "image/png" | "image/apng" | "image/gif"
    )
}

pub fn is_blossom_https_url(url: &str, sha256: &str) -> bool {
    let Ok(parsed) = Url::parse(url) else {
        return false;
    };
    if parsed.scheme() != "https" || parsed.host_str().is_none() {
        return false;
    }
    parsed
        .path()
        .to_ascii_lowercase()
        .contains(&sha256.to_ascii_lowercase())
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}
