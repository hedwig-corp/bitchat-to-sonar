//! Platform-neutral BLE mesh link state machine.
//!
//! Every platform used to re-implement the same orchestration around the mesh
//! protocol — announce/identity handling, dial policy, per-instance links,
//! liveness, Noise session lifecycle, fail-fast sends, relay — and every bug had
//! to be found and fixed once per platform (see PR #291: zombie links, the
//! multi-service-instance lottery, write-queue races). This module owns that
//! machine once, deterministically:
//!
//! ```text
//! driver event ──▶ Engine::on_*(…, now_ms) ──▶ Output {
//!     commands: what the driver must do to the radio,
//!     events:   what the app layer must be told,
//! }
//! ```
//!
//! The engine performs no I/O and reads no clocks — `now_ms` (a MONOTONIC
//! timestamp; wall-clock would cull every link on an NTP jump) comes in with
//! every call, so every scenario is unit-testable, including process-freeze
//! recovery. Platform drivers stay thin: radio access (scan/advertise/GATT),
//! platform flow control (e.g. Android's one-outstanding-GATT-op queue and its
//! stuck-op recovery), permissions/background modes, and scheduling of the
//! `after_ms` command delays.
//!
//! Links are keyed by `(connection handle, service instance)`: one remote
//! device can expose SEVERAL instances of the mesh service behind one address
//! (a Mac running Sonar.app and the bitchat iOS-wrapper registers it twice in
//! the shared GATT database), and two apps on one controller can never hear
//! each other over the air — each instance is a distinct peer app. The handle
//! is opaque (Android: MAC address; iOS: CBPeripheral UUID — iOS never exposes
//! MAC addresses).

use std::collections::{HashMap, HashSet, VecDeque};

use sha2::{Digest, Sha256};

use crate::mesh::{self, msg_type, noise_payload};
use crate::noise::{NoiseHandshake, NoiseSession};

// ── Wire/behavior constants ──
// These values are load-bearing: they are the on-device-proven behavior from
// the Kotlin implementation (announce cadence interop with iOS, Android GATT
// MTU realities, bitchat compatibility). Do not tune casually.
pub const DEFAULT_TTL: u8 = 7;
pub const MAX_CLIENTS: usize = 4;
pub const CONNECT_ESTABLISH_MS: u64 = 5_000;
pub const ANNOUNCE_TIMEOUT_MS: u64 = 6_000;
pub const REDIAL_BACKOFF_MS: u64 = 30_000;
pub const HANDSHAKE_RETRY_MS: u64 = 8_000;
/// A healthy link carries rx at least every ~30s (our heartbeat plus iOS's
/// 15–38s connected announce cadence): 90s of silence means the link is dead
/// even though no disconnect callback ever fired (Pixel 10 stack).
pub const LINK_STALE_MS: u64 = 90_000;
pub const TICK_MS: u64 = 15_000;
pub const HEARTBEAT_MS: u64 = 30_000;
/// A tick arriving later than this means OUR process was frozen/dozed while
/// the monotonic clock ran on — re-seed instead of culling for our downtime.
pub const SWEEP_RESUME_GAP_MS: u64 = TICK_MS * 3;
pub const MAX_SINGLE_GATT_PACKET_BYTES: usize = 480;
/// One BLE write must stay inside bitchat's 256-byte block. A Pixel 10 reports a
/// 517-byte MTU to an iPhone, but iOS can acknowledge a 512-byte characteristic
/// write without ever surfacing it to `didReceiveWrite`. Measured: a 350-byte
/// chunk encodes to exactly a 512-byte write for every fragment, which is what
/// made Pixel -> iPhone media transfers vanish while Android logged success.
pub const RELIABLE_GATT_WRITE_BYTES: usize = 256;
/// `Fragment::encode_payload` adds `fragment::HEADER_SIZE` and the enclosing
/// `0x20` packet adds its own header; both are fixed-width, so the per-write
/// overhead is a constant (measured at 43 bytes for a recipient-addressed,
/// unsigned fragment packet).
const FRAGMENT_PACKET_OVERHEAD_BYTES: usize = 43;
/// Headroom so a future header field cannot silently push fragments back over
/// the block boundary — the failure mode is invisible (Android reports success,
/// iOS never sees the write), so it must be impossible by construction rather
/// than caught in the field. The exact ceiling is a 213-byte chunk (256 bytes on
/// the wire); anything larger jumps to a 512-byte write.
const FRAGMENT_SAFETY_MARGIN_BYTES: usize = 8;
/// Derived, not tuned: the largest chunk that provably fits one reliable write.
/// At 205 bytes a full 1 MiB transfer needs 5,116 fragments, comfortably under
/// `fragment::MAX_FRAGMENTS` (8,192), and carries 28% more payload per write
/// than the 160-byte value this replaces.
/// Pinned by `every_fragment_write_stays_in_the_reliable_block`.
pub const FRAGMENT_CHUNK_SIZE: usize =
    RELIABLE_GATT_WRITE_BYTES - FRAGMENT_PACKET_OVERHEAD_BYTES - FRAGMENT_SAFETY_MARGIN_BYTES;
pub const MAX_FILE_TRANSFER_BYTES: usize = 1024 * 1024;
pub const MAX_V1_FILE_PAYLOAD_BYTES: usize = 0xFFFF;
const MAX_PENDING_SONAR: usize = 128;
const SEEN_CAP: usize = 1024;
/// Minimum spacing between instance re-discoveries on one connection.
const REFRESH_INSTANCES_COOLDOWN_MS: u64 = 30_000;
/// Soft cap on the identity maps (signing key / fingerprint per sender id):
/// sender ids rotate and can be attacker-minted, so an unbounded map is a
/// slow leak. Clearing wholesale is safe — entries repopulate from the next
/// verified announce.
const IDENTITY_MAP_CAP: usize = 4096;
/// A pinned identity refreshed within this window is protected from eviction at
/// capacity. Measured against `now_ms`, which is the MONOTONIC clock — `wall()`
/// applies the wall-clock offset separately — so this window cannot be widened
/// by a peer-supplied timestamp or a device clock jump.
/// Any live peer re-announces far more often (every ~15-38s), so only
/// genuinely absent peers are evictable; a flood of fresh identities cannot
/// dislodge an active pin (the new identity is refused instead).
const IDENTITY_PROTECT_MS: u64 = 5 * 60 * 1000;
/// Server discovery burst: the first notification pair is easy to lose during
/// role setup, so announce three times with these delays after a subscribe.
const DISCOVERY_BURST_DELAYS_MS: [u64; 3] = [0, 350, 1_200];
/// Stagger the 0x53 behind the announce so back-to-back writes don't collide.
const SONAR_STAGGER_MS: u64 = 150;

/// One client link: a peer APP on a connection (`conn`, opaque handle) at a
/// mesh service `instance`.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct LinkId {
    pub conn: String,
    pub instance: i32,
}

/// What the driver must do to the radio. `after_ms` delays are scheduled by
/// the driver (the engine has no timers).
#[derive(Debug)]
pub enum Command {
    Dial { conn: String },
    /// Tear down the CLIENT connection (close the outbound GATT). Must not
    /// touch a server-role leg the same peer holds toward us.
    Disconnect { conn: String },
    /// Cancel the SERVER-role connection from an inbound central. Must not
    /// touch a client GATT we hold toward the same address.
    CancelServer { conn: String },
    /// Re-run service discovery on an existing client connection. Emitted when
    /// a server-leg Direct announce proves a peer app is alive behind a client
    /// connection that has no instance link for it (e.g. its CCC subscribe
    /// failed and the dead link was culled) — without this, a lost instance
    /// has no recovery path until the whole connection drops.
    RefreshInstances { conn: String },
    Subscribe { conn: String, instance: i32 },
    WriteLink { conn: String, instance: i32, bytes: Vec<u8>, after_ms: u64 },
    NotifyConn { conn: String, bytes: Vec<u8>, after_ms: u64 },
}

/// What the app layer must be told (the old `MeshGatt` listener surface).
/// `fingerprint` is the peer's STABLE identity (SHA-256 of its Noise static
/// key) so conversations survive peerID and address rotation.
#[derive(Debug, Clone)]
pub enum AppEvent {
    PeerAnnounced {
        fingerprint: String,
        nickname: String,
        peer_id_hex: String,
        direct: bool,
    },
    SonarPayload {
        fingerprint: String,
        payload: Vec<u8>,
    },
    TextReceived {
        fingerprint: String,
        message_id: String,
        content: String,
    },
    DeliveryReceived {
        fingerprint: String,
        message_id: String,
    },
    FileReceived {
        fingerprint: String,
        transfer_key: String,
        message_id: Option<String>,
        file_name: Option<String>,
        mime_type: Option<String>,
        content: Vec<u8>,
        timestamp_ms: u64,
    },
    BroadcastReceived {
        fingerprint: String,
        /// The 8-byte packet sender id (hex) — distinct from the fingerprint
        /// fallback so listeners get honest wire metadata.
        sender_id_hex: String,
        content: String,
        timestamp_ms: u64,
    },
    LinkEstablished {
        fingerprint: String,
    },
}

#[derive(Debug, Default)]
pub struct Output {
    pub commands: Vec<Command>,
    pub events: Vec<AppEvent>,
}

impl Output {
    fn merge(&mut self, other: Output) {
        self.commands.extend(other.commands);
        self.events.extend(other.events);
    }
}

enum NoiseState {
    Handshake { hs: NoiseHandshake, started_ms: u64 },
    Session(NoiseSession),
}

impl NoiseState {
    fn established(&self) -> bool {
        matches!(self, NoiseState::Session(_))
    }
}

#[derive(Default)]
struct PeerBinding {
    peer_id_hex: Option<String>,
    fingerprint: Option<String>,
}

struct ClientLink {
    bind: PeerBinding,
    noise: Option<NoiseState>,
    last_rx_ms: u64,
    subscribed: bool,
}

struct ServerConn {
    bind: PeerBinding,
    noise: Option<NoiseState>,
    last_rx_ms: u64,
}

struct DialState {
    started_ms: u64,
    connected: bool,
}

enum Origin {
    Client(LinkId),
    Server(String),
}

pub struct Engine {
    // Identity (never changes for the engine's lifetime).
    noise_private: [u8; 32],
    noise_public_hex: String,
    signer: mesh::MeshSigner,
    my_peer_id: [u8; 8],
    my_peer_id_hex: String,
    nickname: String,
    sonar_payload: Option<Vec<u8>>,
    /// Known-only discovery: lowercase fingerprints allowed, None = everyone.
    allowlist: Option<HashSet<String>>,

    links: HashMap<LinkId, ClientLink>,
    server_conns: HashMap<String, ServerConn>,
    /// In-flight dials (from Dial until the first Direct announce answers).
    dialing: HashMap<String, DialState>,
    /// Client connections that reached GATT-connected.
    connected: HashSet<String>,
    recent_dials: HashMap<String, u64>,

    /// Once a sender ID has established an Ed25519 signing key, later announces
    /// must not replace it (reinstall rotates the sender ID too, so an in-place
    /// signing-key change is an impersonation).
    signing_key_by_peer: HashMap<String, String>,
    fingerprint_by_peer: HashMap<String, String>,
    /// `(peer_key, last_seen_ms)` in least-recently-announced order (front =
    /// stalest). Kept in lockstep with `signing_key_by_peer`'s keys so that at
    /// capacity we evict only the single stalest pin, and only if it is older
    /// than `IDENTITY_PROTECT_MS`. A pin refreshed within that window is never
    /// evicted; when every pin is recent (a flood) the new identity is refused
    /// instead. This defeats the wipe-and-rebind attack where an attacker
    /// floods `IDENTITY_MAP_CAP` throwaway announces to drop a live peer's pin
    /// and then rebinds its fingerprint to an attacker signing key.
    identity_lru: VecDeque<(String, u64)>,
    /// Count of announces refused because every pin was protected. This file is
    /// a pure state machine with no logging, so without a counter a saturated
    /// pin map is an invisible cause of "that peer never shows up for me".
    identity_refused: u64,
    /// Pin-map bound, `IDENTITY_MAP_CAP` in production. A field rather than a
    /// `cfg(test)` constant so tests exercise the same code path as production
    /// with different data, instead of a different constant.
    identity_map_cap: usize,
    /// A 0x53 can arrive before its 0x01 announce supplies the signing key.
    pending_sonar: HashMap<String, Vec<u8>>,
    seen_broadcasts: HashSet<String>,
    seen_files: HashSet<String>,
    reassembler: mesh::fragment::Reassembler,

    last_heartbeat_ms: u64,
    last_tick_ms: u64,
    /// Last instance re-discovery per connection (see `RefreshInstances`).
    last_refresh_ms: HashMap<String, u64>,
    /// Wire timestamps are WALL-clock milliseconds (bitchat protocol), while
    /// every deadline/liveness decision uses the monotonic `now_ms` — a wall
    /// clock would cull links on an NTP jump, and a monotonic clock on the
    /// wire would hand peers uptime-scale timestamps. The driver syncs this
    /// offset (wall − monotonic) at start and on every tick.
    wall_minus_mono_ms: i64,
    /// Monotonic per-send counter mixed into fragment ids so two fragmented
    /// sends in the same millisecond cannot collide.
    fragment_seq: u64,
}

impl Engine {
    /// `noise_public_hex` is the static public key matching `noise_private`
    /// (the platform key store holds both; deriving X25519 public keys is not
    /// this module's business).
    pub fn new(
        noise_private: [u8; 32],
        noise_public_hex: String,
        ed25519_seed: [u8; 32],
        nickname: String,
    ) -> Option<Self> {
        let noise_public = hex::decode(&noise_public_hex).ok()?;
        if noise_public.len() != 32 {
            return None;
        }
        let my_peer_id_hex = mesh::peer_id_from_noise_key(&noise_public);
        let mut my_peer_id = [0u8; 8];
        hex::decode_to_slice(&my_peer_id_hex, &mut my_peer_id).ok()?;
        Some(Self {
            noise_private,
            noise_public_hex,
            signer: mesh::MeshSigner::from_seed(&ed25519_seed),
            my_peer_id,
            my_peer_id_hex,
            nickname,
            sonar_payload: None,
            allowlist: None,
            links: HashMap::new(),
            server_conns: HashMap::new(),
            dialing: HashMap::new(),
            connected: HashSet::new(),
            recent_dials: HashMap::new(),
            signing_key_by_peer: HashMap::new(),
            fingerprint_by_peer: HashMap::new(),
            identity_lru: VecDeque::new(),
            identity_refused: 0,
            identity_map_cap: IDENTITY_MAP_CAP,
            pending_sonar: HashMap::new(),
            seen_broadcasts: HashSet::new(),
            seen_files: HashSet::new(),
            reassembler: mesh::fragment::Reassembler::new(),
            last_heartbeat_ms: 0,
            last_tick_ms: 0,
            last_refresh_ms: HashMap::new(),
            wall_minus_mono_ms: 0,
            fragment_seq: 0,
        })
    }

    pub fn my_peer_id_hex(&self) -> &str {
        &self.my_peer_id_hex
    }

    /// Sync the wall clock (driver-supplied, at start and each tick). Wire
    /// timestamps are accurate to within one tick of NTP drift, which is all
    /// the protocol needs (peers stamp their own packets).
    pub fn set_wall_clock(&mut self, now_ms: u64, wall_ms: u64) {
        self.wall_minus_mono_ms = wall_ms as i64 - now_ms as i64;
    }

    /// The wall-clock time to stamp into a wire packet built "now".
    fn wall(&self, now_ms: u64) -> u64 {
        (now_ms as i64 + self.wall_minus_mono_ms).max(0) as u64
    }

    /// Dialer election between two node-id-advertising Sonar-Androids: the
    /// lexicographically SMALLER id dials first (the larger follows after a
    /// head-start delay, driver-scheduled). Peers with no node id (iOS / stock
    /// bitchat) are dialed immediately by the caller.
    pub fn should_dial_first(&self, peer_node_id: &[u8]) -> bool {
        let mine = &self.my_peer_id[..];
        let n = mine.len().min(peer_node_id.len());
        for i in 0..n {
            if mine[i] != peer_node_id[i] {
                return mine[i] < peer_node_id[i];
            }
        }
        mine.len() < peer_node_id.len()
    }

    /// True iff `conn` is currently linked (dialed, dialing, or accepted as a
    /// server) — the scanner uses this to gate recovery re-dials.
    pub fn is_linked_conn(&self, conn: &str) -> bool {
        self.connected.contains(conn)
            || self.dialing.contains_key(conn)
            || self.server_conns.contains_key(conn)
    }

    /// True iff there is an established, writable Noise route to `fingerprint`.
    pub fn has_link(&self, fingerprint: &str) -> bool {
        self.sendable_route(fingerprint).is_some()
    }

    /// Peer-app count currently reachable with a broadcast.
    pub fn connected_count(&self) -> usize {
        let links = self
            .links
            .iter()
            .filter(|(_, l)| self.bind_allowed(&l.bind))
            .count();
        let servers = self
            .server_conns
            .values()
            .filter(|s| self.bind_allowed(&s.bind))
            .count();
        links + servers
    }

    // ── Dial policy ──

    /// The driver asks to dial a scan-result connection. Gated on dedup,
    /// redial backoff, and the concurrent-client cap (BLE MAC rotation makes
    /// one device a stream of fresh handles; dialing each floods the radio).
    pub fn on_dial_request(&mut self, conn: &str, now_ms: u64) -> Output {
        let mut out = Output::default();
        if self.connected.contains(conn) || self.dialing.contains_key(conn) {
            return out;
        }
        if let Some(t) = self.recent_dials.get(conn) {
            if now_ms.saturating_sub(*t) < REDIAL_BACKOFF_MS {
                return out;
            }
        }
        let open = self.connected.len()
            + self
                .dialing
                .keys()
                .filter(|c| !self.connected.contains(*c))
                .count();
        if open >= MAX_CLIENTS {
            return out;
        }
        self.recent_dials.insert(conn.to_string(), now_ms);
        if self.recent_dials.len() > 256 {
            self.recent_dials
                .retain(|_, t| now_ms.saturating_sub(*t) <= REDIAL_BACKOFF_MS);
        }
        self.dialing.insert(
            conn.to_string(),
            DialState {
                started_ms: now_ms,
                connected: false,
            },
        );
        out.commands.push(Command::Dial {
            conn: conn.to_string(),
        });
        out
    }

    pub fn on_client_connected(&mut self, conn: &str, now_ms: u64) -> Output {
        let _ = now_ms;
        if let Some(d) = self.dialing.get_mut(conn) {
            d.connected = true;
        }
        self.connected.insert(conn.to_string());
        Output::default()
    }

    /// Driver-scheduled deadline check (at CONNECT_ESTABLISH_MS and again at
    /// CONNECT_ESTABLISH_MS + ANNOUNCE_TIMEOUT_MS after each dial). Fail fast:
    /// a rotated-away address often hangs with no callback at all, and a
    /// connection that never produces an announce is not a mesh peer.
    pub fn on_dial_deadline(&mut self, conn: &str, now_ms: u64) -> Output {
        let mut out = Output::default();
        let Some(d) = self.dialing.get(conn) else {
            return out;
        };
        let age = now_ms.saturating_sub(d.started_ms);
        let dead_unconnected = !d.connected && age >= CONNECT_ESTABLISH_MS;
        let dead_unannounced = age >= CONNECT_ESTABLISH_MS + ANNOUNCE_TIMEOUT_MS;
        if dead_unconnected || dead_unannounced {
            self.cleanup_client_conn(conn);
            out.commands.push(Command::Disconnect {
                conn: conn.to_string(),
            });
        }
        out
    }

    /// A failed connect (transient 133, dial-race 19, …) is frequently
    /// retryable — clear the backoff so the next scan hit can re-dial at once.
    pub fn on_client_connect_failed(&mut self, conn: &str) -> Output {
        self.recent_dials.remove(conn);
        self.cleanup_client_conn(conn);
        Output::default()
    }

    pub fn on_client_disconnected(&mut self, conn: &str) -> Output {
        self.cleanup_client_conn(conn);
        Output::default()
    }

    pub fn on_instances_discovered(
        &mut self,
        conn: &str,
        instances: &[i32],
        now_ms: u64,
    ) -> Output {
        let mut out = Output::default();
        for &instance in instances {
            let id = LinkId {
                conn: conn.to_string(),
                instance,
            };
            self.links.entry(id).or_insert(ClientLink {
                bind: PeerBinding::default(),
                noise: None,
                last_rx_ms: now_ms,
                subscribed: false,
            });
            out.commands.push(Command::Subscribe {
                conn: conn.to_string(),
                instance,
            });
        }
        out
    }

    /// CCC write completed (`subscribed=false` = the instance has no CCC: we
    /// can't receive its notifies but can still write our announce to it).
    pub fn on_subscribe_result(
        &mut self,
        conn: &str,
        instance: i32,
        subscribed: bool,
        now_ms: u64,
    ) -> Output {
        let mut out = Output::default();
        let id = LinkId {
            conn: conn.to_string(),
            instance,
        };
        let Some(link) = self.links.get_mut(&id) else {
            // Dropped (policy) while the CCC write was in flight — don't
            // announce ourselves to it.
            return out;
        };
        link.subscribed = subscribed;
        link.last_rx_ms = now_ms;
        if let Some(ann) = self.announce_bytes(now_ms) {
            out.commands.push(Command::WriteLink {
                conn: conn.to_string(),
                instance,
                bytes: ann,
                after_ms: 0,
            });
        }
        if subscribed {
            if let Some(p) = self.sonar_bytes(now_ms) {
                out.commands.push(Command::WriteLink {
                    conn: conn.to_string(),
                    instance,
                    bytes: p,
                    after_ms: SONAR_STAGGER_MS,
                });
            }
        }
        out
    }

    // ── Server role ──

    pub fn on_server_connected(&mut self, conn: &str, now_ms: u64) -> Output {
        self.server_conns.insert(
            conn.to_string(),
            ServerConn {
                bind: PeerBinding::default(),
                noise: None,
                last_rx_ms: now_ms,
            },
        );
        Output::default()
    }

    pub fn on_server_disconnected(&mut self, conn: &str) -> Output {
        self.server_conns.remove(conn);
        Output::default()
    }

    /// The central subscribed → send the discovery burst (the first pair of
    /// notifications is easy to lose during role setup, so repeat it).
    pub fn on_server_subscribed(&mut self, conn: &str, now_ms: u64) -> Output {
        let mut out = Output::default();
        self.server_conns
            .entry(conn.to_string())
            .or_insert(ServerConn {
                bind: PeerBinding::default(),
                noise: None,
                last_rx_ms: now_ms,
            });
        for delay in DISCOVERY_BURST_DELAYS_MS {
            if let Some(ann) = self.announce_bytes(now_ms) {
                out.commands.push(Command::NotifyConn {
                    conn: conn.to_string(),
                    bytes: ann,
                    after_ms: delay,
                });
            }
            if let Some(p) = self.sonar_bytes(now_ms) {
                out.commands.push(Command::NotifyConn {
                    conn: conn.to_string(),
                    bytes: p,
                    after_ms: delay + SONAR_STAGGER_MS,
                });
            }
        }
        out
    }

    // ── Receive ──

    pub fn on_client_rx(
        &mut self,
        conn: &str,
        instance: i32,
        bytes: &[u8],
        now_ms: u64,
    ) -> Output {
        let id = LinkId {
            conn: conn.to_string(),
            instance,
        };
        if let Some(l) = self.links.get_mut(&id) {
            l.last_rx_ms = now_ms;
        }
        self.handle_packet(Origin::Client(id), bytes, now_ms)
    }

    pub fn on_server_rx(&mut self, conn: &str, bytes: &[u8], now_ms: u64) -> Output {
        let entry = self
            .server_conns
            .entry(conn.to_string())
            .or_insert(ServerConn {
                bind: PeerBinding::default(),
                noise: None,
                last_rx_ms: now_ms,
            });
        entry.last_rx_ms = now_ms;
        self.handle_packet(Origin::Server(conn.to_string()), bytes, now_ms)
    }

    // ── Tick: heartbeat + liveness ──

    pub fn on_tick(&mut self, now_ms: u64) -> Output {
        let mut out = Output::default();
        let gap = if self.last_tick_ms == 0 {
            0
        } else {
            now_ms.saturating_sub(self.last_tick_ms)
        };
        let resumed_from_gap = self.last_tick_ms != 0 && gap >= SWEEP_RESUME_GAP_MS;
        self.last_tick_ms = now_ms;

        if (!self.links.is_empty() || !self.server_conns.is_empty())
            && now_ms.saturating_sub(self.last_heartbeat_ms) >= HEARTBEAT_MS
        {
            self.last_heartbeat_ms = now_ms;
            out.merge(self.discovery_broadcast(now_ms));
        }

        if resumed_from_gap {
            // Our process was frozen/dozed: silence measured across that gap
            // is OUR downtime, not the peer's. Re-seed every window and judge
            // on the next tick.
            for l in self.links.values_mut() {
                l.last_rx_ms = now_ms;
            }
            for s in self.server_conns.values_mut() {
                s.last_rx_ms = now_ms;
            }
            return out;
        }

        // Cull zombie links the stack never reported as disconnected: a stale
        // entry would gate off every re-dial (`is_linked_conn`) and a
        // static-address peer (a Mac) would stay undetectable forever. A dead
        // instance culls itself while a chatty sibling keeps the connection.
        let stale_links: Vec<LinkId> = self
            .links
            .iter()
            .filter(|(_, l)| now_ms.saturating_sub(l.last_rx_ms) >= LINK_STALE_MS)
            .map(|(id, _)| id.clone())
            .collect();
        for id in stale_links {
            self.recent_dials.remove(&id.conn); // allow an immediate re-dial
            out.merge(self.drop_client_link(&id));
        }
        let stale_servers: Vec<String> = self
            .server_conns
            .iter()
            .filter(|(_, s)| now_ms.saturating_sub(s.last_rx_ms) >= LINK_STALE_MS)
            .map(|(c, _)| c.clone())
            .collect();
        for conn in stale_servers {
            self.recent_dials.remove(&conn); // let us dial the peer back
            self.server_conns.remove(&conn);
            out.commands.push(Command::CancelServer { conn });
        }

        // Keep the refresh-cooldown map from growing across rotating handles.
        self.last_refresh_ms
            .retain(|_, t| now_ms.saturating_sub(*t) < REFRESH_INSTANCES_COOLDOWN_MS);

        // Backstop for dial deadlines the driver failed to schedule.
        let expired: Vec<String> = self
            .dialing
            .iter()
            .filter(|(_, d)| {
                now_ms.saturating_sub(d.started_ms)
                    >= CONNECT_ESTABLISH_MS + ANNOUNCE_TIMEOUT_MS
            })
            .map(|(c, _)| c.clone())
            .collect();
        for conn in expired {
            self.cleanup_client_conn(&conn);
            out.commands.push(Command::Disconnect { conn });
        }
        out
    }

    // ── App-facing sends ──

    /// Send a DM by stable fingerprint over a live Noise route. The engine must
    /// never hide plaintext for a later reconnect: the app-owned outbox needs
    /// an honest `None` so it can preserve ordering and choose another route.
    pub fn send_text(
        &mut self,
        fingerprint: &str,
        message_id: &str,
        text: &str,
        now_ms: u64,
    ) -> Option<Output> {
        if !self.fp_allowed(fingerprint) {
            return None;
        }
        let mut out = Output::default();
        if !self.try_send_text(fingerprint, message_id, text, now_ms, &mut out) {
            return None;
        }
        Some(out)
    }

    /// Immediate send for real-time controls; never queues. Refreshes our
    /// discovery on the route first (pre-control), like the Kotlin path.
    pub fn send_text_now(
        &mut self,
        fingerprint: &str,
        message_id: &str,
        text: &str,
        now_ms: u64,
    ) -> Option<Output> {
        if !self.fp_allowed(fingerprint) {
            return None;
        }
        let route = self.sendable_route(fingerprint)?;
        let mut out = self.discovery_to_route(&route, now_ms);
        if !self.try_send_text(fingerprint, message_id, text, now_ms, &mut out) {
            return None;
        }
        Some(out)
    }

    /// Private file transfer over a live route. Never queued: a large stale
    /// transfer after a reconnect is worse than an immediate route failure.
    pub fn send_file(
        &mut self,
        fingerprint: &str,
        message_id: &str,
        content: &[u8],
        file_name: &str,
        mime_type: &str,
        now_ms: u64,
    ) -> Option<Output> {
        if !self.fp_allowed(fingerprint)
            || message_id.is_empty()
            || content.is_empty()
            || content.len() > MAX_FILE_TRANSFER_BYTES
        {
            return None;
        }
        let route = self.sendable_route(fingerprint)?;
        let peer_id_hex = self.route_peer_id(&route)?;
        let peer_id = parse_id8(&peer_id_hex)?;
        let payload = mesh::file_packet::FilePacket {
            file_name: Some(file_name.to_string()),
            file_size: Some(content.len() as u64),
            mime_type: Some(mime_type.to_string()),
            message_id: Some(message_id.to_string()),
            content: content.to_vec(),
        }
        .encode()?;
        let mut packet = mesh::Packet::new(msg_type::FILE_TRANSFER, DEFAULT_TTL, self.wall(now_ms), self.my_peer_id);
        packet.recipient_id = Some(peer_id);
        packet.payload = payload;
        if packet.payload.len() > MAX_V1_FILE_PAYLOAD_BYTES {
            packet.version = 2;
        }
        if !mesh::sign_packet(&mut packet, &self.signer) {
            return None;
        }
        let bytes = packet.encode()?;
        let mut out = self.discovery_to_route(&route, now_ms);
        self.write_maybe_fragmented(&route, bytes, msg_type::FILE_TRANSFER, now_ms, &mut out);
        Some(out)
    }

    /// Confirm that a decoded private text or file was accepted by the
    /// recipient application. This uses bitchat's existing encrypted
    /// `delivered` payload, so receipts expose no message metadata over BLE.
    pub fn send_delivery_ack(
        &mut self,
        fingerprint: &str,
        message_id: &str,
        now_ms: u64,
    ) -> Option<Output> {
        if !self.fp_allowed(fingerprint) {
            return None;
        }
        let route = self.sendable_route(fingerprint)?;
        let peer_id = parse_id8(&self.route_peer_id(&route)?)?;
        let plain = mesh::encode_delivered_plaintext(message_id)?;
        let ciphertext = self.encrypt_on_route(&route, &plain)?;
        let packet = mesh::encrypted_packet(
            self.my_peer_id,
            peer_id,
            DEFAULT_TTL,
            self.wall(now_ms),
            ciphertext,
        );
        let bytes = packet.encode()?;
        let mut out = Output::default();
        self.write_maybe_fragmented(&route, bytes, msg_type::NOISE_ENCRYPTED, now_ms, &mut out);
        Some(out)
    }

    /// PUBLIC broadcast (the BLE "Mesh" channel) to every connected peer app.
    /// Returns None when nothing is connected.
    pub fn broadcast(&mut self, text: &str, now_ms: u64) -> Option<Output> {
        let mut packet = mesh::Packet::new(msg_type::MESSAGE, DEFAULT_TTL, self.wall(now_ms), self.my_peer_id);
        packet.payload = text.as_bytes().to_vec();
        if !mesh::sign_packet(&mut packet, &self.signer) {
            return None;
        }
        let bytes = packet.encode()?;
        // Skip our own echo if it loops back through a relay. The key must use
        // the SAME timestamp the packet carries on the wire.
        self.remember_broadcast(format!("{}-{}", self.my_peer_id_hex, packet.timestamp));
        let mut out = Output::default();
        let mut peers = 0;
        let link_ids: Vec<LinkId> = self
            .links
            .iter()
            .filter(|(_, l)| self.bind_allowed(&l.bind))
            .map(|(id, _)| id.clone())
            .collect();
        for id in link_ids {
            out.commands.push(Command::WriteLink {
                conn: id.conn,
                instance: id.instance,
                bytes: bytes.clone(),
                after_ms: 0,
            });
            peers += 1;
        }
        let servers: Vec<String> = self
            .server_conns
            .iter()
            .filter(|(_, s)| self.bind_allowed(&s.bind))
            .map(|(c, _)| c.clone())
            .collect();
        for conn in servers {
            out.commands.push(Command::NotifyConn {
                conn,
                bytes: bytes.clone(),
                after_ms: 0,
            });
            peers += 1;
        }
        if peers == 0 {
            return None;
        }
        Some(out)
    }

    // ── Config ──

    pub fn set_nickname(&mut self, nickname: &str, now_ms: u64) -> Output {
        let next = nickname.trim().to_string();
        if next == self.nickname {
            return Output::default();
        }
        self.nickname = next;
        self.discovery_broadcast(now_ms)
    }

    pub fn set_sonar_payload(&mut self, payload: Option<Vec<u8>>, now_ms: u64) -> Output {
        if payload == self.sonar_payload {
            return Output::default();
        }
        self.sonar_payload = payload;
        self.discovery_broadcast(now_ms)
    }

    /// Known-only policy. A disallowed client instance drops only ITS link
    /// (an allowed sibling app keeps the shared connection); a disallowed
    /// server peer is disconnected.
    pub fn set_allowlist(&mut self, allowed: Option<Vec<String>>) -> Output {
        self.allowlist =
            allowed.map(|v| v.into_iter().map(|s| s.to_lowercase()).collect());
        let mut out = Output::default();
        if self.allowlist.is_none() {
            return out;
        }
        let bad_links: Vec<LinkId> = self
            .links
            .iter()
            .filter(|(_, l)| !self.bind_allowed(&l.bind))
            .map(|(id, _)| id.clone())
            .collect();
        for id in bad_links {
            out.merge(self.drop_client_link(&id));
        }
        let bad_servers: Vec<String> = self
            .server_conns
            .iter()
            .filter(|(_, s)| !self.bind_allowed(&s.bind))
            .map(|(c, _)| c.clone())
            .collect();
        for conn in bad_servers {
            self.server_conns.remove(&conn);
            out.commands.push(Command::CancelServer { conn });
        }
        // Pending dials have no identity yet: conservatively cut them.
        let pending: Vec<String> = self.dialing.keys().cloned().collect();
        for conn in pending {
            self.cleanup_client_conn(&conn);
            out.commands.push(Command::Disconnect { conn });
        }
        out
    }

    pub fn reset(&mut self) {
        self.links.clear();
        self.server_conns.clear();
        self.dialing.clear();
        self.connected.clear();
        self.recent_dials.clear();
        self.signing_key_by_peer.clear();
        self.fingerprint_by_peer.clear();
        self.identity_lru.clear();
        self.identity_refused = 0;
        self.pending_sonar.clear();
        self.seen_broadcasts.clear();
        self.seen_files.clear();
        self.reassembler = mesh::fragment::Reassembler::new();
        self.last_heartbeat_ms = 0;
        self.last_tick_ms = 0;
        self.last_refresh_ms.clear();
    }

    // ── Internals ──

    fn fp_allowed(&self, fingerprint: &str) -> bool {
        match &self.allowlist {
            None => true,
            Some(a) => !fingerprint.is_empty() && a.contains(&fingerprint.to_lowercase()),
        }
    }

    /// Move an already-pinned peer to the most-recently-seen end of the LRU and
    /// stamp it with `now_ms`. Linear in the map size (≤ IDENTITY_MAP_CAP) but
    /// called only once per re-announce (~every 15-38s per peer), so the scan is
    /// negligible.
    fn note_identity_seen(&mut self, sender_key: &str, now_ms: u64) {
        if let Some(pos) = self.identity_lru.iter().position(|(k, _)| k == sender_key) {
            self.identity_lru.remove(pos);
        }
        self.identity_lru.push_back((sender_key.to_string(), now_ms));
    }

    /// Evict the single stalest pinned identity if it is older than
    /// `IDENTITY_PROTECT_MS`, removing it from both maps and the LRU in lockstep.
    /// Returns `false` (evicting nothing) when the stalest pin is still within
    /// the protection window, i.e. every pin is recent, so the caller refuses
    /// the new identity rather than dropping a live peer's pin.
    ///
    /// Deliberately recency-only: keying protection on "is this peer bound to a
    /// live link" instead would leave every relay-only peer evictable (only a
    /// `direct`, full-TTL announce sets a binding), which hands the wipe-and-
    /// rebind attack straight back for exactly the multi-hop peers the mesh
    /// exists to reach. Removing the resulting new-peer refusal needs a
    /// per-origin pin quota, not a weaker protection rule — see `identity_refused`.
    fn evict_stalest_identity(&mut self, now_ms: u64) -> bool {
        match self.identity_lru.front() {
            Some((_, last_seen)) if now_ms.saturating_sub(*last_seen) >= IDENTITY_PROTECT_MS => {}
            _ => return false,
        }
        if let Some((stale, _)) = self.identity_lru.pop_front() {
            self.signing_key_by_peer.remove(&stale);
            self.fingerprint_by_peer.remove(&stale);
        }
        true
    }

    /// `(pinned identities, announces refused because every pin was protected)`.
    /// Diagnostics only — a non-zero refusal count means the pin map is
    /// saturated with live peers and new-peer discovery is degraded.
    pub fn identity_pressure(&self) -> (usize, u64) {
        (self.signing_key_by_peer.len(), self.identity_refused)
    }

    #[cfg(test)]
    fn set_identity_map_cap(&mut self, cap: usize) {
        self.identity_map_cap = cap;
    }

    fn bind_allowed(&self, bind: &PeerBinding) -> bool {
        match &self.allowlist {
            None => true,
            Some(_) => bind
                .fingerprint
                .as_deref()
                .map(|fp| self.fp_allowed(fp))
                .unwrap_or(false),
        }
    }

    fn announce_bytes(&self, now_ms: u64) -> Option<Vec<u8>> {
        if self.nickname.is_empty() {
            return None;
        }
        let announce = mesh::Announce {
            nickname: self.nickname.clone(),
            noise_public_key: hex::decode(&self.noise_public_hex).ok()?,
            signing_public_key: self.signer.public_key().to_vec(),
            direct_neighbors: None,
        };
        let mut packet =
            mesh::Packet::new(msg_type::ANNOUNCE, DEFAULT_TTL, self.wall(now_ms), self.my_peer_id);
        packet.payload = announce.encode()?;
        if !mesh::sign_packet(&mut packet, &self.signer) {
            return None;
        }
        packet.encode()
    }

    fn sonar_bytes(&self, now_ms: u64) -> Option<Vec<u8>> {
        let payload = self.sonar_payload.clone()?;
        // Signed with the same Ed25519 key as the announce — iOS rejects an
        // unsigned 0x53 as unverified.
        let mut packet =
            mesh::Packet::new(msg_type::SONAR_ANNOUNCE, DEFAULT_TTL, self.wall(now_ms), self.my_peer_id);
        packet.payload = payload;
        if !mesh::sign_packet(&mut packet, &self.signer) {
            return None;
        }
        packet.encode()
    }

    /// Announce + 0x53 to every link and server connection ("heartbeat" /
    /// nickname / payload refresh). Android had no periodic announce before
    /// PR #291; iOS announces every 15–38s while connected.
    fn discovery_broadcast(&mut self, now_ms: u64) -> Output {
        let mut out = Output::default();
        let ann = self.announce_bytes(now_ms);
        let sonar = self.sonar_bytes(now_ms);
        let link_ids: Vec<LinkId> = self.links.keys().cloned().collect();
        for id in link_ids {
            if let Some(a) = &ann {
                out.commands.push(Command::WriteLink {
                    conn: id.conn.clone(),
                    instance: id.instance,
                    bytes: a.clone(),
                    after_ms: 0,
                });
            }
            if let Some(p) = &sonar {
                out.commands.push(Command::WriteLink {
                    conn: id.conn.clone(),
                    instance: id.instance,
                    bytes: p.clone(),
                    after_ms: SONAR_STAGGER_MS,
                });
            }
        }
        let servers: Vec<String> = self.server_conns.keys().cloned().collect();
        for conn in servers {
            if let Some(a) = &ann {
                out.commands.push(Command::NotifyConn {
                    conn: conn.clone(),
                    bytes: a.clone(),
                    after_ms: 0,
                });
            }
            if let Some(p) = &sonar {
                out.commands.push(Command::NotifyConn {
                    conn: conn.clone(),
                    bytes: p.clone(),
                    after_ms: SONAR_STAGGER_MS,
                });
            }
        }
        out
    }

    fn discovery_to_route(&self, route: &Origin, now_ms: u64) -> Output {
        let mut out = Output::default();
        let ann = self.announce_bytes(now_ms);
        let sonar = self.sonar_bytes(now_ms);
        for bytes in [ann, sonar].into_iter().flatten() {
            match route {
                Origin::Client(id) => out.commands.push(Command::WriteLink {
                    conn: id.conn.clone(),
                    instance: id.instance,
                    bytes,
                    after_ms: 0,
                }),
                Origin::Server(conn) => out.commands.push(Command::NotifyConn {
                    conn: conn.clone(),
                    bytes,
                    after_ms: 0,
                }),
            }
        }
        out
    }

    /// The route with an established, writable Noise session to `fingerprint`
    /// (client links first — we were the initiator there).
    fn sendable_route(&self, fingerprint: &str) -> Option<Origin> {
        if !self.fp_allowed(fingerprint) {
            return None;
        }
        for (id, l) in &self.links {
            if l.bind.fingerprint.as_deref() == Some(fingerprint)
                && l.noise.as_ref().map(|n| n.established()).unwrap_or(false)
            {
                return Some(Origin::Client(id.clone()));
            }
        }
        for (conn, s) in &self.server_conns {
            if s.bind.fingerprint.as_deref() == Some(fingerprint)
                && s.noise.as_ref().map(|n| n.established()).unwrap_or(false)
            {
                return Some(Origin::Server(conn.clone()));
            }
        }
        None
    }

    fn route_peer_id(&self, route: &Origin) -> Option<String> {
        match route {
            Origin::Client(id) => self.links.get(id)?.bind.peer_id_hex.clone(),
            Origin::Server(conn) => self.server_conns.get(conn)?.bind.peer_id_hex.clone(),
        }
    }

    fn try_send_text(
        &mut self,
        fingerprint: &str,
        message_id: &str,
        text: &str,
        now_ms: u64,
        out: &mut Output,
    ) -> bool {
        let Some(route) = self.sendable_route(fingerprint) else {
            return false;
        };
        let Some(peer_id_hex) = self.route_peer_id(&route) else {
            return false;
        };
        let Some(peer_id) = parse_id8(&peer_id_hex) else {
            return false;
        };
        let pm = mesh::PrivateMessage {
            message_id: message_id.to_string(),
            content: text.to_string(),
        };
        let Some(plain) = mesh::encode_private_message_plaintext(&pm) else {
            return false;
        };
        let Some(ciphertext) = self.encrypt_on_route(&route, &plain) else {
            return false;
        };
        let packet =
            mesh::encrypted_packet(self.my_peer_id, peer_id, DEFAULT_TTL, self.wall(now_ms), ciphertext);
        let Some(bytes) = packet.encode() else {
            return false;
        };
        self.write_maybe_fragmented(&route, bytes, msg_type::NOISE_ENCRYPTED, now_ms, out);
        true
    }

    fn encrypt_on_route(&mut self, route: &Origin, plain: &[u8]) -> Option<Vec<u8>> {
        let noise = match route {
            Origin::Client(id) => self.links.get_mut(id)?.noise.as_mut(),
            Origin::Server(conn) => self.server_conns.get_mut(conn)?.noise.as_mut(),
        }?;
        match noise {
            NoiseState::Session(s) => s.encrypt(plain).ok(),
            _ => None,
        }
    }

    /// One value per GATT write; fragment anything over the MTU-safe bound.
    fn write_maybe_fragmented(
        &mut self,
        route: &Origin,
        packet_bytes: Vec<u8>,
        original_type: u8,
        now_ms: u64,
        out: &mut Output,
    ) {
        let peer_id_hex = self.route_peer_id(route).unwrap_or_default();
        let mut pieces: Vec<Vec<u8>> = Vec::new();
        if packet_bytes.len() <= MAX_SINGLE_GATT_PACKET_BYTES {
            pieces.push(packet_bytes);
        } else {
            let frag_id = self.random_fragment_id(now_ms);
            let Some(frags) = mesh::file_packet::fragment(
                &packet_bytes,
                frag_id,
                original_type,
                FRAGMENT_CHUNK_SIZE,
            ) else {
                return;
            };
            let recipient = parse_id8(&peer_id_hex);
            for f in frags {
                let mut p = mesh::Packet::new(
                    msg_type::FRAGMENT,
                    DEFAULT_TTL,
                    self.wall(now_ms),
                    self.my_peer_id,
                );
                p.recipient_id = recipient;
                p.payload = f.encode_payload();
                if let Some(b) = p.encode() {
                    pieces.push(b);
                }
            }
        }
        for bytes in pieces {
            match route {
                Origin::Client(id) => out.commands.push(Command::WriteLink {
                    conn: id.conn.clone(),
                    instance: id.instance,
                    bytes,
                    after_ms: 0,
                }),
                Origin::Server(conn) => out.commands.push(Command::NotifyConn {
                    conn: conn.clone(),
                    bytes,
                    after_ms: 0,
                }),
            }
        }
    }

    /// Deterministic enough for fragment correlation; uniqueness comes from
    /// the (sender, id) reassembly key plus a strictly monotonic sequence —
    /// two fragmented sends in the same millisecond must not collide.
    fn random_fragment_id(&mut self, now_ms: u64) -> [u8; 8] {
        self.fragment_seq += 1;
        let mut h = Sha256::new();
        h.update(self.my_peer_id);
        h.update(now_ms.to_be_bytes());
        h.update(self.fragment_seq.to_be_bytes());
        let d = h.finalize();
        let mut id = [0u8; 8];
        id.copy_from_slice(&d[..8]);
        id
    }

    fn remember_broadcast(&mut self, key: String) -> bool {
        if self.seen_broadcasts.len() > SEEN_CAP {
            self.seen_broadcasts.clear();
        }
        self.seen_broadcasts.insert(key)
    }

    fn cleanup_client_conn(&mut self, conn: &str) {
        self.links.retain(|id, _| id.conn != conn);
        self.dialing.remove(conn);
        self.connected.remove(conn);
    }

    /// Drop ONE client instance link; close the connection once no instance
    /// remains on it (a sibling app on the same controller may still be live).
    fn drop_client_link(&mut self, id: &LinkId) -> Output {
        let mut out = Output::default();
        self.links.remove(id);
        if !self.links.keys().any(|k| k.conn == id.conn) {
            self.cleanup_client_conn(&id.conn);
            out.commands.push(Command::Disconnect {
                conn: id.conn.clone(),
            });
        }
        out
    }

    fn fingerprint_of(noise_public_key_hex: &str) -> String {
        match hex::decode(noise_public_key_hex) {
            Ok(bytes) => hex::encode(Sha256::digest(&bytes)),
            Err(_) => String::new(),
        }
    }

    fn handle_packet(&mut self, origin: Origin, bytes: &[u8], now_ms: u64) -> Output {
        let mut out = Output::default();
        let Some(packet) = mesh::Packet::decode(bytes) else {
            return out;
        };
        match packet.type_ {
            msg_type::ANNOUNCE => self.handle_announce(origin, bytes, &packet, now_ms, &mut out),
            msg_type::MESSAGE => self.handle_broadcast(origin, bytes, &packet, &mut out),
            msg_type::NOISE_HANDSHAKE => {
                self.handle_handshake(origin, &packet, now_ms, &mut out)
            }
            msg_type::NOISE_ENCRYPTED => self.handle_encrypted(origin, &packet, &mut out),
            msg_type::FRAGMENT => {
                if let Some(frag) = mesh::fragment::Fragment::decode_payload(&packet.payload) {
                    if let Some(full) = self.reassembler.add(packet.sender_id, &frag) {
                        out.merge(self.handle_packet(origin, &full, now_ms));
                    }
                }
            }
            msg_type::FILE_TRANSFER => self.handle_file(origin, bytes, &packet, &mut out),
            msg_type::SONAR_ANNOUNCE => self.handle_sonar(origin, bytes, &packet, &mut out),
            _ => {}
        }
        out
    }

    fn origin_bind(&mut self, origin: &Origin) -> Option<&mut PeerBinding> {
        match origin {
            Origin::Client(id) => self.links.get_mut(id).map(|l| &mut l.bind),
            Origin::Server(conn) => self.server_conns.get_mut(conn).map(|s| &mut s.bind),
        }
    }

    /// The fingerprint this route proved through a completed Noise handshake.
    /// `None` while the handshake is still in flight, where the binding rests
    /// on the announce alone.
    fn origin_authenticated_fingerprint(&self, origin: &Origin) -> Option<String> {
        let (noise, bind) = match origin {
            Origin::Client(id) => self.links.get(id).map(|l| (&l.noise, &l.bind))?,
            Origin::Server(conn) => self.server_conns.get(conn).map(|s| (&s.noise, &s.bind))?,
        };
        noise.as_ref().filter(|n| n.established())?;
        bind.fingerprint.clone()
    }

    fn handle_announce(
        &mut self,
        origin: Origin,
        raw: &[u8],
        packet: &mesh::Packet,
        now_ms: u64,
        out: &mut Output,
    ) {
        let Some(announce) = mesh::Announce::decode(&packet.payload) else {
            return;
        };
        let sender_hex = hex::encode(packet.sender_id);
        if mesh::peer_id_from_noise_key(&announce.noise_public_key) != sender_hex {
            return;
        }
        if !mesh::verify_packet(packet, &announce.signing_public_key) {
            return;
        }
        // Our own announce can loop back over a second connection via a relay.
        if sender_hex.eq_ignore_ascii_case(&self.my_peer_id_hex) {
            return;
        }
        let _ = raw;
        // Only a full-TTL announce may bind the physical neighbour; a relayed
        // one still belongs in the radar but must never own link routing.
        let mut direct = packet.ttl == DEFAULT_TTL;
        let noise_pub_hex = hex::encode(&announce.noise_public_key);
        let fp = Self::fingerprint_of(&noise_pub_hex);
        // An established Noise session has already pinned this link to an
        // authenticated static key. Announces are replayable by any listener,
        // so one naming a different identity is not evidence about who is on
        // the other end of this link: keep it in the radar as relayed, but
        // never let it move the route off the authenticated peer.
        if direct
            && self
                .origin_authenticated_fingerprint(&origin)
                .is_some_and(|bound| !bound.eq_ignore_ascii_case(&fp))
        {
            direct = false;
        }
        let signing_hex = hex::encode(&announce.signing_public_key);
        let sender_key = sender_hex.to_lowercase();
        match self.signing_key_by_peer.get(&sender_key) {
            Some(existing) if !existing.eq_ignore_ascii_case(&signing_hex) => return,
            Some(_) => {
                // Known peer re-announcing with its pinned key: refresh recency
                // so a concurrent flood of new identities cannot evict it.
                self.note_identity_seen(&sender_key, now_ms);
            }
            None => {
                // At capacity, evict only the single stalest pin, and only if it
                // is older than the protection window. If every pin is recent (a
                // flood), refuse this new identity rather than drop a live peer's
                // pin: the old wholesale `clear()` let an attacker flood
                // IDENTITY_MAP_CAP throwaway announces to drop a victim's pin and
                // then rebind its fingerprint to an attacker signing key.
                // The refusal is counted, not silent — see `identity_refused`.
                if self.signing_key_by_peer.len() >= self.identity_map_cap
                    && !self.evict_stalest_identity(now_ms)
                {
                    self.identity_refused += 1;
                    return;
                }
                self.signing_key_by_peer
                    .insert(sender_key.clone(), signing_hex.clone());
                self.note_identity_seen(&sender_key, now_ms);
            }
        }
        if !fp.is_empty() {
            self.fingerprint_by_peer.insert(sender_key.clone(), fp.clone());
        }
        if !self.fp_allowed(&fp) {
            if direct {
                match &origin {
                    Origin::Client(id) => out.merge(self.drop_client_link(&id.clone())),
                    Origin::Server(conn) => {
                        self.server_conns.remove(conn);
                        out.commands.push(Command::CancelServer { conn: conn.clone() });
                    }
                }
            }
            return;
        }
        if direct {
            if let Some(bind) = self.origin_bind(&origin) {
                bind.peer_id_hex = Some(sender_hex.clone());
                if !fp.is_empty() {
                    bind.fingerprint = Some(fp.clone());
                }
            }
            // A real peer answered — keep this connection past the dial window.
            if let Origin::Client(id) = &origin {
                self.dialing.remove(&id.conn);
            }
        }
        out.events.push(AppEvent::PeerAnnounced {
            fingerprint: fp.clone(),
            nickname: announce.nickname.clone(),
            peer_id_hex: sender_hex.clone(),
            direct,
        });
        // A 0x53 that arrived before this announce can be verified now.
        if let Some(pending) = self.pending_sonar.remove(&sender_key) {
            if let Some(p) = mesh::Packet::decode(&pending) {
                if p.type_ == msg_type::SONAR_ANNOUNCE
                    && mesh::verify_packet(&p, &announce.signing_public_key)
                    && !fp.is_empty()
                {
                    out.events.push(AppEvent::SonarPayload {
                        fingerprint: fp.clone(),
                        payload: p.payload,
                    });
                }
            }
        }
        if !direct {
            return;
        }
        // A Direct announce over the SERVER role proves the peer app is alive
        // — but the peripheral waits for the peer's 0x10, so if our CLIENT
        // connection to the same handle has no instance link for this peer
        // (its CCC subscribe failed, or the dead link was culled), the peer is
        // unreachable for DMs with no recovery until the whole connection
        // drops. Re-discover instances so the client side can re-subscribe and
        // initiate. (On platforms where server/client handles differ this
        // never fires; the cooldown bounds discovery churn.)
        if let Origin::Server(conn) = &origin {
            let has_client_route = self
                .links
                .iter()
                .any(|(id, l)| id.conn == *conn && l.bind.fingerprint.as_deref() == Some(&fp));
            if self.connected.contains(conn) && !has_client_route && self.sendable_route(&fp).is_none() {
                let due = self
                    .last_refresh_ms
                    .get(conn)
                    .map(|t| now_ms.saturating_sub(*t) >= REFRESH_INSTANCES_COOLDOWN_MS)
                    .unwrap_or(true);
                if due {
                    self.last_refresh_ms.insert(conn.clone(), now_ms);
                    out.commands.push(Command::RefreshInstances { conn: conn.clone() });
                }
            }
        }
        // Central opens the Noise link for DMs (initiator); peripheral waits
        // for the peer's 0x10. Retry a half-open handshake after
        // HANDSHAKE_RETRY_MS — a lost m2/m3 must not block DMs forever.
        if let Origin::Client(id) = &origin {
            let start = match self.links.get(id).and_then(|l| l.noise.as_ref()) {
                None => true,
                Some(NoiseState::Handshake { started_ms, .. }) => {
                    now_ms.saturating_sub(*started_ms) > HANDSHAKE_RETRY_MS
                }
                Some(NoiseState::Session(_)) => false,
            };
            if start {
                if let Ok(mut hs) = NoiseHandshake::initiator(&self.noise_private) {
                    if let Ok(m1) = hs.write_message() {
                        if let Some(l) = self.links.get_mut(id) {
                            l.noise = Some(NoiseState::Handshake {
                                hs,
                                started_ms: now_ms,
                            });
                        }
                        if let Some(peer_id) = parse_id8(&sender_hex) {
                            let p = mesh::handshake_packet(
                                self.my_peer_id,
                                peer_id,
                                DEFAULT_TTL,
                                self.wall(now_ms),
                                m1,
                            );
                            if let Some(b) = p.encode() {
                                out.commands.push(Command::WriteLink {
                                    conn: id.conn.clone(),
                                    instance: id.instance,
                                    bytes: b,
                                    after_ms: 0,
                                });
                            }
                        }
                    }
                }
            }
        }
    }

    fn handle_broadcast(
        &mut self,
        origin: Origin,
        raw: &[u8],
        packet: &mesh::Packet,
        out: &mut Output,
    ) {
        let Ok(content) = String::from_utf8(packet.payload.clone()) else {
            return;
        };
        let sender_hex = hex::encode(packet.sender_id);
        let sender_key = sender_hex.to_lowercase();
        // A broadcast is signed by its sender. If we hold that sender's pinned
        // signing key (learned from their verified announce), the signature
        // MUST verify: otherwise an attacker who reuses a known peer's public
        // `sender_id` could have a forged message attributed to that peer's
        // pinned fingerprint. Senders we have not yet heard announce from can
        // carry no such pin, so they are attributed to the raw id below and
        // never to a stolen fingerprint. (This is the verify-when-pinned half of
        // `handle_sonar`'s gate; unlike sonar, an unpinned broadcast is still
        // delivered under its raw id rather than buffered as pending.)
        if let Some(signing_hex) = self.signing_key_by_peer.get(&sender_key) {
            let Ok(signing_key) = hex::decode(signing_hex) else {
                return;
            };
            if !mesh::verify_packet(packet, &signing_key) {
                return;
            }
        }
        let key = format!("{}-{}", sender_hex, packet.timestamp);
        if !self.remember_broadcast(key) {
            return;
        }
        let fp = self
            .fingerprint_by_peer
            .get(&sender_key)
            .cloned()
            .unwrap_or_else(|| sender_hex.clone());
        if !self.fp_allowed(&fp) {
            return;
        }
        out.events.push(AppEvent::BroadcastReceived {
            fingerprint: fp,
            sender_id_hex: sender_hex.clone(),
            content,
            timestamp_ms: packet.timestamp,
        });
        // Multi-hop: flood onward so the mesh extends past direct neighbours.
        // A SIBLING instance on the same connection is a different app and
        // DOES get the relay — two apps on one controller can't hear each
        // other over the air; we are their only bridge.
        if packet.ttl <= 1 {
            return;
        }
        let mut relayed = raw.to_vec();
        relayed[2] = packet.ttl - 1; // TTL is header byte 2, signed as zero
        let (skip_link, skip_conn) = match &origin {
            Origin::Client(id) => (Some(id.clone()), id.conn.clone()),
            Origin::Server(conn) => (None, conn.clone()),
        };
        let link_ids: Vec<LinkId> = self
            .links
            .iter()
            .filter(|(id, l)| Some(*id) != skip_link.as_ref().map(|s| s).map(|s| s) && self.bind_allowed(&l.bind))
            .map(|(id, _)| id.clone())
            .collect();
        for id in link_ids {
            if skip_link.as_ref() == Some(&id) {
                continue;
            }
            out.commands.push(Command::WriteLink {
                conn: id.conn,
                instance: id.instance,
                bytes: relayed.clone(),
                after_ms: 0,
            });
        }
        let servers: Vec<String> = self
            .server_conns
            .iter()
            .filter(|(c, s)| **c != skip_conn && self.bind_allowed(&s.bind))
            .map(|(c, _)| c.clone())
            .collect();
        for conn in servers {
            out.commands.push(Command::NotifyConn {
                conn,
                bytes: relayed.clone(),
                after_ms: 0,
            });
        }
    }

    fn handle_handshake(
        &mut self,
        origin: Origin,
        packet: &mesh::Packet,
        now_ms: u64,
        out: &mut Output,
    ) {
        let sender_hex = hex::encode(packet.sender_id);
        match origin {
            Origin::Server(conn) => {
                let Some(s) = self.server_conns.get_mut(&conn) else {
                    return;
                };
                if s.noise.as_ref().map(|n| n.established()).unwrap_or(false) {
                    return;
                }
                if s.noise.is_none() {
                    match NoiseHandshake::responder(&self.noise_private) {
                        Ok(hs) => {
                            s.noise = Some(NoiseState::Handshake {
                                hs,
                                started_ms: now_ms,
                            })
                        }
                        Err(_) => return,
                    }
                }
                let Some(NoiseState::Handshake { hs, .. }) = s.noise.as_mut() else {
                    return;
                };
                if hs.read_message(&packet.payload).is_err() {
                    s.noise = None;
                    return;
                }
                // Bind the sender id so replies are addressed correctly even
                // before the announce lands on this connection.
                if s.bind.peer_id_hex.is_none() {
                    s.bind.peer_id_hex = Some(sender_hex.clone());
                }
                if hs.is_finished() {
                    self.finish_noise_server(&conn, out);
                } else {
                    let m2 = match hs.write_message() {
                        Ok(m) => m,
                        Err(_) => {
                            s.noise = None;
                            return;
                        }
                    };
                    let peer = parse_id8(&sender_hex).unwrap_or([0u8; 8]);
                    let p = mesh::handshake_packet(
                        self.my_peer_id,
                        peer,
                        DEFAULT_TTL,
                        self.wall(now_ms),
                        m2,
                    );
                    if let Some(b) = p.encode() {
                        out.commands.push(Command::NotifyConn {
                            conn: conn.clone(),
                            bytes: b,
                            after_ms: 0,
                        });
                    }
                }
            }
            Origin::Client(id) => {
                let Some(l) = self.links.get_mut(&id) else {
                    return;
                };
                let Some(NoiseState::Handshake { hs, .. }) = l.noise.as_mut() else {
                    return;
                };
                if hs.read_message(&packet.payload).is_err() {
                    l.noise = None;
                    return;
                }
                if !hs.is_finished() {
                    let m3 = match hs.write_message() {
                        Ok(m) => m,
                        Err(_) => {
                            l.noise = None;
                            return;
                        }
                    };
                    let peer = l
                        .bind
                        .peer_id_hex
                        .as_deref()
                        .and_then(parse_id8)
                        .unwrap_or([0u8; 8]);
                    let p = mesh::handshake_packet(
                        self.my_peer_id,
                        peer,
                        DEFAULT_TTL,
                        self.wall(now_ms),
                        m3,
                    );
                    if let Some(b) = p.encode() {
                        out.commands.push(Command::WriteLink {
                            conn: id.conn.clone(),
                            instance: id.instance,
                            bytes: b,
                            after_ms: 0,
                        });
                    }
                }
                // Re-borrow: is_finished may have flipped after m3.
                let finished = matches!(
                    self.links.get(&id).and_then(|l| l.noise.as_ref()),
                    Some(NoiseState::Handshake { hs, .. }) if hs.is_finished()
                );
                if finished {
                    self.finish_noise_client(&id, out);
                }
            }
        }
    }

    /// The fingerprint a completed handshake is allowed to own, or `None` when
    /// the peer's static key is missing or contradicts the bound identity.
    ///
    /// Noise XX authenticates the remote static key, but nothing else on this
    /// link does. `bind.fingerprint` comes from an announce, and an announce is
    /// a self-contained signed packet that anyone who overheard it can replay
    /// verbatim. Without this check an attacker replays a victim's announce on
    /// its own link, completes the handshake with its own key, and takes over
    /// the victim's route: `sendable_route` would hand the victim's DMs to the
    /// attacker's session, and `handle_encrypted` would attribute the
    /// attacker's traffic to the victim.
    fn authenticated_fingerprint(hs: &NoiseHandshake, bind: &PeerBinding) -> Option<String> {
        let fp = Self::fingerprint_of(&hex::encode(hs.remote_static()?));
        if fp.is_empty() {
            return None;
        }
        match bind.fingerprint.as_deref() {
            Some(bound) if !bound.eq_ignore_ascii_case(&fp) => None,
            _ => Some(fp),
        }
    }

    fn finish_noise_client(&mut self, id: &LinkId, out: &mut Output) {
        let Some(l) = self.links.get_mut(id) else {
            return;
        };
        let Some(NoiseState::Handshake { hs, .. }) = l.noise.take() else {
            return;
        };
        let Some(fp) = Self::authenticated_fingerprint(&hs, &l.bind) else {
            l.noise = None;
            return;
        };
        match hs.into_session() {
            Ok(session) => {
                l.noise = Some(NoiseState::Session(session));
                l.bind.fingerprint = Some(fp.clone());
                self.link_established(&fp, out);
            }
            Err(_) => l.noise = None,
        }
    }

    fn finish_noise_server(&mut self, conn: &str, out: &mut Output) {
        let Some(s) = self.server_conns.get_mut(conn) else {
            return;
        };
        let Some(NoiseState::Handshake { hs, .. }) = s.noise.take() else {
            return;
        };
        // The responder authenticates the initiator's static key here, so the
        // fingerprint is derived from that key even when the announce is still
        // in flight. A later announce may only agree with it, never move it.
        let Some(fp) = Self::authenticated_fingerprint(&hs, &s.bind) else {
            s.noise = None;
            return;
        };
        match hs.into_session() {
            Ok(session) => {
                s.noise = Some(NoiseState::Session(session));
                s.bind.fingerprint = Some(fp.clone());
                self.link_established(&fp, out);
            }
            Err(_) => s.noise = None,
        }
    }

    fn link_established(&mut self, fingerprint: &str, out: &mut Output) {
        if !self.fp_allowed(fingerprint) {
            return;
        }
        out.events.push(AppEvent::LinkEstablished {
            fingerprint: fingerprint.to_string(),
        });
    }

    fn handle_encrypted(&mut self, origin: Origin, packet: &mesh::Packet, out: &mut Output) {
        let fp = match &origin {
            Origin::Client(id) => self.links.get(id).and_then(|l| l.bind.fingerprint.clone()),
            Origin::Server(conn) => self
                .server_conns
                .get(conn)
                .and_then(|s| s.bind.fingerprint.clone()),
        };
        if self.allowlist.is_some() {
            let allowed = fp.as_deref().map(|f| self.fp_allowed(f)).unwrap_or(false);
            if !allowed {
                match &origin {
                    Origin::Client(id) => out.merge(self.drop_client_link(&id.clone())),
                    Origin::Server(conn) => {
                        self.server_conns.remove(conn);
                        out.commands.push(Command::CancelServer { conn: conn.clone() });
                    }
                }
                return;
            }
        }
        // Prefer this route's own session; fall back to the peer's session on
        // its OTHER route (snow does not advance the nonce on a failed
        // decrypt, so the fallback can't desync a healthy session).
        let plain = self
            .decrypt_on_origin(&origin, &packet.payload)
            .or_else(|| {
                fp.as_deref()
                    .and_then(|f| self.decrypt_on_any_route(f, &packet.payload))
            });
        let Some(plain) = plain else {
            return;
        };
        let Some((t, rest)) = mesh::split_noise_plaintext(&plain) else {
            return;
        };
        let id_fp = fp
            .or_else(|| match &origin {
                Origin::Client(id) => self
                    .links
                    .get(id)
                    .and_then(|l| l.bind.peer_id_hex.clone()),
                Origin::Server(conn) => self
                    .server_conns
                    .get(conn)
                    .and_then(|s| s.bind.peer_id_hex.clone()),
            })
            .unwrap_or_else(|| match &origin {
                Origin::Client(id) => id.conn.clone(),
                Origin::Server(conn) => conn.clone(),
            });
        match t {
            noise_payload::PRIVATE_MESSAGE => {
                let Some(pm) = mesh::PrivateMessage::decode(rest) else {
                    return;
                };
                out.events.push(AppEvent::TextReceived {
                    fingerprint: id_fp,
                    message_id: pm.message_id,
                    content: pm.content,
                });
            }
            noise_payload::DELIVERED => {
                let Ok(message_id) = String::from_utf8(rest.to_vec()) else {
                    return;
                };
                if message_id.is_empty() {
                    return;
                }
                out.events.push(AppEvent::DeliveryReceived {
                    fingerprint: id_fp,
                    message_id,
                });
            }
            _ => {}
        }
    }

    fn decrypt_on_origin(&mut self, origin: &Origin, ciphertext: &[u8]) -> Option<Vec<u8>> {
        let noise = match origin {
            Origin::Client(id) => self.links.get_mut(id)?.noise.as_mut()?,
            Origin::Server(conn) => self.server_conns.get_mut(conn)?.noise.as_mut()?,
        };
        match noise {
            NoiseState::Session(s) => s.decrypt(ciphertext).ok(),
            _ => None,
        }
    }

    fn decrypt_on_any_route(&mut self, fingerprint: &str, ciphertext: &[u8]) -> Option<Vec<u8>> {
        let link_ids: Vec<LinkId> = self
            .links
            .iter()
            .filter(|(_, l)| l.bind.fingerprint.as_deref() == Some(fingerprint))
            .map(|(id, _)| id.clone())
            .collect();
        for id in link_ids {
            if let Some(p) = self.decrypt_on_origin(&Origin::Client(id), ciphertext) {
                return Some(p);
            }
        }
        let conns: Vec<String> = self
            .server_conns
            .iter()
            .filter(|(_, s)| s.bind.fingerprint.as_deref() == Some(fingerprint))
            .map(|(c, _)| c.clone())
            .collect();
        for conn in conns {
            if let Some(p) = self.decrypt_on_origin(&Origin::Server(conn), ciphertext) {
                return Some(p);
            }
        }
        None
    }

    fn handle_file(
        &mut self,
        origin: Origin,
        raw: &[u8],
        packet: &mesh::Packet,
        out: &mut Output,
    ) {
        let _ = raw;
        let Some(recipient) = packet.recipient_id else {
            return;
        };
        if hex::encode(recipient) != self.my_peer_id_hex {
            return;
        }
        let fp = match &origin {
            Origin::Client(id) => self.links.get(id).and_then(|l| {
                l.bind
                    .fingerprint
                    .clone()
                    .or_else(|| l.bind.peer_id_hex.clone())
            }),
            Origin::Server(conn) => self.server_conns.get(conn).and_then(|s| {
                s.bind
                    .fingerprint
                    .clone()
                    .or_else(|| s.bind.peer_id_hex.clone())
            }),
        };
        let Some(fp) = fp else {
            return;
        };
        let payload_hash8 = {
            let d = Sha256::digest(&packet.payload);
            hex::encode(&d[..8])
        };
        let transfer_key = format!(
            "{}-{}-{}",
            hex::encode(packet.sender_id),
            packet.timestamp,
            payload_hash8
        );
        if self.seen_files.len() > SEEN_CAP {
            self.seen_files.clear();
        }
        if !self.seen_files.insert(transfer_key.clone()) {
            return;
        }
        let Some(file) = mesh::file_packet::FilePacket::decode(&packet.payload) else {
            return;
        };
        if file.content.is_empty() || file.content.len() > MAX_FILE_TRANSFER_BYTES {
            return;
        }
        out.events.push(AppEvent::FileReceived {
            fingerprint: fp,
            transfer_key,
            message_id: file.message_id,
            file_name: file.file_name,
            mime_type: file.mime_type,
            content: file.content,
            timestamp_ms: packet.timestamp,
        });
    }

    fn handle_sonar(
        &mut self,
        origin: Origin,
        raw: &[u8],
        packet: &mesh::Packet,
        out: &mut Output,
    ) {
        let _ = origin;
        let sender_hex = hex::encode(packet.sender_id);
        if sender_hex.eq_ignore_ascii_case(&self.my_peer_id_hex) {
            return;
        }
        let sender_key = sender_hex.to_lowercase();
        let (Some(fp), Some(signing_hex)) = (
            self.fingerprint_by_peer.get(&sender_key).cloned(),
            self.signing_key_by_peer.get(&sender_key).cloned(),
        ) else {
            // Packet order is not guaranteed: cache the full signed packet by
            // sender until its verified announce supplies the signing key.
            if self.pending_sonar.len() >= MAX_PENDING_SONAR {
                self.pending_sonar.clear();
            }
            self.pending_sonar.insert(sender_key, raw.to_vec());
            return;
        };
        let Ok(signing_key) = hex::decode(&signing_hex) else {
            return;
        };
        if !mesh::verify_packet(packet, &signing_key) {
            return;
        }
        if !self.fp_allowed(&fp) {
            return;
        }
        out.events.push(AppEvent::SonarPayload {
            fingerprint: fp,
            payload: packet.payload.clone(),
        });
    }
}

fn parse_id8(hexs: &str) -> Option<[u8; 8]> {
    let bytes = hex::decode(hexs).ok()?;
    bytes.try_into().ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::noise::NoiseKeypair;

    fn engine(seed: u8, nickname: &str) -> Engine {
        let kp = NoiseKeypair::generate().expect("keypair");
        let mut sk = [0u8; 32];
        sk.copy_from_slice(&kp.private);
        Engine::new(sk, hex::encode(&kp.public), [seed; 32], nickname.to_string())
            .expect("engine")
    }

    /// Pump packets between an initiator engine (client link) and a responder
    /// engine (server conn) until both stop emitting, returning app events.
    fn pump(
        a: &mut Engine,
        link: &LinkId,
        b: &mut Engine,
        b_conn: &str,
        first: Output,
        now: u64,
    ) -> (Vec<AppEvent>, Vec<AppEvent>) {
        let mut a_events = first.events.clone();
        let mut b_events = Vec::new();
        let mut a_out: Vec<Command> = first.commands;
        let mut b_out: Vec<Command> = Vec::new();
        for _ in 0..12 {
            if a_out.is_empty() && b_out.is_empty() {
                break;
            }
            for c in std::mem::take(&mut a_out) {
                if let Command::WriteLink { bytes, .. } = c {
                    let o = b.on_server_rx(b_conn, &bytes, now);
                    b_events.extend(o.events);
                    b_out.extend(o.commands);
                }
            }
            for c in std::mem::take(&mut b_out) {
                if let Command::NotifyConn { bytes, .. } = c {
                    let o = a.on_client_rx(&link.conn, link.instance, &bytes, now);
                    a_events.extend(o.events);
                    a_out.extend(o.commands);
                }
            }
        }
        (a_events, b_events)
    }

    /// Drive A (central) fully up against B (peripheral): dial, discover one
    /// instance, subscribe, exchange announces, complete the Noise handshake.
    fn establish(a: &mut Engine, b: &mut Engine, conn: &str, instance: i32, now: u64) -> LinkId {
        let out = a.on_dial_request(conn, now);
        assert!(matches!(out.commands.as_slice(), [Command::Dial { .. }]));
        a.on_client_connected(conn, now);
        b.on_server_connected("droid", now);
        let out = a.on_instances_discovered(conn, &[instance], now);
        assert_eq!(out.commands.len(), 1);
        let sub = a.on_subscribe_result(conn, instance, true, now);
        let link = LinkId {
            conn: conn.to_string(),
            instance,
        };
        // B's announce arrives (as if from its discovery burst).
        let b_ann = b.announce_bytes(now).expect("b announce");
        let ann_out = a.on_client_rx(conn, instance, &b_ann, now);
        // A's announce + handshake m1 flow to B; pump to completion.
        let mut first = Output::default();
        first.merge(sub);
        first.merge(ann_out);
        let (a_events, b_events) = pump(a, &link, b, "droid", first, now);
        assert!(
            a_events
                .iter()
                .any(|e| matches!(e, AppEvent::LinkEstablished { .. })),
            "initiator link must establish, got {a_events:?}"
        );
        assert!(
            b_events
                .iter()
                .any(|e| matches!(e, AppEvent::LinkEstablished { .. })),
            "responder link must establish, got {b_events:?}"
        );
        link
    }

    fn fp_of(e: &Engine) -> String {
        Engine::fingerprint_of(&e.noise_public_hex)
    }

    /// An announce is a self-contained signed packet, so anyone who overhears
    /// one can replay it verbatim on their own link. Completing Noise with the
    /// attacker's own static key must not then hand it the victim's route.
    #[test]
    fn replayed_announce_cannot_bind_an_attacker_link_to_the_victim_route() {
        let mut a = engine(1, "pixel");
        let mut attacker = engine(7, "attacker");
        let victim = engine(9, "victim");
        let victim_fp = fp_of(&victim);
        let now = 1_000;
        let (conn, instance) = ("84:2F", 34);

        a.on_dial_request(conn, now);
        a.on_client_connected(conn, now);
        attacker.on_server_connected("droid", now);
        a.on_instances_discovered(conn, &[instance], now);
        let sub = a.on_subscribe_result(conn, instance, true, now);
        let link = LinkId {
            conn: conn.to_string(),
            instance,
        };

        // The attacker replays the victim's genuine, signature-valid announce,
        // then answers the handshake with its own key.
        let stolen = victim.announce_bytes(now).expect("victim announce");
        let mut first = Output::default();
        first.merge(sub);
        first.merge(a.on_client_rx(conn, instance, &stolen, now));
        let (a_events, _) = pump(&mut a, &link, &mut attacker, "droid", first, now);

        assert!(
            !a_events.iter().any(|e| matches!(
                e,
                AppEvent::LinkEstablished { fingerprint } if *fingerprint == victim_fp
            )),
            "no link may establish under the victim's fingerprint, got {a_events:?}"
        );
        assert!(
            !a.has_link(&victim_fp),
            "the attacker's link must not become the victim's route"
        );
        assert!(
            a.send_text_now(&victim_fp, "mid", "secret", now).is_none(),
            "a DM to the victim must not leave over the attacker's session"
        );
    }

    /// The same binding in the other arrival order: the handshake authenticates
    /// first, and a replayed announce arrives afterwards. The authenticated key
    /// owns the link, so the late announce may not move it.
    #[test]
    fn late_replayed_announce_cannot_move_an_authenticated_link() {
        let mut attacker = engine(7, "attacker");
        let mut a = engine(1, "pixel");
        let victim = engine(9, "victim");
        let (victim_fp, attacker_fp) = (fp_of(&victim), fp_of(&attacker));
        let now = 1_000;

        // `a` is the peripheral; the attacker establishes under its own key.
        establish(&mut attacker, &mut a, "84:2F", 34, now);
        assert!(
            a.has_link(&attacker_fp),
            "the attacker's own link is legitimate and must still work"
        );

        let stolen = victim.announce_bytes(now).expect("victim announce");
        let out = a.on_server_rx("droid", &stolen, now + 1);

        assert!(
            !a.has_link(&victim_fp),
            "a replayed announce must not repoint the victim's route at this link"
        );
        assert!(
            a.has_link(&attacker_fp),
            "the authenticated binding must survive the replay"
        );
        assert!(
            out.events.iter().any(|e| matches!(
                e,
                AppEvent::PeerAnnounced { fingerprint, direct, .. }
                    if *fingerprint == victim_fp && !*direct
            )),
            "the victim stays in the radar as relayed, not as this link's neighbour, got {:?}",
            out.events
        );
    }

    #[test]
    fn announce_binds_and_starts_handshake_then_dm_round_trip() {
        let mut a = engine(1, "pixel");
        let mut b = engine(9, "vincent-osx");
        let link = establish(&mut a, &mut b, "84:2F", 34, 1_000);
        assert!(a.has_link(&fp_of(&b)));
        assert!(b.has_link(&fp_of(&a)));

        // DM A→B over the established session.
        let out = a
            .send_text(&fp_of(&b), "mid-1", "e2e-test", 2_000)
            .expect("allowed");
        let mut got = Vec::new();
        for c in out.commands {
            if let Command::WriteLink { bytes, .. } = c {
                got.extend(b.on_server_rx("droid", &bytes, 2_000).events);
            }
        }
        assert!(
            got.iter().any(|e| matches!(
                e,
                AppEvent::TextReceived { content, .. } if content == "e2e-test"
            )),
            "B must receive the DM, got {got:?}"
        );
        let _ = link;
    }

    /// The failure this guards is invisible from the sending side: Android's GATT
    /// stack reports success for a 512-byte write that iOS never surfaces to
    /// `didReceiveWrite`, so the media simply never arrives and no error is
    /// logged anywhere. Keeping every write inside the 256-byte block is what
    /// makes it arrive, and that must hold for text and media, for the first
    /// full-size fragment and the short trailing one, and after any future
    /// change to the packet or fragment header.
    #[test]
    fn every_fragment_write_stays_in_the_reliable_block() {
        // The derived chunk size is only correct while the measured per-write
        // overhead is. Assert it directly so a header change fails here rather
        // than silently pushing fragments into the 512-byte bucket in the field.
        let frags = mesh::file_packet::fragment(
            &vec![0u8; FRAGMENT_CHUNK_SIZE * 3],
            [9u8; 8],
            msg_type::NOISE_ENCRYPTED,
            FRAGMENT_CHUNK_SIZE,
        )
        .expect("fragment");
        let mut probe = mesh::Packet::new(msg_type::FRAGMENT, DEFAULT_TTL, 1_000, [1u8; 8]);
        probe.recipient_id = Some([2u8; 8]);
        probe.payload = frags[0].encode_payload();
        let encoded = probe.encode().expect("encode").len();
        assert_eq!(
            encoded - FRAGMENT_CHUNK_SIZE,
            FRAGMENT_PACKET_OVERHEAD_BYTES,
            "per-write fragment overhead moved; re-measure FRAGMENT_PACKET_OVERHEAD_BYTES",
        );
        assert!(
            encoded <= RELIABLE_GATT_WRITE_BYTES,
            "a full-size fragment encodes to {encoded} bytes, over the reliable block",
        );

        // Sizes chosen to exercise an exact multiple of the chunk, a 1-byte
        // trailing fragment, and a payload just past the single-write bound.
        for payload_len in [
            MAX_SINGLE_GATT_PACKET_BYTES + 1,
            FRAGMENT_CHUNK_SIZE * 4,
            FRAGMENT_CHUNK_SIZE * 4 + 1,
            64 * 1024,
        ] {
            let mut a = engine(1, "pixel");
            let mut b = engine(9, "iphone");
            let _link = establish(&mut a, &mut b, "84:2F", 34, 1_000);

            let media = vec![0x42; payload_len];
            let send = a
                .send_file(&fp_of(&b), "mid", &media, "photo.jpg", "image/jpeg", 3_000)
                .expect("media route");
            let mut writes = 0usize;
            for command in &send.commands {
                if let Command::WriteLink { bytes, .. } | Command::NotifyConn { bytes, .. } = command
                {
                    writes += 1;
                    assert!(
                        bytes.len() <= RELIABLE_GATT_WRITE_BYTES,
                        "media payload {payload_len} produced a {}-byte write",
                        bytes.len(),
                    );
                }
            }
            assert!(writes > 1, "payload {payload_len} should have fragmented");

            // Text takes the same fragmentation path once it outgrows a single
            // write, so it has to hold there too.
            let long_text = "x".repeat(payload_len.min(32 * 1024));
            let text = a
                .send_text(&fp_of(&b), "text-mid", &long_text, 3_100)
                .expect("text route");
            for command in &text.commands {
                if let Command::WriteLink { bytes, .. } | Command::NotifyConn { bytes, .. } = command
                {
                    assert!(
                        bytes.len() <= RELIABLE_GATT_WRITE_BYTES,
                        "text of {} chars produced a {}-byte write",
                        long_text.len(),
                        bytes.len(),
                    );
                }
            }
        }
    }

    #[test]
    fn recipient_delivery_receipt_round_trips_for_text_and_media() {
        let mut a = engine(1, "pixel");
        let mut b = engine(9, "iphone");
        let link = establish(&mut a, &mut b, "84:2F", 34, 1_000);

        let text_ack = b
            .send_delivery_ack(&fp_of(&a), "text-mid", 2_000)
            .expect("receipt route");
        let mut a_events = Vec::new();
        for command in text_ack.commands {
            if let Command::NotifyConn { bytes, .. } = command {
                a_events.extend(a.on_client_rx(&link.conn, link.instance, &bytes, 2_000).events);
            }
        }
        assert!(a_events.iter().any(|event| matches!(
            event,
            AppEvent::DeliveryReceived { message_id, .. } if message_id == "text-mid"
        )));

        let media = vec![0x42; 4_096];
        let send = a
            .send_file(
                &fp_of(&b),
                "media-mid",
                &media,
                "photo.jpg",
                "image/jpeg",
                3_000,
            )
            .expect("media route");
        assert!(send.commands.iter().all(|command| match command {
            Command::WriteLink { bytes, .. } | Command::NotifyConn { bytes, .. } => {
                bytes.len() <= RELIABLE_GATT_WRITE_BYTES
            }
            _ => true,
        }));
        let mut b_events = Vec::new();
        for command in send.commands {
            if let Command::WriteLink { bytes, .. } = command {
                b_events.extend(b.on_server_rx("droid", &bytes, 3_000).events);
            }
        }
        assert!(b_events.iter().any(|event| matches!(
            event,
            AppEvent::FileReceived { message_id, content, .. }
                if message_id.as_deref() == Some("media-mid") && content == &media
        )));

        let media_ack = b
            .send_delivery_ack(&fp_of(&a), "media-mid", 3_100)
            .expect("media receipt route");
        let mut receipt_events = Vec::new();
        for command in media_ack.commands {
            if let Command::NotifyConn { bytes, .. } = command {
                receipt_events.extend(
                    a.on_client_rx(&link.conn, link.instance, &bytes, 3_100).events,
                );
            }
        }
        assert!(receipt_events.iter().any(|event| matches!(
            event,
            AppEvent::DeliveryReceived { message_id, .. } if message_id == "media-mid"
        )));
    }

    #[test]
    fn two_instances_on_one_connection_are_distinct_peers() {
        let mut a = engine(1, "pixel");
        let mut sonar_mac = engine(5, "Vincenzo-Mac");
        let mut bitchat_mac = engine(9, "vincent-osx");
        let now = 1_000;
        a.on_dial_request("84:2F", now);
        a.on_client_connected("84:2F", now);
        a.on_instances_discovered("84:2F", &[25, 34], now);
        a.on_subscribe_result("84:2F", 25, true, now);
        a.on_subscribe_result("84:2F", 34, true, now);
        let ann25 = sonar_mac.announce_bytes(now).unwrap();
        let ann34 = bitchat_mac.announce_bytes(now).unwrap();
        let e25 = a.on_client_rx("84:2F", 25, &ann25, now);
        let e34 = a.on_client_rx("84:2F", 34, &ann34, now);
        let name = |o: &Output| {
            o.events
                .iter()
                .find_map(|e| match e {
                    AppEvent::PeerAnnounced { nickname, direct, .. } if *direct => {
                        Some(nickname.clone())
                    }
                    _ => None,
                })
                .unwrap()
        };
        assert_eq!(name(&e25), "Vincenzo-Mac");
        assert_eq!(name(&e34), "vincent-osx");
        assert_eq!(a.connected_count(), 2);
    }

    #[test]
    fn dead_instance_culls_itself_while_sibling_lives() {
        let mut a = engine(1, "pixel");
        let sonar_mac = engine(5, "Vincenzo-Mac");
        let bitchat_mac = engine(9, "vincent-osx");
        let now = 10_000;
        a.on_dial_request("84:2F", now);
        a.on_client_connected("84:2F", now);
        a.on_instances_discovered("84:2F", &[25, 34], now);
        a.on_subscribe_result("84:2F", 25, true, now);
        a.on_subscribe_result("84:2F", 34, true, now);
        // Both peers answer (clears the dial's announce deadline).
        let ann25 = sonar_mac.announce_bytes(now).unwrap();
        let ann34 = bitchat_mac.announce_bytes(now).unwrap();
        a.on_client_rx("84:2F", 25, &ann25, now);
        a.on_client_rx("84:2F", 34, &ann34, now);
        // Instance 25 chatters, 34 goes silent. Regular ticks keep arriving.
        let mut t = now;
        let mut disconnected = false;
        while t < now + LINK_STALE_MS + 2 * TICK_MS {
            t += TICK_MS;
            a.on_client_rx("84:2F", 25, &[0u8; 4], t); // undecodable but rx
            let out = a.on_tick(t);
            disconnected |= out
                .commands
                .iter()
                .any(|c| matches!(c, Command::Disconnect { .. }));
        }
        assert!(!disconnected, "sibling keeps the connection alive");
        assert!(a.is_linked_conn("84:2F"));
        // Now BOTH go silent → the connection closes.
        let mut closed = false;
        while t < now + 3 * LINK_STALE_MS {
            t += TICK_MS;
            closed |= a
                .on_tick(t)
                .commands
                .iter()
                .any(|c| matches!(c, Command::Disconnect { .. }));
        }
        assert!(closed, "fully-silent connection must be culled");
        assert!(!a.is_linked_conn("84:2F"));
    }

    #[test]
    fn freeze_resume_does_not_cull() {
        let mut a = engine(1, "pixel");
        let peer = engine(5, "mac");
        let now = 10_000;
        a.on_dial_request("84:2F", now);
        a.on_client_connected("84:2F", now);
        a.on_instances_discovered("84:2F", &[25], now);
        a.on_subscribe_result("84:2F", 25, true, now);
        let ann = peer.announce_bytes(now).unwrap();
        a.on_client_rx("84:2F", 25, &ann, now);
        a.on_tick(now + TICK_MS);
        // Process frozen for 10 minutes; first tick after resume must re-seed,
        // not cull.
        let resumed = now + TICK_MS + 600_000;
        let out = a.on_tick(resumed);
        assert!(
            !out.commands
                .iter()
                .any(|c| matches!(c, Command::Disconnect { .. })),
            "resume tick must not cull for our own downtime"
        );
        assert!(a.is_linked_conn("84:2F"));
    }

    #[test]
    fn dial_gating_backoff_and_cap() {
        let mut a = engine(1, "pixel");
        assert_eq!(a.on_dial_request("c1", 1_000).commands.len(), 1);
        // Dedup while dialing.
        assert_eq!(a.on_dial_request("c1", 1_100).commands.len(), 0);
        // Backoff after cleanup.
        a.on_client_disconnected("c1");
        assert_eq!(a.on_dial_request("c1", 2_000).commands.len(), 0);
        assert_eq!(
            a.on_dial_request("c1", 1_000 + REDIAL_BACKOFF_MS).commands.len(),
            1
        );
        // Cap at MAX_CLIENTS concurrent.
        let mut accepted = 1;
        for i in 0..10 {
            let conn = format!("x{i}");
            accepted += a.on_dial_request(&conn, 50_000).commands.len();
        }
        assert_eq!(accepted, MAX_CLIENTS);
    }

    #[test]
    fn self_echo_announce_is_ignored() {
        let mut a = engine(1, "pixel");
        let now = 1_000;
        a.on_dial_request("relay", now);
        a.on_client_connected("relay", now);
        a.on_instances_discovered("relay", &[7], now);
        a.on_subscribe_result("relay", 7, true, now);
        let own = a.announce_bytes(now).unwrap();
        let out = a.on_client_rx("relay", 7, &own, now);
        assert!(out.events.is_empty(), "own announce must not surface");
    }

    // Documents a KNOWN GAP, not a guarantee we are happy with. The engine
    // judges freshness by the driver-supplied monotonic `now_ms` and never by
    // the wall clock in the packet, so a peer months out of date is announced
    // normally - which is why a Pixel whose clock had drifted 153 days was
    // visible to Android while being silently invisible to every Apple peer
    // (Apple enforces a +/-120s skew gate and a 900s announce-age gate).
    //
    // The flip side is that this engine accepts a replayed captured announce
    // indefinitely: nothing here binds acceptance to freshness evidence that an
    // attacker cannot replay. Apple's windows at least force a replay to happen
    // within 120s of capture. Closing this properly needs a challenge/nonce on
    // both platforms; until then this test pins current behaviour so a change
    // is deliberate rather than accidental.
    #[test]
    fn announce_from_peer_with_skewed_wall_clock_is_still_accepted() {
        let mut a = engine(1, "pixel");
        let mut far = engine(9, "wrong-clock-phone");

        let now = 1_000_000;
        // 153 days in the past, the real skew measured on the test device.
        let skewed_wall = 1_000u64;
        far.set_wall_clock(now, skewed_wall);
        a.set_wall_clock(now, now + 153 * 24 * 60 * 60 * 1000);

        a.on_dial_request("relay", now);
        a.on_client_connected("relay", now);
        a.on_instances_discovered("relay", &[7], now);
        a.on_subscribe_result("relay", 7, true, now);

        let skewed_announce = far.announce_bytes(now).expect("announce bytes");
        let out = a.on_client_rx("relay", 7, &skewed_announce, now);

        assert!(
            out.events
                .iter()
                .any(|e| matches!(e, AppEvent::PeerAnnounced { .. })),
            "an announce from a peer with a badly skewed clock must still surface the peer"
        );
    }

    #[test]
    fn relayed_announce_lists_but_does_not_bind_or_handshake() {
        let mut a = engine(1, "pixel");
        let far = engine(7, "far-peer");
        let now = 1_000;
        a.on_dial_request("relay", now);
        a.on_client_connected("relay", now);
        a.on_instances_discovered("relay", &[7], now);
        a.on_subscribe_result("relay", 7, true, now);
        let mut ann = far.announce_bytes(now).unwrap();
        ann[2] = DEFAULT_TTL - 1; // relayed: TTL already decremented
        let out = a.on_client_rx("relay", 7, &ann, now);
        assert!(out.events.iter().any(|e| matches!(
            e,
            AppEvent::PeerAnnounced { direct: false, .. }
        )));
        assert!(
            !out.commands
                .iter()
                .any(|c| matches!(c, Command::WriteLink { .. })),
            "no handshake toward a relayed peer"
        );
    }

    #[test]
    fn broadcast_relays_to_sibling_instance_with_decremented_ttl() {
        let mut a = engine(1, "pixel");
        let sender = engine(7, "sender");
        let now = 1_000;
        a.on_dial_request("84:2F", now);
        a.on_client_connected("84:2F", now);
        a.on_instances_discovered("84:2F", &[25, 34], now);
        a.on_subscribe_result("84:2F", 25, true, now);
        a.on_subscribe_result("84:2F", 34, true, now);
        let bytes = {
            let mut p = mesh::Packet::new(msg_type::MESSAGE, DEFAULT_TTL, now, sender.my_peer_id);
            p.payload = b"hello mesh".to_vec();
            assert!(mesh::sign_packet(&mut p, &sender.signer));
            p.encode().unwrap()
        };
        let out = a.on_client_rx("84:2F", 25, &bytes, now);
        assert!(out
            .events
            .iter()
            .any(|e| matches!(e, AppEvent::BroadcastReceived { .. })));
        let relayed: Vec<_> = out
            .commands
            .iter()
            .filter_map(|c| match c {
                Command::WriteLink {
                    instance, bytes, ..
                } => Some((*instance, bytes.clone())),
                _ => None,
            })
            .collect();
        assert_eq!(relayed.len(), 1, "only the sibling instance gets the relay");
        assert_eq!(relayed[0].0, 34);
        assert_eq!(relayed[0].1[2], DEFAULT_TTL - 1);
        // Duplicate delivery of the same broadcast is dropped.
        let dup = a.on_client_rx("84:2F", 34, &bytes, now);
        assert!(dup.events.is_empty());
    }

    #[test]
    fn send_text_without_live_route_fails_instead_of_hiding_plaintext() {
        let mut a = engine(1, "pixel");
        let b = engine(9, "peer");
        let fp = fp_of(&b);
        assert!(
            a.send_text(&fp, "mid-q", "must stay in app outbox", 500).is_none(),
            "a missing live route must be visible to the app router"
        );
    }

    #[test]
    fn allowlist_drops_disallowed_instance_but_keeps_sibling() {
        let mut a = engine(1, "pixel");
        let mut sonar_mac = engine(5, "Vincenzo-Mac");
        let bitchat_mac = engine(9, "vincent-osx");
        let now = 1_000;
        a.on_dial_request("84:2F", now);
        a.on_client_connected("84:2F", now);
        a.on_instances_discovered("84:2F", &[25, 34], now);
        a.on_subscribe_result("84:2F", 25, true, now);
        a.on_subscribe_result("84:2F", 34, true, now);
        let ann25 = sonar_mac.announce_bytes(now).unwrap();
        let ann34 = bitchat_mac.announce_bytes(now).unwrap();
        a.on_client_rx("84:2F", 25, &ann25, now);
        a.on_client_rx("84:2F", 34, &ann34, now);
        // Allow only Sonar-Mac.
        let out = a.set_allowlist(Some(vec![fp_of(&sonar_mac)]));
        assert!(
            !out.commands
                .iter()
                .any(|c| matches!(c, Command::Disconnect { .. })),
            "the allowed sibling keeps the shared connection"
        );
        assert_eq!(a.connected_count(), 1);
        // A fresh disallowed announce drops only its own instance link.
        let ann34b = bitchat_mac.announce_bytes(now + 10).unwrap();
        let out = a.on_client_rx("84:2F", 34, &ann34b, now + 10);
        assert!(out.events.is_empty());
        // The connection survives because instance 25 is still allowed.
        assert!(a.is_linked_conn("84:2F"));
        let _ = sonar_mac.set_nickname("x", now); // silence unused-mut lint
    }

    #[test]
    fn signing_key_change_is_rejected() {
        let mut a = engine(1, "pixel");
        let now = 1_000;
        a.on_dial_request("84:2F", now);
        a.on_client_connected("84:2F", now);
        a.on_instances_discovered("84:2F", &[7], now);
        a.on_subscribe_result("84:2F", 7, true, now);
        // Two announcers with the SAME noise key (same sender id) but
        // different signing keys — the second must be rejected.
        let kp = NoiseKeypair::generate().unwrap();
        let mut sk = [0u8; 32];
        sk.copy_from_slice(&kp.private);
        let pk = hex::encode(&kp.public);
        let e1 = Engine::new(sk, pk.clone(), [11u8; 32], "p".into()).unwrap();
        let e2 = Engine::new(sk, pk, [22u8; 32], "p".into()).unwrap();
        let a1 = e1.announce_bytes(now).unwrap();
        let a2 = e2.announce_bytes(now).unwrap();
        assert!(!a.on_client_rx("84:2F", 7, &a1, now).events.is_empty());
        assert!(
            a.on_client_rx("84:2F", 7, &a2, now).events.is_empty(),
            "in-place signing-key change is an impersonation"
        );
    }

    #[test]
    fn dial_deadline_recycles_unanswered_connections() {
        let mut a = engine(1, "pixel");
        a.on_dial_request("dead", 1_000);
        // Never connected: recycled at the establish deadline.
        let out = a.on_dial_deadline("dead", 1_000 + CONNECT_ESTABLISH_MS);
        assert!(out
            .commands
            .iter()
            .any(|c| matches!(c, Command::Disconnect { .. })));
        assert!(!a.is_linked_conn("dead"));
        // Connected but never announced: recycled at the announce deadline.
        a.on_dial_request("mute", 60_000);
        a.on_client_connected("mute", 60_100);
        assert!(a
            .on_dial_deadline("mute", 60_000 + CONNECT_ESTABLISH_MS)
            .commands
            .is_empty());
        let out =
            a.on_dial_deadline("mute", 60_000 + CONNECT_ESTABLISH_MS + ANNOUNCE_TIMEOUT_MS);
        assert!(out
            .commands
            .iter()
            .any(|c| matches!(c, Command::Disconnect { .. })));
    }

    #[test]
    fn server_direct_announce_without_client_route_triggers_rediscovery() {
        // Peer app alive behind our live client connection (it announces over
        // its own inbound central leg) but its instance link is gone: the
        // engine must ask the driver to re-discover so the client side can
        // re-subscribe and initiate — otherwise the peer is unreachable for
        // DMs until the whole connection drops.
        let mut a = engine(1, "pixel");
        let peer = engine(9, "vincent-osx");
        let now = 1_000;
        a.on_dial_request("84:2F", now);
        a.on_client_connected("84:2F", now);
        a.on_instances_discovered("84:2F", &[25], now);
        a.on_subscribe_result("84:2F", 25, true, now);
        // Complete the dial with the OTHER app's announce so the connection
        // survives the announce deadline.
        let sonar_mac = engine(5, "Vincenzo-Mac");
        let ann = sonar_mac.announce_bytes(now).unwrap();
        a.on_client_rx("84:2F", 25, &ann, now);
        // vincent-osx announces via the server leg (same handle on Android).
        a.on_server_connected("84:2F", now);
        let ann_osx = peer.announce_bytes(now).unwrap();
        let out = a.on_server_rx("84:2F", &ann_osx, now);
        assert!(
            out.commands
                .iter()
                .any(|c| matches!(c, Command::RefreshInstances { conn } if conn == "84:2F")),
            "must re-discover instances, got {:?}",
            out.commands
        );
        // Cooldown: an immediate repeat announce must not re-trigger.
        let again = a.on_server_rx("84:2F", &peer.announce_bytes(now + 10).unwrap(), now + 10);
        assert!(
            !again
                .commands
                .iter()
                .any(|c| matches!(c, Command::RefreshInstances { .. })),
            "cooldown must suppress repeats"
        );
    }

    #[test]
    fn heartbeat_covers_all_links_and_servers() {
        let mut a = engine(1, "pixel");
        let now = 1_000;
        a.on_dial_request("84:2F", now);
        a.on_client_connected("84:2F", now);
        a.on_instances_discovered("84:2F", &[25, 34], now);
        a.on_subscribe_result("84:2F", 25, true, now);
        a.on_subscribe_result("84:2F", 34, true, now);
        a.on_server_connected("central-1", now);
        let out = a.on_tick(now + HEARTBEAT_MS + 1);
        let writes = out
            .commands
            .iter()
            .filter(|c| matches!(c, Command::WriteLink { .. }))
            .count();
        let notifies = out
            .commands
            .iter()
            .filter(|c| matches!(c, Command::NotifyConn { .. }))
            .count();
        assert_eq!(writes, 2, "one announce per instance link");
        assert_eq!(notifies, 1, "one announce per server connection");
    }

    /// Open a client link on `a` ready to receive `on_client_rx`.
    fn open_link(a: &mut Engine, conn: &str, instance: i32, now: u64) {
        a.on_dial_request(conn, now);
        a.on_client_connected(conn, now);
        a.on_instances_discovered(conn, &[instance], now);
        a.on_subscribe_result(conn, instance, true, now);
    }

    fn announce_from(
        noise_pub: &[u8],
        signer: &mesh::MeshSigner,
        nick: &str,
        ttl: u8,
        now: u64,
    ) -> Vec<u8> {
        let sender_hex = mesh::peer_id_from_noise_key(noise_pub);
        let mut sender_id = [0u8; 8];
        hex::decode_to_slice(&sender_hex, &mut sender_id).expect("peer id hex");
        let announce = mesh::Announce {
            nickname: nick.to_string(),
            noise_public_key: noise_pub.to_vec(),
            signing_public_key: signer.public_key().to_vec(),
            direct_neighbors: None,
        };
        let mut p = mesh::Packet::new(msg_type::ANNOUNCE, ttl, now, sender_id);
        p.payload = announce.encode().expect("announce encode");
        assert!(mesh::sign_packet(&mut p, signer), "sign announce");
        p.encode().expect("packet encode")
    }

    fn broadcast_from(sender_id: [u8; 8], text: &str, ts: u64, signer: &mesh::MeshSigner) -> Vec<u8> {
        let mut p = mesh::Packet::new(msg_type::MESSAGE, DEFAULT_TTL, ts, sender_id);
        p.payload = text.as_bytes().to_vec();
        assert!(mesh::sign_packet(&mut p, signer), "sign broadcast");
        p.encode().expect("packet encode")
    }

    /// A broadcast whose `sender_id` reuses a known peer's (public) id but is
    /// signed by an attacker must not be attributed to that peer's pinned
    /// fingerprint. Without the signature gate, `handle_broadcast` looked the
    /// sender up in `fingerprint_by_peer` and emitted the forged content under
    /// the victim's identity, then flooded it onward.
    #[test]
    fn forged_broadcast_reusing_a_pinned_sender_id_is_dropped() {
        let mut a = engine(1, "pixel");
        let victim = engine(7, "victim");
        let attacker = mesh::MeshSigner::from_seed(&[42u8; 32]);
        let now = 1_000;
        open_link(&mut a, "84:2F", 25, now);

        // Victim announces, so `a` pins its signing key and fingerprint.
        let victim_noise = hex::decode(&victim.noise_public_hex).unwrap();
        let ann = announce_from(&victim_noise, &victim.signer, "victim", DEFAULT_TTL, now);
        a.on_client_rx("84:2F", 25, &ann, now);
        let victim_fp = Engine::fingerprint_of(&victim.noise_public_hex);

        // A genuine broadcast from the victim is received under its fingerprint.
        let genuine = broadcast_from(victim.my_peer_id, "hi all", now, &victim.signer);
        let out = a.on_client_rx("84:2F", 25, &genuine, now);
        assert!(
            out.events.iter().any(|e| matches!(
                e,
                AppEvent::BroadcastReceived { fingerprint, content, .. }
                    if fingerprint == &victim_fp && content == "hi all"
            )),
            "victim's own signed broadcast should be delivered"
        );

        // A forged broadcast reusing the victim's sender_id but signed by the
        // attacker must be dropped, not attributed to the victim.
        let forged = broadcast_from(victim.my_peer_id, "forged", now + 5, &attacker);
        let out = a.on_client_rx("84:2F", 25, &forged, now + 5);
        assert!(
            !out.events.iter().any(
                |e| matches!(e, AppEvent::BroadcastReceived { content, .. } if content == "forged")
            ),
            "forged broadcast under a pinned peer's id must not be delivered"
        );
        assert!(
            !out.commands.iter().any(|c| matches!(c, Command::WriteLink { .. })),
            "forged broadcast must not be relayed onward"
        );
    }

    /// A genuine broadcast that a relay hop has TTL-decremented must still
    /// verify. This holds only because `mesh::signing_bytes` zeroes `ttl` before
    /// signing; pin it here so the broadcast gate can never silently take
    /// multi-hop public chat down with it.
    #[test]
    fn relayed_signed_broadcast_still_verifies() {
        let mut a = engine(1, "pixel");
        let victim = engine(7, "victim");
        let now = 1_000;
        open_link(&mut a, "84:2F", 25, now);

        let victim_noise = hex::decode(&victim.noise_public_hex).unwrap();
        let ann = announce_from(&victim_noise, &victim.signer, "victim", DEFAULT_TTL, now);
        a.on_client_rx("84:2F", 25, &ann, now);
        let victim_fp = Engine::fingerprint_of(&victim.noise_public_hex);

        let mut bytes = broadcast_from(victim.my_peer_id, "relayed hi", now, &victim.signer);
        bytes[2] = DEFAULT_TTL - 3; // a relay hop mutated TTL in place
        let out = a.on_client_rx("84:2F", 25, &bytes, now);
        assert!(
            out.events.iter().any(|e| matches!(
                e,
                AppEvent::BroadcastReceived { fingerprint, content, .. }
                    if fingerprint == &victim_fp && content == "relayed hi"
            )),
            "TTL-decremented relayed broadcast must still verify and be delivered"
        );
    }

    /// The TOFU signing-key pin for an actively-announcing peer must survive a
    /// flood of throwaway identities. The old wholesale `clear()` at
    /// IDENTITY_MAP_CAP let an attacker evict the pin and then rebind the
    /// victim's fingerprint to an attacker-chosen signing key.
    #[test]
    fn identity_flood_cannot_evict_and_rebind_an_active_pin() {
        const CAP: u32 = 64;
        let mut a = engine(1, "pixel");
        a.set_identity_map_cap(CAP as usize);
        let victim = engine(7, "victim");
        let attacker = mesh::MeshSigner::from_seed(&[99u8; 32]);
        let now = 1_000;
        open_link(&mut a, "84:2F", 25, now);

        let victim_noise = hex::decode(&victim.noise_public_hex).unwrap();
        let victim_key = hex::encode(victim.my_peer_id);
        let victim_signing = hex::encode(victim.signer.public_key());

        // Pin the victim.
        let ann = announce_from(&victim_noise, &victim.signer, "victim", DEFAULT_TTL, now);
        a.on_client_rx("84:2F", 25, &ann, now);
        assert_eq!(
            a.signing_key_by_peer.get(&victim_key),
            Some(&victim_signing),
            "victim pinned"
        );

        // Flood past capacity with distinct throwaway identities, all at `now`
        // (i.e. all within the protection window, the attacker's best case).
        for i in 0..(CAP + 8) {
            let mut nk = [0u8; 32];
            nk[..4].copy_from_slice(&i.to_le_bytes());
            nk[31] = 0xAA; // keep it distinct from the victim's key space
            let seed = {
                let mut s = [0u8; 32];
                s[..4].copy_from_slice(&i.to_le_bytes());
                s[30] = 0xBB;
                s
            };
            let flood_signer = mesh::MeshSigner::from_seed(&seed);
            let bytes = announce_from(&nk, &flood_signer, "flood", DEFAULT_TTL, now);
            a.on_client_rx("84:2F", 25, &bytes, now);
        }

        // The victim's pin must still be intact after the flood.
        assert_eq!(
            a.signing_key_by_peer.get(&victim_key),
            Some(&victim_signing),
            "active victim pin survives the flood"
        );

        // The rebind attempt: reuse the victim's noise key (→ same sender_id and
        // fingerprint) but carry the attacker's signing key. It must be rejected
        // by the surviving pin.
        let attacker_signing = hex::encode(attacker.public_key());
        let rebind = announce_from(&victim_noise, &attacker, "imposter", DEFAULT_TTL, now);
        a.on_client_rx("84:2F", 25, &rebind, now);
        assert_eq!(
            a.signing_key_by_peer.get(&victim_key),
            Some(&victim_signing),
            "rebind to the attacker signing key must be rejected"
        );
        assert_ne!(
            a.signing_key_by_peer.get(&victim_key),
            Some(&attacker_signing),
            "attacker signing key must never own the victim's fingerprint"
        );
    }
}
