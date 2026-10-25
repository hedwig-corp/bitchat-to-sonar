//! Payload compression (`CompressionUtil`).
//!
//! Both reference clients compress a payload when it is at least
//! [`THRESHOLD_BYTES`] long and fewer than 90% of its (first 256) byte values
//! are distinct, and only keep the result when it is strictly smaller. The
//! stream is **raw DEFLATE** (Apple `COMPRESSION_ZLIB` via `libcompression`;
//! `java.util.zip.Deflater(nowrap = true)`). Android's inflater additionally
//! accepts a zlib-wrapped stream; this crate does too.
//!
//! DEFLATE output is not canonical: different encoders give different byte
//! strings for one input. That is why a verifier must never re-compress a
//! received payload to rebuild a signature preimage — see
//! [`crate::packet::WirePayload`].
//!
//! The encoder here is reference zlib at [`LEVEL`] 5, which is exactly what
//! Apple's `COMPRESSION_ZLIB` emits (measured byte for byte over a corpus that
//! separates the levels; SPEC.md §3). Stock bitchat iOS still rebuilds
//! preimages by re-compressing, so emitting Apple's stream is what lets our
//! signed compressible frames verify there. bitchat-android uses
//! `java.util.zip.Deflater` at its default, level 6: identical to level 5 for
//! most payloads, not for all — Android verifies over the received bytes, so
//! that difference costs nothing there.

use std::io::Read;

use flate2::read::{DeflateDecoder, ZlibDecoder};
use flate2::write::DeflateEncoder;
use flate2::Compression;

/// Payloads shorter than this are never compressed.
pub const THRESHOLD_BYTES: usize = 100;

/// zlib compression level: Apple `COMPRESSION_ZLIB`'s.
pub const LEVEL: u32 = 5;

/// The reference heuristic: long enough, and not already high-entropy.
pub fn should_compress(payload: &[u8]) -> bool {
    if payload.len() < THRESHOLD_BYTES {
        return false;
    }
    let mut seen = [false; 256];
    let mut unique = 0usize;
    for &b in payload {
        if !seen[b as usize] {
            seen[b as usize] = true;
            unique += 1;
        }
    }
    let sample = payload.len().min(256);
    (unique as f64) / (sample as f64) < 0.9
}

/// Raw-DEFLATE `payload`; `None` when below the threshold or when the result
/// is not strictly smaller (the encoder then sends the payload uncompressed).
pub fn compress(payload: &[u8]) -> Option<Vec<u8>> {
    if payload.len() < THRESHOLD_BYTES {
        return None;
    }
    let mut enc = DeflateEncoder::new(Vec::with_capacity(payload.len()), Compression::new(LEVEL));
    std::io::Write::write_all(&mut enc, payload).ok()?;
    let out = enc.finish().ok()?;
    if out.is_empty() || out.len() >= payload.len() {
        return None;
    }
    Some(out)
}

/// Inflate to exactly `original_size` bytes. Raw DEFLATE first; a stream that
/// carries a zlib header is retried as zlib (Android emits raw but inflates
/// both). Anything that does not produce exactly `original_size` bytes is
/// rejected: a declared size is a promise, not a hint.
pub fn decompress(compressed: &[u8], original_size: usize) -> Option<Vec<u8>> {
    if compressed.is_empty() || original_size == 0 {
        return None;
    }
    if let Some(out) = inflate_exact(DeflateDecoder::new(compressed), original_size) {
        return Some(out);
    }
    if looks_like_zlib(compressed) {
        return inflate_exact(ZlibDecoder::new(compressed), original_size);
    }
    None
}

fn inflate_exact<R: Read>(reader: R, original_size: usize) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(original_size);
    // Read at most one byte past the promise so an over-long stream is
    // detected without unbounded allocation.
    let mut limited = reader.take(original_size as u64 + 1);
    limited.read_to_end(&mut out).ok()?;
    if out.len() != original_size {
        return None;
    }
    Some(out)
}

fn looks_like_zlib(data: &[u8]) -> bool {
    if data.len() < 2 {
        return false;
    }
    let cmf = data[0] as u16;
    let flg = data[1] as u16;
    (cmf & 0x0F) == 8 && (cmf >> 4) <= 7 && ((cmf << 8) | flg) % 31 == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn heuristic_matches_reference() {
        assert!(!should_compress(&[0u8; 99]));
        assert!(should_compress(&[0u8; 100]));
        let unique: Vec<u8> = (0..100u8).collect();
        assert!(!should_compress(&unique)); // ratio exactly 1.0
        let all: Vec<u8> = (0..=255u8).collect();
        assert!(!should_compress(&all));
        let text = b"compress-me".repeat(30);
        assert!(should_compress(&text));
    }

    #[test]
    fn compress_roundtrip_raw_and_zlib() {
        let text = b"The quick brown fox jumps over the lazy dog. ".repeat(25);
        let c = compress(&text).expect("compressible");
        assert!(c.len() < text.len());
        assert_eq!(decompress(&c, text.len()).unwrap(), text);
        // Wrong declared size is rejected both ways.
        assert!(decompress(&c, text.len() - 1).is_none());
        assert!(decompress(&c, text.len() + 1).is_none());
        // zlib-wrapped stream of the same data is accepted.
        let mut z = flate2::write::ZlibEncoder::new(Vec::new(), Compression::default());
        std::io::Write::write_all(&mut z, &text).unwrap();
        let z = z.finish().unwrap();
        assert!(looks_like_zlib(&z));
        assert_eq!(decompress(&z, text.len()).unwrap(), text);
    }

    #[test]
    fn incompressible_input_is_left_alone() {
        let noise: Vec<u8> = (0..300u32).map(|i| (i * 7919 % 251) as u8).collect();
        // Either the heuristic or the size check declines; never a larger frame.
        if let Some(c) = compress(&noise) {
            assert!(c.len() < noise.len());
        }
        assert!(compress(&[1u8; 50]).is_none());
        assert!(decompress(&[], 10).is_none());
        assert!(decompress(&[1, 2, 3], 0).is_none());
    }
}
