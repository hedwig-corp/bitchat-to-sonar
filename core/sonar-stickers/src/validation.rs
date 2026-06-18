use crate::error::{Result, StickerError};

pub fn validate_shortcode(value: &str) -> Result<()> {
    if value.is_empty()
        || value.len() > 64
        || !value.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
    {
        return Err(StickerError::InvalidField {
            field: "shortcode",
            reason: "expected 1..64 ASCII alnum/underscore characters".into(),
        });
    }
    Ok(())
}

pub fn validate_sha256_hex(value: &str) -> Result<()> {
    normalize_sha256_hex(value).map(|_| ())
}

pub(crate) fn normalize_sha256_hex(value: &str) -> Result<String> {
    if value.len() != 64 || !value.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err(StickerError::InvalidField {
            field: "sha256",
            reason: "expected 64 hex characters".into(),
        });
    }
    Ok(value.to_ascii_lowercase())
}

pub(crate) fn validate_dim(width: Option<u32>, height: Option<u32>) -> Result<()> {
    match (width, height) {
        (None, None) => Ok(()),
        (Some(w), Some(h)) if (1..=4096).contains(&w) && (1..=4096).contains(&h) => Ok(()),
        (Some(_), Some(_)) => Err(StickerError::InvalidField {
            field: "dim",
            reason: "width and height must be between 1 and 4096".into(),
        }),
        _ => Err(StickerError::InvalidField {
            field: "dim",
            reason: "width and height must be provided together".into(),
        }),
    }
}
