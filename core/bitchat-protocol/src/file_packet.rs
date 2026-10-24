//! Mesh file transfer payload (`BitchatFilePacket`), carried as the payload
//! of a `0x22` packet or, encrypted, as Noise payload `0x20`.
//!
//! TLV with two-byte big-endian lengths: fileName (0x01), fileSize (0x02,
//! 4-byte value), mimeType (0x03), content (0x04, **four-byte** length).
//! Decoders tolerate the legacy 8-byte fileSize and 2-byte content length,
//! skip unknown tags, and concatenate repeated content TLVs. `0x05` is Sonar's
//! optional message-id extension; a malformed value costs the delivery
//! receipt, never the file.
//!
//! Ported from `bitchat/Protocols/BitchatFilePacket.swift`; both reference
//! decoders now skip unknown tags (bitchat-android did not before its #826 —
//! installed builds that predate it drop the packet on the Sonar `0x05`, so
//! the extension is gated on a verified Sonar peer by the engine).

use crate::fragment::Fragment;

/// Max content size (bitchat `FileTransferLimits.maxPayloadBytes` = 1 MiB).
pub const MAX_PAYLOAD_BYTES: usize = crate::types::limits::MAX_FILE_CONTENT_BYTES;
/// Ceiling for an encoded framed file (`FileTransferLimits.maxFramedFileBytes`).
pub const MAX_FRAMED_FILE_BYTES: usize = crate::types::limits::MAX_FRAMED_FILE_BYTES;

// Canonical TLV tags (must match bitchat exactly).
const T_FILE_NAME: u8 = 0x01;
const T_FILE_SIZE: u8 = 0x02;
const T_MIME_TYPE: u8 = 0x03;
const T_CONTENT: u8 = 0x04;
/// Optional Sonar extension. Stock bitchat decoders skip unknown TLVs, so
/// adding the sender's chat message id remains wire-compatible.
const T_MESSAGE_ID: u8 = 0x05;

/// A decoded file transfer payload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FilePacket {
    /// Suggested file name.
    pub file_name: Option<String>,
    /// Declared size; resolved to `content.len()` when absent.
    pub file_size: Option<u64>,
    /// MIME type.
    pub mime_type: Option<String>,
    /// Sonar extension (TLV 0x05): the chat message id for delivery receipts.
    pub message_id: Option<String>,
    /// File bytes.
    pub content: Vec<u8>,
}

impl FilePacket {
    /// Encode using v2 canonical TLVs (4-byte fileSize, u32 content length).
    /// Returns `None` when fields exceed protocol limits. Byte-identical to
    /// `BitchatFilePacket.encode()`.
    pub fn encode(&self) -> Option<Vec<u8>> {
        let resolved = self.file_size.unwrap_or(self.content.len() as u64);
        if resolved > u32::MAX as u64 || resolved > MAX_PAYLOAD_BYTES as u64 {
            return None;
        }
        if self.content.len() > u32::MAX as usize || self.content.len() > MAX_PAYLOAD_BYTES {
            return None;
        }
        let mut out = Vec::new();
        if let Some(name) = &self.file_name {
            let nb = name.as_bytes();
            if nb.len() <= u16::MAX as usize {
                out.push(T_FILE_NAME);
                out.extend_from_slice(&(nb.len() as u16).to_be_bytes());
                out.extend_from_slice(nb);
            }
        }
        out.push(T_FILE_SIZE);
        out.extend_from_slice(&4u16.to_be_bytes());
        out.extend_from_slice(&(resolved as u32).to_be_bytes());
        if let Some(mime) = &self.mime_type {
            let mb = mime.as_bytes();
            if mb.len() <= u16::MAX as usize {
                out.push(T_MIME_TYPE);
                out.extend_from_slice(&(mb.len() as u16).to_be_bytes());
                out.extend_from_slice(mb);
            }
        }
        // Same asymmetry on the way out: an unusable id costs the receipt,
        // not the transfer. Skipping the TLV degrades to legacy behaviour
        // (the recipient simply returns no receipt) instead of failing a
        // send the user asked for.
        if let Some(id) = self
            .message_id
            .as_deref()
            .map(str::as_bytes)
            .filter(|id| !id.is_empty() && id.len() <= u16::MAX as usize)
        {
            out.push(T_MESSAGE_ID);
            out.extend_from_slice(&(id.len() as u16).to_be_bytes());
            out.extend_from_slice(id);
        }
        out.push(T_CONTENT);
        out.extend_from_slice(&(self.content.len() as u32).to_be_bytes());
        out.extend_from_slice(&self.content);
        Some(out)
    }

    /// Decode, tolerating legacy encodings (8-byte fileSize, 2-byte content
    /// length) exactly like `BitchatFilePacket.decode()`.
    pub fn decode(data: &[u8]) -> Option<FilePacket> {
        let end = data.len();
        let mut cur = 0usize;
        let mut file_name = None;
        let mut file_size: Option<u64> = None;
        let mut mime_type = None;
        let mut message_id = None;
        let mut content: Vec<u8> = Vec::new();

        // Read a big-endian length of `bytes` width, advancing `cur`.
        fn read_be(data: &[u8], cur: &mut usize, bytes: usize) -> Option<usize> {
            if data.len() - *cur < bytes {
                return None;
            }
            let mut r: u64 = 0;
            for _ in 0..bytes {
                r = (r << 8) | data[*cur] as u64;
                *cur += 1;
            }
            if r > usize::MAX as u64 {
                return None;
            }
            Some(r as usize)
        }

        while cur < end {
            let type_raw = data[cur];
            cur += 1;

            let length = if type_raw == T_CONTENT {
                let snap = cur;
                match read_be(data, &mut cur, 4) {
                    Some(c) if c <= end - cur => Some(c),
                    _ => {
                        cur = snap;
                        read_be(data, &mut cur, 2)
                    }
                }
            } else {
                read_be(data, &mut cur, 2)
            };

            let len = length?;
            if end - cur < len {
                return None;
            }
            let value = &data[cur..cur + len];
            cur += len;

            match type_raw {
                T_FILE_NAME => file_name = String::from_utf8(value.to_vec()).ok(),
                T_FILE_SIZE => {
                    if len == 4 || len == 8 {
                        let mut size: u64 = 0;
                        for &b in value {
                            size = (size << 8) | b as u64;
                        }
                        if size > MAX_PAYLOAD_BYTES as u64 {
                            return None;
                        }
                        file_size = Some(size);
                    }
                }
                T_MIME_TYPE => mime_type = String::from_utf8(value.to_vec()).ok(),
                T_MESSAGE_ID => {
                    // Degrade, never fail: this is an OPTIONAL Sonar
                    // extension whose only job is to enable a delivery
                    // receipt. Rejecting the packet would let a malformed
                    // hint destroy the media it was attached to — every
                    // other optional field here degrades (T_MIME_TYPE uses
                    // `.ok()`, unknown tags `continue`).
                    message_id = String::from_utf8(value.to_vec())
                        .ok()
                        .filter(|id| !id.is_empty());
                }
                T_CONTENT => {
                    if content.len() + value.len() > MAX_PAYLOAD_BYTES {
                        return None;
                    }
                    content.extend_from_slice(value);
                }
                _ => continue, // unknown tag: skip (tolerant, like bitchat)
            }
        }

        if content.is_empty() || content.len() > MAX_PAYLOAD_BYTES {
            return None;
        }
        Some(FilePacket {
            file_name,
            file_size: Some(file_size.unwrap_or(content.len() as u64)),
            mime_type,
            message_id,
            content,
        })
    }
}

/// Split an encoded frame into `0x20` fragments; see [`crate::fragment::split`].
pub fn fragment(data: &[u8], fragment_id: [u8; 8], original_type: u8, chunk_size: usize) -> Option<Vec<Fragment>> {
    crate::fragment::split(data, fragment_id, original_type, chunk_size)
}
