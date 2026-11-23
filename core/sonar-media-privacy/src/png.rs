//! PNG: keep an allowlist of chunks that change what a decoder draws.
//!
//! The list is Signal-iOS's (`NormalizedImage.pngChunkTypesToKeep`) plus the
//! HDR colour chunks (`cICP`, `mDCv`, `cLLi`). Everything else goes: `eXIf`,
//! the text chunks (`tEXt`, `zTXt`, `iTXt` — where XMP lives), `tIME`, and
//! private chunks. Chunks are copied whole, so their CRCs stay valid.

use crate::{be32, Malformed, Rewrite};

pub(crate) const SIGNATURE: &[u8] = b"\x89PNG\r\n\x1a\n";

#[rustfmt::skip]
const KEEP: [&[u8; 4]; 19] = [
    // Critical.
    b"IHDR", b"PLTE", b"IDAT", b"IEND",
    // Ancillary chunks that affect rendering.
    b"tRNS", b"cHRM", b"gAMA", b"iCCP", b"sRGB", b"sBIT", b"bKGD", b"pHYs", b"sPLT",
    b"cICP", b"mDCv", b"cLLi",
    // APNG.
    b"acTL", b"fcTL", b"fdAT",
];

/// The PNG spec's ceiling on a chunk length.
const MAX_CHUNK_LEN: usize = 0x7FFF_FFFF;

pub(crate) fn scrub(data: &[u8]) -> Rewrite {
    let mut out = Vec::with_capacity(data.len());
    out.extend_from_slice(SIGNATURE);
    let mut changed = false;
    let mut pos = SIGNATURE.len();
    loop {
        let len = usize::try_from(be32(data, pos).ok_or(Malformed)?).map_err(|_| Malformed)?;
        let kind = data.get(pos + 4..pos + 8).ok_or(Malformed)?;
        // Length, type, data, CRC.
        let end = (len <= MAX_CHUNK_LEN)
            .then(|| pos.checked_add(12)?.checked_add(len))
            .flatten()
            .filter(|&end| end <= data.len())
            .ok_or(Malformed)?;
        let first = pos == SIGNATURE.len();
        if !kind.iter().all(u8::is_ascii_alphabetic) || (first && kind != b"IHDR") {
            return Err(Malformed);
        }
        if KEEP.iter().any(|keep| keep.as_slice() == kind) {
            out.extend_from_slice(&data[pos..end]);
        } else {
            changed = true;
        }
        pos = end;
        if kind == b"IEND" {
            changed |= pos < data.len();
            return Ok(changed.then_some(out));
        }
    }
}
