//! JPEG: keep the segments a decoder needs, drop the rest.
//!
//! Kept: frame and scan headers, Huffman/arithmetic/quantization tables,
//! restart intervals, the coded scan data, the JFIF header (without its
//! thumbnail), the ICC colour profile (APP2 `ICC_PROFILE`) and Adobe's colour
//! transform (APP14), which CMYK/YCCK files need to decode correctly.
//!
//! Dropped: Exif (GPS, device, serial numbers, timestamps, the embedded
//! thumbnail), XMP, IPTC/Photoshop (APP13), multi-picture/depth/gain-map
//! segments (APP2 `MPF`), every other APPn, comments, and anything after the
//! end-of-image marker — which is where MPF secondary images and vendor
//! trailers live. The Exif Orientation tag is the one value carried over, in a
//! minimal Exif segment of its own, so the photo stays upright.

use crate::{be16, tiff, Malformed, Rewrite};

const SOI: u8 = 0xD8;
const EOI: u8 = 0xD9;
const SOS: u8 = 0xDA;
const TEM: u8 = 0x01;
const APP0: u8 = 0xE0;
const APP1: u8 = 0xE1;
const APP2: u8 = 0xE2;
const APP14: u8 = 0xEE;
const APP15: u8 = 0xEF;
const COM: u8 = 0xFE;

const JFIF: &[u8] = b"JFIF\0";
const EXIF: &[u8] = b"Exif\0\0";
const ICC_PROFILE: &[u8] = b"ICC_PROFILE\0";
const ADOBE: &[u8] = b"Adobe";

/// JFIF identifier, version, units, densities, then the thumbnail size.
const JFIF_HEADER_LEN: usize = 14;

pub(crate) fn scrub(data: &[u8]) -> Rewrite {
    let mut out = Vec::with_capacity(data.len());
    out.extend_from_slice(&[0xFF, SOI]);
    let mut changed = false;
    let mut exif_seen = false;
    let mut pos = 2;
    loop {
        let (marker, after) = read_marker(data, pos)?;
        // More than one 0xFF before a marker is fill, which we do not copy.
        changed |= after - pos > 2;
        pos = after;
        match marker {
            EOI => {
                out.extend_from_slice(&[0xFF, EOI]);
                changed |= pos < data.len();
                return Ok(changed.then_some(out));
            }
            // Parameterless markers.
            0xD0..=0xD7 | TEM => out.extend_from_slice(&[0xFF, marker]),
            _ => {
                let len = usize::from(be16(data, pos).ok_or(Malformed)?);
                let end = pos
                    .checked_add(len)
                    .filter(|&end| len >= 2 && end <= data.len())
                    .ok_or(Malformed)?;
                let payload = &data[pos + 2..end];
                let segment = |out: &mut Vec<u8>| {
                    out.extend_from_slice(&[0xFF, marker]);
                    out.extend_from_slice(&data[pos..end]);
                };
                match marker {
                    APP0 if payload.starts_with(JFIF) && payload.len() >= JFIF_HEADER_LEN => {
                        let thumbnail = payload[12] != 0 || payload[13] != 0;
                        if thumbnail || payload.len() != JFIF_HEADER_LEN {
                            changed = true;
                            out.extend_from_slice(&[0xFF, APP0, 0x00, 0x10]);
                            out.extend_from_slice(&payload[..12]);
                            out.extend_from_slice(&[0, 0]);
                        } else {
                            segment(&mut out);
                        }
                    }
                    APP1 if payload.starts_with(EXIF) && !exif_seen => {
                        exif_seen = true;
                        let orientation = tiff::orientation(&payload[EXIF.len()..]).unwrap_or(1);
                        if orientation == 1 {
                            changed = true;
                        } else {
                            let minimal = minimal_exif(orientation);
                            changed |= minimal[2..] != data[pos..end];
                            out.extend_from_slice(&minimal);
                        }
                    }
                    APP2 if payload.starts_with(ICC_PROFILE) => segment(&mut out),
                    APP14 if payload.starts_with(ADOBE) => segment(&mut out),
                    APP0..=APP15 | COM => changed = true,
                    SOS => {
                        segment(&mut out);
                        let scan_end = entropy_coded_end(data, end)?;
                        out.extend_from_slice(&data[end..scan_end]);
                        pos = scan_end;
                        continue;
                    }
                    // SOFn, DHT, DAC; DQT, DNL, DRI, DHP, EXP.
                    0xC0..=0xCF | 0xDB..=0xDF => segment(&mut out),
                    // JPEG-LS, JPEG XT and reserved markers: we cannot vouch
                    // for what they carry, so the caller re-encodes.
                    _ => return Err(Malformed),
                }
                pos = end;
            }
        }
    }
}

/// The Orientation of the first Exif segment before the image data.
pub(crate) fn orientation(data: &[u8]) -> Option<u8> {
    let mut pos = 2;
    loop {
        let (marker, after) = read_marker(data, pos).ok()?;
        pos = after;
        if matches!(marker, EOI | SOS | TEM | 0xD0..=0xD7) {
            return None;
        }
        let end = pos.checked_add(usize::from(be16(data, pos)?))?;
        let payload = data.get(pos.checked_add(2)?..end)?;
        if marker == APP1 && payload.starts_with(EXIF) {
            return tiff::orientation(&payload[EXIF.len()..]);
        }
        pos = end;
    }
}

/// Read the marker at `pos`, skipping fill bytes. Returns it and the offset
/// just past it.
fn read_marker(data: &[u8], mut pos: usize) -> Result<(u8, usize), Malformed> {
    if data.get(pos) != Some(&0xFF) {
        return Err(Malformed);
    }
    while data.get(pos) == Some(&0xFF) {
        pos += 1;
    }
    match data.get(pos) {
        Some(&marker) if marker != 0x00 && marker != SOI => Ok((marker, pos + 1)),
        _ => Err(Malformed),
    }
}

/// The offset of the first marker after the coded data that starts at `from`:
/// inside a scan, 0xFF is followed by a stuffed 0x00 or a restart marker.
fn entropy_coded_end(data: &[u8], mut from: usize) -> Result<usize, Malformed> {
    loop {
        let ff = from
            + data[from..]
                .iter()
                .position(|&b| b == 0xFF)
                .ok_or(Malformed)?;
        match data.get(ff + 1) {
            Some(0x00 | 0xD0..=0xD7) => from = ff + 2,
            Some(_) => return Ok(ff),
            None => return Err(Malformed),
        }
    }
}

/// An APP1 segment holding a big-endian TIFF with one IFD0 entry: Orientation.
fn minimal_exif(orientation: u8) -> [u8; 36] {
    let mut s = [0u8; 36];
    s[..4].copy_from_slice(&[0xFF, APP1, 0x00, 0x22]);
    s[4..10].copy_from_slice(EXIF);
    s[10..18].copy_from_slice(b"MM\0*\0\0\0\x08");
    s[18..20].copy_from_slice(&[0x00, 0x01]);
    s[20..32].copy_from_slice(&[0x01, 0x12, 0x00, 0x03, 0, 0, 0, 1, 0, orientation, 0, 0]);
    // Bytes 32..36 stay zero: no next IFD.
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn minimal_exif_is_well_formed() {
        let exif = minimal_exif(6);
        assert_eq!(
            usize::from(u16::from_be_bytes([exif[2], exif[3]])),
            exif.len() - 2
        );
        assert_eq!(tiff::orientation(&exif[10..]), Some(6));
    }

    fn segment(marker: u8, payload: &[u8]) -> Vec<u8> {
        let mut s = vec![0xFF, marker];
        s.extend_from_slice(&u16::try_from(payload.len() + 2).unwrap().to_be_bytes());
        s.extend_from_slice(payload);
        s
    }

    /// A structurally valid JPEG: `head` segments, then a frame, one scan, EOI.
    fn jpeg(head: &[Vec<u8>]) -> Vec<u8> {
        let mut j = vec![0xFF, SOI];
        for s in head {
            j.extend_from_slice(s);
        }
        j.extend(segment(0xDB, &[0; 65]));
        j.extend(segment(0xC0, &[8, 0, 1, 0, 1, 1, 1, 0x11, 0]));
        j.extend(segment(SOS, &[1, 1, 0, 0, 63, 0]));
        j.extend_from_slice(&[0x12, 0xFF, 0x00, 0x34, 0xFF, 0xD0, 0x56]);
        j.extend_from_slice(&[0xFF, EOI]);
        j
    }

    fn exif_with_orientation(orientation: u8) -> Vec<u8> {
        minimal_exif(orientation)[4..].to_vec()
    }

    fn jfif(thumbnail: &[u8]) -> Vec<u8> {
        let mut p = b"JFIF\0\x01\x02\x00\x00\x48\x00\x48".to_vec();
        p.extend_from_slice(if thumbnail.is_empty() {
            &[0, 0]
        } else {
            &[1, 1]
        });
        p.extend_from_slice(thumbnail);
        p
    }

    #[test]
    fn a_file_with_nothing_to_drop_is_clean() {
        let clean = jpeg(&[segment(APP0, &jfif(&[])), minimal_exif(6).to_vec()]);
        assert!(scrub(&clean).unwrap().is_none());
    }

    #[test]
    fn upright_exif_is_dropped_entirely() {
        let out = scrub(&jpeg(&[segment(APP1, &exif_with_orientation(1))]))
            .unwrap()
            .unwrap();
        assert_eq!(out, jpeg(&[]));
    }

    #[test]
    fn jfif_thumbnail_is_dropped() {
        let out = scrub(&jpeg(&[segment(APP0, &jfif(&[9, 9, 9]))]))
            .unwrap()
            .unwrap();
        assert_eq!(out, jpeg(&[segment(APP0, &jfif(&[]))]));
    }

    #[test]
    fn only_the_first_exif_counts() {
        let two = jpeg(&[
            segment(APP1, &exif_with_orientation(3)),
            segment(APP1, &exif_with_orientation(8)),
        ]);
        let out = scrub(&two).unwrap().unwrap();
        assert_eq!(out, jpeg(&[minimal_exif(3).to_vec()]));
        assert_eq!(orientation(&two), Some(3));
    }

    #[test]
    fn markers_we_cannot_vouch_for_are_malformed() {
        assert!(scrub(&jpeg(&[segment(0xF7, &[1, 2, 3])])).is_err());
        let mut no_eoi = jpeg(&[]);
        no_eoi.truncate(no_eoi.len() - 2);
        assert!(scrub(&no_eoi).is_err());
    }

    #[test]
    fn coded_data_scan_skips_stuffing_and_restarts() {
        let data = [0x12, 0xFF, 0x00, 0x34, 0xFF, 0xD3, 0x56, 0xFF, 0xFF, 0xD9];
        assert_eq!(entropy_coded_end(&data, 0).unwrap(), 7);
        assert!(entropy_coded_end(&[0x12, 0x34], 0).is_err());
        assert!(entropy_coded_end(&[0x12, 0xFF], 0).is_err());
    }
}
