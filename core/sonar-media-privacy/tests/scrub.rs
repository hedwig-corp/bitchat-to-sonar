//! Fixtures come from `tests/fixtures/generate.py`: real encoder output (Pillow,
//! `sips`) carrying Exif with GPS, XMP, IPTC, comments, text chunks, MPF and
//! trailers, every text field marked `LEAK`.

use std::io::Cursor;

use image::codecs::{gif::GifDecoder, png::PngDecoder, webp::WebPDecoder};
use image::{AnimationDecoder, RgbaImage};
use sonar_media_privacy::{image_orientation, scrub_image, sniff_image, ImageFormat, ImageScrub};

const JPEG: &[u8] = include_bytes!("fixtures/located.jpg");
const PNG: &[u8] = include_bytes!("fixtures/located.png");
const APNG: &[u8] = include_bytes!("fixtures/located-animated.png");
const GIF: &[u8] = include_bytes!("fixtures/located.gif");
const WEBP: &[u8] = include_bytes!("fixtures/located.webp");
const ANIMATED_WEBP: &[u8] = include_bytes!("fixtures/located-animated.webp");
const TIFF: &[u8] = include_bytes!("fixtures/located.tiff");
const HEIC: &[u8] = include_bytes!("fixtures/located.heic");

const IN_PLACE: [(&str, &[u8]); 6] = [
    ("jpeg", JPEG),
    ("png", PNG),
    ("apng", APNG),
    ("gif", GIF),
    ("webp", WEBP),
    ("animated webp", ANIMATED_WEBP),
];

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|w| w == needle)
}

fn stripped(name: &str, data: &[u8]) -> Vec<u8> {
    match scrub_image(data) {
        ImageScrub::Stripped(out) => out,
        other => panic!("{name}: expected Stripped, got {other:?}"),
    }
}

#[test]
fn fixtures_carry_metadata_to_strip() {
    for (name, data) in IN_PLACE
        .iter()
        .chain([("tiff", TIFF), ("heic", HEIC)].iter())
    {
        assert!(contains(data, b"LEAK"), "{name}: fixture lost its metadata");
    }
}

#[test]
fn nothing_marked_survives() {
    for (name, data) in IN_PLACE {
        let out = stripped(name, data);
        assert!(!contains(&out, b"LEAK"), "{name}: metadata survived");
        assert!(!contains(&out, b"xmpmeta"), "{name}: XMP survived");
        assert!(out.len() < data.len(), "{name}: nothing was removed");
    }
}

#[test]
fn scrubbing_twice_finds_nothing_more() {
    for (name, data) in IN_PLACE {
        assert_eq!(
            scrub_image(&stripped(name, data)),
            ImageScrub::Clean,
            "{name}"
        );
    }
}

#[test]
fn still_images_decode_to_the_same_pixels() {
    for (name, data) in [("jpeg", JPEG), ("png", PNG), ("webp", WEBP)] {
        let before = image::load_from_memory(data).unwrap().to_rgba8();
        let after = image::load_from_memory(&stripped(name, data))
            .unwrap()
            .to_rgba8();
        assert_eq!(before, after, "{name}: pixels changed");
    }
}

#[test]
fn animations_keep_every_frame() {
    fn frames(name: &str, data: &[u8]) -> Vec<RgbaImage> {
        let frames = match name {
            "gif" => GifDecoder::new(Cursor::new(data)).unwrap().into_frames(),
            "apng" => PngDecoder::new(Cursor::new(data))
                .unwrap()
                .apng()
                .unwrap()
                .into_frames(),
            "animated webp" => WebPDecoder::new(Cursor::new(data)).unwrap().into_frames(),
            _ => unreachable!(),
        };
        frames
            .collect_frames()
            .unwrap()
            .into_iter()
            .map(|f| f.into_buffer())
            .collect()
    }
    for (name, data) in [
        ("gif", GIF),
        ("apng", APNG),
        ("animated webp", ANIMATED_WEBP),
    ] {
        let before = frames(name, data);
        assert!(before.len() > 1, "{name}: fixture is not animated");
        assert_eq!(
            before,
            frames(name, &stripped(name, data)),
            "{name}: frames changed"
        );
    }
}

#[test]
fn jpeg_keeps_orientation_and_colour_only() {
    let out = stripped("jpeg", JPEG);
    assert_eq!(image_orientation(JPEG), 6);
    assert_eq!(image_orientation(&out), 6, "the photo would turn sideways");
    // The one Exif segment left is the 34-byte Orientation-only one, so no GPS
    // IFD, device, serial or thumbnail can be in it.
    let exif: Vec<usize> = (0..out.len() - 6)
        .filter(|&i| &out[i..i + 6] == b"Exif\0\0")
        .collect();
    assert_eq!(exif.len(), 1);
    assert_eq!(&out[exif[0] - 4..exif[0]], &[0xFF, 0xE1, 0x00, 0x22]);
    assert!(contains(&out, b"ICC_PROFILE\0"), "colour profile dropped");
    // MPF secondary images and trailers live after the first EOI.
    assert!(out.ends_with(&[0xFF, 0xD9]));
    assert!(!contains(&out, b"MPF\0"));
}

#[test]
fn png_and_webp_drop_their_exif_containers() {
    let png = stripped("png", PNG);
    for chunk in [b"eXIf", b"tEXt", b"zTXt", b"iTXt"] {
        assert!(
            !contains(&png, chunk),
            "png kept {}",
            String::from_utf8_lossy(chunk)
        );
    }
    assert!(contains(&png, b"iCCP"), "colour profile dropped");
    for (name, data) in [("webp", WEBP), ("animated webp", ANIMATED_WEBP)] {
        let out = stripped(name, data);
        assert!(
            !contains(&out, b"EXIF") && !contains(&out, b"XMP "),
            "{name}"
        );
        let riff_len = u32::from_le_bytes(out[4..8].try_into().unwrap()) as usize;
        assert_eq!(riff_len + 8, out.len(), "{name}: RIFF size not updated");
        let vp8x = (12..out.len() - 4)
            .find(|&i| &out[i..i + 4] == b"VP8X")
            .unwrap();
        assert_eq!(out[vp8x + 8] & 0x0C, 0, "{name}: EXIF/XMP flags still set");
    }
}

#[test]
fn containers_we_cannot_rewrite_are_reencoded() {
    assert_eq!(sniff_image(HEIC), Some(ImageFormat::Heif));
    assert_eq!(scrub_image(HEIC), ImageScrub::Reencode);
    assert_eq!(sniff_image(TIFF), Some(ImageFormat::Tiff));
    assert_eq!(scrub_image(TIFF), ImageScrub::Reencode);
    assert_eq!(image_orientation(TIFF), 6);
}

/// A cut-off upload, a half-written temp file: never a panic, and never a
/// result that still carries metadata.
#[test]
fn every_truncation_is_safe() {
    for (name, data) in IN_PLACE {
        for len in 0..=data.len() {
            let prefix = &data[..len];
            match scrub_image(prefix) {
                ImageScrub::Stripped(out) => assert!(!contains(&out, b"LEAK"), "{name}[..{len}]"),
                ImageScrub::Clean => assert!(!contains(prefix, b"LEAK"), "{name}[..{len}]"),
                ImageScrub::NotImage | ImageScrub::Reencode => {}
            }
            let _ = image_orientation(prefix);
        }
    }
}

#[test]
fn corrupt_bytes_never_panic() {
    for (_, data) in IN_PLACE
        .iter()
        .chain([("tiff", TIFF), ("heic", HEIC)].iter())
    {
        let mut copy = data.to_vec();
        for at in 0..copy.len() {
            let original = copy[at];
            for corrupt in [0x00, 0xFF, original ^ 0x55, original.wrapping_add(1)] {
                copy[at] = corrupt;
                let _ = scrub_image(&copy);
                let _ = image_orientation(&copy);
            }
            copy[at] = original;
        }
    }
}
