//! Sonar Desktop BLE radio bridge.
//!
//! Gives the Compose Desktop (JVM) app real Bluetooth LE via CoreBluetooth
//! (macOS) / BlueZ (Linux), reached from Kotlin over a tiny C ABI through JNA —
//! the same "native shim behind the JVM" pattern as the Rust `sonar-core`. This
//! disproves the "JVM can't do BLE" idea: the radio runs in native code that the
//! JVM loads.
//!
//! Scope today: the **central** role — continuous scan + discovery of nearby BLE
//! peripherals, surfacing the ones advertising the bitchat mesh service so the
//! desktop radar lights up with real mesh devices. The peripheral/GATT-server
//! role (advertising, so phones can discover the desktop) and the Noise-over-GATT
//! transport are the next stages toward full mesh interop.
//!
//! C ABI (all thread-safe; the scan runs on its own tokio thread):
//!   sonar_ble_start()          -> begin scanning (idempotent)
//!   sonar_ble_peers_json()     -> *malloc'd UTF-8 JSON array of fresh mesh peers
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

/// Packets centrals wrote to our GATT characteristic (their announce / handshake).
/// Drained by the JVM, which decodes the announce to name + dedupe a peer — this
/// is how the desktop learns a phone that connected to it (the phone suppresses
/// its own advertising while connected, so scanning alone can't see it).
static RX_PACKETS: Lazy<Mutex<Vec<Vec<u8>>>> = Lazy::new(|| Mutex::new(Vec::new()));

/// Packets the JVM mesh engine wants pushed to subscribed centrals (Noise
/// handshake replies, encrypted DMs). The advertise loop drains + notifies them.
static TX_PACKETS: Lazy<Mutex<Vec<Vec<u8>>>> = Lazy::new(|| Mutex::new(Vec::new()));

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
static LINKED: Lazy<Mutex<HashMap<String, ()>>> = Lazy::new(|| Mutex::new(HashMap::new()));
/// True once a central link has delivered or accepted mesh traffic.
static CENTRAL_LINK_OK: AtomicBool = AtomicBool::new(false);
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

/// JSON array of hex-encoded packets written to our GATT characteristic by
/// connected centrals (their announce / handshake), draining the queue. The JVM
/// decodes these to learn + name the peer. Free with [`sonar_ble_free`].
#[no_mangle]
pub extern "C" fn sonar_ble_drain_rx_json() -> *mut c_char {
    let items: Vec<serde_json::Value> = RX_PACKETS
        .lock()
        .map(|mut q| q.drain(..).map(|b| serde_json::Value::String(hex_encode(&b))).collect())
        .unwrap_or_default();
    let json = serde_json::Value::Array(items).to_string();
    CString::new(json).unwrap_or_default().into_raw()
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
                handle_event(&central, ev).await;
                // The desktop takes part as a CENTRAL: link to any bitchat peer
                // we are not already linked to. One task per peer, ending when
                // the link drops so the next sighting relinks.
                if let Ok(peers) = central.peripherals().await {
                    for p in peers {
                        let addr = p.address().to_string();
                        let already = LINKED.lock().map(|l| l.contains_key(&addr)).unwrap_or(true);
                        if already {
                            continue;
                        }
                        let is_mesh = match p.properties().await {
                            Ok(Some(props)) => props.services.contains(&BITCHAT_SERVICE),
                            _ => false,
                        };
                        if is_mesh {
                            LINKED.lock().map(|mut l| l.insert(addr.clone(), ())).ok();
                            tokio::spawn(run_central_link(p, addr));
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
/// peer is seen again.
async fn run_central_link(peer: btleplug::platform::Peripheral, addr: String) {
    use futures::StreamExt as _;

    if peer.connect().await.is_err() {
        dbg_log(&format!("link {addr}: connect failed"));
        return;
    }
    if peer.discover_services().await.is_err() {
        dbg_log(&format!("link {addr}: service discovery failed"));
        let _ = peer.disconnect().await;
        return;
    }
    let Some(ch) = peer.characteristics().into_iter().find(|c| c.uuid == BITCHAT_CHAR) else {
        // Advertised the service but does not serve the characteristic: not a
        // mesh peer we can talk to.
        dbg_log(&format!("link {addr}: no bitchat characteristic"));
        let _ = peer.disconnect().await;
        return;
    };
    if peer.subscribe(&ch).await.is_err() {
        dbg_log(&format!("link {addr}: subscribe failed"));
        let _ = peer.disconnect().await;
        return;
    }
    LINKED.lock().map(|mut l| l.insert(addr.clone(), ())).ok();
    dbg_log(&format!("link {addr}: up (subscribed)"));

    // Announce ourselves immediately: this write is how the peer learns we
    // exist, since it never saw us advertise.
    let ann = ANNOUNCE.lock().ok().and_then(|a| a.clone()).unwrap_or_default();
    if !ann.is_empty() {
        let _ = peer.write(&ch, &ann, WriteType::WithoutResponse).await;
    }

    let Ok(mut notifications) = peer.notifications().await else {
        let _ = peer.disconnect().await;
        LINKED.lock().map(|mut l| l.remove(&addr)).ok();
        return;
    };

    let mut last_announce = Instant::now();
    while RUNNING.load(Ordering::SeqCst) {
        // Drain anything the mesh engine queued for the wire.
        let queued: Vec<Vec<u8>> = TX_PACKETS
            .lock()
            .map(|mut q| std::mem::take(&mut *q))
            .unwrap_or_default();
        for pkt in queued {
            if peer.write(&ch, &pkt, WriteType::WithoutResponse).await.is_err() {
                dbg_log(&format!("link {addr}: write failed, dropping link"));
                break;
            }
            CENTRAL_LINK_OK.store(true, Ordering::SeqCst);
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
            Ok(Some(n)) => {
                CENTRAL_LINK_OK.store(true, Ordering::SeqCst);
                if let Ok(mut q) = RX_PACKETS.lock() {
                    if q.len() < 256 {
                        q.push(n.value);
                    }
                }
            }
            Ok(None) => break, // peer went away
            Err(_) => {
                if !peer.is_connected().await.unwrap_or(false) {
                    break;
                }
            }
        }
    }

    dbg_log(&format!("link {addr}: down"));
    LINKED.lock().map(|mut l| l.remove(&addr)).ok();
    let _ = peer.disconnect().await;
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

async fn handle_event(central: &btleplug::platform::Adapter, ev: CentralEvent) {
    let id = match &ev {
        CentralEvent::DeviceDiscovered(id)
        | CentralEvent::DeviceUpdated(id)
        | CentralEvent::DeviceConnected(id)
        | CentralEvent::DeviceDisconnected(id) => id.clone(),
        _ => return,
    };
    let Ok(p) = central.peripheral(&id).await else { return };
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
        return;
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

/// Whether this build can play the peripheral/advertise role at all, so the host
/// can tell the user "scan only" instead of presenting a desktop that silently
/// never becomes discoverable. See `run_peripheral`: the GATT side channel it
/// needs exists only in bluster's CoreBluetooth backend.
#[no_mangle]
pub extern "C" fn sonar_ble_advertising_supported() -> bool {
    if !cfg!(any(target_os = "macos", target_os = "ios", target_os = "linux")) {
        return false;
    }
    // Optimistic until proven otherwise: the host calls this before the radio
    // starts, and answering false there would hide mesh on a machine that can
    // do it. Once an attempt has completed, the answer is what actually
    // happened.
    !ADVERTISE_ATTEMPTED.load(Ordering::SeqCst) || ADVERTISE_OK.load(Ordering::SeqCst)
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

/// Queue a raw packet to notify to subscribed centrals (the JVM mesh engine sends
/// Noise handshake replies + encrypted DMs this way). The advertise loop flushes it.
///
/// # Safety
/// `ptr` must point to `len` readable bytes, or be null.
#[no_mangle]
pub unsafe extern "C" fn sonar_ble_notify(ptr: *const u8, len: usize) {
    if ptr.is_null() || len == 0 {
        return;
    }
    let bytes = std::slice::from_raw_parts(ptr, len).to_vec();
    if let Ok(mut q) = TX_PACKETS.lock() {
        if q.len() < 256 {
            q.push(bytes);
        }
    }
}

/// Peripheral role is CoreBluetooth-only for now. The notify/write-drain side
/// channel `run_peripheral` relies on (`Peripheral::notify`/`take_writes`) is a
/// Sonar patch that exists solely in bluster's CoreBluetooth backend; the BlueZ
/// backend carries no equivalent, and its cross-platform `gatt::event` channel
/// is a different mechanism that has to be wired separately. Keeping the full
/// C ABI on every target (the JVM `BleLib` binds all of it via JNA) and failing
/// here means Linux gets the central/scan radar with advertising reported
/// unavailable, rather than the whole crate failing to build.
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
///   drained. Subscribers that fail are retried on the next tick rather than
///   dropped, and a closed channel is what prunes them.
#[cfg(target_os = "linux")]
async fn run_peripheral() -> Result<(), Box<dyn std::error::Error>> {
    use futures::SinkExt;

    let svc = Uuid08::from_u128(BITCHAT_SERVICE_U128);
    let chr = Uuid08::from_u128(BITCHAT_CHAR_U128);

    // Each step logs: when this fails it is almost always one specific BlueZ
    // call, and a single "advertise: ERR" line cannot tell you which. Diagnosing
    // it without these took a bisect through D-Bus errors.
    dbg_log("advertise: creating BlueZ peripheral");
    let peripheral = Peripheral::new()
        .await
        .map_err(|e| { dbg_log(&format!("advertise: Peripheral::new FAILED ({e}); is the adapter blocked or powered off?")); e })?;

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
    peripheral
        .register_gatt()
        .await
        .map_err(|e| { dbg_log(&format!("advertise: register_gatt FAILED ({e})")); e })?;
    dbg_log("advertise: GATT application registered");
    let started = peripheral.start_advertising("Sonar", &[svc]).await;
    ADVERTISE_ATTEMPTED.store(true, Ordering::SeqCst);
    if let Err(e) = started {
        // Adapter present and powered, controller still refuses. Record it so
        // the host stops claiming mesh works and shows the scan-only notice.
        ADVERTISE_OK.store(false, Ordering::SeqCst);
        dbg_log(&format!(
            "advertise: start_advertising REFUSED by the adapter ({e}); mesh stays scan-only"
        ));
        return Err(e.into());
    }
    ADVERTISE_OK.store(true, Ordering::SeqCst);
    dbg_log("advertise: started on BlueZ (bitchat service)");

    fn announce() -> Vec<u8> {
        ANNOUNCE.lock().ok().and_then(|a| a.clone()).unwrap_or_default()
    }

    // One sender per subscribed central.
    let mut subs: Vec<futures::channel::mpsc::Sender<Vec<u8>>> = Vec::new();

    // Push to every subscriber, dropping only those whose channel has closed.
    // A full channel is not a dead one: capacity is 1, so a burst outruns it
    // routinely and the next tick retries.
    fn push(subs: &mut Vec<futures::channel::mpsc::Sender<Vec<u8>>>, payload: &[u8]) -> usize {
        let mut delivered = 0;
        subs.retain_mut(|s| match s.try_send(payload.to_vec()) {
            Ok(()) => {
                delivered += 1;
                true
            }
            Err(e) if e.is_full() => true,
            Err(_) => false, // disconnected
        });
        delivered
    }

    let mut last_notify = Instant::now()
        .checked_sub(Duration::from_secs(60))
        .unwrap_or_else(Instant::now);
    while ADVERTISING.load(Ordering::SeqCst) {
        // Re-announce on a timer like the CoreBluetooth path: a central that
        // subscribes between ticks is caught by the next one.
        if last_notify.elapsed() >= Duration::from_secs(2) && !subs.is_empty() {
            let ann = announce();
            if !ann.is_empty() {
                let n = push(&mut subs, &ann);
                dbg_log(&format!(
                    "advertise: notify announce ({} bytes) to {}/{} subscriber(s)",
                    ann.len(),
                    n,
                    subs.len()
                ));
            }
            last_notify = Instant::now();
        }

        // Packets the JVM mesh engine queued (handshake replies, DMs). Taken
        // only when someone is subscribed, so they are not dropped on the floor
        // before a phone connects.
        if !subs.is_empty() {
            let queued: Vec<Vec<u8>> = TX_PACKETS
                .lock()
                .map(|mut q| std::mem::take(&mut *q))
                .unwrap_or_default();
            for pkt in queued {
                push(&mut subs, &pkt);
            }
        }

        match tokio::time::timeout(Duration::from_millis(120), rx.next()).await {
            Ok(Some(ev)) => match ev {
                Event::NotifySubscribe(sub) => {
                    dbg_log("advertise: central subscribed");
                    let mut s = sub.notification;
                    // Send our announce immediately: this is the moment the
                    // phone is waiting for to show this desktop as a peer.
                    let _ = s.send(announce()).await;
                    subs.push(s);
                }
                Event::NotifyUnsubscribe => {
                    dbg_log("advertise: central unsubscribed");
                    subs.retain(|s| !s.is_closed());
                }
                Event::ReadRequest(req) => {
                    let _ = req.response.send(Response::Success(announce()));
                }
                Event::WriteRequest(req) => {
                    // A central's packet: its announce, a handshake step, or a
                    // DM. Hand it to the JVM mesh engine through RX_PACKETS.
                    dbg_log(&format!("advertise: rx write {} bytes from central", req.data.len()));
                    if let Ok(mut q) = RX_PACKETS.lock() {
                        if q.len() < 256 {
                            q.push(req.data);
                        }
                    }
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
    dbg_log("advertise: started (bitchat service)");

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
        let tx: Vec<Vec<u8>> = TX_PACKETS.lock().map(|mut q| std::mem::take(&mut *q)).unwrap_or_default();
        for pkt in tx {
            peripheral.notify(&pkt);
        }
        // Drain packets centrals wrote to us (bluster's event channel is a no-op
        // on macOS; we patched it to queue writes — take them here).
        let writes = peripheral.take_writes();
        if !writes.is_empty() {
            dbg_log(&format!("advertise: rx {} write packet(s) from central", writes.len()));
            if let Ok(mut q) = RX_PACKETS.lock() {
                for w in writes {
                    if q.len() < 256 {
                        q.push(w);
                    }
                }
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
    fn advertising_supported_covers_every_implemented_platform() {
        // Reset: another test in this binary may have recorded an attempt.
        ADVERTISE_ATTEMPTED.store(false, Ordering::SeqCst);
        assert_eq!(
            sonar_ble_advertising_supported(),
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
    /// compile-time answer there would tell the app mesh works while nothing is
    /// discoverable, which is the bug the UI notice exists to prevent, one layer
    /// down.
    #[test]
    fn a_refused_advertisement_downgrades_the_capability() {
        ADVERTISE_ATTEMPTED.store(false, Ordering::SeqCst);
        ADVERTISE_OK.store(false, Ordering::SeqCst);
        assert!(
            sonar_ble_advertising_supported() == cfg!(any(target_os = "macos", target_os = "ios", target_os = "linux")),
            "before an attempt the answer is the platform's"
        );

        // The adapter refused.
        ADVERTISE_ATTEMPTED.store(true, Ordering::SeqCst);
        ADVERTISE_OK.store(false, Ordering::SeqCst);
        assert!(!sonar_ble_advertising_supported(), "a refusal must downgrade it");

        // And a later success restores it.
        ADVERTISE_OK.store(true, Ordering::SeqCst);
        assert_eq!(
            sonar_ble_advertising_supported(),
            cfg!(any(target_os = "macos", target_os = "ios", target_os = "linux"))
        );
        ADVERTISE_ATTEMPTED.store(false, Ordering::SeqCst);
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
