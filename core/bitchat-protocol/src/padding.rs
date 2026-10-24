//! PKCS#7-style frame padding (`MessagePadding` in both clients).
//!
//! Every pad byte equals the pad length and `unpad` verifies that run. Two
//! limits matter: the pad length must fit one byte, so a frame more than 255
//! bytes below its bucket is emitted unpadded rather than padded to a smaller
//! bucket; and the reference clients today pad only Noise frames
//! (`BLEOutboundPacketPolicy.padsBLEFrame`), everything else travels at its
//! natural length. Decoders accept both shapes, so the choice is airtime, not
//! compatibility — see [`crate::packet::PaddingPolicy`].

/// The bucket sizes a padded frame is rounded up to.
pub const BLOCK_SIZES: [usize; 4] = [256, 512, 1024, 2048];

/// Smallest bucket that fits `data_size + 16` (an AES-GCM-tag allowance kept
/// for compatibility); the size itself when nothing fits (large frames are
/// fragmented, not padded).
pub fn optimal_block_size(data_size: usize) -> usize {
    let total = data_size + 16;
    for &b in &BLOCK_SIZES {
        if total <= b {
            return b;
        }
    }
    data_size
}

/// Pad to `target` when `data` is shorter and the gap is 1..=255; otherwise
/// return the data unchanged (== `MessagePadding.pad`).
pub fn pad(data: Vec<u8>, target: usize) -> Vec<u8> {
    if data.len() >= target {
        return data;
    }
    let needed = target - data.len();
    if needed == 0 || needed > 255 {
        return data;
    }
    let mut out = data;
    out.extend(std::iter::repeat_n(needed as u8, needed));
    out
}

/// Strip a valid PKCS#7 run from the tail; return the data unchanged when the
/// tail is not a valid run (== `MessagePadding.unpad`).
pub fn unpad(data: &[u8]) -> Vec<u8> {
    let Some(&last) = data.last() else {
        return Vec::new();
    };
    let pad_len = last as usize;
    if pad_len == 0 || pad_len > data.len() {
        return data.to_vec();
    }
    let start = data.len() - pad_len;
    if data[start..].iter().any(|&b| b != last) {
        return data.to_vec();
    }
    data[..start].to_vec()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn block_size_matches_reference_rules() {
        assert_eq!(optimal_block_size(0), 256);
        assert_eq!(optimal_block_size(240), 256);
        assert_eq!(optimal_block_size(241), 512);
        assert_eq!(optimal_block_size(496), 512);
        assert_eq!(optimal_block_size(497), 1024);
        assert_eq!(optimal_block_size(2032), 2048);
        assert_eq!(optimal_block_size(2033), 2033);
    }

    #[test]
    fn pad_and_unpad_roundtrip_and_limits() {
        let d = vec![1u8, 2, 3];
        let p = pad(d.clone(), 256);
        assert_eq!(p.len(), 256);
        assert!(p[3..].iter().all(|&b| b == 253));
        assert_eq!(unpad(&p), d);
        // Gap over 255: unchanged.
        assert_eq!(pad(vec![0u8; 10], 300), vec![0u8; 10]);
        // Already at/over target: unchanged.
        assert_eq!(pad(vec![0u8; 256], 256).len(), 256);
        // Invalid run: unchanged.
        assert_eq!(unpad(&[1, 2, 3, 2]), vec![1, 2, 3, 2]);
        assert_eq!(unpad(&[1, 2, 2, 2]), vec![1, 2]);
        assert_eq!(unpad(&[4, 4, 4, 4]), Vec::<u8>::new());
        assert_eq!(unpad(&[]), Vec::<u8>::new());
        // Zero marker is not padding.
        assert_eq!(unpad(&[5, 0]), vec![5, 0]);
    }
}
