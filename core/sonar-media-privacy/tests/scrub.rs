//! Fixtures come from `tests/fixtures/generate.py`: real encoder output (Pillow,
//! libavif, `sips`) carrying Exif with GPS, XMP, IPTC, comments, text chunks,
//! MPF and trailers, every text field marked `LEAK`.

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
const AVIF: &[u8] = include_bytes!("fixtures/located.avif");

/// Rewritten without the chunks, segments and blocks decoders do not need.
const IN_PLACE: [(&str, &[u8]); 6] = [
    ("jpeg", JPEG),
    ("png", PNG),
    ("apng", APNG),
    ("gif", GIF),
    ("webp", WEBP),
    ("animated webp", ANIMATED_WEBP),
];

/// Cleaned by zeroing: the same length, so every `iloc` offset still holds.
const ZEROED: [(&str, &[u8]); 2] = [("heic", HEIC), ("avif", AVIF)];

fn cleaned_in_place() -> impl Iterator<Item = (&'static str, &'static [u8])> {
    IN_PLACE.into_iter().chain(ZEROED)
}

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
    for (name, data) in cleaned_in_place().chain([("tiff", TIFF)]) {
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

/// Top-level boxes of an ISO-BMFF file: type and byte range.
fn top_level_boxes(data: &[u8]) -> Vec<([u8; 4], std::ops::Range<usize>)> {
    let mut boxes = Vec::new();
    let mut pos = 0;
    while pos < data.len() {
        let mut size = u32::from_be_bytes(data[pos..pos + 4].try_into().unwrap()) as usize;
        if size == 1 {
            // `sips` writes mdat with a 64-bit size.
            size = u64::from_be_bytes(data[pos + 8..pos + 16].try_into().unwrap()) as usize;
        }
        assert!(size >= 8, "{pos}: box size {size}");
        boxes.push((data[pos + 4..pos + 8].try_into().unwrap(), pos..pos + size));
        pos += size;
    }
    boxes
}

/// TIFF header offset 6, `Exif\0\0`, then IFD0 with Orientation 6 alone.
const ORIENTATION_EXIF: &[u8] = b"\0\0\0\x06Exif\0\0MM\0*\0\0\0\x08\0\x01\
    \x01\x12\0\x03\0\0\0\x01\0\x06\0\0\0\0\0\0";
/// The same with an empty IFD0: libavif moves the Orientation into `irot`
/// and drops the tag, so the AVIF's Exif has none to keep.
const EMPTY_EXIF: &[u8] = b"\0\0\0\x06Exif\0\0MM\0*\0\0\0\x08\0\0\0\0\0\0";

#[test]
fn heif_and_avif_are_zeroed_in_place() {
    for ((name, data), (format, minimal_exif)) in ZEROED.into_iter().zip([
        (ImageFormat::Heif, ORIENTATION_EXIF),
        (ImageFormat::Avif, EMPTY_EXIF),
    ]) {
        let out = stripped(name, data);
        assert!(!contains(&out, b"LEAK"), "{name}: metadata survived");
        assert!(!contains(&out, b"xmpmeta"), "{name}: XMP survived");
        assert_eq!(out.len(), data.len(), "{name}: a byte moved");
        assert_eq!(sniff_image(&out), Some(format), "{name}");
        // The Exif item now holds a TIFF header and the Orientation alone:
        // libavif rejects a file whose Exif item has no TIFF header.
        let exif = (0..out.len() - 10)
            .find(|&at| &out[at..at + 10] == b"Exif\0\0MM\0*")
            .expect("an Exif item")
            - 4;
        let exif = exif..exif + minimal_exif.len();
        assert_eq!(&out[exif.clone()], minimal_exif, "{name}");
        // Every other byte is the original or zero, and only mdat changed:
        // ftyp and meta — the item list, every iloc offset, irot and colr —
        // are untouched.
        for (at, (&o, &d)) in out.iter().zip(data).enumerate() {
            let rewritten = !exif.contains(&at) && o != d && o != 0;
            assert!(!rewritten, "{name}: byte {at} rewritten");
        }
        let boxes = top_level_boxes(data);
        assert_eq!(top_level_boxes(&out), boxes, "{name}: box layout changed");
        for (kind, range) in boxes {
            if &kind != b"mdat" {
                assert_eq!(out[range.clone()], data[range], "{name}: {kind:?} changed");
            }
        }
        assert!(contains(&out, b"irot"), "{name}: orientation dropped");
    }
}

#[test]
fn scrubbing_twice_finds_nothing_more() {
    for (name, data) in cleaned_in_place() {
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
    assert_eq!(sniff_image(TIFF), Some(ImageFormat::Tiff));
    assert_eq!(scrub_image(TIFF), ImageScrub::Reencode);
    assert_eq!(image_orientation(TIFF), 6);
}

/// A cut-off upload, a half-written temp file: never a panic, and never a
/// result that still carries metadata.
#[test]
fn every_truncation_is_safe() {
    for (name, data) in cleaned_in_place() {
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
    for (_, data) in cleaned_in_place().chain([("tiff", TIFF)]) {
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
