//! Fragmentation (packet type `0x20`).
//!
//! A frame larger than one GATT write is split: each fragment is a `0x20`
//! packet whose payload is
//! `fragmentID(8) | index(u16 BE) | total(u16 BE) | originalType(1) | chunk`,
//! with the original packet's sender / recipient / ttl / timestamp preserved.
//! The receiver reassembles by `(sender, fragmentID)` into the original
//! encoded frame bytes and decodes those. The [`Reassembler`] is hardened
//! against untrusted peers: sparse storage, per-stream and global byte
//! budgets, idle and absolute lifetimes, and a protect window so a live
//! stream is never evicted by a flood.

/// Fixed fragment header: id(8) + index(2) + total(2) + original type(1).
pub const HEADER_SIZE: usize = 13;

/// A parsed fragment payload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Fragment {
    /// Random 8-byte id shared by every fragment of one frame.
    pub fragment_id: [u8; 8],
    /// Zero-based position.
    pub index: u16,
    /// Fragment count (1..=[`MAX_FRAGMENTS`]).
    pub total: u16,
    /// Packet type of the frame being carried.
    pub original_type: u8,
    /// This fragment's slice of the encoded frame.
    pub chunk: Vec<u8>,
}

impl Fragment {
    /// Encode to the `0x20` packet payload (big-endian index/total).
    pub fn encode_payload(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(HEADER_SIZE + self.chunk.len());
        out.extend_from_slice(&self.fragment_id);
        out.extend_from_slice(&self.index.to_be_bytes());
        out.extend_from_slice(&self.total.to_be_bytes());
        out.push(self.original_type);
        out.extend_from_slice(&self.chunk);
        out
    }

    /// Decode a `0x20` packet payload.
    pub fn decode_payload(p: &[u8]) -> Option<Fragment> {
        if p.len() < HEADER_SIZE {
            return None;
        }
        let mut fragment_id = [0u8; 8];
        fragment_id.copy_from_slice(&p[0..8]);
        let index = u16::from_be_bytes([p[8], p[9]]);
        let total = u16::from_be_bytes([p[10], p[11]]);
        let original_type = p[12];
        Some(Fragment {
            fragment_id,
            index,
            total,
            original_type,
            chunk: p[HEADER_SIZE..].to_vec(),
        })
    }
}

use std::collections::{BTreeMap, HashMap};

/// Upper bound on a message's fragment count. The fragments arrive from
/// UNTRUSTED BLE peers, so a malicious `total` (up to 65535) would otherwise
/// pre-allocate a large slot vec from a single tiny packet. 8192 fragments
/// comfortably covers the 1 MiB file cap at any realistic chunk size.
pub const MAX_FRAGMENTS: u16 = 8192;
/// Max concurrent in-flight reassembly streams. Bounds memory against an
/// attacker opening many never-completed streams with distinct fragment ids.
pub const MAX_BUCKETS: usize = 256;
/// A stream that has not seen a new fragment for this long is abandoned.
/// Legitimate BLE fragment trains arrive back-to-back and finish within a
/// few seconds even at worst-case throughput; a bucket idle for 30s is a
/// sender that gave up, went out of range, or an attacker parking streams
/// to exhaust `MAX_BUCKETS`. (Mirrors iOS `bleFragmentLifetimeSeconds`.)
pub const STREAM_IDLE_TIMEOUT_MS: u64 = 30_000;
/// Absolute stream lifetime. Refreshing `last_touch` with trickled (even
/// duplicate) fragments would otherwise keep a bucket alive forever at a
/// few packets per second; no legitimate 1 MiB transfer takes 5 minutes
/// even at worst-case BLE throughput.
pub const STREAM_MAX_LIFETIME_MS: u64 = 5 * 60 * 1_000;
/// Cumulative byte cap per stream, mirroring iOS `assemblyLimit`
/// (`maxFramedFileBytes`): sparse storage bounds slots, this bounds
/// bytes — without it 256 buckets of attacker chunks could hold ~100+ MB
/// of heap alive via periodic refresh.
pub const MAX_STREAM_BYTES: usize = crate::types::limits::MAX_FRAMED_FILE_BYTES;
/// Cumulative byte cap across ALL in-flight streams. The per-stream cap
/// alone does not bound heap: `MAX_BUCKETS * MAX_STREAM_BYTES` is ~287 MiB,
/// which is a jetsam kill on a phone, and an attacker can approach it while
/// refreshing every bucket inside its lifetime. Eight concurrent maximal
/// transfers is far past any real mesh encounter (fragments arrive from
/// peers in radio range, one file at a time) and two orders of magnitude
/// below the per-stream-only ceiling.
pub const MAX_TOTAL_STREAM_BYTES: usize = 8 * MAX_STREAM_BYTES;
/// A newcomer at capacity may only evict a bucket idle at least this
/// long. What this buys, precisely: an ACTIVELY transmitting stream
/// refreshes its bucket every few ms and is therefore never evictable —
/// which unconditional stalest-wins did not guarantee (a flood could
/// evict a victim between its own fragments).
///
/// What it does NOT buy, stated because the first version of this comment
/// claimed it: refusal is not a "≤2s stall". There is no fragment-level
/// ACK or retransmit in this engine — `send_file` emits its writes once,
/// fire-and-forget — so a refused fragment is lost, and under a sustained
/// flood (≈4 kB/s of minimal fragments refreshing 256 buckets) reassembly
/// stays denied until the attacker's buckets hit STREAM_MAX_LIFETIME_MS.
/// The absolute lifetime, not this window, is what bounds the denial.
pub const STREAM_EVICT_PROTECT_MS: u64 = 2_000;

/// One in-flight reassembly stream. Chunks are stored sparsely, keyed by
/// fragment index: memory grows with what actually arrived, so a forged
/// `total` of `MAX_FRAGMENTS` cannot reserve ~8192 slots from one tiny
/// packet.
struct Bucket {
    total: u16,
    chunks: BTreeMap<u16, Vec<u8>>,
    bytes: usize,
    created_ms: u64,
    last_touch_ms: u64,
}

/// Reassembles fragments keyed by (sender, fragmentID). `add` returns the
/// concatenated original bytes once every index 0..total has arrived.
///
/// Buckets are bounded two ways: idle streams expire after
/// [`STREAM_IDLE_TIMEOUT_MS`], and when the table is full the stalest
/// stream is evicted for a new one. Without the second rule, 256 stuck
/// streams (untrusted, ~14 bytes each) would permanently disable
/// reassembly for every legitimate peer.
#[derive(Default)]
pub struct Reassembler {
    buckets: HashMap<([u8; 8], [u8; 8]), Bucket>,
}

impl Reassembler {
    /// An empty reassembler.
    pub fn new() -> Self {
        Reassembler {
            buckets: HashMap::new(),
        }
    }

    /// Total chunks currently buffered across all in-flight streams.
    /// Memory diagnostics / tests; storage is sparse so this tracks what
    /// actually arrived, never a claimed `total`.
    pub fn stored_chunks(&self) -> usize {
        self.buckets.values().map(|b| b.chunks.len()).sum()
    }

    /// Bytes currently buffered across all in-flight streams.
    ///
    /// Derived rather than maintained as a counter on purpose: an
    /// incremental total has to be adjusted at every mutation point
    /// (chunk replace, per-stream cap drop, completion, eviction, lifetime
    /// drop, sweep retain), and a single missed path silently corrupts the
    /// budget in the direction of accepting more. Summing ≤ MAX_BUCKETS
    /// integers on the fragment path is not measurable next to the
    /// decrypt/BLE work around it, and this is not on a render path.
    pub fn buffered_bytes(&self) -> usize {
        self.buckets.values().map(|b| b.bytes).sum()
    }

    /// Free buckets until `needed` bytes are reclaimable, largest first,
    /// never touching `keep` or a bucket inside the protect window (an
    /// actively transmitting stream). Returns whether enough was freed.
    fn reclaim_bytes(
        &mut self,
        keep: ([u8; 8], [u8; 8]),
        needed: usize,
        now_ms: u64,
    ) -> bool {
        let mut freed = 0usize;
        loop {
            if freed >= needed {
                return true;
            }
            let victim = self
                .buckets
                .iter()
                .filter(|(k, b)| {
                    **k != keep
                        && now_ms.saturating_sub(b.last_touch_ms) >= STREAM_EVICT_PROTECT_MS
                })
                .max_by_key(|(_, b)| b.bytes)
                .map(|(k, b)| (*k, b.bytes));
            match victim {
                Some((k, bytes)) => {
                    self.buckets.remove(&k);
                    freed = freed.saturating_add(bytes);
                }
                None => return freed >= needed,
            }
        }
    }

    /// Drops streams idle past [`STREAM_IDLE_TIMEOUT_MS`] or older than
    /// [`STREAM_MAX_LIFETIME_MS`]. Called from the engine tick so parked
    /// streams free their memory without waiting for the table to fill.
    pub fn sweep(&mut self, now_ms: u64) {
        self.buckets.retain(|_, b| {
            now_ms.saturating_sub(b.last_touch_ms) < STREAM_IDLE_TIMEOUT_MS
                && now_ms.saturating_sub(b.created_ms) < STREAM_MAX_LIFETIME_MS
        });
    }

    /// Doze/freeze recovery: silence measured across a process-suspend gap
    /// is OUR downtime, not the senders'. Shift each bucket's IDLE clock
    /// forward by the gap so a transfer that was live when we froze
    /// survives the next sweep — the same intent as the engine re-seeding
    /// link `last_rx_ms`.
    ///
    /// Shifted, not stamped to `now`: stamping would resurrect buckets
    /// already dead before the freeze.
    ///
    /// `created_ms` is deliberately NOT shifted. Android drives `on_tick`
    /// from a `postDelayed` handler that Doze suppresses, while the engine
    /// clock is `elapsedRealtime()` which keeps advancing — so every
    /// screen-off period is a resume gap. Shifting `created_ms` too would
    /// rewind the absolute lifetime on every one of them, turning the
    /// ceiling into an "awake-time" ceiling: a probe kept an attacker
    /// bucket alive for 12 hours of wall clock by refreshing it once per
    /// 20s of awake time. The absolute lifetime must be monotonic or it is
    /// not a backstop.
    pub fn reseed(&mut self, gap_ms: u64, now_ms: u64) {
        for b in self.buckets.values_mut() {
            b.last_touch_ms = b.last_touch_ms.saturating_add(gap_ms).min(now_ms);
        }
    }

    /// Feed one fragment (with the carrying packet's `sender` and the
    /// engine's monotonic clock). Returns the reassembled original packet
    /// bytes when complete. Hardened against untrusted input: rejects an
    /// oversized `total`, stores chunks sparsely, and admits a new stream
    /// at capacity by evicting expired buckets first and the stalest
    /// bucket as a last resort — a full table never becomes a permanent
    /// denial of reassembly.
    pub fn add(&mut self, sender: [u8; 8], frag: &Fragment, now_ms: u64) -> Option<Vec<u8>> {
        if frag.total == 0 || frag.index >= frag.total || frag.total > MAX_FRAGMENTS {
            return None;
        }
        let key = (sender, frag.fragment_id);
        if !self.buckets.contains_key(&key) && self.buckets.len() >= MAX_BUCKETS {
            self.sweep(now_ms);
            if self.buckets.len() >= MAX_BUCKETS {
                // Still full: evict the stalest bucket, but ONLY if it has
                // been idle past the protect window. An unconditional
                // stalest-wins would let ~256 fresh attacker streams evict
                // a victim's bucket between its own fragments; with the
                // protect window an actively transmitting stream (which
                // refreshes every few ms) is never evictable.
                //
                // The refused fragment is LOST, not stalled: there is no
                // fragment ACK or retransmit here (`send_file` writes once,
                // fire-and-forget). See STREAM_EVICT_PROTECT_MS for what
                // this window does and does not bound — the absolute
                // lifetime is what ends a sustained flood, not this.
                let stalest = self
                    .buckets
                    .iter()
                    .min_by_key(|(_, b)| b.last_touch_ms)
                    .map(|(k, b)| (*k, b.last_touch_ms));
                match stalest {
                    Some((k, touched))
                        if now_ms.saturating_sub(touched) >= STREAM_EVICT_PROTECT_MS =>
                    {
                        self.buckets.remove(&k);
                    }
                    _ => return None, // everything is live: refuse, don't evict
                }
            }
        }
        // Deliberately NOT enforcing the absolute lifetime here, only in
        // `sweep`. Reviewed and rejected: rejecting the fragment and
        // dropping the bucket in `add` looks tighter, but the engine now
        // sweeps on every tick including the resume path, so the aged
        // bucket survives at most one tick while holding bytes already
        // capped by MAX_STREAM_BYTES and the global budget. Folding the
        // fragment into a fresh bucket instead is actively wrong — it
        // stamps `created_ms = now` and hands the sender an indefinitely
        // renewable stream, defeating the ceiling that
        // `refresh_cannot_extend_a_stream_forever` pins.

        // Global byte budget. The per-stream cap below bounds ONE stream;
        // without this, 256 buckets each approaching MAX_STREAM_BYTES hold
        // ~287 MiB alive, which is a jetsam kill rather than a bounded
        // reassembler. Reclaim idle buckets (largest first) to make room
        // and refuse the fragment only if everything else is actively
        // transmitting — the same "never evict a live stream" rule the
        // capacity path uses.
        let replaced_now = self
            .buckets
            .get(&key)
            .and_then(|b| b.chunks.get(&frag.index))
            .map_or(0, Vec::len);
        let projected = self
            .buffered_bytes()
            .saturating_sub(replaced_now)
            .saturating_add(frag.chunk.len());
        if projected > MAX_TOTAL_STREAM_BYTES {
            let needed = projected - MAX_TOTAL_STREAM_BYTES;
            if !self.reclaim_bytes(key, needed, now_ms) {
                return None;
            }
        }
        let bucket = self.buckets.entry(key).or_insert_with(|| Bucket {
            total: frag.total,
            chunks: BTreeMap::new(),
            bytes: 0,
            created_ms: now_ms,
            last_touch_ms: now_ms,
        });
        if bucket.total != frag.total {
            return None; // inconsistent total for this id
        }
        // Cumulative byte cap (iOS `assemblyLimit` mirror): a stream that
        // claims more than a maximal framed file is hostile — drop the
        // whole bucket rather than keep buffering for it.
        let replaced = bucket.chunks.get(&frag.index).map_or(0, Vec::len);
        // `saturating_sub` states the invariant instead of relying on it:
        // `bytes` is maintained as the exact sum of stored chunk lengths,
        // but a debug-build panic on an untrusted BLE path is a bad
        // failure mode for an invariant no type enforces.
        if bucket.bytes.saturating_sub(replaced) + frag.chunk.len() > MAX_STREAM_BYTES {
            self.buckets.remove(&key);
            return None;
        }
        bucket.last_touch_ms = now_ms;
        bucket.bytes = bucket.bytes.saturating_sub(replaced) + frag.chunk.len();
        bucket.chunks.insert(frag.index, frag.chunk.clone());
        if bucket.chunks.len() == bucket.total as usize {
            let mut out = Vec::with_capacity(bucket.bytes);
            for chunk in bucket.chunks.values() {
                out.extend_from_slice(chunk);
            }
            self.buckets.remove(&key);
            Some(out)
        } else {
            None
        }
    }
}

/// Split `data` (an encoded frame) into fragments of `chunk_size` bytes,
/// each tagged with `original_type`. `None` when `chunk_size == 0` or more
/// than [`MAX_FRAGMENTS`] would be needed (`total` is a u16 on the wire).
pub fn split(data: &[u8], fragment_id: [u8; 8], original_type: u8, chunk_size: usize) -> Option<Vec<Fragment>> {
    if chunk_size == 0 {
        return None;
    }
    let count = data.len().div_ceil(chunk_size).max(1);
    if count > MAX_FRAGMENTS as usize {
        return None;
    }
    let total = count as u16;
    Some(
        data.chunks(chunk_size)
            .enumerate()
            .map(|(i, chunk)| Fragment {
                fragment_id,
                index: i as u16,
                total,
                original_type,
                chunk: chunk.to_vec(),
            })
            .collect(),
    )
}

