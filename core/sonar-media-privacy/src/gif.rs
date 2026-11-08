//! GIF: keep the image data and the extensions that drive rendering and
//! animation; drop comments and every other application extension (XMP lives
//! in an `XMP DataXMP` application extension).

use crate::{Malformed, Rewrite};

const EXTENSION: u8 = 0x21;
const IMAGE: u8 = 0x2C;
const TRAILER: u8 = 0x3B;
const PLAIN_TEXT: u8 = 0x01;
const GRAPHIC_CONTROL: u8 = 0xF9;
const APPLICATION: u8 = 0xFF;

/// Header (6) plus logical screen descriptor (7).
const PREAMBLE_LEN: usize = 13;
/// Image separator, position, size and packed fields.
const IMAGE_DESCRIPTOR_LEN: usize = 10;

pub(crate) fn scrub(data: &[u8]) -> Rewrite {
    let packed = *data.get(10).ok_or(Malformed)?;
    let mut pos = PREAMBLE_LEN + color_table_len(packed);
    let mut out = Vec::with_capacity(data.len());
    out.extend_from_slice(data.get(..pos).ok_or(Malformed)?);
    let mut changed = false;
    loop {
        match *data.get(pos).ok_or(Malformed)? {
            TRAILER => {
                out.push(TRAILER);
                changed |= pos + 1 < data.len();
                return Ok(changed.then_some(out));
            }
            IMAGE => {
                let packed = *data.get(pos + 9).ok_or(Malformed)?;
                // Descriptor, local colour table, LZW minimum code size, data.
                let code_size = pos + IMAGE_DESCRIPTOR_LEN + color_table_len(packed);
                let end = skip_sub_blocks(data, code_size + 1)?;
                out.extend_from_slice(&data[pos..end]);
                pos = end;
            }
            EXTENSION => {
                let label = *data.get(pos + 1).ok_or(Malformed)?;
                let end = skip_sub_blocks(data, pos + 2)?;
                let keep = match label {
                    GRAPHIC_CONTROL | PLAIN_TEXT => true,
                    APPLICATION => is_animation_extension(&data[pos + 2..end]),
                    _ => false,
                };
                if keep {
                    out.extend_from_slice(&data[pos..end]);
                } else {
                    changed = true;
                }
                pos = end;
            }
            _ => return Err(Malformed),
        }
    }
}

fn color_table_len(packed: u8) -> usize {
    if packed & 0x80 == 0 {
        0
    } else {
        3 << ((packed & 0x07) + 1)
    }
}

/// The offset just past a chain of data sub-blocks and its 0 terminator.
fn skip_sub_blocks(data: &[u8], mut pos: usize) -> Result<usize, Malformed> {
    loop {
        let size = usize::from(*data.get(pos).ok_or(Malformed)?);
        pos += 1 + size;
        if size == 0 {
            return Ok(pos);
        }
    }
}

/// The looping extensions (Netscape's and its AnimExts twin).
fn is_animation_extension(blocks: &[u8]) -> bool {
    blocks.first() == Some(&11)
        && [b"NETSCAPE2.0", b"ANIMEXTS1.0"]
            .iter()
            .any(|id| blocks.get(1..12) == Some(id.as_slice()))
}
