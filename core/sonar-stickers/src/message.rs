use crate::{PackAddress, Result, StickerError, StickerRef};

pub const STICKER_MESSAGE_MARKER: &str = "[sonar-sticker-v1]";
const STICKER_FALLBACK_PREFIX: &str = "[sticker]";
const PACK_FIELD: &str = "pack=";
const SHORTCODE_FIELD: &str = "shortcode=";
const SHA256_FIELD: &str = "sha256=";

/// Build the encrypted chat content for a sticker message.
///
/// The leading `[sticker]` gives older clients a harmless readable fallback.
/// New clients parse the strict `sonar-sticker-v1` fields and resolve only by
/// pack address + shortcode + immutable plaintext SHA-256.
pub fn build_sticker_message(sticker_ref: &StickerRef) -> String {
    format!(
        "{STICKER_FALLBACK_PREFIX} {STICKER_MESSAGE_MARKER} {PACK_FIELD}{} {SHORTCODE_FIELD}{} {SHA256_FIELD}{}",
        sticker_ref.pack.coordinate(),
        sticker_ref.shortcode,
        sticker_ref.plaintext_sha256
    )
}

/// Parse encrypted chat content into a sticker reference.
///
/// Returns `Ok(None)` for ordinary text. Returns an error only when the sticker
/// marker is present but the payload is malformed.
pub fn parse_sticker_message(content: &str) -> Result<Option<StickerRef>> {
    let trimmed = content.trim();
    let Some(payload) = trimmed.strip_prefix(STICKER_FALLBACK_PREFIX) else {
        return Ok(None);
    };
    let payload = payload.trim_start();
    let Some(payload) = payload.strip_prefix(STICKER_MESSAGE_MARKER) else {
        return Ok(None);
    };
    let fields = payload.split_whitespace().collect::<Vec<_>>();
    if fields.len() != 3 {
        return Err(invalid_message(
            "expected pack, shortcode, and sha256 fields",
        ));
    }

    let pack = strip_field(fields[0], PACK_FIELD)?;
    let shortcode = strip_field(fields[1], SHORTCODE_FIELD)?;
    let sha256 = strip_field(fields[2], SHA256_FIELD)?;
    Ok(Some(StickerRef::new(
        PackAddress::parse(pack)?,
        shortcode,
        sha256,
    )?))
}

fn strip_field<'a>(field: &'a str, prefix: &str) -> Result<&'a str> {
    field
        .strip_prefix(prefix)
        .ok_or_else(|| invalid_message(format!("expected {prefix}<value>")))
}

fn invalid_message(reason: impl Into<String>) -> StickerError {
    StickerError::InvalidField {
        field: "sticker_message",
        reason: reason.into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PUBKEY: &str = "6a04ab98d9e4774ad806e302dddeb63bea16b5cb5f223ee77478e861bb583eb3";
    const HASH: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    fn sticker_ref() -> StickerRef {
        StickerRef::new(
            PackAddress::new(PUBKEY, "signal-0123456789abcdef0123456789abcdef").unwrap(),
            "cat_wave",
            HASH,
        )
        .unwrap()
    }

    #[test]
    fn sticker_message_round_trips() {
        let sticker_ref = sticker_ref();
        let content = build_sticker_message(&sticker_ref);

        assert_eq!(parse_sticker_message(&content).unwrap(), Some(sticker_ref));
        assert!(content.starts_with("[sticker] [sonar-sticker-v1] "));
    }

    #[test]
    fn ordinary_text_is_not_a_sticker_message() {
        assert_eq!(
            parse_sticker_message("hello [sonar-sticker-v1]").unwrap(),
            None
        );
        assert_eq!(parse_sticker_message("[sticker] cat_wave").unwrap(), None);
    }

    #[test]
    fn malformed_sticker_marker_is_rejected() {
        let err = parse_sticker_message(
            "[sticker] [sonar-sticker-v1] pack=30030:bad shortcode=cat_wave sha256=bad",
        )
        .unwrap_err();

        assert!(matches!(
            err,
            StickerError::InvalidField {
                field: "author_pubkey_hex" | "pack_address" | "sticker_message",
                ..
            }
        ));
    }
}
