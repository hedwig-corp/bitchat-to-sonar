//! Pixel size of an image read from its header, for the MIP-04 `dim` field.
//!
//! MDK 0.8 decoded every image it encrypted to fill `dim`. The v2 port
//! encrypted without it, so every photo Sonar sent arrived without a size,
//! and both apps drew it letterboxed in their largest media box (found by
//! QA-106). Receivers size the bubble from `dim` before any bytes arrive
//! (Signal's pre-sizing), so the sender reads it here from the header alone:
//! no decode, bounded reads, and `None` for anything it does not recognise,
//! which leaves the receiver on its fallback box as before.
//!
//! Sizes are as displayed: a JPEG whose EXIF orientation turns it a quarter
//! turn reports width and height swapped.

/// `(width, height)` of a PNG, GIF, WebP or JPEG, or `None`.
pub(crate) fn image_dimensions(data: &[u8]) -> Option<(u32, u32)> {
    let (width, height) = png(data)
        .or_else(|| gif(data))
        .or_else(|| webp(data))
        .or_else(|| jpeg(data))?;
    (width > 0 && height > 0).then_some((width, height))
}

fn be16(b: &[u8]) -> u16 {
    u16::from_be_bytes([b[0], b[1]])
}

fn png(d: &[u8]) -> Option<(u32, u32)> {
    // Signature, then the IHDR chunk: length, "IHDR", width, height (big-endian).
    if d.len() < 24 || &d[..8] != b"\x89PNG\r\n\x1a\n" || &d[12..16] != b"IHDR" {
        return None;
    }
    let width = u32::from_be_bytes([d[16], d[17], d[18], d[19]]);
    let height = u32::from_be_bytes([d[20], d[21], d[22], d[23]]);
    Some((width, height))
}

fn gif(d: &[u8]) -> Option<(u32, u32)> {
    // Logical screen descriptor: width, height (little-endian u16).
    if d.len() < 10 || !(d.starts_with(b"GIF87a") || d.starts_with(b"GIF89a")) {
        return None;
    }
    let width = u16::from_le_bytes([d[6], d[7]]);
    let height = u16::from_le_bytes([d[8], d[9]]);
    Some((u32::from(width), u32::from(height)))
}

fn webp(d: &[u8]) -> Option<(u32, u32)> {
    if d.len() < 30 || &d[..4] != b"RIFF" || &d[8..12] != b"WEBP" {
        return None;
    }
    match &d[12..16] {
        // Lossy: frame tag, start code 9d 01 2a, then 14-bit width and height.
        b"VP8 " => {
            if d[23..26] != [0x9d, 0x01, 0x2a] {
                return None;
            }
            let width = u16::from_le_bytes([d[26], d[27]]) & 0x3fff;
            let height = u16::from_le_bytes([d[28], d[29]]) & 0x3fff;
            Some((u32::from(width), u32::from(height)))
        }
        // Lossless: signature 0x2f, then width-1 and height-1 in 14 bits each.
        b"VP8L" => {
            if d[20] != 0x2f {
                return None;
            }
            let bits = u32::from_le_bytes([d[21], d[22], d[23], d[24]]);
            Some(((bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1))
        }
        // Extended: canvas width-1 and height-1, 24 bits each.
        b"VP8X" => {
            let width = u32::from_le_bytes([d[24], d[25], d[26], 0]) + 1;
            let height = u32::from_le_bytes([d[27], d[28], d[29], 0]) + 1;
            Some((width, height))
        }
        _ => None,
    }
}

fn jpeg(d: &[u8]) -> Option<(u32, u32)> {
    if d.len() < 4 || d[0] != 0xff || d[1] != 0xd8 {
        return None;
    }
    let mut orientation = 1u16;
    let mut i = 2usize;
    while i + 4 <= d.len() {
        if d[i] != 0xff {
            return None;
        }
        let marker = d[i + 1];
        match marker {
            // Fill byte before a marker.
            0xff => {
                i += 1;
                continue;
            }
            // Markers without a length.
            0x01 | 0xd0..=0xd7 => {
                i += 2;
                continue;
            }
            // End of image, or scan data before any frame header.
            0xd9 | 0xda => return None,
            _ => {}
        }
        let len = usize::from(be16(&d[i + 2..i + 4]));
        if len < 2 {
            return None;
        }
        let end = i.checked_add(2)?.checked_add(len)?;
        let segment = d.get(i + 4..end)?;
        match marker {
            0xe1 => {
                if let Some(o) = exif_orientation(segment) {
                    orientation = o;
                }
            }
            // Start of frame (every SOFn except DHT 0xc4, JPG 0xc8, DAC 0xcc):
            // precision, height, width.
            0xc0..=0xcf if !matches!(marker, 0xc4 | 0xc8 | 0xcc) => {
                if segment.len() < 5 {
                    return None;
                }
                let height = u32::from(be16(&segment[1..3]));
                let width = u32::from(be16(&segment[3..5]));
                // EXIF orientations 5–8 turn the image a quarter turn.
                return Some(if (5..=8).contains(&orientation) {
                    (height, width)
                } else {
                    (width, height)
                });
            }
            _ => {}
        }
        i = end;
    }
    None
}

/// The orientation tag (0x0112) of an APP1 Exif segment's first IFD.
fn exif_orientation(segment: &[u8]) -> Option<u16> {
    let tiff = segment.strip_prefix(b"Exif\0\0")?;
    let little = match tiff.get(..2)? {
        b"II" => true,
        b"MM" => false,
        _ => return None,
    };
    let read16 = |at: usize| -> Option<u16> {
        let b = tiff.get(at..at.checked_add(2)?)?;
        Some(if little {
            u16::from_le_bytes([b[0], b[1]])
        } else {
            u16::from_be_bytes([b[0], b[1]])
        })
    };
    let read32 = |at: usize| -> Option<u32> {
        let b = tiff.get(at..at.checked_add(4)?)?;
        let bytes = [b[0], b[1], b[2], b[3]];
        Some(if little {
            u32::from_le_bytes(bytes)
        } else {
            u32::from_be_bytes(bytes)
        })
    };
    if read16(2)? != 42 {
        return None;
    }
    let ifd = usize::try_from(read32(4)?).ok()?;
    let entries = usize::from(read16(ifd)?);
    for n in 0..entries.min(256) {
        let entry = ifd.checked_add(2)?.checked_add(n.checked_mul(12)?)?;
        if read16(entry)? == 0x0112 {
            // SHORT, count 1: the value sits in the first two value bytes.
            return read16(entry.checked_add(8)?);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn png_header(width: u32, height: u32) -> Vec<u8> {
        let mut d = b"\x89PNG\r\n\x1a\n\0\0\0\x0dIHDR".to_vec();
        d.extend_from_slice(&width.to_be_bytes());
        d.extend_from_slice(&height.to_be_bytes());
        d.extend_from_slice(&[8, 2, 0, 0, 0, 0, 0, 0, 0]);
        d
    }

    /// A baseline JPEG head: SOI, an optional APP1 Exif segment carrying
    /// `orientation`, then SOF0 for `width` x `height`.
    fn jpeg_header(width: u16, height: u16, orientation: Option<u16>, little: bool) -> Vec<u8> {
        let mut d = vec![0xff, 0xd8];
        // An APP0 segment first, so the scan has to skip one.
        d.extend_from_slice(&[0xff, 0xe0, 0x00, 0x10]);
        d.extend_from_slice(b"JFIF\0\x01\x01\0\0\x01\0\x01\0\0");
        if let Some(o) = orientation {
            let (w16, w32): (fn(u16) -> [u8; 2], fn(u32) -> [u8; 4]) = if little {
                (u16::to_le_bytes, u32::to_le_bytes)
            } else {
                (u16::to_be_bytes, u32::to_be_bytes)
            };
            let mut tiff = if little { b"II".to_vec() } else { b"MM".to_vec() };
            tiff.extend_from_slice(&w16(42));
            tiff.extend_from_slice(&w32(8));
            tiff.extend_from_slice(&w16(2)); // two entries
            // An unrelated tag first (ImageWidth), then Orientation.
            tiff.extend_from_slice(&w16(0x0100));
            tiff.extend_from_slice(&w16(3));
            tiff.extend_from_slice(&w32(1));
            tiff.extend_from_slice(&w16(width));
            tiff.extend_from_slice(&[0, 0]);
            tiff.extend_from_slice(&w16(0x0112));
            tiff.extend_from_slice(&w16(3));
            tiff.extend_from_slice(&w32(1));
            tiff.extend_from_slice(&w16(o));
            tiff.extend_from_slice(&[0, 0]);
            let mut app1 = b"Exif\0\0".to_vec();
            app1.extend_from_slice(&tiff);
            d.extend_from_slice(&[0xff, 0xe1]);
            d.extend_from_slice(&((app1.len() + 2) as u16).to_be_bytes());
            d.extend_from_slice(&app1);
        }
        d.extend_from_slice(&[0xff, 0xc0, 0x00, 0x11, 0x08]);
        d.extend_from_slice(&height.to_be_bytes());
        d.extend_from_slice(&width.to_be_bytes());
        d.extend_from_slice(&[3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]);
        d
    }

    #[test]
    fn reads_png_gif_and_webp_headers() {
        assert_eq!(image_dimensions(&png_header(320, 180)), Some((320, 180)));

        let mut gif = b"GIF89a".to_vec();
        gif.extend_from_slice(&[0x40, 0x01, 0xb4, 0x00, 0, 0, 0]);
        assert_eq!(image_dimensions(&gif), Some((320, 180)));

        let mut vp8 = b"RIFF\0\0\0\0WEBPVP8 \0\0\0\0".to_vec();
        vp8.extend_from_slice(&[0x30, 0x01, 0x00, 0x9d, 0x01, 0x2a]);
        vp8.extend_from_slice(&320u16.to_le_bytes());
        vp8.extend_from_slice(&180u16.to_le_bytes());
        assert_eq!(image_dimensions(&vp8), Some((320, 180)));

        let mut vp8l = b"RIFF\0\0\0\0WEBPVP8L\0\0\0\0\x2f".to_vec();
        let bits: u32 = (320 - 1) | ((180 - 1) << 14);
        vp8l.extend_from_slice(&bits.to_le_bytes());
        vp8l.extend_from_slice(&[0; 5]);
        assert_eq!(image_dimensions(&vp8l), Some((320, 180)));

        let mut vp8x = b"RIFF\0\0\0\0WEBPVP8X\x0a\0\0\0\0\0\0\0".to_vec();
        vp8x.extend_from_slice(&(320u32 - 1).to_le_bytes()[..3]);
        vp8x.extend_from_slice(&(180u32 - 1).to_le_bytes()[..3]);
        assert_eq!(image_dimensions(&vp8x), Some((320, 180)));
    }

    #[test]
    fn reads_a_jpeg_frame_header_and_honours_exif_orientation() {
        assert_eq!(image_dimensions(&jpeg_header(320, 180, None, false)), Some((320, 180)));
        for little in [false, true] {
            // 1 = upright, 3 = upside down: same box.
            assert_eq!(
                image_dimensions(&jpeg_header(320, 180, Some(3), little)),
                Some((320, 180))
            );
            // 6 = rotate 90° clockwise (a portrait phone photo): shown 180 x 320.
            assert_eq!(
                image_dimensions(&jpeg_header(320, 180, Some(6), little)),
                Some((180, 320)),
                "little-endian EXIF: {little}"
            );
        }
    }

    /// Anything else, and every truncation of a valid header, is `None`
    /// rather than a panic: the bytes come from whatever the user shared.
    #[test]
    fn unknown_or_truncated_input_is_none_never_a_panic() {
        assert_eq!(image_dimensions(b""), None);
        assert_eq!(image_dimensions(b"%PDF-1.7 not an image"), None);
        assert_eq!(image_dimensions(&png_header(0, 180)), None, "a zero side is no size");
        let headers = [
            png_header(320, 180),
            jpeg_header(320, 180, Some(6), true),
            jpeg_header(320, 180, Some(6), false),
        ];
        for header in headers {
            for cut in 0..header.len() {
                let _ = image_dimensions(&header[..cut]);
            }
        }
        // A segment length that runs past the end, and an IFD offset past it.
        assert_eq!(image_dimensions(&[0xff, 0xd8, 0xff, 0xe1, 0xff, 0xff, 0]), None);
        let mut bad_ifd = jpeg_header(320, 180, Some(6), false);
        let tiff_at = bad_ifd.windows(6).position(|w| w == b"Exif\0\0").unwrap() + 6;
        bad_ifd[tiff_at + 4..tiff_at + 8].copy_from_slice(&u32::MAX.to_be_bytes());
        assert_eq!(image_dimensions(&bad_ifd), Some((320, 180)), "a bad IFD only loses orientation");
    }
}
