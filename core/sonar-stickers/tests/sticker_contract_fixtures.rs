use nostr::prelude::*;
use serde::Deserialize;
use sonar_stickers::{
    build_installed_packs_tags, build_pack_tags, build_sticker_ref_tag, parse_installed_pack_list,
    parse_pack_event, parse_sticker_ref_tag, InstalledPackList, PackAddress, Sticker, StickerError,
    StickerPack, StickerRef, STICKER_PACK_KIND, USER_STICKER_PACKS_KIND,
};

const FIXTURE: &str = include_str!("fixtures/sticker-contract-v1.json");

#[derive(Debug, Deserialize)]
struct ContractFixture {
    version: u8,
    secret_key_hex: String,
    author_pubkey_hex: String,
    pack: PackFixture,
    installed_pack_addresses: Vec<String>,
    sent_ref: StickerRefFixture,
    edited_pack_mismatch: StickerRefFixture,
    invalid: InvalidFixture,
}

#[derive(Debug, Deserialize)]
struct PackFixture {
    identifier: String,
    title: String,
    description: Option<String>,
    license: Option<String>,
    cover_shortcode: Option<String>,
    stickers: Vec<StickerFixture>,
}

#[derive(Clone, Debug, Deserialize)]
struct StickerFixture {
    shortcode: String,
    url: String,
    sha256: String,
    mime: String,
    width: Option<u32>,
    height: Option<u32>,
    alt: Option<String>,
    emoji: Option<String>,
}

#[derive(Debug, Deserialize)]
struct StickerRefFixture {
    pack: String,
    shortcode: String,
    plaintext_sha256: String,
}

#[derive(Debug, Deserialize)]
struct InvalidFixture {
    non_https_url: String,
    duplicate_shortcode: String,
    duplicate_sha256: String,
}

fn fixture() -> ContractFixture {
    serde_json::from_str(FIXTURE).expect("fixture is valid JSON")
}

fn sticker(value: &StickerFixture) -> Sticker {
    Sticker::new(
        &value.shortcode,
        &value.url,
        &value.sha256,
        &value.mime,
        value.width,
        value.height,
        value.alt.clone(),
        value.emoji.clone(),
    )
    .expect("fixture sticker is valid")
}

fn pack(value: &ContractFixture) -> StickerPack {
    let address = PackAddress::new(&value.author_pubkey_hex, &value.pack.identifier)
        .expect("fixture pack address is valid");
    let stickers = value.pack.stickers.iter().map(sticker).collect::<Vec<_>>();
    let cover = value
        .pack
        .cover_shortcode
        .as_deref()
        .and_then(|shortcode| {
            stickers
                .iter()
                .find(|sticker| sticker.shortcode == shortcode)
        })
        .cloned();

    StickerPack::new(
        address,
        &value.pack.title,
        value.pack.description.clone(),
        cover,
        stickers,
        value.pack.license.clone(),
    )
    .expect("fixture sticker pack is valid")
}

fn sticker_ref(value: &StickerRefFixture) -> StickerRef {
    StickerRef::new(
        PackAddress::parse(&value.pack).expect("fixture ref pack address is valid"),
        &value.shortcode,
        &value.plaintext_sha256,
    )
    .expect("fixture sticker ref is valid")
}

#[test]
fn fixture_pubkey_matches_secret_key() {
    let fixture = fixture();
    let keys = Keys::parse(&fixture.secret_key_hex).expect("fixture secret key is valid");

    assert_eq!(fixture.version, 1);
    assert_eq!(keys.public_key().to_hex(), fixture.author_pubkey_hex);
}

#[test]
fn pack_fixture_round_trips_through_nostr_event() {
    let fixture = fixture();
    let keys = Keys::parse(&fixture.secret_key_hex).expect("fixture secret key is valid");
    let pack = pack(&fixture);
    let event = EventBuilder::new(Kind::Custom(STICKER_PACK_KIND), "")
        .tags(build_pack_tags(&pack))
        .sign_with_keys(&keys)
        .expect("fixture pack event signs");

    let parsed = parse_pack_event(&event).expect("fixture pack event parses");

    assert_eq!(parsed.address, pack.address);
    assert_eq!(parsed.title, "Sonar Signal Cats");
    assert_eq!(parsed.description, pack.description);
    assert_eq!(parsed.license, pack.license);
    assert_eq!(parsed.stickers, pack.stickers);
    assert_eq!(
        parsed.cover.expect("fixture has cover").sha256,
        pack.cover.expect("fixture source has cover").sha256
    );
}

#[test]
fn installed_pack_fixture_round_trips_and_deduplicates() {
    let fixture = fixture();
    let keys = Keys::parse(&fixture.secret_key_hex).expect("fixture secret key is valid");
    let list = InstalledPackList::new(
        fixture
            .installed_pack_addresses
            .iter()
            .map(|value| PackAddress::parse(value).expect("fixture installed address is valid"))
            .collect(),
    );
    let event = EventBuilder::new(Kind::Custom(USER_STICKER_PACKS_KIND), "")
        .tags(build_installed_packs_tags(&list))
        .sign_with_keys(&keys)
        .expect("fixture installed list event signs");

    let parsed = parse_installed_pack_list(&event).expect("fixture installed list parses");

    assert_eq!(list.packs.len(), 1);
    assert_eq!(parsed, list);
}

#[test]
fn sticker_ref_fixture_round_trips_and_resolves_by_shortcode_and_hash() {
    let fixture = fixture();
    let pack = pack(&fixture);
    let sticker_ref = sticker_ref(&fixture.sent_ref);
    let tag = build_sticker_ref_tag(&sticker_ref);

    let parsed = parse_sticker_ref_tag(&tag).expect("fixture sticker ref parses");
    let resolved = pack
        .sticker(&parsed.shortcode)
        .expect("fixture referenced sticker exists");

    assert_eq!(parsed, sticker_ref);
    assert_eq!(resolved.sha256, parsed.plaintext_sha256);
}

#[test]
fn edited_pack_mismatch_does_not_resolve_to_original_sticker() {
    let fixture = fixture();
    let pack = pack(&fixture);
    let sticker_ref = sticker_ref(&fixture.edited_pack_mismatch);
    let local_sticker = pack
        .sticker(&sticker_ref.shortcode)
        .expect("fixture mismatch still names an existing shortcode");

    assert_ne!(local_sticker.sha256, sticker_ref.plaintext_sha256);
}

#[test]
fn invalid_fixture_cases_are_rejected() {
    let fixture = fixture();
    let mut duplicate_shortcode_pack = pack(&fixture);
    duplicate_shortcode_pack.stickers[1].shortcode = fixture.invalid.duplicate_shortcode.clone();
    let mut duplicate_hash_pack = pack(&fixture);
    duplicate_hash_pack.stickers[1].sha256 = fixture.invalid.duplicate_sha256.clone();
    duplicate_hash_pack.stickers[1].url = duplicate_hash_pack.stickers[0].url.clone();
    let first = &fixture.pack.stickers[0];

    assert!(matches!(
        Sticker::new(
            "bad_url",
            &fixture.invalid.non_https_url,
            &first.sha256,
            &first.mime,
            first.width,
            first.height,
            first.alt.clone(),
            first.emoji.clone(),
        ),
        Err(StickerError::InvalidField { field: "url", .. })
    ));
    assert_eq!(
        duplicate_shortcode_pack.validate(),
        Err(StickerError::DuplicateShortcode("cat_wave".into()))
    );
    assert_eq!(
        duplicate_hash_pack.validate(),
        Err(StickerError::DuplicateHash(
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb".into()
        ))
    );
}
