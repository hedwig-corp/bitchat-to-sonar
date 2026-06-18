//! Sonar sticker pack primitives.
//!
//! This crate is deliberately transport-free. It validates the public pack
//! model and converts to/from Nostr events, but it does not upload blobs, fetch
//! relays, or send chat messages.

mod blossom;
mod error;
mod model;
#[cfg(feature = "nostr")]
mod nostr;
mod validation;

#[cfg(feature = "signal-import")]
pub mod signal;
#[cfg(feature = "wasm")]
pub mod wasm;

pub use blossom::{is_allowed_sticker_mime, is_blossom_https_url, sha256_hex};
pub use error::{Result, StickerError};
pub use model::{
    InstalledPackList, PackAddress, Sticker, StickerPack, StickerRef, PACK_FORMAT,
    STICKER_PACK_KIND, USER_STICKER_PACKS_KIND,
};
pub use validation::{validate_sha256_hex, validate_shortcode};

#[cfg(feature = "nostr")]
pub use crate::nostr::{
    build_installed_packs_tags, build_pack_tags, build_sticker_ref_tag, parse_installed_pack_list,
    parse_pack_event, parse_sticker_ref_tag,
};
