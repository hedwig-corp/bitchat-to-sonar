use thiserror::Error;

pub type Result<T> = std::result::Result<T, StickerError>;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum StickerError {
    #[error("missing required tag: {0}")]
    MissingTag(&'static str),
    #[error("invalid field `{field}`: {reason}")]
    InvalidField { field: &'static str, reason: String },
    #[error("duplicate sticker shortcode: {0}")]
    DuplicateShortcode(String),
    #[error("duplicate sticker hash: {0}")]
    DuplicateHash(String),
    #[error("sticker pack must contain at least one sticker")]
    EmptyPack,
    #[error("sticker pack has too many stickers: {count} > {max}")]
    TooManyStickers { count: usize, max: usize },
    #[error("event is not a Sonar sticker pack")]
    NotStickerPack,
    #[error("signal import: {0}")]
    Signal(String),
    #[error("http: {0}")]
    Http(String),
    #[error("crypto: {0}")]
    Crypto(String),
    #[error("protobuf: {0}")]
    Proto(String),
}
