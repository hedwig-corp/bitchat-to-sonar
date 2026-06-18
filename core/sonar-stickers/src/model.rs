use std::collections::HashSet;
use std::fmt;

use serde::{Deserialize, Serialize};

use crate::error::{Result, StickerError};
use crate::validation::{normalize_sha256_hex, validate_dim, validate_shortcode};
use crate::{is_allowed_sticker_mime, is_blossom_https_url};

pub const PACK_FORMAT: &str = "sonar-sticker-pack-v1";
pub const STICKER_PACK_KIND: u16 = 30030;
pub const USER_STICKER_PACKS_KIND: u16 = 10030;
pub const MAX_STICKERS_PER_PACK: usize = 200;
pub const MAX_TITLE_CHARS: usize = 80;
pub const MAX_DESCRIPTION_CHARS: usize = 500;
pub const MAX_ALT_CHARS: usize = 160;

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct PackAddress {
    pub author_pubkey_hex: String,
    pub identifier: String,
}

impl PackAddress {
    pub fn new(
        author_pubkey_hex: impl Into<String>,
        identifier: impl Into<String>,
    ) -> Result<Self> {
        let author_pubkey_hex = author_pubkey_hex.into().to_ascii_lowercase();
        if author_pubkey_hex.len() != 64
            || !author_pubkey_hex.chars().all(|c| c.is_ascii_hexdigit())
        {
            return Err(StickerError::InvalidField {
                field: "author_pubkey_hex",
                reason: "expected 64 lowercase hex characters".into(),
            });
        }
        let identifier = identifier.into();
        if !is_valid_identifier(&identifier) {
            return Err(StickerError::InvalidField {
                field: "identifier",
                reason: "expected 1..80 chars of ASCII alnum, dot, underscore, or dash".into(),
            });
        }
        Ok(Self {
            author_pubkey_hex,
            identifier,
        })
    }

    pub fn parse(value: &str) -> Result<Self> {
        let mut parts = value.splitn(3, ':');
        let kind = parts.next();
        let pubkey = parts.next();
        let identifier = parts.next();
        if kind != Some("30030") || pubkey.is_none() || identifier.is_none() {
            return Err(StickerError::InvalidField {
                field: "pack_address",
                reason: "expected 30030:<author-pubkey>:<identifier>".into(),
            });
        }
        Self::new(pubkey.unwrap_or_default(), identifier.unwrap_or_default())
    }

    pub fn coordinate(&self) -> String {
        format!("30030:{}:{}", self.author_pubkey_hex, self.identifier)
    }
}

impl fmt::Display for PackAddress {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.coordinate())
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Sticker {
    pub shortcode: String,
    pub url: String,
    pub sha256: String,
    pub mime: String,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub alt: Option<String>,
    pub emoji: Option<String>,
}

impl Sticker {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        shortcode: impl Into<String>,
        url: impl Into<String>,
        sha256: impl Into<String>,
        mime: impl Into<String>,
        width: Option<u32>,
        height: Option<u32>,
        alt: Option<String>,
        emoji: Option<String>,
    ) -> Result<Self> {
        let sticker = Self {
            shortcode: shortcode.into(),
            url: url.into(),
            sha256: sha256.into(),
            mime: mime.into(),
            width,
            height,
            alt,
            emoji,
        };
        sticker.validate()?;
        Ok(sticker.normalized())
    }

    pub fn dim(&self) -> Option<String> {
        match (self.width, self.height) {
            (Some(w), Some(h)) => Some(format!("{w}x{h}")),
            _ => None,
        }
    }

    pub fn validate(&self) -> Result<()> {
        validate_shortcode(&self.shortcode)?;
        normalize_sha256_hex(&self.sha256)?;
        if !is_allowed_sticker_mime(&self.mime) {
            return Err(StickerError::InvalidField {
                field: "mime",
                reason: "expected image/webp, image/png, image/apng, or image/gif".into(),
            });
        }
        if !is_blossom_https_url(&self.url, &self.sha256) {
            return Err(StickerError::InvalidField {
                field: "url",
                reason: "expected an https Blossom-style URL containing the sticker sha256".into(),
            });
        }
        validate_dim(self.width, self.height)?;
        if self
            .alt
            .as_ref()
            .is_some_and(|alt| alt.chars().count() > MAX_ALT_CHARS)
        {
            return Err(StickerError::InvalidField {
                field: "alt",
                reason: format!("must be at most {MAX_ALT_CHARS} characters"),
            });
        }
        if self
            .emoji
            .as_ref()
            .is_some_and(|emoji| emoji.chars().count() > 8)
        {
            return Err(StickerError::InvalidField {
                field: "emoji",
                reason: "must be a short representative emoji string".into(),
            });
        }
        Ok(())
    }

    fn normalized(&self) -> Self {
        Self {
            shortcode: self.shortcode.clone(),
            url: self.url.clone(),
            sha256: self.sha256.to_ascii_lowercase(),
            mime: self.mime.to_ascii_lowercase(),
            width: self.width,
            height: self.height,
            alt: self.alt.clone().filter(|s| !s.trim().is_empty()),
            emoji: self.emoji.clone().filter(|s| !s.trim().is_empty()),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct StickerPack {
    pub address: PackAddress,
    pub title: String,
    pub description: Option<String>,
    pub cover: Option<Sticker>,
    pub stickers: Vec<Sticker>,
    pub license: Option<String>,
}

impl StickerPack {
    pub fn new(
        address: PackAddress,
        title: impl Into<String>,
        description: Option<String>,
        cover: Option<Sticker>,
        stickers: Vec<Sticker>,
        license: Option<String>,
    ) -> Result<Self> {
        let pack = Self {
            address,
            title: title.into(),
            description,
            cover,
            stickers,
            license,
        };
        pack.validate()?;
        Ok(pack.normalized())
    }

    pub fn validate(&self) -> Result<()> {
        if self.title.trim().is_empty() || self.title.chars().count() > MAX_TITLE_CHARS {
            return Err(StickerError::InvalidField {
                field: "title",
                reason: format!("must be 1..{MAX_TITLE_CHARS} characters"),
            });
        }
        if self
            .description
            .as_ref()
            .is_some_and(|description| description.chars().count() > MAX_DESCRIPTION_CHARS)
        {
            return Err(StickerError::InvalidField {
                field: "description",
                reason: format!("must be at most {MAX_DESCRIPTION_CHARS} characters"),
            });
        }
        if self.stickers.is_empty() {
            return Err(StickerError::EmptyPack);
        }
        if self.stickers.len() > MAX_STICKERS_PER_PACK {
            return Err(StickerError::TooManyStickers {
                count: self.stickers.len(),
                max: MAX_STICKERS_PER_PACK,
            });
        }
        let mut shortcodes = HashSet::new();
        let mut hashes = HashSet::new();
        for sticker in &self.stickers {
            sticker.validate()?;
            if !shortcodes.insert(sticker.shortcode.clone()) {
                return Err(StickerError::DuplicateShortcode(sticker.shortcode.clone()));
            }
            if !hashes.insert(sticker.sha256.to_ascii_lowercase()) {
                return Err(StickerError::DuplicateHash(sticker.sha256.clone()));
            }
        }
        if let Some(cover) = &self.cover {
            cover.validate()?;
        }
        Ok(())
    }

    pub fn sticker(&self, shortcode: &str) -> Option<&Sticker> {
        self.stickers
            .iter()
            .find(|sticker| sticker.shortcode == shortcode)
    }

    fn normalized(&self) -> Self {
        Self {
            address: self.address.clone(),
            title: self.title.trim().to_string(),
            description: self
                .description
                .as_ref()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty()),
            cover: self.cover.clone(),
            stickers: self.stickers.iter().map(Sticker::normalized).collect(),
            license: self
                .license
                .as_ref()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty()),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct StickerRef {
    pub pack: PackAddress,
    pub shortcode: String,
    pub plaintext_sha256: String,
}

impl StickerRef {
    pub fn new(
        pack: PackAddress,
        shortcode: impl Into<String>,
        plaintext_sha256: impl Into<String>,
    ) -> Result<Self> {
        let shortcode = shortcode.into();
        validate_shortcode(&shortcode)?;
        Ok(Self {
            pack,
            shortcode,
            plaintext_sha256: normalize_sha256_hex(&plaintext_sha256.into())?,
        })
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct InstalledPackList {
    pub packs: Vec<PackAddress>,
}

impl InstalledPackList {
    pub fn new(packs: Vec<PackAddress>) -> Self {
        let mut out = Vec::new();
        let mut seen = HashSet::new();
        for pack in packs {
            if seen.insert(pack.coordinate()) {
                out.push(pack);
            }
        }
        Self { packs: out }
    }
}

fn is_valid_identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 80
        && value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
}
