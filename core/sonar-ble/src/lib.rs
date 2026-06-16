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
use futures::StreamExt;
use once_cell::sync::Lazy;
use std::collections::HashMap;
use std::ffi::{c_char, CString};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use uuid::Uuid;

/// bitchat mesh GATT service — must match the iOS/Android apps for real interop.
const BITCHAT_SERVICE: Uuid = Uuid::from_u128(0xF47B5E2D_4A9E_4C5A_9B3F_8E1D2C3A4B5C);
/// Drop a peer from the radar this long after its last advertisement.
const PEER_TTL: Duration = Duration::from_secs(12);

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

/// Free a string returned by [`sonar_ble_peers_json`].
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
    let Some(central) = init_central().await else {
        RUNNING.store(false, Ordering::SeqCst);
        return;
    };
    let Ok(mut events) = central.events().await else {
        RUNNING.store(false, Ordering::SeqCst);
        return;
    };
    let _ = central.start_scan(ScanFilter::default()).await;

    while RUNNING.load(Ordering::SeqCst) {
        // 1s timeout so a stop() is noticed even when no advertisements arrive.
        match tokio::time::timeout(Duration::from_secs(1), events.next()).await {
            Ok(Some(ev)) => handle_event(&central, ev).await,
            Ok(None) => break, // stream ended
            Err(_) => {}       // tick — re-check RUNNING
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
    let services = props.as_ref().map(|pr| pr.services.clone()).unwrap_or_default();
    let bitchat = services.contains(&BITCHAT_SERVICE);
    if let Ok(mut d) = DEVICES.lock() {
        d.insert(
            id.to_string(),
            Seen { name, rssi, bitchat, at: Instant::now() },
        );
    }
}
