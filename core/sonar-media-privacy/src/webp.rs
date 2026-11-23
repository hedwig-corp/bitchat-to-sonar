//! WebP: drop the `EXIF` and `XMP ` chunks (and anything unknown), clear the
//! matching VP8X flags, and fix the RIFF size. Animation (`ANIM`/`ANMF`),
//! alpha and the ICC profile stay.

use crate::{le32, Malformed, Rewrite};

const KEEP: [&[u8; 4]; 7] = [
    b"VP8 ", b"VP8L", b"VP8X", b"ALPH", b"ANIM", b"ANMF", b"ICCP",
];
const VP8X_EXIF: u8 = 0x08;
const VP8X_XMP: u8 = 0x04;
/// `RIFF`, size, `WEBP`.
const HEADER_LEN: usize = 12;
/// Chunk FourCC and size.
const CHUNK_HEADER_LEN: usize = 8;

pub(crate) fn scrub(data: &[u8]) -> Rewrite {
    let riff_len = usize::try_from(le32(data, 4).ok_or(Malformed)?).map_err(|_| Malformed)?;
    let riff_end = riff_len
        .checked_add(8)
        .filter(|&end| end >= HEADER_LEN && end <= data.len())
        .ok_or(Malformed)?;
    let mut out = Vec::with_capacity(riff_end);
    out.extend_from_slice(&data[..HEADER_LEN]);
    let mut changed = riff_end < data.len();
    let mut flags_at = None;
    let mut pos = HEADER_LEN;
    while pos < riff_end {
        let body = pos + CHUNK_HEADER_LEN;
        if body > riff_end {
            return Err(Malformed);
        }
        let kind = &data[pos..pos + 4];
        let len = usize::try_from(le32(data, pos + 4).ok_or(Malformed)?).map_err(|_| Malformed)?;
        let body_end = body
            .checked_add(len)
            .filter(|&end| end <= riff_end)
            .ok_or(Malformed)?;
        // Chunks pad to an even length; tolerate a missing pad on the last one.
        let end = (body_end + (len & 1)).min(riff_end);
        if KEEP.iter().any(|keep| keep.as_slice() == kind) {
            if kind == b"VP8X" {
                if len < 10 {
                    return Err(Malformed);
                }
                flags_at = Some(out.len() + CHUNK_HEADER_LEN);
            }
            out.extend_from_slice(&data[pos..end]);
        } else {
            changed = true;
        }
        pos = end;
    }
    if let Some(at) = flags_at {
        let cleared = out[at] & !(VP8X_EXIF | VP8X_XMP);
        changed |= cleared != out[at];
        out[at] = cleared;
    }
    if !changed {
        return Ok(None);
    }
    let riff_len = u32::try_from(out.len() - 8).map_err(|_| Malformed)?;
    out[4..8].copy_from_slice(&riff_len.to_le_bytes());
    Ok(Some(out))
}
