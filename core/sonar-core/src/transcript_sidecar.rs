//! At-rest encoding of the host-owned transcript.
//!
//! MDK 0.9 keeps MLS state in SQLCipher but not chat rows, so Sonar's
//! transcript (`<db>.sonar-transcript.json` snapshot plus the
//! `<db>.sonar-transcript.log` append journal) is the only local copy of every
//! message — recovered 0.8 history and new 0.9 traffic alike. The 0.8 store it
//! replaces was SQLCipher-encrypted, so the transcript is sealed with
//! ChaCha20-Poly1305 under a key derived from that same SQLCipher key: chat
//! plaintext never sits on disk in the clear, and a backup restored with its
//! `db_key_hex` still opens it. Snapshots written by earlier #613 builds (and
//! test fixtures) are plaintext JSON; those still read and are sealed on the
//! next write.
//!
//! One sealed record per message keeps ingest O(1). Rewriting the whole
//! snapshot per message cost O(history): 17 ms at 10k rows and 53 ms at 30k on
//! an M-series Mac, quadratic across a catch-up sync.

use std::collections::HashMap;

use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{ChaCha20Poly1305, Nonce};
use hkdf::Hkdf;
use serde::Serialize;
use sha2::Sha256;

use crate::error::Error;
use crate::marmot::ChatMessage;
use crate::Result;

/// Header of a sealed snapshot. Anything else is legacy plaintext JSON.
const SNAPSHOT_MAGIC: &[u8; 8] = b"SNTRXv1\0";
const HKDF_INFO: &[u8] = b"sonar/transcript-sidecar/v1";
const NONCE_LEN: usize = 12;
/// A journal record longer than this is corruption, not a message.
const MAX_JOURNAL_RECORD: usize = 16 * 1024 * 1024;

/// Group-id hex → rows, the snapshot's JSON shape.
pub(crate) type TranscriptRows = HashMap<String, Vec<ChatMessage>>;

/// Transcript sealing key, derived from the store's 32-byte SQLCipher key.
#[derive(Clone)]
pub(crate) struct TranscriptKey([u8; 32]);

impl TranscriptKey {
    pub(crate) fn derive(db_key: &[u8; 32]) -> Self {
        let hk = Hkdf::<Sha256>::new(None, db_key);
        let mut okm = [0u8; 32];
        hk.expand(HKDF_INFO, &mut okm)
            .expect("32 bytes is a valid HKDF-SHA256 output length");
        Self(okm)
    }

    /// Derive from the host's hex key (account backup paths carry hex).
    pub(crate) fn from_db_key_hex(db_key_hex: &str) -> Option<Self> {
        let key: [u8; 32] = hex::decode(db_key_hex).ok()?.try_into().ok()?;
        Some(Self::derive(&key))
    }

    fn cipher(&self) -> ChaCha20Poly1305 {
        ChaCha20Poly1305::new_from_slice(&self.0).expect("32-byte ChaCha20-Poly1305 key")
    }

    /// `nonce ‖ ciphertext`. The nonce comes from the OS CSPRNG; a failure
    /// fails the write (Randomness Rule) instead of sealing under a zero nonce.
    fn seal(&self, plaintext: &[u8]) -> Result<Vec<u8>> {
        let mut nonce = [0u8; NONCE_LEN];
        getrandom::getrandom(&mut nonce)?;
        let ciphertext = self
            .cipher()
            .encrypt(Nonce::from_slice(&nonce), plaintext)
            .map_err(|_| Error::Storage("transcript seal failed".into()))?;
        let mut out = Vec::with_capacity(NONCE_LEN + ciphertext.len());
        out.extend_from_slice(&nonce);
        out.extend_from_slice(&ciphertext);
        Ok(out)
    }

    fn open(&self, sealed: &[u8]) -> Result<Vec<u8>> {
        if sealed.len() <= NONCE_LEN {
            return Err(Error::Storage("transcript record too short".into()));
        }
        let (nonce, ciphertext) = sealed.split_at(NONCE_LEN);
        self.cipher()
            .decrypt(Nonce::from_slice(nonce), ciphertext)
            .map_err(|_| Error::Storage("transcript does not open with this key".into()))
    }
}

/// Seal a full snapshot. Generic so callers can serialize borrowed rows
/// without cloning the whole transcript.
pub(crate) fn encode_snapshot<T: Serialize>(key: &TranscriptKey, rows: &T) -> Result<Vec<u8>> {
    let json =
        serde_json::to_vec(rows).map_err(|e| Error::Storage(format!("transcript encode: {e}")))?;
    let sealed = key.seal(&json)?;
    let mut out = Vec::with_capacity(SNAPSHOT_MAGIC.len() + sealed.len());
    out.extend_from_slice(SNAPSHOT_MAGIC);
    out.extend_from_slice(&sealed);
    Ok(out)
}

/// Read a snapshot: sealed (needs `key`) or legacy plaintext JSON.
pub(crate) fn decode_snapshot(key: Option<&TranscriptKey>, bytes: &[u8]) -> Result<TranscriptRows> {
    let json = if let Some(sealed) = bytes.strip_prefix(SNAPSHOT_MAGIC.as_slice()) {
        let key = key.ok_or_else(|| Error::Storage("sealed transcript needs its key".into()))?;
        key.open(sealed)?
    } else {
        bytes.to_vec()
    };
    serde_json::from_slice(&json).map_err(|e| Error::Storage(format!("transcript decode: {e}")))
}

/// True when `bytes` is a sealed snapshot (not legacy plaintext).
pub(crate) fn is_sealed_snapshot(bytes: &[u8]) -> bool {
    bytes.starts_with(SNAPSHOT_MAGIC)
}

/// One journal record: big-endian `u32` length, then `nonce ‖ ciphertext`.
pub(crate) fn encode_journal_record(key: &TranscriptKey, msg: &ChatMessage) -> Result<Vec<u8>> {
    let json = serde_json::to_vec(msg)
        .map_err(|e| Error::Storage(format!("transcript journal encode: {e}")))?;
    let sealed = key.seal(&json)?;
    let len = u32::try_from(sealed.len())
        .map_err(|_| Error::Storage("transcript journal record too large".into()))?;
    let mut out = Vec::with_capacity(4 + sealed.len());
    out.extend_from_slice(&len.to_be_bytes());
    out.extend_from_slice(&sealed);
    Ok(out)
}

/// Replay a journal. Stops at the first record that is truncated or does not
/// open (a torn append from a crash, or corruption): everything before it is
/// returned, and `false` says the tail was dropped.
pub(crate) fn decode_journal(key: &TranscriptKey, mut bytes: &[u8]) -> (Vec<ChatMessage>, bool) {
    let mut out = Vec::new();
    while !bytes.is_empty() {
        let Some((len, rest)) = bytes.split_first_chunk::<4>() else {
            return (out, false);
        };
        let len = u32::from_be_bytes(*len) as usize;
        if len > MAX_JOURNAL_RECORD || rest.len() < len {
            return (out, false);
        }
        let (record, rest) = rest.split_at(len);
        let Ok(json) = key.open(record) else {
            return (out, false);
        };
        let Ok(msg) = serde_json::from_slice::<ChatMessage>(&json) else {
            return (out, false);
        };
        out.push(msg);
        bytes = rest;
    }
    (out, true)
}

/// Sealed snapshot + journal, as account-backup stats and preview read them.
/// `None` when the snapshot is present but does not open.
pub(crate) fn decode_snapshot_and_journal(
    key: Option<&TranscriptKey>,
    snapshot: Option<&[u8]>,
    journal: Option<&[u8]>,
) -> Option<TranscriptRows> {
    let mut rows = match snapshot {
        Some(bytes) => decode_snapshot(key, bytes).ok()?,
        None => TranscriptRows::new(),
    };
    if let (Some(key), Some(journal)) = (key, journal) {
        let (appended, _) = decode_journal(key, journal);
        merge_rows(&mut rows, appended);
    }
    Some(rows)
}

/// Append journal rows to snapshot rows, skipping ids already present.
pub(crate) fn merge_rows(rows: &mut TranscriptRows, appended: Vec<ChatMessage>) {
    for msg in appended {
        let group = rows
            .entry(hex::encode(msg.group_id.as_slice()))
            .or_default();
        if !group.iter().any(|existing| existing.id == msg.id) {
            group.push(msg);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::Identity;
    use crate::marmot::{DeliveryState, MessageClassification};
    use crate::GroupId;
    use nostr::{EventId, Timestamp};

    fn msg(n: u8, body: &str) -> ChatMessage {
        ChatMessage {
            id: EventId::from_slice(&[n; 32]).unwrap(),
            group_id: GroupId::new(vec![0x44; 16]),
            sender: Identity::generate().public_key(),
            content: body.to_owned(),
            created_at: Timestamp::from_secs(1_700_000_000 + u64::from(n)),
            mine: false,
            delivery_state: DeliveryState::Received,
            media: vec![],
            sticker_ref: None,
            classification: MessageClassification::of(body),
            reply: None,
        }
    }

    fn rows(msgs: Vec<ChatMessage>) -> TranscriptRows {
        let mut out = TranscriptRows::new();
        merge_rows(&mut out, msgs);
        out
    }

    #[test]
    fn sealed_snapshot_round_trips_and_hides_plaintext() {
        let key = TranscriptKey::derive(&[7; 32]);
        let written = rows(vec![msg(1, "meet at the north gate")]);
        let bytes = encode_snapshot(&key, &written).unwrap();
        assert!(is_sealed_snapshot(&bytes));
        assert!(
            !bytes.windows(10).any(|w| w == b"north gate"),
            "chat plaintext must not reach the disk"
        );
        let read = decode_snapshot(Some(&key), &bytes).unwrap();
        assert_eq!(read, written);
    }

    #[test]
    fn a_sealed_snapshot_does_not_open_with_another_key() {
        let bytes =
            encode_snapshot(&TranscriptKey::derive(&[7; 32]), &rows(vec![msg(1, "x")])).unwrap();
        assert!(decode_snapshot(Some(&TranscriptKey::derive(&[8; 32])), &bytes).is_err());
        assert!(decode_snapshot(None, &bytes).is_err());
    }

    #[test]
    fn legacy_plaintext_snapshot_still_reads() {
        let legacy = serde_json::to_vec(&rows(vec![msg(2, "from an earlier build")])).unwrap();
        let read = decode_snapshot(Some(&TranscriptKey::derive(&[7; 32])), &legacy).unwrap();
        assert_eq!(
            read.values().next().unwrap()[0].content,
            "from an earlier build"
        );
    }

    #[test]
    fn journal_replays_and_stops_at_a_torn_tail() {
        let key = TranscriptKey::derive(&[7; 32]);
        let mut journal = encode_journal_record(&key, &msg(1, "first")).unwrap();
        journal.extend(encode_journal_record(&key, &msg(2, "second")).unwrap());
        assert!(!journal.windows(6).any(|w| w == b"second"));
        let (all, clean) = decode_journal(&key, &journal);
        assert!(clean);
        assert_eq!(all.len(), 2);

        let torn = &journal[..journal.len() - 3];
        let (kept, clean) = decode_journal(&key, torn);
        assert!(!clean, "a crash mid-append must be reported");
        assert_eq!(kept.len(), 1, "records before the torn one survive");
        assert_eq!(kept[0].content, "first");
    }

    #[test]
    fn snapshot_and_journal_merge_without_duplicates() {
        let key = TranscriptKey::derive(&[7; 32]);
        let snapshot = encode_snapshot(&key, &rows(vec![msg(1, "a")])).unwrap();
        let mut journal = encode_journal_record(&key, &msg(1, "a")).unwrap();
        journal.extend(encode_journal_record(&key, &msg(2, "b")).unwrap());
        let merged =
            decode_snapshot_and_journal(Some(&key), Some(&snapshot), Some(&journal)).unwrap();
        assert_eq!(merged.values().next().unwrap().len(), 2);
    }
}
