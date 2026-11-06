//! Strip metadata from an image before it leaves the device.
//!
//! Cameras and editors store where and when a photo was taken, the device that
//! took it, and sometimes an uncropped thumbnail next to the pixels. Signal
//! strips all of it on send; so does White Noise (MDK re-encodes JPEG and PNG).
//! Sonar sends images over more paths than that — Bluetooth mesh, files, the
//! share sheet — so the apps call [`scrub_image`] wherever an image enters a
//! send path.
//!
//! [`scrub_image`] rewrites the containers it can edit without decoding —
//! JPEG, PNG (and APNG), GIF, WebP (still and animated), HEIF (HEIC) and AVIF —
//! keeping only what a decoder needs to draw the same picture: the coded image
//! data, the colour profile and the orientation. The coded pixel data is copied
//! byte for byte. HEIF and AVIF are cleaned in place, by zeroing: an iPhone
//! photo stays a HEIC of the same size.
//!
//! It never decodes and never guesses. A file it recognizes as an image but
//! cannot rewrite (TIFF, JPEG XL, HEIF image sequences) or cannot parse is
//! [`ImageScrub::Reencode`]: the caller must decode it and encode a new file,
//! the one way to be sure nothing survives. Images are recognized by their
//! bytes, never by the file name or MIME type they arrived with.

mod gif;
mod heif;
mod jpeg;
mod png;
mod tiff;
mod webp;

/// An image container [`sniff_image`] recognizes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImageFormat {
    Jpeg,
    Png,
    Gif,
    WebP,
    Heif,
    Avif,
    Tiff,
    JpegXl,
}

/// What a sender must do with a file before it leaves the device.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ImageScrub {
    /// Not an image this crate recognizes: send it as it is.
    NotImage,
    /// An image that carries nothing to remove: send it as it is.
    Clean,
    /// The image without its metadata.
    Stripped(Vec<u8>),
    /// An image this crate cannot rewrite in place, or could not parse. Decode
    /// it and send a re-encoded copy, applying [`image_orientation`] if the
    /// decoder does not; never send the input.
    Reencode,
}

/// Remove location, device, time, comment and thumbnail metadata from `data`.
pub fn scrub_image(data: &[u8]) -> ImageScrub {
    let Some(format) = sniff_image(data) else {
        return ImageScrub::NotImage;
    };
    let rewrite = match format {
        ImageFormat::Jpeg => jpeg::scrub(data),
        ImageFormat::Png => png::scrub(data),
        ImageFormat::Gif => gif::scrub(data),
        ImageFormat::WebP => webp::scrub(data),
        ImageFormat::Heif | ImageFormat::Avif => heif::scrub(data),
        ImageFormat::Tiff | ImageFormat::JpegXl => return ImageScrub::Reencode,
    };
    match rewrite {
        Ok(None) => ImageScrub::Clean,
        Ok(Some(stripped)) => ImageScrub::Stripped(stripped),
        Err(Malformed) => ImageScrub::Reencode,
    }
}

/// The EXIF orientation (1–8) of a JPEG or TIFF, or 1 when it has none.
///
/// For decoders that ignore it (Android `BitmapFactory`, Java ImageIO): a
/// re-encode that drops the tag without rotating sends the photo sideways.
pub fn image_orientation(data: &[u8]) -> u8 {
    match sniff_image(data) {
        Some(ImageFormat::Jpeg) => jpeg::orientation(data),
        Some(ImageFormat::Tiff) => tiff::orientation(data),
        _ => None,
    }
    .unwrap_or(1)
}

/// Identify an image container from its first bytes.
pub fn sniff_image(data: &[u8]) -> Option<ImageFormat> {
    const JXL_CONTAINER: &[u8] = b"\x00\x00\x00\x0CJXL \x0D\x0A\x87\x0A";
    if data.starts_with(&[0xFF, 0xD8, 0xFF]) {
        Some(ImageFormat::Jpeg)
    } else if data.starts_with(png::SIGNATURE) {
        Some(ImageFormat::Png)
    } else if data.starts_with(b"GIF87a") || data.starts_with(b"GIF89a") {
        Some(ImageFormat::Gif)
    } else if data.len() >= 12 && data.starts_with(b"RIFF") && &data[8..12] == b"WEBP" {
        Some(ImageFormat::WebP)
    } else if [b"II*\0", b"MM\0*", b"II+\0", b"MM\0+"]
        .iter()
        .any(|magic| data.starts_with(*magic))
    {
        Some(ImageFormat::Tiff)
    } else if data.starts_with(&[0xFF, 0x0A]) || data.starts_with(JXL_CONTAINER) {
        Some(ImageFormat::JpegXl)
    } else {
        isobmff_image(data)
    }
}

/// HEIF and AVIF are ISO-BMFF files whose `ftyp` box names an image brand.
/// MP4/MOV share the container but not the brands, so videos stay `None`.
fn isobmff_image(data: &[u8]) -> Option<ImageFormat> {
    const HEIF: [&[u8; 4]; 10] = [
        b"heic", b"heix", b"hevc", b"hevx", b"heim", b"heis", b"hevm", b"hevs", b"mif1", b"msf1",
    ];
    const AVIF: [&[u8; 4]; 2] = [b"avif", b"avis"];
    if data.get(4..8)? != b"ftyp" {
        return None;
    }
    let box_end = usize::try_from(be32(data, 0)?).ok()?.min(data.len());
    // Major brand at 8, minor version at 12, then compatible brands.
    let brands = std::iter::once(8)
        .chain((16..box_end).step_by(4))
        .filter_map(|at| data.get(at..at + 4));
    let mut format = None;
    for brand in brands {
        if AVIF.iter().any(|b| b.as_slice() == brand) {
            return Some(ImageFormat::Avif);
        }
        if HEIF.iter().any(|b| b.as_slice() == brand) {
            format = Some(ImageFormat::Heif);
        }
    }
    format
}

/// The input does not parse as the container it starts like.
#[derive(Debug)]
struct Malformed;

/// `Ok(None)`: nothing to remove. `Ok(Some(bytes))`: the rewritten file.
type Rewrite = Result<Option<Vec<u8>>, Malformed>;

fn be16(data: &[u8], at: usize) -> Option<u16> {
    let b = data.get(at..at.checked_add(2)?)?;
    Some(u16::from_be_bytes([b[0], b[1]]))
}

fn be32(data: &[u8], at: usize) -> Option<u32> {
    let b = data.get(at..at.checked_add(4)?)?;
    Some(u32::from_be_bytes([b[0], b[1], b[2], b[3]]))
}

fn be64(data: &[u8], at: usize) -> Option<u64> {
    let b = data.get(at..at.checked_add(8)?)?;
    Some(u64::from_be_bytes(b.try_into().ok()?))
}

fn le32(data: &[u8], at: usize) -> Option<u32> {
    let b = data.get(at..at.checked_add(4)?)?;
    Some(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sniffs_by_bytes_not_names() {
        assert_eq!(sniff_image(b"\xFF\xD8\xFF\xE0"), Some(ImageFormat::Jpeg));
        assert_eq!(sniff_image(b"GIF89a\x01\x00"), Some(ImageFormat::Gif));
        assert_eq!(
            sniff_image(b"RIFF\x00\x00\x00\x00WEBPVP8 "),
            Some(ImageFormat::WebP)
        );
        assert_eq!(sniff_image(b"RIFF\x00\x00\x00\x00WAVEfmt "), None);
        assert_eq!(
            sniff_image(b"MM\x00*\x00\x00\x00\x08"),
            Some(ImageFormat::Tiff)
        );
        assert_eq!(sniff_image(b"%PDF-1.7"), None);
        assert_eq!(sniff_image(b""), None);
    }

    #[test]
    fn sniffs_heif_and_avif_but_not_video() {
        let ftyp = |major: &[u8; 4], compat: &[&[u8; 4]]| {
            let mut b = Vec::new();
            b.extend_from_slice(&(16 + 4 * compat.len() as u32).to_be_bytes());
            b.extend_from_slice(b"ftyp");
            b.extend_from_slice(major);
            b.extend_from_slice(&[0; 4]);
            for c in compat {
                b.extend_from_slice(*c);
            }
            b
        };
        assert_eq!(
            sniff_image(&ftyp(b"heic", &[b"mif1", b"heic"])),
            Some(ImageFormat::Heif)
        );
        assert_eq!(
            sniff_image(&ftyp(b"mif1", &[b"avif"])),
            Some(ImageFormat::Avif)
        );
        assert_eq!(sniff_image(&ftyp(b"isom", &[b"isom", b"mp41"])), None);
        assert_eq!(sniff_image(&ftyp(b"qt  ", &[b"qt  "])), None);
    }

    #[test]
    fn non_images_pass_through() {
        assert_eq!(scrub_image(b"just some text"), ImageScrub::NotImage);
        assert_eq!(image_orientation(b"just some text"), 1);
    }
}
