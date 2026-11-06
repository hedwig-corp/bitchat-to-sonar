//! The Orientation tag of a TIFF structure: a TIFF file, or the body of a JPEG
//! Exif segment (which is a TIFF header plus IFDs).

const ORIENTATION: u16 = 0x0112;
const SHORT: u16 = 3;

/// A big-endian TIFF structure whose IFD0 holds `orientation` and nothing
/// else: 26 bytes with an Orientation tag, 14 without.
pub(crate) fn minimal(orientation: Option<u8>) -> Vec<u8> {
    let mut tiff = b"MM\0*\0\0\0\x08".to_vec();
    match orientation {
        Some(value) => {
            tiff.extend_from_slice(&[0, 1]);
            tiff.extend_from_slice(&ORIENTATION.to_be_bytes());
            tiff.extend_from_slice(&SHORT.to_be_bytes());
            tiff.extend_from_slice(&1u32.to_be_bytes());
            tiff.extend_from_slice(&[0, value, 0, 0]);
        }
        None => tiff.extend_from_slice(&[0, 0]),
    }
    // No next IFD.
    tiff.extend_from_slice(&[0; 4]);
    tiff
}

/// The IFD0 Orientation value (1–8), if present and well formed.
pub(crate) fn orientation(tiff: &[u8]) -> Option<u8> {
    let little_endian = match tiff.get(..4)? {
        b"II*\0" => true,
        b"MM\0*" => false,
        _ => return None,
    };
    let u16_at = |at: usize| -> Option<u16> {
        let b = tiff.get(at..at.checked_add(2)?)?;
        Some(if little_endian {
            u16::from_le_bytes([b[0], b[1]])
        } else {
            u16::from_be_bytes([b[0], b[1]])
        })
    };
    let u32_at = |at: usize| -> Option<u32> {
        let b = tiff.get(at..at.checked_add(4)?)?;
        Some(if little_endian {
            u32::from_le_bytes([b[0], b[1], b[2], b[3]])
        } else {
            u32::from_be_bytes([b[0], b[1], b[2], b[3]])
        })
    };
    let ifd = usize::try_from(u32_at(4)?).ok()?;
    let entries = usize::from(u16_at(ifd)?);
    for index in 0..entries {
        let entry = ifd.checked_add(2)?.checked_add(index.checked_mul(12)?)?;
        if u16_at(entry)? != ORIENTATION {
            continue;
        }
        if u16_at(entry.checked_add(2)?)? != SHORT || u32_at(entry.checked_add(4)?)? != 1 {
            return None;
        }
        // A single SHORT sits left-justified in the 4-byte value field.
        let value = u16_at(entry.checked_add(8)?)?;
        return u8::try_from(value).ok().filter(|v| (1..=8).contains(v));
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tiff(little_endian: bool, tag: u16, kind: u16, count: u32, value: u16) -> Vec<u8> {
        let u16b = |v: u16| {
            if little_endian {
                v.to_le_bytes()
            } else {
                v.to_be_bytes()
            }
        };
        let u32b = |v: u32| {
            if little_endian {
                v.to_le_bytes()
            } else {
                v.to_be_bytes()
            }
        };
        let mut b = if little_endian {
            b"II*\0".to_vec()
        } else {
            b"MM\0*".to_vec()
        };
        b.extend_from_slice(&u32b(8));
        b.extend_from_slice(&u16b(1));
        b.extend_from_slice(&u16b(tag));
        b.extend_from_slice(&u16b(kind));
        b.extend_from_slice(&u32b(count));
        b.extend_from_slice(&u16b(value));
        b.extend_from_slice(&[0, 0, 0, 0, 0, 0]);
        b
    }

    #[test]
    fn reads_both_byte_orders() {
        assert_eq!(orientation(&tiff(true, ORIENTATION, SHORT, 1, 6)), Some(6));
        assert_eq!(orientation(&tiff(false, ORIENTATION, SHORT, 1, 8)), Some(8));
    }

    #[test]
    fn rejects_out_of_range_and_wrong_types() {
        assert_eq!(orientation(&tiff(true, ORIENTATION, SHORT, 1, 9)), None);
        assert_eq!(orientation(&tiff(true, ORIENTATION, SHORT, 1, 0)), None);
        assert_eq!(orientation(&tiff(true, ORIENTATION, 4, 1, 6)), None);
        assert_eq!(orientation(&tiff(true, 0x010F, SHORT, 1, 6)), None);
    }

    #[test]
    fn minimal_holds_only_the_orientation() {
        assert_eq!(orientation(&minimal(Some(6))), Some(6));
        assert_eq!(minimal(Some(6)).len(), 26);
        assert_eq!(orientation(&minimal(None)), None);
        assert_eq!(minimal(None).len(), 14);
    }

    #[test]
    fn survives_truncation_and_bogus_offsets() {
        let good = tiff(false, ORIENTATION, SHORT, 1, 3);
        for len in 0..good.len() {
            let _ = orientation(&good[..len]);
        }
        let mut bogus = good.clone();
        bogus[4..8].copy_from_slice(&u32::MAX.to_be_bytes());
        assert_eq!(orientation(&bogus), None);
    }
}
