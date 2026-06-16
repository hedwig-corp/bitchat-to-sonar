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

use btleplug::api::{Central, CentralEvent, Manager as _, Peripheral as _, ScanFilter};
use btleplug::platform::Manager;
use bluster::gatt::characteristic::{Characteristic, Properties, Read, Secure, Write};
use bluster::gatt::event::{Event, Response};
use bluster::gatt::service::Service;
use bluster::Peripheral;
use futures::StreamExt;
use once_cell::sync::Lazy;
use std::collections::{HashMap, HashSet};
use std::ffi::{c_char, CString};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use uuid::Uuid;
use uuid08::Uuid as Uuid08; // bluster's UUID version

/// bitchat mesh GATT service + characteristic — must match the iOS/Android apps.
const BITCHAT_SERVICE_U128: u128 = 0xF47B5E2D_4A9E_4C5A_9B3F_8E1D2C3A4B5C;
const BITCHAT_CHAR_U128: u128 = 0xA1B2C3D4_E5F6_4A5B_8C9D_0E1F2A3B4C5D;
const BITCHAT_SERVICE: Uuid = Uuid::from_u128(BITCHAT_SERVICE_U128);

/// The signed bitchat ANNOUNCE packet (built by the Rust core via the JVM and
/// pushed down) that the GATT server sends when a central subscribes — that's
/// what makes a phone show this desktop as a named mesh peer.
static ANNOUNCE: Lazy<Mutex<Option<Vec<u8>>>> = Lazy::new(|| Mutex::new(None));
static ADVERTISING: AtomicBool = AtomicBool::new(false);

/// Packets centrals wrote to our GATT characteristic (their announce / handshake).
/// Drained by the JVM, which decodes the announce to name + dedupe a peer — this
/// is how the desktop learns a phone that connected to it (the phone suppresses
/// its own advertising while connected, so scanning alone can't see it).
static RX_PACKETS: Lazy<Mutex<Vec<Vec<u8>>>> = Lazy::new(|| Mutex::new(Vec::new()));

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

/// Diagnostic log (only when SONAR_BLE_DEBUG is set) — appends to a file so it's
/// readable regardless of how the app is launched (a jpackage app has no stdout).
fn dbg_log(msg: &str) {
    if std::env::var_os("SONAR_BLE_DEBUG").is_none() {
        return;
    }
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open("/tmp/sonar-ble.log")
    {
        let _ = writeln!(f, "{msg}");
    }
}

#[derive(Clone)]
struct Seen {
    name: Option<String>,
    rssi: i16,
    bitchat: bool,
    at: Instant,
}

static DEVICES: Lazy<Mutex<HashMap<String, Seen>>> = Lazy::new(|| Mutex::new(HashMap::new()));
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
        for (id, s) in d.iter() {
            // Only surface bitchat-mesh advertisers as radar peers.
            if !s.bitchat {
                continue;
            }
            items.push(serde_json::json!({
                "id": id,
                "name": s.name,
                "rssi": s.rssi,
                "bitchat": s.bitchat,
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
            Ok(Some(ev)) => handle_event(&central, ev).await,
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

async fn init_central() -> Option<btleplug::platform::Adapter> {
    let manager = Manager::new().await.ok()?;
    let adapters = manager.adapters().await.ok()?;
    adapters.into_iter().next()
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
    // The scan is filtered to the bitchat service, so every reported peripheral
    // matched it — even when CoreBluetooth hands back an empty parsed services
    // array (common). So treat all scan results as bitchat peers.
    let bitchat = true;
    dbg_log(&format!("discovered BITCHAT peer {id} rssi={rssi}"));
    if let Ok(mut d) = DEVICES.lock() {
        d.insert(
            id.to_string(),
            Seen { name, rssi, bitchat, at: Instant::now() },
        );
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

/// Begin advertising the bitchat service (peripheral role) so phones discover
/// this desktop and, on subscribe, receive the announce. Idempotent.
#[no_mangle]
pub extern "C" fn sonar_ble_start_advertising() {
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
        match tokio::time::timeout(Duration::from_millis(500), rx.next()).await {
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
