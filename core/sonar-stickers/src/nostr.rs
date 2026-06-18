use nostr::prelude::*;

use crate::error::{Result, StickerError};
use crate::model::{
    InstalledPackList, PackAddress, Sticker, StickerPack, StickerRef, PACK_FORMAT,
    STICKER_PACK_KIND, USER_STICKER_PACKS_KIND,
};

pub fn build_pack_tags(pack: &StickerPack) -> Vec<Tag> {
    let mut tags = vec![
        d_tag(&pack.address.identifier),
        Tag::custom(TagKind::Custom("title".into()), [pack.title.clone()]),
        Tag::custom(TagKind::Custom("pack_format".into()), [PACK_FORMAT]),
        Tag::hashtag(PACK_FORMAT),
    ];
    if let Some(description) = &pack.description {
        tags.push(Tag::custom(
            TagKind::Custom("description".into()),
            [description.clone()],
        ));
    }
    if let Some(cover) = &pack.cover {
        let mut fields = vec![cover.url.clone(), cover.sha256.clone()];
        if let Some(dim) = cover.dim() {
            fields.push(dim);
        }
        tags.push(Tag::custom(TagKind::Custom("image".into()), fields));
    }
    if let Some(license) = &pack.license {
        tags.push(Tag::custom(
            TagKind::Custom("license".into()),
            [license.clone()],
        ));
    }
    for sticker in &pack.stickers {
        tags.push(sticker_tag(sticker));
    }
    for sticker in &pack.stickers {
        tags.push(Tag::custom(
            TagKind::Custom("emoji".into()),
            [sticker.shortcode.clone(), sticker.url.clone()],
        ));
    }
    tags
}

pub fn parse_pack_event(event: &Event) -> Result<StickerPack> {
    if event.kind != Kind::Custom(STICKER_PACK_KIND)
        || !has_tag_value(event, "pack_format", PACK_FORMAT)
    {
        return Err(StickerError::NotStickerPack);
    }
    let identifier = first_tag_value(event, "d").ok_or(StickerError::MissingTag("d"))?;
    let title = first_tag_value(event, "title").ok_or(StickerError::MissingTag("title"))?;
    let address = PackAddress::new(event.pubkey.to_hex(), identifier)?;
    let description = first_tag_value(event, "description");
    let license = first_tag_value(event, "license");
    let cover = parse_cover(event)?;
    let stickers = event
        .tags
        .iter()
        .filter(|tag| tag_name(tag).as_deref() == Some("sticker"))
        .map(parse_sticker_tag)
        .collect::<Result<Vec<_>>>()?;
    StickerPack::new(address, title, description, cover, stickers, license)
}

pub fn build_installed_packs_tags(list: &InstalledPackList) -> Vec<Tag> {
    list.packs
        .iter()
        .map(|pack| {
            Tag::custom(
                TagKind::SingleLetter(SingleLetterTag::lowercase(Alphabet::A)),
                [pack.coordinate()],
            )
        })
        .collect()
}

pub fn parse_installed_pack_list(event: &Event) -> Result<InstalledPackList> {
    if event.kind != Kind::Custom(USER_STICKER_PACKS_KIND) {
        return Err(StickerError::InvalidField {
            field: "kind",
            reason: "expected kind 10030 installed sticker list".into(),
        });
    }
    let packs = event
        .tags
        .iter()
        .filter(|tag| tag.single_letter_tag() == Some(SingleLetterTag::lowercase(Alphabet::A)))
        .filter_map(|tag| tag.content())
        .filter_map(|value| PackAddress::parse(value).ok())
        .collect();
    Ok(InstalledPackList::new(packs))
}

pub fn build_sticker_ref_tag(sticker_ref: &StickerRef) -> Tag {
    Tag::custom(
        TagKind::Custom("sticker".into()),
        [
            sticker_ref.pack.coordinate(),
            sticker_ref.shortcode.clone(),
            sticker_ref.plaintext_sha256.clone(),
        ],
    )
}

pub fn parse_sticker_ref_tag(tag: &Tag) -> Result<StickerRef> {
    if tag_name(tag).as_deref() != Some("sticker") {
        return Err(StickerError::InvalidField {
            field: "sticker",
            reason: "expected sticker tag".into(),
        });
    }
    let fields = tag_fields(tag);
    if fields.len() < 3 {
        return Err(StickerError::InvalidField {
            field: "sticker",
            reason: "expected pack address, shortcode, and plaintext sha256".into(),
        });
    }
    StickerRef::new(
        PackAddress::parse(&fields[0])?,
        fields[1].clone(),
        fields[2].clone(),
    )
}

fn sticker_tag(sticker: &Sticker) -> Tag {
    let mut fields = vec![
        sticker.shortcode.clone(),
        sticker.url.clone(),
        sticker.sha256.clone(),
        sticker.mime.clone(),
        sticker.dim().unwrap_or_default(),
        sticker.alt.clone().unwrap_or_default(),
    ];
    if let Some(emoji) = &sticker.emoji {
        fields.push(emoji.clone());
    }
    Tag::custom(TagKind::Custom("sticker".into()), fields)
}

fn parse_sticker_tag(tag: &Tag) -> Result<Sticker> {
    let fields = tag_fields(tag);
    if fields.len() < 5 {
        return Err(StickerError::InvalidField {
            field: "sticker",
            reason: "expected sticker shortcode, url, sha256, mime, and optional metadata".into(),
        });
    }
    let (width, height) = parse_dim(fields.get(4).map(String::as_str).unwrap_or_default())?;
    Sticker::new(
        fields[0].clone(),
        fields[1].clone(),
        fields[2].clone(),
        fields[3].clone(),
        width,
        height,
        fields.get(5).cloned().filter(|s| !s.is_empty()),
        fields.get(6).cloned().filter(|s| !s.is_empty()),
    )
}

fn parse_cover(event: &Event) -> Result<Option<Sticker>> {
    let Some(tag) = event
        .tags
        .iter()
        .find(|tag| tag_name(tag).as_deref() == Some("image"))
    else {
        return Ok(None);
    };
    let fields = tag_fields(tag);
    if fields.len() < 2 {
        return Err(StickerError::InvalidField {
            field: "image",
            reason: "expected url, sha256, and optional dimensions".into(),
        });
    }
    let (width, height) = parse_dim(fields.get(2).map(String::as_str).unwrap_or_default())?;
    Ok(Some(Sticker::new(
        "cover",
        fields[0].clone(),
        fields[1].clone(),
        "image/webp",
        width,
        height,
        Some("Sticker pack cover".into()),
        None,
    )?))
}

fn parse_dim(value: &str) -> Result<(Option<u32>, Option<u32>)> {
    if value.is_empty() {
        return Ok((None, None));
    }
    let Some((w, h)) = value.split_once('x') else {
        return Err(StickerError::InvalidField {
            field: "dim",
            reason: "expected WIDTHxHEIGHT".into(),
        });
    };
    let width = w.parse::<u32>().map_err(|_| StickerError::InvalidField {
        field: "dim",
        reason: "invalid width".into(),
    })?;
    let height = h.parse::<u32>().map_err(|_| StickerError::InvalidField {
        field: "dim",
        reason: "invalid height".into(),
    })?;
    Ok((Some(width), Some(height)))
}

fn first_tag_value(event: &Event, name: &str) -> Option<String> {
    event
        .tags
        .iter()
        .find(|tag| tag_name(tag).as_deref() == Some(name))
        .and_then(|tag| tag.content())
        .map(ToString::to_string)
}

fn has_tag_value(event: &Event, name: &str, value: &str) -> bool {
    event
        .tags
        .iter()
        .any(|tag| tag_name(tag).as_deref() == Some(name) && (tag.content() == Some(value)))
}

fn d_tag(identifier: &str) -> Tag {
    Tag::custom(
        TagKind::SingleLetter(SingleLetterTag::lowercase(Alphabet::D)),
        [identifier.to_string()],
    )
}

fn tag_name(tag: &Tag) -> Option<String> {
    tag.as_slice().first().cloned()
}

fn tag_fields(tag: &Tag) -> Vec<String> {
    tag.as_slice().iter().skip(1).cloned().collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{sha256_hex, Sticker, StickerPack};

    const SECRET: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const HASH_A: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const HASH_B: &str = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";

    fn sticker(shortcode: &str, hash: &str) -> Sticker {
        Sticker::new(
            shortcode,
            format!("https://blossom.example/{hash}.webp"),
            hash,
            "image/webp",
            Some(512),
            Some(512),
            Some(format!("{shortcode} sticker")),
            Some("🙂".into()),
        )
        .unwrap()
    }

    #[test]
    fn pack_event_round_trip_preserves_stickers() {
        let keys = Keys::parse(SECRET).unwrap();
        let pubkey = keys.public_key().to_hex();
        let address = PackAddress::new(pubkey.clone(), "sonar-cats-v1").unwrap();
        let pack = StickerPack::new(
            address,
            "Sonar Cats",
            Some("Default cat stickers".into()),
            Some(sticker("cat_wave", HASH_A)),
            vec![sticker("cat_wave", HASH_A), sticker("cat_cry", HASH_B)],
            Some("CC-BY-4.0".into()),
        )
        .unwrap();
        let event = EventBuilder::new(Kind::Custom(STICKER_PACK_KIND), "")
            .tags(build_pack_tags(&pack))
            .sign_with_keys(&keys)
            .unwrap();

        let parsed = parse_pack_event(&event).unwrap();
        assert_eq!(parsed.title, "Sonar Cats");
        assert_eq!(parsed.stickers.len(), 2);
        assert_eq!(parsed.sticker("cat_wave").unwrap().sha256, HASH_A);
        assert_eq!(
            parsed.address.coordinate(),
            format!("30030:{pubkey}:sonar-cats-v1")
        );
    }

    #[test]
    fn installed_pack_list_round_trips_and_deduplicates() {
        let keys = Keys::parse(SECRET).unwrap();
        let pack = PackAddress::new(keys.public_key().to_hex(), "sonar-cats-v1").unwrap();
        let list = InstalledPackList::new(vec![pack.clone(), pack.clone()]);
        let event = EventBuilder::new(Kind::Custom(USER_STICKER_PACKS_KIND), "")
            .tags(build_installed_packs_tags(&list))
            .sign_with_keys(&keys)
            .unwrap();

        let parsed = parse_installed_pack_list(&event).unwrap();
        assert_eq!(parsed.packs, vec![pack]);
    }

    #[test]
    fn rejects_missing_pack_format_marker() {
        let keys = Keys::parse(SECRET).unwrap();
        let event = EventBuilder::new(Kind::Custom(STICKER_PACK_KIND), "")
            .tags([d_tag("sonar-cats-v1")])
            .sign_with_keys(&keys)
            .unwrap();

        assert_eq!(parse_pack_event(&event), Err(StickerError::NotStickerPack));
    }

    #[test]
    fn sticker_ref_tag_round_trips_with_plaintext_hash() {
        let keys = Keys::parse(SECRET).unwrap();
        let pack = PackAddress::new(keys.public_key().to_hex(), "sonar-cats-v1").unwrap();
        let sticker_ref = StickerRef::new(pack.clone(), "cat_wave", HASH_A).unwrap();

        let tag = build_sticker_ref_tag(&sticker_ref);
        let parsed = parse_sticker_ref_tag(&tag).unwrap();

        assert_eq!(parsed.pack, pack);
        assert_eq!(parsed.shortcode, "cat_wave");
        assert_eq!(parsed.plaintext_sha256, HASH_A);
    }

    #[test]
    fn sha256_helper_matches_known_value() {
        assert_eq!(
            sha256_hex(b"sonar"),
            "48ce1a75f18924f02f7d555a0c30d5c2f5f09eba641a555555d355a477bb9ae6"
        );
    }
}
