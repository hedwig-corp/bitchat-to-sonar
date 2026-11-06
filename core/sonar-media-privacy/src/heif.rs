//! HEIF (HEIC) and AVIF: zero every byte that no image item points at.
//!
//! Both are ISO-BMFF files. The `meta` box lists the items (`iinf`) and says
//! where each item's bytes are (`iloc`); the bytes sit in `mdat`, or in `idat`
//! inside `meta`. Exif is an `Exif` item and XMP a `mime` item, and an editor
//! that deletes one can leave its bytes behind with nothing pointing at them.
//!
//! So the rewrite keeps only what a decoder reads. In the data regions —
//! `mdat`, `idat` and the payload of every `free`/`skip` box — each byte that
//! is not part of an image item is set to zero. No byte moves and no box
//! changes size, so every `iloc` offset stays valid and the coded image data,
//! thumbnails and auxiliary images (alpha, depth, gain maps) are copied byte
//! for byte. Orientation, colour and HDR are item properties (`irot`, `imir`,
//! `colr`, `clli`…), not metadata, so they stay.
//!
//! The metadata items stay where they are, emptied. XMP and the other MIME and
//! URI items are all zeros. An `Exif` item is the one exception: libavif, and
//! with it Chrome, Android and Pillow, rejects the whole file when an Exif item
//! does not lead to a TIFF header. So it becomes a minimal Exif that holds only
//! the Orientation tag the original had (as the JPEG rewrite keeps it), padded
//! with zeros.
//!
//! Anything this cannot vouch for is [`Malformed`], so the caller re-encodes:
//! an unknown box, item type or item property (user descriptions `udes`,
//! timestamps `crtt`/`mdft`/`itai`, camera models `cmin`/`cmex`); image
//! sequences (`moov`); JPEG items, whose bitstream can carry its own Exif;
//! protected items; data in another file or built from another item; metadata
//! that shares bytes with an image or sits outside the data regions; and an
//! Exif item too short to hold the minimal Exif.
//!
//! Not covered: item and handler names in `infe` and `hdlr` (encoder labels
//! such as `Color`), and whatever the coded data itself carries (HEVC SEI, AV1
//! metadata OBUs) — the same line the JPEG rewrite draws at the entropy-coded
//! scan.

use std::ops::Range;

use crate::{be16, be32, be64, tiff, Malformed, Rewrite};

/// Items a decoder draws: coded, derived and tone-mapped images.
#[rustfmt::skip]
const IMAGE_ITEMS: [&[u8; 4]; 12] = [
    b"hvc1", b"hvt1", b"lhv1", b"av01", b"avc1", b"vvc1", b"unci", b"mski",
    b"grid", b"iden", b"iovl", b"tmap",
];

/// Items that only describe an image, besides `Exif`: XMP and other MIME
/// payloads, and URIs.
const METADATA_ITEMS: [&[u8; 4]; 2] = [b"mime", b"uri "];

/// An Exif item: the offset of the TIFF header past these four bytes, then
/// the APP1 identifier every encoder writes before it.
const EXIF_PREFIX: &[u8] = b"\0\0\0\x06Exif\0\0";

/// Item properties that decide what a decoder draws.
#[rustfmt::skip]
const PROPERTIES: [&[u8; 4]; 27] = [
    // Codec configuration.
    b"hvcC", b"lhvC", b"av1C", b"avcC", b"vvcC", b"uncC", b"cmpd",
    // Geometry and transforms.
    b"ispe", b"pasp", b"clap", b"irot", b"imir", b"rloc", b"iscl",
    // Colour and HDR.
    b"colr", b"pixi", b"cloc", b"clli", b"mdcv", b"cclv", b"amve",
    // Auxiliary images, layers and operating points.
    b"auxC", b"lsel", b"oinf", b"tols", b"a1op", b"a1lx",
];

/// Boxes whose payload means nothing: zeroed like data nothing points at.
const PADDING: [&[u8; 4]; 2] = [b"free", b"skip"];

/// A box: its type, and where its payload starts and ends.
#[derive(Clone, Copy)]
struct Bmff {
    kind: [u8; 4],
    body: usize,
    end: usize,
}

impl Bmff {
    fn payload(self) -> Range<usize> {
        self.body..self.end
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Item {
    Image,
    Exif,
    Metadata,
}

/// Byte ranges of the file, from what `meta` says.
#[derive(Default)]
struct Layout {
    /// Payloads to zero, except where an image item's bytes are.
    regions: Vec<Range<usize>>,
    /// Bytes of image items.
    images: Vec<Range<usize>>,
    /// Bytes of metadata items, and of items no `infe` describes.
    metadata: Vec<Range<usize>>,
    /// The extents of each Exif item, in order (they are in `metadata` too).
    exif: Vec<Vec<Range<usize>>>,
}

pub(crate) fn scrub(data: &[u8]) -> Rewrite {
    let mut layout = Layout::default();
    let mut meta = None;
    for (index, top) in boxes(data, 0..data.len())?.into_iter().enumerate() {
        match &top.kind {
            b"ftyp" if index == 0 => {}
            b"meta" if meta.is_none() => meta = Some(top),
            b"mdat" => layout.regions.push(top.payload()),
            kind if PADDING.contains(&kind) => layout.regions.push(top.payload()),
            _ => return Err(Malformed),
        }
    }
    read_meta(data, meta.ok_or(Malformed)?, &mut layout)?;
    let images = merge(layout.images);
    let metadata = merge(layout.metadata);
    // Zeroing them would break the image, and keeping them keeps the metadata.
    if metadata.iter().any(|range| overlaps(&images, range)) {
        return Err(Malformed);
    }

    let mut out = data.to_vec();
    for region in &layout.regions {
        out[region.clone()].fill(0);
    }
    for image in &images {
        out[image.clone()].copy_from_slice(&data[image.clone()]);
    }
    // Metadata outside the data regions was not zeroed.
    if metadata
        .iter()
        .any(|range| out[range.clone()].iter().any(|&b| b != 0))
    {
        return Err(Malformed);
    }
    let mut budget = data.len();
    for extents in &layout.exif {
        write_minimal_exif(data, &mut out, extents, &mut budget)?;
    }
    Ok((out.as_slice() != data).then_some(out))
}

/// Overwrite an Exif item, already zeroed, with an Exif that holds only the
/// Orientation the original had. Reading the originals costs at most `budget`
/// bytes in all, however many items share the same bytes.
fn write_minimal_exif(
    data: &[u8],
    out: &mut [u8],
    extents: &[Range<usize>],
    budget: &mut usize,
) -> Result<(), Malformed> {
    let len = extents
        .iter()
        .try_fold(0usize, |len, extent| len.checked_add(extent.len()))
        .ok_or(Malformed)?;
    *budget = budget.checked_sub(len).ok_or(Malformed)?;
    let original: Vec<u8> = extents
        .iter()
        .flat_map(|extent| &data[extent.clone()])
        .copied()
        .collect();
    let orientation = be32(&original, 0)
        .and_then(|offset| usize::try_from(offset).ok()?.checked_add(4))
        .and_then(|tiff_at| original.get(tiff_at..))
        .and_then(tiff::orientation);
    let exif = [EXIF_PREFIX, &tiff::minimal(orientation)].concat();
    if exif.len() > len {
        return Err(Malformed);
    }
    let mut written = 0;
    for extent in extents {
        let n = (exif.len() - written).min(extent.len());
        out[extent.start..extent.start + n].copy_from_slice(&exif[written..written + n]);
        written += n;
    }
    Ok(())
}

/// Whether `range` shares a byte with any of `sorted`, which are disjoint.
fn overlaps(sorted: &[Range<usize>], range: &Range<usize>) -> bool {
    let first_after = sorted.partition_point(|other| other.end <= range.start);
    sorted
        .get(first_after)
        .is_some_and(|other| other.start < range.end)
}

fn read_meta(data: &[u8], meta: Bmff, layout: &mut Layout) -> Result<(), Malformed> {
    let (version, fields) = full_box(data, meta)?;
    if version != 0 {
        return Err(Malformed);
    }
    let (mut handler, mut properties) = (false, false);
    let (mut items, mut iloc, mut idat) = (None, None, None);
    for child in boxes(data, fields..meta.end)? {
        match &child.kind {
            b"hdlr" if !handler => {
                // Version and flags, pre_defined, then the handler type.
                let kind = data.get(child.body + 8..child.body + 12);
                if child.body + 12 > child.end || kind != Some(b"pict") {
                    return Err(Malformed);
                }
                handler = true;
            }
            b"iinf" if items.is_none() => items = Some(item_types(data, child)?),
            b"iloc" if iloc.is_none() => iloc = Some(child),
            b"idat" if idat.is_none() => {
                idat = Some(child.payload());
                layout.regions.push(child.payload());
            }
            b"iprp" if !properties => {
                check_properties(data, child, layout)?;
                properties = true;
            }
            b"dinf" | b"pitm" | b"iref" | b"grpl" => {}
            kind if PADDING.contains(&kind) => layout.regions.push(child.payload()),
            _ => return Err(Malformed),
        }
    }
    if !handler {
        return Err(Malformed);
    }
    let items = items.ok_or(Malformed)?;
    locate_items(data, iloc.ok_or(Malformed)?, &items, idat, layout)
}

/// Item ID and kind for every `infe` in `iinf`, sorted by ID.
fn item_types(data: &[u8], iinf: Bmff) -> Result<Vec<(u32, Item)>, Malformed> {
    let (version, fields) = full_box(data, iinf)?;
    let (count, first) = match version {
        0 => (u32::from(be16(data, fields).ok_or(Malformed)?), fields + 2),
        1 => (be32(data, fields).ok_or(Malformed)?, fields + 4),
        _ => return Err(Malformed),
    };
    if first > iinf.end {
        return Err(Malformed);
    }
    let entries = boxes(data, first..iinf.end)?;
    if usize::try_from(count).ok() != Some(entries.len()) {
        return Err(Malformed);
    }
    let mut items = Vec::with_capacity(entries.len());
    for infe in entries {
        let (version, fields) = full_box(data, infe)?;
        let (id, after) = match version {
            2 => (u32::from(be16(data, fields).ok_or(Malformed)?), fields + 2),
            3 => (be32(data, fields).ok_or(Malformed)?, fields + 4),
            // Versions 0 and 1 describe files, not image items.
            _ => return Err(Malformed),
        };
        // item_protection_index, then item_type.
        let protection = be16(data, after).ok_or(Malformed)?;
        let kind = data.get(after + 2..after + 6).ok_or(Malformed)?;
        if &infe.kind != b"infe" || after + 6 > infe.end || protection != 0 {
            return Err(Malformed);
        }
        let item = if IMAGE_ITEMS.iter().any(|k| k.as_slice() == kind) {
            Item::Image
        } else if kind == b"Exif" {
            Item::Exif
        } else if METADATA_ITEMS.iter().any(|k| k.as_slice() == kind) {
            Item::Metadata
        } else {
            return Err(Malformed);
        };
        items.push((id, item));
    }
    items.sort_unstable_by_key(|&(id, _)| id);
    if items.windows(2).any(|pair| pair[0].0 == pair[1].0) {
        return Err(Malformed);
    }
    Ok(items)
}

/// Every property must be one that draws the image; `ipma` only links them.
fn check_properties(data: &[u8], iprp: Bmff, layout: &mut Layout) -> Result<(), Malformed> {
    for child in boxes(data, iprp.payload())? {
        match &child.kind {
            b"ipco" => {
                for property in boxes(data, child.payload())? {
                    if PADDING.contains(&&property.kind) {
                        layout.regions.push(property.payload());
                    } else if !PROPERTIES.contains(&&property.kind) {
                        return Err(Malformed);
                    }
                }
            }
            b"ipma" => {}
            kind if PADDING.contains(&kind) => layout.regions.push(child.payload()),
            _ => return Err(Malformed),
        }
    }
    Ok(())
}

/// Sort each `iloc` extent into image or metadata bytes (versions 0–2).
fn locate_items(
    data: &[u8],
    iloc: Bmff,
    items: &[(u32, Item)],
    idat: Option<Range<usize>>,
    layout: &mut Layout,
) -> Result<(), Malformed> {
    let (version, fields) = full_box(data, iloc)?;
    if version > 2 {
        return Err(Malformed);
    }
    let mut iloc = Fields {
        data,
        pos: fields,
        end: iloc.end,
    };
    let sizes = iloc.read(2)?;
    let size = |shift: u32| match (sizes >> shift) & 0xF {
        n @ (0 | 4 | 8) => Ok(n as usize),
        _ => Err(Malformed),
    };
    let offset_size = size(12)?;
    let length_size = size(8)?;
    let base_offset_size = size(4)?;
    let index_size = if version == 0 { 0 } else { size(0)? };
    let id_size = if version < 2 { 2 } else { 4 };
    let count = iloc.read(id_size)?;
    let mut seen = Vec::new();
    // Each entry is at least six bytes, so a bogus count runs out of box.
    for _ in 0..count {
        let id = iloc.read(id_size)?;
        let method = if version == 0 { 0 } else { iloc.read(2)? & 0xF };
        let data_reference = iloc.read(2)?;
        let base = iloc.read(base_offset_size)?;
        let extents = iloc.read(2)?;
        let container = match method {
            0 => 0..data.len(),
            1 => idat.clone().ok_or(Malformed)?,
            // 2: bytes taken from another item.
            _ => return Err(Malformed),
        };
        // An extent of zero bytes per field would let a count spin unbounded.
        let empty_extents = index_size + offset_size + length_size == 0;
        if data_reference != 0 || (empty_extents && extents > 1) {
            return Err(Malformed);
        }
        let kind = items
            .binary_search_by_key(&id, |&(item, _)| u64::from(item))
            .ok()
            .map(|at| items[at].1);
        let mut ranges = Vec::new();
        for _ in 0..extents {
            iloc.read(index_size)?;
            let offset = iloc.read(offset_size)?;
            let length = iloc.read(length_size)?;
            ranges.push(extent(&container, base, offset, length)?);
        }
        match kind {
            Some(Item::Image) => layout.images.extend(ranges),
            Some(Item::Exif) => {
                layout.metadata.extend(ranges.iter().cloned());
                layout.exif.push(ranges);
            }
            // An item no `infe` describes is one no decoder reads: zero it.
            Some(Item::Metadata) | None => layout.metadata.extend(ranges),
        }
        seen.push(id);
    }
    seen.sort_unstable();
    if seen.windows(2).any(|pair| pair[0] == pair[1]) {
        return Err(Malformed);
    }
    Ok(())
}

/// `length` bytes at `base + offset` into `container`, as file offsets. A
/// length of zero means "the rest of the container", which we do not guess at.
fn extent(
    container: &Range<usize>,
    base: u64,
    offset: u64,
    length: u64,
) -> Result<Range<usize>, Malformed> {
    let start = base
        .checked_add(offset)
        .and_then(|at| usize::try_from(at).ok())
        .and_then(|at| container.start.checked_add(at))
        .ok_or(Malformed)?;
    let end = usize::try_from(length)
        .ok()
        .and_then(|length| start.checked_add(length))
        .filter(|&end| length != 0 && end <= container.end)
        .ok_or(Malformed)?;
    Ok(start..end)
}

/// Big-endian fields of 0, 2, 4 or 8 bytes, never read past their box.
struct Fields<'a> {
    data: &'a [u8],
    pos: usize,
    end: usize,
}

impl Fields<'_> {
    fn read(&mut self, size: usize) -> Result<u64, Malformed> {
        let end = self
            .pos
            .checked_add(size)
            .filter(|&end| end <= self.end)
            .ok_or(Malformed)?;
        let value = self.data[self.pos..end]
            .iter()
            .fold(0, |value, &b| (value << 8) | u64::from(b));
        self.pos = end;
        Ok(value)
    }
}

/// A full box's version, and where its fields start.
fn full_box(data: &[u8], full: Bmff) -> Result<(u8, usize), Malformed> {
    let fields = full.body + 4;
    if fields > full.end {
        return Err(Malformed);
    }
    Ok((data[full.body], fields))
}

/// The boxes that exactly fill `span`.
fn boxes(data: &[u8], span: Range<usize>) -> Result<Vec<Bmff>, Malformed> {
    let mut found = Vec::new();
    let mut pos = span.start;
    while pos < span.end {
        let left = span.end - pos;
        let kind = data.get(pos + 4..pos + 8).ok_or(Malformed)?;
        let (size, header) = match be32(data, pos).ok_or(Malformed)? {
            // To the end of the enclosing box or file.
            0 => (left, 8),
            1 => (
                usize::try_from(be64(data, pos + 8).ok_or(Malformed)?).map_err(|_| Malformed)?,
                16,
            ),
            size => (usize::try_from(size).map_err(|_| Malformed)?, 8),
        };
        if left < header || size < header || size > left {
            return Err(Malformed);
        }
        found.push(Bmff {
            kind: kind.try_into().map_err(|_| Malformed)?,
            body: pos + header,
            end: pos + size,
        });
        pos += size;
    }
    Ok(found)
}

/// `ranges` sorted, with overlapping ones joined, so each byte is visited once
/// however many items share it.
fn merge(mut ranges: Vec<Range<usize>>) -> Vec<Range<usize>> {
    ranges.sort_unstable_by_key(|range| range.start);
    let mut merged: Vec<Range<usize>> = Vec::with_capacity(ranges.len());
    for range in ranges {
        match merged.last_mut() {
            Some(last) if range.start <= last.end => last.end = last.end.max(range.end),
            _ => merged.push(range),
        }
    }
    merged
}

#[cfg(test)]
mod tests {
    use super::*;

    const PIXELS: &[u8] = b"CODED-PIXELS";
    const XMP: &[u8] = b"<x:xmpmeta>LEAK-XMP</x:xmpmeta>";
    /// TIFF offset 6, `Exif\0\0`, then IFD0: Make (at 38) and Orientation 6.
    const EXIF: &[u8] = b"\0\0\0\x06Exif\0\0MM\0*\0\0\0\x08\0\x02\
        \x01\x0F\0\x02\0\0\0\x09\0\0\0\x26\
        \x01\x12\0\x03\0\0\0\x01\0\x06\0\0\
        \0\0\0\0LEAKMAKE\0";
    /// The same with no Orientation, so the minimal Exif has an empty IFD0.
    const EXIF_UPRIGHT: &[u8] = b"\0\0\0\x06Exif\0\0MM\0*\0\0\0\x08\0\x01\
        \x01\x0F\0\x02\0\0\0\x09\0\0\0\x1A\0\0\0\0LEAKMAKE\0";

    /// What an Exif item of `len` bytes becomes.
    fn minimal_exif(orientation: Option<u8>, len: usize) -> Vec<u8> {
        let mut exif = [EXIF_PREFIX, &tiff::minimal(orientation)].concat();
        exif.resize(len, 0);
        exif
    }

    fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
        haystack.windows(needle.len()).position(|w| w == needle)
    }

    fn bx(kind: &[u8; 4], body: &[u8]) -> Vec<u8> {
        [
            &(8 + body.len() as u32).to_be_bytes(),
            kind.as_slice(),
            body,
        ]
        .concat()
    }

    fn full(kind: &[u8; 4], version: u8, body: &[u8]) -> Vec<u8> {
        bx(kind, &[&[version, 0, 0, 0], body].concat())
    }

    fn contains(haystack: &[u8], needle: &[u8]) -> bool {
        haystack.windows(needle.len()).any(|w| w == needle)
    }

    /// One item: its ID, its `infe` type (`None`: no `infe`) and its bytes.
    struct Part {
        id: u32,
        kind: Option<&'static [u8; 4]>,
        bytes: &'static [u8],
    }

    fn part(id: u32, kind: &'static [u8; 4], bytes: &'static [u8]) -> Part {
        Part {
            id,
            kind: Some(kind),
            bytes,
        }
    }

    /// A HEIF file built the way encoders lay one out.
    struct Heif {
        parts: Vec<Part>,
        /// `iloc` and `infe` versions; version 2 `iloc` pairs with `infe` v3.
        iloc_version: u8,
        /// Item data in `idat` (construction method 1) instead of `mdat`.
        in_idat: bool,
        property: &'static [u8; 4],
        /// Boxes between `meta` and `mdat`.
        between: Vec<u8>,
        /// Bytes at the end of `mdat` that nothing points at.
        orphan: &'static [u8],
        /// `mdat` with a 64-bit size.
        large_mdat: bool,
    }

    impl Heif {
        fn new(parts: Vec<Part>) -> Self {
            Heif {
                parts,
                iloc_version: 0,
                in_idat: false,
                property: b"ispe",
                between: Vec::new(),
                orphan: b"",
                large_mdat: false,
            }
        }

        fn meta(&self, data_start: u64) -> Vec<u8> {
            let wide = self.iloc_version == 2;
            let id = |id: u32| {
                if wide {
                    id.to_be_bytes().to_vec()
                } else {
                    (id as u16).to_be_bytes().to_vec()
                }
            };
            let mut infes = Vec::new();
            let mut typed = 0u16;
            for part in &self.parts {
                if let Some(kind) = part.kind {
                    let mut body = id(part.id);
                    body.extend_from_slice(&[0, 0]);
                    body.extend_from_slice(kind);
                    body.push(0);
                    if kind == b"mime" {
                        body.extend_from_slice(b"application/rdf+xml\0");
                    }
                    infes.extend(full(b"infe", if wide { 3 } else { 2 }, &body));
                    typed += 1;
                }
            }
            let iinf = full(
                b"iinf",
                0,
                &[&typed.to_be_bytes(), infes.as_slice()].concat(),
            );

            // Offset, length and base offset of 4 bytes; v1+ adds a 4-byte index.
            let v = self.iloc_version;
            let mut iloc = vec![0x44, if v == 0 { 0x40 } else { 0x44 }];
            iloc.extend(if wide {
                (self.parts.len() as u32).to_be_bytes().to_vec()
            } else {
                (self.parts.len() as u16).to_be_bytes().to_vec()
            });
            let mut at = 0u32;
            for part in &self.parts {
                iloc.extend(id(part.id));
                if v > 0 {
                    iloc.extend_from_slice(&[0, u8::from(self.in_idat)]);
                }
                iloc.extend_from_slice(&[0, 0]);
                iloc.extend_from_slice(&(data_start as u32).to_be_bytes());
                iloc.extend_from_slice(&[0, 1]);
                if v > 0 {
                    iloc.extend_from_slice(&[0; 4]);
                }
                iloc.extend_from_slice(&at.to_be_bytes());
                iloc.extend_from_slice(&(part.bytes.len() as u32).to_be_bytes());
                at += part.bytes.len() as u32;
            }
            let iloc = full(b"iloc", v, &iloc);

            let hdlr = full(b"hdlr", 0, b"\0\0\0\0pict\0\0\0\0\0\0\0\0\0\0\0\0\0");
            let ipco = bx(
                b"ipco",
                &full(self.property, 0, &[0, 0, 0, 24, 0, 0, 0, 16]),
            );
            let ipma = full(b"ipma", 0, &[0, 0, 0, 1, 0, 1, 1, 0x81]);
            let iprp = bx(b"iprp", &[ipco, ipma].concat());
            let mut children = [hdlr, iinf, iloc, iprp].concat();
            if self.in_idat {
                children.extend(bx(b"idat", &self.data()));
            }
            full(b"meta", 0, &children)
        }

        fn data(&self) -> Vec<u8> {
            self.parts
                .iter()
                .flat_map(|part| part.bytes)
                .copied()
                .collect()
        }

        fn build(&self) -> Vec<u8> {
            let ftyp = bx(b"ftyp", b"heic\0\0\0\0mif1heic");
            let mdat_header = if self.large_mdat { 16 } else { 8 };
            // The meta box is the same size whatever offsets it holds.
            let probe = self.meta(0);
            let data_start = if self.in_idat {
                // idat is the last child of meta: its payload ends meta.
                ftyp.len() + probe.len() - self.data().len()
            } else {
                ftyp.len() + probe.len() + self.between.len() + mdat_header
            };
            // Construction method 1 offsets are relative to the idat payload.
            let base = if self.in_idat { 0 } else { data_start as u64 };
            let mut mdat = if self.in_idat {
                Vec::new()
            } else {
                self.data()
            };
            mdat.extend_from_slice(self.orphan);
            let mdat = if self.large_mdat {
                [
                    &1u32.to_be_bytes(),
                    b"mdat".as_slice(),
                    &(16 + mdat.len() as u64).to_be_bytes(),
                    &mdat,
                ]
                .concat()
            } else {
                bx(b"mdat", &mdat)
            };
            [ftyp, self.meta(base), self.between.clone(), mdat].concat()
        }
    }

    fn located() -> Vec<Part> {
        vec![
            part(1, b"hvc1", PIXELS),
            part(2, b"Exif", EXIF),
            part(3, b"mime", XMP),
        ]
    }

    fn stripped(file: &[u8]) -> Vec<u8> {
        let out = scrub(file).expect("parses").expect("metadata to remove");
        assert_eq!(out.len(), file.len(), "a byte moved");
        assert!(!contains(&out, b"LEAK"), "metadata survived");
        // The Exif item keeps only its orientation; every other byte is
        // either the original or zero.
        let exif = find(file, EXIF).map(|at| at..at + EXIF.len());
        if let Some(exif) = exif.clone() {
            assert_eq!(out[exif], minimal_exif(Some(6), EXIF.len()));
        }
        for (at, (&o, &f)) in out.iter().zip(file).enumerate() {
            let in_exif = exif.as_ref().is_some_and(|exif| exif.contains(&at));
            assert!(in_exif || o == f || o == 0, "byte {at} rewritten");
        }
        assert!(matches!(scrub(&out), Ok(None)), "not idempotent");
        out
    }

    #[test]
    fn zeroes_exif_and_xmp_and_keeps_the_image() {
        let file = Heif::new(located()).build();
        let out = stripped(&file);
        let at = file
            .windows(PIXELS.len())
            .position(|w| w == PIXELS)
            .unwrap();
        assert_eq!(&out[at..at + PIXELS.len()], PIXELS);
        // Only item data changed: every box is where it was.
        assert_eq!(out[..at], file[..at]);
    }

    #[test]
    fn reads_every_iloc_version_and_idat() {
        for (iloc_version, in_idat) in [(0, false), (1, false), (2, false), (1, true), (2, true)] {
            let mut heif = Heif::new(located());
            heif.iloc_version = iloc_version;
            heif.in_idat = in_idat;
            let file = heif.build();
            let out = stripped(&file);
            assert!(contains(&out, PIXELS), "v{iloc_version} idat={in_idat}");
        }
    }

    #[test]
    fn zeroes_bytes_nothing_points_at() {
        let mut heif = Heif::new(vec![part(1, b"av01", PIXELS)]);
        heif.orphan = b"LEAK-ORPHAN";
        heif.between = bx(b"free", b"LEAK-OLD-EXIF");
        assert!(contains(&stripped(&heif.build()), PIXELS));

        // An iloc entry no infe describes: no decoder reads it.
        let heif = Heif::new(vec![
            part(1, b"hvc1", PIXELS),
            Part {
                id: 7,
                kind: None,
                bytes: b"LEAK-UNTYPED",
            },
        ]);
        assert!(contains(&stripped(&heif.build()), PIXELS));
    }

    #[test]
    fn an_exif_item_keeps_its_orientation_or_nothing() {
        assert_eq!(tiff::orientation(&EXIF[10..]), Some(6));
        assert_eq!(tiff::orientation(&EXIF_UPRIGHT[10..]), None);
        for (exif, orientation) in [
            (EXIF_UPRIGHT, None),
            // Not a TIFF after the offset: nothing to carry over.
            (
                b"\0\0\0\x06Exif\0\0LEAK-NOT-A-TIFF-BUT-LONG-ENOUGH-TO-REWRITE".as_slice(),
                None,
            ),
            (
                b"\xFF\xFF\xFF\xFFLEAK-AN-OFFSET-PAST-THE-END-OF-THE-ITEM".as_slice(),
                None,
            ),
        ] {
            let file = Heif::new(vec![part(1, b"hvc1", PIXELS), part(2, b"Exif", exif)]).build();
            let out = scrub(&file).unwrap().unwrap();
            let at = find(&file, exif).unwrap();
            assert_eq!(
                out[at..at + exif.len()],
                minimal_exif(orientation, exif.len())
            );
            assert!(!contains(&out, b"LEAK"));
            assert!(matches!(scrub(&out), Ok(None)), "not idempotent");
        }
    }

    #[test]
    fn an_exif_item_too_short_for_a_minimal_exif_is_refused() {
        // The smallest minimal Exif, with no Orientation, is 24 bytes.
        assert_eq!(EXIF_PREFIX.len() + tiff::minimal(None).len(), 24);
        let file = Heif::new(vec![
            part(1, b"hvc1", PIXELS),
            part(2, b"Exif", &EXIF[..23]),
        ])
        .build();
        assert!(scrub(&file).is_err());
    }

    #[test]
    fn large_boxes_parse() {
        let mut heif = Heif::new(located());
        heif.large_mdat = true;
        stripped(&heif.build());
    }

    #[test]
    fn a_clean_file_is_left_alone() {
        let file = Heif::new(vec![part(1, b"hvc1", PIXELS)]).build();
        assert!(matches!(scrub(&file), Ok(None)));
    }

    #[test]
    fn refuses_what_it_cannot_vouch_for() {
        let refused = |heif: Heif| assert!(scrub(&heif.build()).is_err());
        // A JPEG item can carry its own Exif segment.
        refused(Heif::new(vec![part(1, b"jpeg", PIXELS)]));
        refused(Heif::new(vec![
            part(1, b"hvc1", PIXELS),
            part(2, b"jumb", EXIF),
        ]));
        for property in [b"udes", b"crtt", b"cmex", b"XXXX"] {
            let mut heif = Heif::new(located());
            heif.property = property;
            refused(heif);
        }
        // An image sequence keeps its own metadata under moov.
        let mut heif = Heif::new(located());
        heif.between = bx(b"moov", &bx(b"udta", b"LEAK"));
        refused(heif);
        let mut heif = Heif::new(located());
        heif.between = bx(b"uuid", b"0123456789abcdefLEAK");
        refused(heif);
    }

    #[test]
    fn refuses_metadata_it_cannot_zero() {
        // Exif sharing an image's bytes, even all-zero ones: writing the
        // minimal Exif there would break the image.
        const BLANK: &[u8] = &[0; 64];
        let blank = Heif::new(vec![part(1, b"hvc1", BLANK), part(2, b"Exif", EXIF)]).build();
        let iloc = blank.windows(4).position(|w| w == b"iloc").unwrap() + 4;
        let mut shared = blank.clone();
        let image_offset = blank[iloc + 18..iloc + 22].to_vec();
        shared[iloc + 18 + 18..iloc + 22 + 18].copy_from_slice(&image_offset);
        assert!(scrub(&blank).is_ok());
        assert!(scrub(&shared).is_err());

        let file = Heif::new(located()).build();
        let iloc = file.windows(4).position(|w| w == b"iloc").unwrap() + 4;
        // v0 entries after version/flags, sizes and count: ID, data
        // reference, base offset, extent count, offset, length.
        let entry = |k: usize| iloc + 8 + 18 * k;
        let patched = |k: usize, field: usize, value: &[u8]| {
            let mut copy = file.clone();
            let at = entry(k) + field;
            copy[at..at + value.len()].copy_from_slice(value);
            copy
        };
        let offset_of = |k: usize| file[entry(k) + 10..entry(k) + 14].to_vec();
        // Exif sharing the image's bytes: zeroing it would break the image.
        assert!(scrub(&patched(1, 10, &offset_of(0))).is_err());
        // Exif inside meta, where nothing is zeroed. Base 0, offset of iloc.
        let mut inside = patched(1, 4, &[0; 4]);
        inside[entry(1) + 10..entry(1) + 14].copy_from_slice(&(iloc as u32).to_be_bytes());
        assert!(scrub(&inside).is_err());
        // In another file, or "the rest of the container".
        assert!(scrub(&patched(1, 2, &[0, 1])).is_err());
        assert!(scrub(&patched(1, 14, &[0; 4])).is_err());
        // Past the end of the file.
        assert!(scrub(&patched(1, 10, &[0x7F, 0, 0, 0])).is_err());
        // The same item twice.
        assert!(scrub(&patched(1, 0, &[0, 1])).is_err());
    }

    #[test]
    fn refuses_bad_structure() {
        let file = Heif::new(located()).build();
        let swap = |from: &[u8; 4], to: &[u8; 4]| {
            let mut copy = file.clone();
            let at = copy.windows(4).position(|w| w == from).unwrap();
            copy[at..at + 4].copy_from_slice(to);
            copy
        };
        for (from, to) in [
            (b"pict", b"vide"),
            (b"iinf", b"jinf"),
            (b"iloc", b"free"),
            (b"meta", b"moov"),
        ] {
            assert!(scrub(&swap(from, to)).is_err(), "{from:?} -> {to:?}");
        }
        assert!(scrub(&[file.as_slice(), b"\0\0"].concat()).is_err());
    }

    #[test]
    fn merge_joins_overlaps() {
        assert_eq!(merge(vec![5..9, 0..2, 1..3, 9..10]), vec![0..3, 5..10]);
        assert_eq!(merge(Vec::new()), Vec::<Range<usize>>::new());
    }

    #[test]
    fn survives_truncation() {
        let file = Heif::new(located()).build();
        for len in 0..file.len() {
            match scrub(&file[..len]) {
                Ok(Some(out)) => assert!(!contains(&out, b"LEAK")),
                Ok(None) => assert!(!contains(&file[..len], b"LEAK")),
                Err(Malformed) => {}
            }
        }
    }
}
