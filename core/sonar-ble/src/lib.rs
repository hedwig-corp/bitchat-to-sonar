//! Sonar Desktop BLE radio bridge.
//!
//! Gives the Compose Desktop (JVM) app real Bluetooth LE via CoreBluetooth
//! (macOS) / BlueZ (Linux), reached from Kotlin over a tiny C ABI through JNA —
//! the same "native shim behind the JVM" pattern as the Rust `sonar-core`. This
//! disproves the "JVM can't do BLE" idea: the radio runs in native code that the
//! JVM loads.
//!
//! Both roles carry mesh packets: the **peripheral** role (advertise + GATT
//! server, CoreBluetooth and BlueZ) lets phones dial us, and when the controller
//! refuses to advertise the **central** role dials them instead (scan, connect,
//! subscribe, write). The Noise protocol runs in the JVM (`MeshLink.kt`); this
//! crate only moves bytes and says which link they came from.
//!
//! C ABI (all thread-safe; each role runs on its own tokio thread):
//!   sonar_ble_start()          -> begin scanning (idempotent)
//!   sonar_ble_peers_json()     -> *malloc'd UTF-8 JSON array of fresh mesh peers
//!   sonar_ble_drain_rx_json()  -> packets + link-down events, per link
//!   sonar_ble_notify(p, n)     -> a packet for every link (broadcast)
//!   sonar_ble_send_link(l,p,n) -> a packet for one central link
//!   sonar_ble_free(ptr)        -> free a string returned above
//!   sonar_ble_stop()           -> stop scanning + clear state

use btleplug::api::{Central, CentralEvent, Manager as _, Peripheral as _, ScanFilter, WriteType};
use btleplug::platform::Manager;
// The peripheral/advertise role runs on CoreBluetooth and BlueZ; see
// `run_peripheral`. The two drive different mechanisms behind the same API.
use bluster::gatt::characteristic::{Characteristic, Properties, Read, Secure, Write};
use bluster::gatt::event::{Event, Response};
use bluster::gatt::service::Service;
use bluster::Peripheral;
use futures::StreamExt;
use once_cell::sync::Lazy;
use std::collections::HashMap;
use std::collections::HashSet;
use std::ffi::{c_char, CString};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use uuid::Uuid;
use uuid08::Uuid as Uuid08; // bluster's UUID version

/// bitchat mesh GATT service + characteristic — must match the iOS/Android apps.
const BITCHAT_SERVICE_U128: u128 = 0xF47B5E2D_4A9E_4C5A_9B3F_8E1D2C3A4B5C;
// Served by the peripheral role (CoreBluetooth and BlueZ).
const BITCHAT_CHAR_U128: u128 = 0xA1B2C3D4_E5F6_4A5B_8C9D_0E1F2A3B4C5D;
const BITCHAT_SERVICE: Uuid = Uuid::from_u128(BITCHAT_SERVICE_U128);
const BITCHAT_CHAR: Uuid = Uuid::from_u128(BITCHAT_CHAR_U128);

/// The signed bitchat ANNOUNCE packet (built by the Rust core via the JVM and
/// pushed down) that the GATT server sends when a central subscribes — that's
/// what makes a phone show this desktop as a named mesh peer.
static ANNOUNCE: Lazy<Mutex<Option<Vec<u8>>>> = Lazy::new(|| Mutex::new(None));
static ADVERTISING: AtomicBool = AtomicBool::new(false);
/// Whether `start_advertising` has actually succeeded at least once this run.
///
/// Compile-time support is not the same question as working hardware. A BlueZ
/// adapter can be present, powered and unblocked and still refuse to register an
/// advertisement (an Intel AX201 on this developer's laptop rejects every LE
/// advertisement, `bluetoothctl advertise on` included, with mgmt
/// "Invalid Parameters"). Reporting the compile-time answer there would tell the
/// app mesh works, advertising would fail out of sight, and the user would be
/// back to a Mesh channel that silently delivers nothing.
static ADVERTISE_OK: AtomicBool = AtomicBool::new(false);
/// Set once an attempt has completed, so callers can tell "not tried yet" from
/// "tried and failed" instead of reading a not-yet-started run as broken.
static ADVERTISE_ATTEMPTED: AtomicBool = AtomicBool::new(false);

/// What the radio heard, in arrival order, for the JVM mesh engine to drain:
/// packets centrals wrote to our GATT characteristic, notifications from peers
/// we linked to as a central, and those links going down.
///
/// Every item names its link. `0` is the GATT server, which cannot tell its
/// centrals apart; a central link uses its [`TX`] outbox id. The JVM needs the
/// attribution for three things the protocol does per ROUTE, not per peer:
/// replying on the link a peer is actually on (Android answers a handshake
/// whatever its recipient id says, so a broadcast m1 resets every other phone's
/// responder), initiating only where we are the central (Android never
/// initiates on its server side), and dropping a Noise session when its link
/// drops (Android drops its half, and never tells us).
static RX_PACKETS: Lazy<Mutex<Vec<RxItem>>> = Lazy::new(|| Mutex::new(Vec::new()));

/// The GATT server's link id: writes from centrals cannot be attributed.
const SERVER_LINK: u64 = 0;
const RX_QUEUE_MAX: usize = 256;

enum RxItem {
    Packet { link: u64, bytes: Vec<u8> },
    LinkDown { link: u64 },
}

fn rx_push(link: u64, bytes: Vec<u8>) {
    if let Ok(mut q) = RX_PACKETS.lock() {
        if q.len() < RX_QUEUE_MAX {
            q.push(RxItem::Packet { link, bytes });
        }
    }
}

/// Never dropped for a full queue: a lost down event would leave the JVM
/// holding a session the phone has already thrown away.
fn rx_link_down(link: u64) {
    if let Ok(mut q) = RX_PACKETS.lock() {
        q.push(RxItem::LinkDown { link });
    }
}

fn rx_json(items: Vec<RxItem>) -> String {
    let items: Vec<serde_json::Value> = items
        .into_iter()
        .map(|i| match i {
            RxItem::Packet { link, bytes } => serde_json::json!({ "l": link, "p": hex_encode(&bytes) }),
            RxItem::LinkDown { link } => serde_json::json!({ "l": link, "d": true }),
        })
        .collect();
    serde_json::Value::Array(items).to_string()
}

/// Packets the JVM mesh engine wants on the air (announce-driven handshakes,
/// Noise replies, encrypted DMs, 0x53), one queue per radio consumer.
///
/// Every consumer (each central link, the advertise loop) gets its OWN copy of
/// every packet. The JVM addresses packets by bitchat recipient id, not by radio
/// link, so the bridge cannot route and has to broadcast, which is what the
/// peripheral's notify-to-every-subscriber already did; phones drop packets
/// addressed to someone else. A single queue drained with `mem::take` instead
/// handed each packet to whichever consumer woke first, so with two phones in
/// range a handshake or DM for one of them was written to the other and lost.
static TX: Lazy<Mutex<TxFanout>> = Lazy::new(|| Mutex::new(TxFanout::default()));

/// Per-consumer bound, matching the RX queue. A consumer that stops draining
/// (a wedged link) loses its newest packets, not everyone's.
const TX_QUEUE_MAX: usize = 256;

#[derive(Default)]
struct TxFanout {
    next_id: u64,
    outboxes: HashMap<u64, Vec<Vec<u8>>>,
    /// Queued while nothing was on the air; handed to the next consumer to
    /// register, as the old single queue held them until someone subscribed.
    backlog: Vec<Vec<u8>>,
}

impl TxFanout {
    fn register(&mut self) -> u64 {
        self.next_id += 1;
        let id = self.next_id;
        self.outboxes.insert(id, std::mem::take(&mut self.backlog));
        id
    }

    fn unregister(&mut self, id: u64) {
        self.outboxes.remove(&id);
    }

    fn push(&mut self, pkt: Vec<u8>) {
        if self.outboxes.is_empty() {
            if self.backlog.len() < TX_QUEUE_MAX {
                self.backlog.push(pkt);
            }
            return;
        }
        for q in self.outboxes.values_mut() {
            if q.len() < TX_QUEUE_MAX {
                q.push(pkt.clone());
            }
        }
    }

    /// Queue for ONE consumer. False when it is gone (the link dropped), so
    /// the caller knows the packet went nowhere.
    fn push_to(&mut self, id: u64, pkt: Vec<u8>) -> bool {
        match self.outboxes.get_mut(&id) {
            Some(q) if q.len() < TX_QUEUE_MAX => {
                q.push(pkt);
                true
            }
            _ => false,
        }
    }

    fn take(&mut self, id: u64) -> Vec<Vec<u8>> {
        self.outboxes.get_mut(&id).map(std::mem::take).unwrap_or_default()
    }
}

fn tx_register() -> u64 {
    TX.lock().map(|mut t| t.register()).unwrap_or(0)
}

fn tx_unregister(id: u64) {
    if let Ok(mut t) = TX.lock() {
        t.unregister(id);
    }
}

fn tx_take(id: u64) -> Vec<Vec<u8>> {
    TX.lock().map(|mut t| t.take(id)).unwrap_or_default()
}

fn hex_encode(b: &[u8]) -> String {
    let mut s = String::with_capacity(b.len() * 2);
    for byte in b {
        s.push_str(&format!("{byte:02x}"));
    }
    s
}
/// Drop a peer from the radar this long after its last advertisement. Generous
/// because CoreBluetooth coalesces duplicate adverts (it reports a peripheral
/// once per scan), so refreshes only arrive on each periodic re-scan below.
const PEER_TTL: Duration = Duration::from_secs(30);
/// Restart the scan this often so CoreBluetooth re-delivers current advertisers
/// (refreshing their last-seen) — without this, a device is reported once and
/// then ages out even though it's still nearby.
const RESCAN_EVERY: Duration = Duration::from_secs(6);

/// Where the diagnostic log lives. NOT a fixed path in a world-writable shared
/// directory: this file records what radios are near the user, which is location
/// data. It goes in the per-user state dir, owner-readable only.
fn dbg_log_path() -> Option<std::path::PathBuf> {
    let base = if let Some(dir) = std::env::var_os("XDG_STATE_HOME") {
        std::path::PathBuf::from(dir)
    } else {
        let home = std::env::var_os("HOME")?;
        let home = std::path::PathBuf::from(home);
        if cfg!(any(target_os = "macos", target_os = "ios")) {
            home.join("Library/Logs")
        } else {
            home.join(".local/state")
        }
    };
    let dir = base.join("sonar");
    std::fs::create_dir_all(&dir).ok()?;
    Some(dir.join("sonar-ble.log"))
}

/// Stop appending past this size. An advertisement flood must not be able to
/// fill the user's disk (or RAM, when the state dir is a tmpfs).
const DBG_LOG_MAX_BYTES: u64 = 4 * 1024 * 1024;

/// Diagnostic log (only when SONAR_BLE_DEBUG is set) — appends to a file so it's
/// readable regardless of how the app is launched (a jpackage app has no stdout).
///
/// Never log a raw device address or advertised name: on BlueZ the peripheral id
/// is the BDADDR, and a list of nearby MACs localizes a machine better than most
/// IP geolocation. Callers pass [`peer_tag`] output instead.
fn dbg_log(msg: &str) {
    if std::env::var_os("SONAR_BLE_DEBUG").is_none() {
        return;
    }
    use std::io::Write;
    let Some(path) = dbg_log_path() else { return };
    let mut opts = std::fs::OpenOptions::new();
    opts.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        // 0600 so another local user cannot read the proximity trail, and
        // O_NOFOLLOW so a pre-planted symlink cannot redirect the append.
        opts.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    if let Ok(mut f) = opts.open(&path) {
        if f.metadata().map(|m| m.len()).unwrap_or(0) >= DBG_LOG_MAX_BYTES {
            return;
        }
        let _ = writeln!(f, "{msg}");
    }
}

/// Short, non-reversible-at-a-glance tag for a device id, so the debug log can
/// distinguish "this device again" from "a new device" without recording the
/// address itself.
fn peer_tag(id: &str) -> String {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in id.as_bytes() {
        h ^= *b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    format!("{:08x}", (h >> 32) as u32)
}

#[derive(Clone)]
struct Seen {
    name: Option<String>,
    rssi: i16,
    at: Instant,
}

/// Ceiling on tracked devices. Only reached under an advertisement flood, since
/// real radar populations are single digits.
const MAX_TRACKED_DEVICES: usize = 256;

static DEVICES: Lazy<Mutex<HashMap<String, Seen>>> = Lazy::new(|| Mutex::new(HashMap::new()));
/// Peers the central link currently holds a GATT connection to.
///
/// The desktop reaches the mesh as a CENTRAL: the phone advertises, we connect,
/// subscribe to its bitchat characteristic and write ours. That needs only scan
/// and connect, which every adapter does. Advertising is the fragile half — some
/// controllers refuse to register an advertisement at all — and it is only needed
/// so a phone can find US first.
///
/// Keyed by `PeripheralId`, never by `address()`: CoreBluetooth hides addresses
/// and btleplug returns `00:00:00:00:00:00` for every peripheral there, so an
/// address key let the first link on macOS block every other phone.
static LINKED: Lazy<Mutex<HashSet<String>>> = Lazy::new(|| Mutex::new(HashSet::new()));
static RUNNING: AtomicBool = AtomicBool::new(false);

/// Begin a continuous background scan (idempotent). Spawns a dedicated thread
/// owning a tokio runtime + the CoreBluetooth/BlueZ central.
#[no_mangle]
pub extern "C" fn sonar_ble_start() {
    if RUNNING.swap(true, Ordering::SeqCst) {
        return; // already scanning
    }
    std::thread::Builder::new()
        .name("sonar-ble-scan".into())
        .spawn(|| {
            let rt = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
                Ok(rt) => rt,
                Err(_) => {
                    RUNNING.store(false, Ordering::SeqCst);
                    return;
                }
            };
            rt.block_on(scan_loop());
        })
        .ok();
}

/// Stop scanning and clear discovered peers.
#[no_mangle]
pub extern "C" fn sonar_ble_stop() {
    RUNNING.store(false, Ordering::SeqCst);
    if let Ok(mut d) = DEVICES.lock() {
        d.clear();
    }
}

/// JSON array of fresh bitchat-mesh peers:
/// `[{"id":"<uuid>","name":"<str|null>","rssi":-40,"bitchat":true}, …]`.
/// Caller owns the returned buffer — free it with [`sonar_ble_free`].
#[no_mangle]
pub extern "C" fn sonar_ble_peers_json() -> *mut c_char {
    let now = Instant::now();
    let mut items: Vec<serde_json::Value> = Vec::new();
    if let Ok(mut d) = DEVICES.lock() {
        d.retain(|_, s| now.duration_since(s.at) < PEER_TTL);
        // Every entry is a bitchat advertiser by construction: handle_event drops
        // everything else before inserting. The `bitchat` field is kept in the
        // JSON for wire compatibility with the JVM reader.
        for (id, s) in d.iter() {
            items.push(serde_json::json!({
                "id": id,
                "name": s.name,
                "rssi": s.rssi,
                "bitchat": true,
            }));
        }
    }
    let json = serde_json::Value::Array(items).to_string();
    CString::new(json).unwrap_or_default().into_raw()
}

/// JSON array of everything the radio heard since the last call, in order:
/// `{"l":<link>,"p":"<hex packet>"}` or `{"l":<link>,"d":true}` for a link that
/// went down. See [`RX_PACKETS`] for what the link id means. Free with
/// [`sonar_ble_free`].
#[no_mangle]
pub extern "C" fn sonar_ble_drain_rx_json() -> *mut c_char {
    let items = RX_PACKETS.lock().map(|mut q| std::mem::take(&mut *q)).unwrap_or_default();
    CString::new(rx_json(items)).unwrap_or_default().into_raw()
}

/// Free a string returned by [`sonar_ble_peers_json`] / [`sonar_ble_drain_rx_json`].
///
/// # Safety
/// `ptr` must be a pointer previously returned by this library, or null.
#[no_mangle]
pub unsafe extern "C" fn sonar_ble_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}

async fn scan_loop() {
    dbg_log("scan_loop: init");
    let Some(central) = init_central().await else {
        dbg_log("scan_loop: NO ADAPTER");
        RUNNING.store(false, Ordering::SeqCst);
        return;
    };
    dbg_log(&format!(
        "scan_loop: adapter = {}",
        central.adapter_info().await.unwrap_or_default()
    ));
    let Ok(mut events) = central.events().await else {
        dbg_log("scan_loop: events() FAILED");
        RUNNING.store(false, Ordering::SeqCst);
        return;
    };
    // Scan FILTERED to the bitchat service (like the Android app) — far more
    // reliable than scanning everything and checking the parsed service UUID,
    // which CoreBluetooth often reports empty (especially while also advertising).
    let filter = ScanFilter { services: vec![BITCHAT_SERVICE] };
    match central.start_scan(filter.clone()).await {
        Ok(_) => dbg_log("scan_loop: scan started (bitchat filter)"),
        Err(e) => dbg_log(&format!("scan_loop: start_scan ERR {e}")),
    }

    let mut last_rescan = Instant::now();
    while RUNNING.load(Ordering::SeqCst) {
        // 1s timeout so a stop() is noticed even when no advertisements arrive.
        match tokio::time::timeout(Duration::from_secs(1), events.next()).await {
            Ok(Some(ev)) => {
                // The desktop takes part as a CENTRAL: link to the bitchat peer
                // this event is about, if we are not linked to it yet. One task
                // per peer, ending when the link drops so the next sighting
                // relinks. Only the event's own peripheral: walking every known
                // peripheral and awaiting its properties on EVERY advertisement
                // made the scan loop's cost grow with the room.
                if let Some(p) = handle_event(&central, ev).await {
                    if should_link_out() {
                        let key = p.id().to_string();
                        let fresh = LINKED.lock().map(|mut l| l.insert(key.clone())).unwrap_or(false);
                        if fresh {
                            tokio::spawn(run_central_link(p, key));
                        }
                    }
                }
            }
            Ok(None) => break, // stream ended
            Err(_) => {}       // tick — re-check RUNNING
        }
        // Periodic re-scan: CoreBluetooth coalesces duplicate advertisements, so
        // without restarting the scan a still-present device is never re-reported.
        if last_rescan.elapsed() >= RESCAN_EVERY {
            let stop = central.stop_scan().await;
            let start = central.start_scan(filter.clone()).await;
            let total = DEVICES.lock().map(|d| d.len()).unwrap_or(0);
            dbg_log(&format!(
                "scan: rescan stop={:?} start={:?} (total devices seen={})",
                stop.is_ok(), start.is_ok(), total
            ));
            last_rescan = Instant::now();
        }
    }
    let _ = central.stop_scan().await;
}

/// Hold a GATT client link to one bitchat peer: subscribe to its notifications
/// and drain our outbound queue into its characteristic.
///
/// This is the half that makes mesh work on a desktop whose adapter will not
/// advertise. The phone exposes the bitchat characteristic with
/// WRITE | WRITE_WITHOUT_RESPONSE | NOTIFY, so a central can both send and
/// receive; being discoverable is not required to take part.
///
/// Runs until the link drops, then returns so the scan loop can relink when the
/// peer is seen again. `key` is the peripheral id the scan loop registered in
/// [`LINKED`]; every exit path releases it (see [`LinkGuard`]).
async fn run_central_link(peer: btleplug::platform::Peripheral, key: String) {
    use futures::StreamExt as _;

    let mut guard = LinkGuard { key: key.clone(), tx: None };
    let tag = peer_tag(&key);

    if peer.connect().await.is_err() {
        dbg_log(&format!("link {tag}: connect failed"));
        return;
    }
    if peer.discover_services().await.is_err() {
        dbg_log(&format!("link {tag}: service discovery failed"));
        let _ = peer.disconnect().await;
        return;
    }
    let Some(ch) = peer.characteristics().into_iter().find(|c| c.uuid == BITCHAT_CHAR) else {
        // Advertised the service but does not serve the characteristic: not a
        // mesh peer we can talk to.
        dbg_log(&format!("link {tag}: no bitchat characteristic"));
        let _ = peer.disconnect().await;
        return;
    };
    // Open the notification stream BEFORE subscribing: the phone answers a
    // subscribe with its announce burst, and a stream opened afterwards starts
    // after that burst, so the desktop would not learn the phone until its next
    // periodic announce.
    let Ok(mut notifications) = peer.notifications().await else {
        let _ = peer.disconnect().await;
        return;
    };
    if peer.subscribe(&ch).await.is_err() {
        dbg_log(&format!("link {tag}: subscribe failed"));
        let _ = peer.disconnect().await;
        return;
    }
    let tx = tx_register();
    guard.tx = Some(tx);
    dbg_log(&format!("link {tag}: up (subscribed)"));

    // Announce ourselves immediately: this write is how the peer learns we
    // exist, since it never saw us advertise.
    let ann = ANNOUNCE.lock().ok().and_then(|a| a.clone()).unwrap_or_default();
    if !ann.is_empty() {
        let _ = peer.write(&ch, &ann, WriteType::WithoutResponse).await;
    }

    let mut last_announce = Instant::now();
    'link: while RUNNING.load(Ordering::SeqCst) {
        // Drain what the mesh engine queued for the wire. This link's own copy:
        // see [`TX`] for why the queue is fanned out rather than shared.
        for pkt in tx_take(tx) {
            if peer.write(&ch, &pkt, WriteType::WithoutResponse).await.is_err() {
                // The rest of this batch goes with the link; the Noise layer
                // restarts the handshake on the next announce.
                dbg_log(&format!("link {tag}: write failed, dropping link"));
                break 'link;
            }
        }
        // Re-announce periodically so a peer that restarts its app re-learns us.
        if last_announce.elapsed() >= Duration::from_secs(10) {
            let ann = ANNOUNCE.lock().ok().and_then(|a| a.clone()).unwrap_or_default();
            if !ann.is_empty() {
                let _ = peer.write(&ch, &ann, WriteType::WithoutResponse).await;
            }
            last_announce = Instant::now();
        }

        match tokio::time::timeout(Duration::from_millis(200), notifications.next()).await {
            Ok(Some(n)) => rx_push(tx, n.value),
            Ok(None) => break, // peer went away
            Err(_) => {
                if !peer.is_connected().await.unwrap_or(false) {
                    break;
                }
            }
        }
    }

    dbg_log(&format!("link {tag}: down"));
    let _ = peer.disconnect().await;
}

/// Releases a central link's slot in [`LINKED`] and its TX outbox on EVERY exit
/// path. The early returns (connect, discovery, subscribe failures) used to
/// leave the peer marked linked, so one failed connect stopped the desktop from
/// ever relinking that phone.
struct LinkGuard {
    key: String,
    tx: Option<u64>,
}

impl Drop for LinkGuard {
    fn drop(&mut self) {
        if let Some(id) = self.tx {
            tx_unregister(id);
            rx_link_down(id);
        }
        if let Ok(mut l) = LINKED.lock() {
            l.remove(&self.key);
        }
    }
}

/// Whether the scan loop should connect OUT to the phones it sees.
///
/// Only while the peripheral role is not up. When phones can find and dial us,
/// linking out as well gives every phone two routes to this desktop, and the
/// two ends do not agree on what that means: Android keeps a Noise session per
/// ROUTE (and never initiates on its server side), `MeshLink` keeps one per
/// peer. So each phone gets exactly one route: theirs when we advertise, ours
/// when the controller refuses to (the case this path exists for). It also
/// keeps macOS, where advertising works, on the verified phone-initiates path.
fn should_link_out() -> bool {
    link_out_policy(sonar_ble_advertising_supported())
}

fn link_out_policy(advertising: bool) -> bool {
    !advertising
}

async fn init_central() -> Option<btleplug::platform::Adapter> {
    let manager = Manager::new().await.ok()?;
    let adapters = manager.adapters().await.ok()?;
    adapters.into_iter().next()
}

/// True when this peripheral is believed to offer the bitchat mesh service,
/// from the advertised service UUIDs or a service-data key.
///
/// NOT an authentication boundary. The service UUID is a public constant and
/// nothing here is signed, so anyone can advertise it and land on the radar.
/// The real trust boundary is the signed announce verified in MeshLink.pump,
/// and sends refuse without an established Noise session. Do not build
/// authorization on top of this returning true.
///
/// Note on BlueZ: `services` comes from the daemon's cached UUIDs property for
/// the device, which can include services learned from an earlier GATT
/// connection, so this means "BlueZ believes this device offers the service",
/// not strictly "it advertised in this scan window".
///
/// Unused outside tests on CoreBluetooth, which enforces the ScanFilter itself
/// (see `handle_event`).
#[cfg_attr(any(target_os = "macos", target_os = "ios"), allow(dead_code))]
fn advertises_bitchat(props: &btleplug::api::PeripheralProperties) -> bool {
    props.services.contains(&BITCHAT_SERVICE)
        || props.service_data.contains_key(&BITCHAT_SERVICE)
}

/// Record a scan event on the radar. Returns the peripheral when the event is a
/// sighting (discovered/updated) of a bitchat peer, so the caller can link to it.
async fn handle_event(
    central: &btleplug::platform::Adapter,
    ev: CentralEvent,
) -> Option<btleplug::platform::Peripheral> {
    let (id, sighting) = match &ev {
        CentralEvent::DeviceDiscovered(id) | CentralEvent::DeviceUpdated(id) => (id.clone(), true),
        CentralEvent::DeviceConnected(id) | CentralEvent::DeviceDisconnected(id) => (id.clone(), false),
        _ => return None,
    };
    let Ok(p) = central.peripheral(&id).await else { return None };
    let props = p.properties().await.ok().flatten();
    let name = props.as_ref().and_then(|pr| pr.local_name.clone());
    let rssi = props.as_ref().and_then(|pr| pr.rssi).unwrap_or(0);
    // CoreBluetooth enforces the ScanFilter, so every reported peripheral matched
    // it, and it routinely hands back an EMPTY parsed services array, so we
    // cannot re-check the UUID there and must trust the filter.
    //
    // BlueZ does not behave that way: btleplug's Linux backend raises
    // DeviceDiscovered/DeviceUpdated for every device the daemon knows about,
    // including already-paired peripherals that never advertised our service, so
    // the filter is a hint rather than a guarantee. Trusting it there labeled a
    // Logitech mouse as a bitchat mesh peer, which made MeshRadio.peers() report
    // a phantom "nearby phone" on the radar. Re-check the reported services
    // instead (a plausibility filter, not authentication: see advertises_bitchat).
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    let bitchat = true;
    #[cfg(not(any(target_os = "macos", target_os = "ios")))]
    let bitchat = props.as_ref().map(advertises_bitchat).unwrap_or(false);
    if !bitchat {
        // Enough to tell "seen but filtered out" from "never seen" when someone
        // reports a missing phone, without recording who or what was nearby.
        dbg_log(&format!(
            "ignoring non-bitchat device {} services={}",
            peer_tag(&id.to_string()),
            props.as_ref().map(|pr| pr.services.len()).unwrap_or(0),
        ));
        return None;
    }
    dbg_log(&format!(
        "discovered BITCHAT peer {} rssi={rssi}",
        peer_tag(&id.to_string())
    ));
    if let Ok(mut d) = DEVICES.lock() {
        // Prune HERE, in the writer, not only in sonar_ble_peers_json: both JVM
        // callers of that reader short-circuit past it once a named mesh peer
        // exists (MeshRadio.peers / hasActivePeer), so relying on the reader let
        // the map grow for the life of the session. BLE addresses rotate for
        // privacy, so a single nearby radio produces a new key every few minutes.
        let now = Instant::now();
        let key = id.to_string();
        d.retain(|_, s| now.duration_since(s.at) < PEER_TTL);
        // Hard cap as well: the bitchat service UUID is public and unauthenticated,
        // so anyone can mint fresh entries faster than the TTL expires them.
        //
        // Eviction is LRU by last-seen. Be clear about what that does and does not
        // buy: under a flood the attacker's entries are the NEWEST by construction,
        // while a real phone holds the oldest `at` (it only refreshes each
        // RESCAN_EVERY, because duplicate adverts are coalesced), so LRU evicts the
        // genuine peer FIRST. It bounds memory; it does not keep a real phone on the
        // radar during a flood. Refusing the newest instead would be worse (an
        // attacker could then freeze the map), and the blast radius is cosmetic
        // today because MeshRadio.peers() collapses every scan hit into one
        // "nearby phone" node, so only the reported RSSI is affected. Keeping a
        // real peer discoverable under flood needs authentication, not an eviction
        // policy.
        if d.len() >= MAX_TRACKED_DEVICES && !d.contains_key(&key) {
            if let Some(oldest) = d
                .iter()
                .min_by_key(|(_, s)| s.at)
                .map(|(k, _)| k.clone())
            {
                d.remove(&oldest);
            }
        }
        d.insert(key, Seen { name, rssi, at: now });
    }
    sighting.then_some(p)
}

// ── Peripheral role: advertise the bitchat service + serve the announce ──

/// Set/replace the signed ANNOUNCE the GATT server sends to subscribers. Built by
/// the Rust core (meshBuildAnnounce) on the JVM side and pushed down as bytes.
///
/// # Safety
/// `ptr` must point to `len` readable bytes, or be null (which clears it).
#[no_mangle]
pub unsafe extern "C" fn sonar_ble_set_announce(ptr: *const u8, len: usize) {
    let next = if ptr.is_null() || len == 0 {
        None
    } else {
        Some(std::slice::from_raw_parts(ptr, len).to_vec())
    };
    dbg_log(&format!("set_announce: {} bytes", next.as_ref().map(|v| v.len()).unwrap_or(0)));
    if let Ok(mut a) = ANNOUNCE.lock() {
        *a = next;
    }
}

/// Whether phones can discover this desktop: the peripheral/advertise role, on
/// a platform that implements it (CoreBluetooth, BlueZ) and a controller that
/// has not refused it. Mesh traffic does not depend on it; see
/// [`sonar_ble_mesh_supported`].
#[no_mangle]
pub extern "C" fn sonar_ble_advertising_supported() -> bool {
    advertising_capability(
        PERIPHERAL_ROLE_IMPLEMENTED,
        ADVERTISE_ATTEMPTED.load(Ordering::SeqCst),
        ADVERTISE_OK.load(Ordering::SeqCst),
    )
}

const PERIPHERAL_ROLE_IMPLEMENTED: bool =
    cfg!(any(target_os = "macos", target_os = "ios", target_os = "linux"));

/// Optimistic until proven otherwise: the host asks before the radio starts,
/// and answering false there would hide a role the machine may well have. Once
/// an attempt has completed, the answer is what actually happened.
///
/// Pure so the tests can cover every state without racing each other on the
/// process-wide atomics (they did: two tests writing `ADVERTISE_ATTEMPTED` in
/// parallel failed about 1 run in 130).
fn advertising_capability(implemented: bool, attempted: bool, ok: bool) -> bool {
    implemented && (!attempted || ok)
}

/// Publish the outcome of an advertising attempt. `ADVERTISE_OK` is written
/// first so a concurrent reader never sees "attempted" paired with a stale
/// "not ok" on the success path.
fn record_advertise_result(ok: bool) {
    ADVERTISE_OK.store(ok, Ordering::SeqCst);
    ADVERTISE_ATTEMPTED.store(true, Ordering::SeqCst);
}

/// Whether this build can take part in the mesh at all.
///
/// Distinct from [sonar_ble_advertising_supported], which asks only whether
/// phones can discover US. The desktop participates as a GATT central — scan,
/// connect, subscribe, write — and that carries traffic in both directions, so
/// mesh works on adapters that refuse to advertise. Advertising is additive: it
/// lets a phone initiate instead of waiting for us to.
#[no_mangle]
pub extern "C" fn sonar_ble_mesh_supported() -> bool {
    cfg!(any(target_os = "macos", target_os = "ios", target_os = "linux"))
}

/// Begin advertising the bitchat service (peripheral role) so phones discover
/// this desktop and, on subscribe, receive the announce. Idempotent.
#[no_mangle]
pub extern "C" fn sonar_ble_start_advertising() {
    // Bail before spawning a thread and a multi-thread tokio runtime for a call
    // that cannot succeed. MeshRadio.start() runs on every discovery-mode change,
    // known-peer-set change and foreground transition.
    if !sonar_ble_advertising_supported() {
        dbg_log("advertise: unsupported on this platform, scan-only");
        return;
    }
    if ADVERTISING.swap(true, Ordering::SeqCst) {
        return;
    }
    std::thread::Builder::new()
        .name("sonar-ble-adv".into())
        .spawn(|| {
            let rt = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
                Ok(rt) => rt,
                Err(_) => {
                    ADVERTISING.store(false, Ordering::SeqCst);
                    return;
                }
            };
            rt.block_on(async {
                if let Err(e) = run_peripheral().await {
                    dbg_log(&format!("advertise: ERR {e}"));
                }
                ADVERTISING.store(false, Ordering::SeqCst);
            });
        })
        .ok();
}

#[no_mangle]
pub extern "C" fn sonar_ble_stop_advertising() {
    ADVERTISING.store(false, Ordering::SeqCst);
}

/// Queue a raw packet for every peer on the air (the JVM mesh engine sends
/// handshakes, encrypted DMs and 0x53 this way): each central link writes it and
/// the advertise loop notifies it to its subscribers. See [`TX`].
///
/// # Safety
/// `ptr` must point to `len` readable bytes, or be null.
#[no_mangle]
pub unsafe extern "C" fn sonar_ble_notify(ptr: *const u8, len: usize) {
    if ptr.is_null() || len == 0 {
        return;
    }
    let bytes = std::slice::from_raw_parts(ptr, len).to_vec();
    if let Ok(mut t) = TX.lock() {
        t.push(bytes);
    }
}

/// Queue a packet for ONE central link, the one the JVM last heard its
/// recipient on (see [`RX_PACKETS`]). Returns false when that link is gone.
///
/// # Safety
/// `ptr` must point to `len` readable bytes, or be null.
#[no_mangle]
pub unsafe extern "C" fn sonar_ble_send_link(link: u64, ptr: *const u8, len: usize) -> bool {
    if ptr.is_null() || len == 0 || link == SERVER_LINK {
        return false;
    }
    let bytes = std::slice::from_raw_parts(ptr, len).to_vec();
    TX.lock().map(|mut t| t.push_to(link, bytes)).unwrap_or(false)
}

/// Unregisters a TX outbox when its consumer loop ends, however it ends.
struct TxOutbox(u64);

impl Drop for TxOutbox {
    fn drop(&mut self) {
        tx_unregister(self.0);
    }
}

/// One subscribed central on the BlueZ GATT server, with what it is still owed.
///
/// bluster hands each subscriber a notification channel of capacity 1, so
/// `try_send` fails whenever the previous notification has not drained. A full
/// channel is not a dead one, and the packet that did not fit has to WAIT here:
/// retrying only the subscriber and dropping the packet lost whichever handshake
/// step or DM happened to arrive in a burst. Only a closed channel prunes.
///
/// Compiled everywhere so its unit tests run on the macOS job too.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
struct NotifySub {
    tx: futures::channel::mpsc::Sender<Vec<u8>>,
    pending: std::collections::VecDeque<Vec<u8>>,
}

#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
impl NotifySub {
    fn new(tx: futures::channel::mpsc::Sender<Vec<u8>>) -> Self {
        Self { tx, pending: std::collections::VecDeque::new() }
    }

    fn queue(&mut self, pkt: Vec<u8>) {
        if self.pending.len() < TX_QUEUE_MAX {
            self.pending.push_back(pkt);
        }
    }

    /// Hand the channel as much as it will take, in order. False once the
    /// channel is closed (the central went away), so the caller can prune it.
    fn flush(&mut self) -> bool {
        while let Some(pkt) = self.pending.pop_front() {
            match self.tx.try_send(pkt) {
                Ok(()) => {}
                Err(e) if e.is_full() => {
                    self.pending.push_front(e.into_inner());
                    return true;
                }
                Err(_) => return false,
            }
        }
        !self.tx.is_closed()
    }
}

/// BlueZ (Linux) peripheral role.
///
/// Same job as the CoreBluetooth version below, driven through a different
/// mechanism. CoreBluetooth has no subscribe callback in bluster, so that path
/// uses a Sonar side channel (`notify()`/`take_writes()`) and polls. BlueZ does
/// deliver the cross-platform `gatt::event` stream, so this drives everything
/// from it: `NotifySubscribe` hands us an `mpsc::Sender<Vec<u8>>` per subscribed
/// central, and `WriteRequest` carries what a central wrote.
///
/// Two details are load-bearing:
///
/// - **Every `WriteRequest` must be answered.** BlueZ's `WriteValue` blocks on
///   the oneshot until we reply, so dropping it wedges the writing central.
/// - **The notification channel has capacity 1** (`mpsc::channel(1)` inside
///   bluster), so a `try_send` fails whenever the previous notification has not
///   drained. Each subscriber keeps what did not fit ([`NotifySub`]) and the
///   next tick retries it; a closed channel is what prunes them.
#[cfg(target_os = "linux")]
async fn run_peripheral() -> Result<(), Box<dyn std::error::Error>> {
    let svc = Uuid08::from_u128(BITCHAT_SERVICE_U128);
    let chr = Uuid08::from_u128(BITCHAT_CHAR_U128);

    // Each step logs: when this fails it is almost always one specific BlueZ
    // call, and a single "advertise: ERR" line cannot tell you which. Diagnosing
    // it without these took a bisect through D-Bus errors.
    dbg_log("advertise: creating BlueZ peripheral");
    let peripheral = Peripheral::new().await.map_err(|e| {
        dbg_log(&format!("advertise: Peripheral::new FAILED ({e}); is the adapter blocked or powered off?"));
        record_advertise_result(false);
        e
    })?;

    // BlueZ rejects RegisterApplication while the adapter is down, and the app
    // may start before the user powers Bluetooth on.
    let mut tries = 0;
    while !peripheral.is_powered().await? {
        tokio::time::sleep(Duration::from_millis(200)).await;
        tries += 1;
        if tries > 50 {
            return Err("bluetooth adapter never powered on".into());
        }
    }

    let (tx, mut rx) = futures::channel::mpsc::channel(32);
    // read + write + notify, matching what the phones advertise: iOS uses
    // [.notify, .write, .writeWithoutResponse, .read] and Android
    // PROPERTY_WRITE | PROPERTY_WRITE_NO_RESPONSE | PROPERTY_NOTIFY.
    let characteristic = Characteristic::new(
        chr,
        Properties::new(
            Some(Read(Secure::Insecure(tx.clone()))),
            Some(Write::WithResponse(Secure::Insecure(tx.clone()))),
            Some(tx.clone()),
            None,
        ),
        None,
        HashSet::new(),
    );
    let mut chars = HashSet::new();
    chars.insert(characteristic);
    peripheral.add_service(&Service::new(svc, true, chars))?;
    // A controller that refuses the GATT application refuses the role just as
    // much as one that refuses the advertisement, and it is the more common of
    // the two (the controller this was developed on stops here). Record both, or
    // the capability stays at its optimistic "not tried yet" answer forever.
    peripheral.register_gatt().await.map_err(|e| {
        dbg_log(&format!("advertise: register_gatt FAILED ({e})"));
        record_advertise_result(false);
        e
    })?;
    dbg_log("advertise: GATT application registered");
    if let Err(e) = peripheral.start_advertising("Sonar", &[svc]).await {
        // Adapter present and powered, controller still refuses. Record it so
        // the host stops claiming phones can find us.
        record_advertise_result(false);
        dbg_log(&format!(
            "advertise: start_advertising REFUSED by the adapter ({e}); reachable only as a central"
        ));
        return Err(e.into());
    }
    record_advertise_result(true);
    dbg_log("advertise: started on BlueZ (bitchat service)");

    fn announce() -> Vec<u8> {
        ANNOUNCE.lock().ok().and_then(|a| a.clone()).unwrap_or_default()
    }

    // One entry per subscribed central, each with its own backlog.
    let mut subs: Vec<NotifySub> = Vec::new();
    let outbox = TxOutbox(tx_register());

    let mut last_notify = Instant::now()
        .checked_sub(Duration::from_secs(60))
        .unwrap_or_else(Instant::now);
    while ADVERTISING.load(Ordering::SeqCst) {
        // Re-announce on a timer like the CoreBluetooth path: a central that
        // subscribes between ticks is caught by the next one. Skipped for a
        // subscriber that is still behind, so announces cannot pile up in front
        // of real traffic.
        if last_notify.elapsed() >= Duration::from_secs(2) && !subs.is_empty() {
            let ann = announce();
            if !ann.is_empty() {
                for s in subs.iter_mut().filter(|s| s.pending.is_empty()) {
                    s.queue(ann.clone());
                }
            }
            last_notify = Instant::now();
        }

        // Packets the JVM mesh engine queued (handshakes, DMs), to every
        // subscriber: notify cannot be attributed to one central. Taken only
        // when someone is subscribed, so they are not dropped on the floor
        // before a phone connects.
        if !subs.is_empty() {
            for pkt in tx_take(outbox.0) {
                for s in subs.iter_mut() {
                    s.queue(pkt.clone());
                }
            }
        }
        subs.retain_mut(NotifySub::flush);

        match tokio::time::timeout(Duration::from_millis(120), rx.next()).await {
            Ok(Some(ev)) => match ev {
                Event::NotifySubscribe(sub) => {
                    dbg_log("advertise: central subscribed");
                    // Our announce first: this is the moment the phone is
                    // waiting for to show this desktop as a peer.
                    let mut s = NotifySub::new(sub.notification);
                    s.queue(announce());
                    if s.flush() {
                        subs.push(s);
                    }
                }
                Event::NotifyUnsubscribe => {
                    dbg_log("advertise: central unsubscribed");
                    subs.retain(|s| !s.tx.is_closed());
                }
                Event::ReadRequest(req) => {
                    let _ = req.response.send(Response::Success(announce()));
                }
                Event::WriteRequest(req) => {
                    // A central's packet: its announce, a handshake step, or a
                    // DM. Hand it to the JVM mesh engine through RX_PACKETS.
                    dbg_log(&format!("advertise: rx write {} bytes from central", req.data.len()));
                    rx_push(SERVER_LINK, req.data);
                    // Must answer, or BlueZ leaves the central blocked.
                    let _ = req.response.send(Response::Success(vec![]));
                }
            },
            Ok(None) => break,
            Err(_) => {} // tick
        }
    }
    let _ = peripheral.stop_advertising().await;
    let _ = peripheral.unregister_gatt().await;
    Ok(())
}

#[cfg(not(any(target_os = "macos", target_os = "ios", target_os = "linux")))]
async fn run_peripheral() -> Result<(), Box<dyn std::error::Error>> {
    Err("peripheral/advertise role is not implemented for this platform".into())
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
async fn run_peripheral() -> Result<(), Box<dyn std::error::Error>> {
    let svc = Uuid08::from_u128(BITCHAT_SERVICE_U128);
    let chr = Uuid08::from_u128(BITCHAT_CHAR_U128);

    let peripheral = Peripheral::new().await?;

    // CoreBluetooth silently ignores addService:/startAdvertising: until the
    // CBPeripheralManager is powered on — so WAIT for power-on BEFORE registering
    // the GATT service. (Adding it first drops it, and a central then discovers
    // no service: the Android client logs `servicesDiscovered svc=false`.)
    let mut tries = 0;
    while !peripheral.is_powered().await? {
        tokio::time::sleep(Duration::from_millis(200)).await;
        tries += 1;
        if tries > 50 {
            return Err("peripheral never powered on".into());
        }
    }

    let (tx, mut rx) = futures::channel::mpsc::channel(32);
    let characteristic = Characteristic::new(
        chr,
        Properties::new(
            Some(Read(Secure::Insecure(tx.clone()))),
            Some(Write::WithResponse(Secure::Insecure(tx.clone()))),
            Some(tx.clone()),
            None,
        ),
        None,
        HashSet::new(),
    );
    let mut chars = HashSet::new();
    chars.insert(characteristic);
    peripheral.add_service(&Service::new(svc, true, chars))?;
    peripheral.register_gatt().await?;
    // Let CoreBluetooth commit the service (didAddService) before advertising, so
    // the GATT DB is populated by the time a central connects + discovers.
    tokio::time::sleep(Duration::from_millis(400)).await;

    peripheral.start_advertising("Sonar", &[svc]).await?;
    record_advertise_result(true);
    dbg_log("advertise: started (bitchat service)");
    let outbox = TxOutbox(tx_register());

    fn announce() -> Vec<u8> {
        ANNOUNCE.lock().ok().and_then(|a| a.clone()).unwrap_or_default()
    }

    let mut last_notify = Instant::now()
        .checked_sub(Duration::from_secs(60))
        .unwrap_or_else(Instant::now);
    while ADVERTISING.load(Ordering::SeqCst) {
        // Push our announce to any subscribed central every ~2s. bluster's
        // CoreBluetooth backend has no didSubscribe callback, so instead of
        // sending on-subscribe we just keep notifying; updateValue only reaches
        // subscribed centrals, so a phone that just subscribed picks up the next
        // tick and then shows this desktop as a peer.
        if last_notify.elapsed() >= Duration::from_secs(2) {
            let ann = announce();
            if !ann.is_empty() {
                let sent = peripheral.notify(&ann);
                dbg_log(&format!("advertise: notify announce ({} bytes) sent={}", ann.len(), sent));
            }
            last_notify = Instant::now();
        }
        // Flush packets the JVM mesh engine queued (handshake replies, DMs).
        for pkt in tx_take(outbox.0) {
            peripheral.notify(&pkt);
        }
        // Drain packets centrals wrote to us (bluster's event channel is a no-op
        // on macOS; we patched it to queue writes — take them here).
        let writes = peripheral.take_writes();
        if !writes.is_empty() {
            dbg_log(&format!("advertise: rx {} write packet(s) from central", writes.len()));
            for w in writes {
                rx_push(SERVER_LINK, w);
            }
        }
        // Short tick so handshake replies / DMs queued by the JVM flush quickly.
        match tokio::time::timeout(Duration::from_millis(120), rx.next()).await {
            Ok(Some(ev)) => match ev {
                Event::NotifySubscribe(sub) => {
                    let _ = sub.notification.clone().try_send(announce());
                }
                Event::ReadRequest(req) => {
                    let _ = req.response.send(Response::Success(announce()));
                }
                Event::WriteRequest(req) => {
                    // The central's packets (its announce / handshake). Discovery
                    // doesn't consume them yet; ack so it isn't left hanging.
                    dbg_log(&format!("advertise: rx write {} bytes from central", req.data.len()));
                    let _ = req.response.send(Response::Success(vec![]));
                }
                Event::NotifyUnsubscribe => {}
            },
            Ok(None) => break,
            Err(_) => {} // tick — re-check ADVERTISING + re-notify
        }
    }
    let _ = peripheral.stop_advertising().await;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use btleplug::api::PeripheralProperties;

    fn props_with(services: Vec<Uuid>) -> PeripheralProperties {
        PeripheralProperties {
            services,
            ..Default::default()
        }
    }

    /// A device that advertises our service is a mesh peer.
    #[test]
    fn bitchat_service_uuid_matches() {
        assert!(advertises_bitchat(&props_with(vec![BITCHAT_SERVICE])));
    }

    /// Regression: BlueZ raises discovery events for every device the daemon
    /// knows about, not just ScanFilter matches, so an unrelated peripheral
    /// (this was a Logitech MX Master 3) must NOT be reported as a mesh peer,
    /// doing so put a phantom "nearby phone" on the desktop radar.
    #[test]
    fn unrelated_peripheral_is_not_a_mesh_peer() {
        let hid = Uuid::from_u128(0x00001812_0000_1000_8000_00805f9b34fb);
        let battery = Uuid::from_u128(0x0000180f_0000_1000_8000_00805f9b34fb);
        assert!(!advertises_bitchat(&props_with(vec![hid, battery])));
    }

    /// An empty advertisement is not a match either (the CoreBluetooth
    /// empty-services case is handled by trusting the filter, not by this fn).
    #[test]
    fn empty_advertisement_is_not_a_mesh_peer() {
        assert!(!advertises_bitchat(&props_with(vec![])));
    }

    /// The capability must be reported for every platform that has a peripheral
    /// implementation, since the host uses it to decide whether to promise
    /// discoverability. BlueZ joined CoreBluetooth here.
    #[test]
    fn advertising_is_implemented_on_every_platform_with_a_peripheral_role() {
        assert_eq!(
            PERIPHERAL_ROLE_IMPLEMENTED,
            cfg!(any(target_os = "macos", target_os = "ios", target_os = "linux"))
        );
    }

    /// A platform with no implementation must still say so, rather than letting
    /// the host promise a discoverability it cannot deliver.
    #[cfg(not(any(target_os = "macos", target_os = "ios", target_os = "linux")))]
    #[test]
    fn unimplemented_platform_reports_unsupported() {
        let rt = tokio::runtime::Builder::new_current_thread().build().unwrap();
        assert!(rt.block_on(run_peripheral()).is_err());
        assert!(!ADVERTISING.load(Ordering::SeqCst));
    }

    /// Compile-time support is not the same claim as a working radio.
    ///
    /// An adapter can be present, powered and unblocked and still refuse every LE
    /// advertisement — an Intel AX201 does exactly that on the machine this was
    /// written on, rejecting `bluetoothctl advertise on` too. Reporting the
    /// compile-time answer there would tell the app phones can find it while
    /// nothing is discoverable.
    ///
    /// Asked of the pure function, not the process-wide atomics: two tests
    /// writing `ADVERTISE_ATTEMPTED` in parallel failed about 1 run in 130.
    #[test]
    fn a_refused_advertisement_downgrades_the_capability() {
        assert!(advertising_capability(true, false, false), "before an attempt the answer is the platform's");
        assert!(!advertising_capability(true, true, false), "a refusal must downgrade it");
        assert!(advertising_capability(true, true, true), "a success keeps it");
        assert!(!advertising_capability(false, false, false), "no implementation, no claim");
    }

    /// Each phone gets exactly one route: we link out only while phones cannot
    /// dial us. Two routes to one phone means two Noise sessions on Android and
    /// one in MeshLink.
    #[test]
    fn links_out_only_while_not_advertising() {
        assert!(!link_out_policy(true));
        assert!(link_out_policy(false));
    }

    /// Every consumer gets every broadcast. A single queue drained with
    /// `mem::take` handed each packet to whichever link task woke first, so with
    /// two phones linked a packet for one of them went to the other.
    #[test]
    fn a_broadcast_reaches_every_link() {
        let mut t = TxFanout::default();
        let a = t.register();
        let b = t.register();
        t.push(vec![1]);
        t.push(vec![2]);
        assert_eq!(t.take(a), vec![vec![1], vec![2]]);
        assert_eq!(t.take(b), vec![vec![1], vec![2]], "the second link must not be starved");
        assert!(t.take(a).is_empty(), "take drains");
    }

    /// A routed packet reaches its link only: Android answers a handshake
    /// whatever its recipient id says, so an m1 written to every phone resets
    /// the other phones' responders.
    #[test]
    fn a_routed_packet_reaches_only_its_link() {
        let mut t = TxFanout::default();
        let a = t.register();
        let b = t.register();
        assert!(t.push_to(b, vec![7]));
        assert!(t.take(a).is_empty());
        assert_eq!(t.take(b), vec![vec![7]]);
        t.unregister(b);
        assert!(!t.push_to(b, vec![8]), "a dropped link must report the packet went nowhere");
        assert!(!t.push_to(999, vec![9]));
    }

    /// Packets queued while nothing was on the air go to the next consumer,
    /// as the old queue held them until a phone subscribed.
    #[test]
    fn packets_queued_before_any_link_go_to_the_first_one() {
        let mut t = TxFanout::default();
        t.push(vec![1]);
        let a = t.register();
        let b = t.register();
        assert_eq!(t.take(a), vec![vec![1]]);
        assert!(t.take(b).is_empty(), "the backlog is handed over once");
    }

    /// A consumer that stops draining loses its own newest packets, not the
    /// others'.
    #[test]
    fn a_stalled_link_does_not_block_the_others() {
        let mut t = TxFanout::default();
        let stalled = t.register();
        let live = t.register();
        for i in 0..(TX_QUEUE_MAX + 10) {
            t.push(vec![i as u8]);
            if i % 2 == 0 {
                assert!(!t.take(live).is_empty());
            }
        }
        assert_eq!(t.take(stalled).len(), TX_QUEUE_MAX);
    }

    /// bluster's notification channel holds one value, so a burst does not fit.
    /// What did not fit must wait, in order. The previous code kept the
    /// subscriber and dropped the PACKET, losing whichever handshake step or DM
    /// arrived second.
    #[test]
    fn a_full_notification_channel_delays_packets_instead_of_dropping_them() {
        let (tx, mut rx) = futures::channel::mpsc::channel::<Vec<u8>>(1);
        let mut sub = NotifySub::new(tx);
        for i in 0..5u8 {
            sub.queue(vec![i]);
        }
        let mut got = Vec::new();
        for _ in 0..10 {
            assert!(sub.flush(), "a full channel is not a closed one");
            while let Ok(Some(v)) = rx.try_next() {
                got.push(v[0]);
            }
        }
        assert_eq!(got, vec![0, 1, 2, 3, 4]);
        drop(rx);
        sub.queue(vec![5]);
        assert!(!sub.flush(), "a closed channel prunes the subscriber");
    }

    /// The JVM parses this shape by hand (no JSON dependency on the desktop
    /// classpath); `BleBridge.drainRx` has the matching test.
    #[test]
    fn rx_items_name_their_link() {
        let json = rx_json(vec![
            RxItem::Packet { link: SERVER_LINK, bytes: vec![0xab, 0x01] },
            RxItem::Packet { link: 7, bytes: vec![0xff] },
            RxItem::LinkDown { link: 7 },
        ]);
        assert_eq!(json, r#"[{"l":0,"p":"ab01"},{"l":7,"p":"ff"},{"d":true,"l":7}]"#);
    }

    /// The debug log must never be a fixed path in a shared directory: it records
    /// which radios are near the user.
    #[test]
    fn debug_log_is_not_in_shared_tmp() {
        if let Some(p) = dbg_log_path() {
            assert!(!p.starts_with("/tmp"), "log path must not be in /tmp: {p:?}");
        }
    }

    /// Some advertisers carry the service only as a service-data key.
    #[test]
    fn bitchat_service_data_matches() {
        let mut props = props_with(vec![]);
        props.service_data.insert(BITCHAT_SERVICE, vec![1, 2, 3]);
        assert!(advertises_bitchat(&props));
    }
}
