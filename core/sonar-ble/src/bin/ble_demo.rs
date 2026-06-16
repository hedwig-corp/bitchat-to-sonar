//! BLE capability probe / demo for Sonar Desktop.
//!
//! Scans for nearby Bluetooth LE peripherals via the host adapter (CoreBluetooth
//! on macOS, BlueZ on Linux) and prints them, highlighting any advertising the
//! bitchat mesh service UUID. This proves the desktop can drive BLE at all — the
//! foundation for the mesh radio — independent of the JVM.
//!
//! Run: cargo run -p sonar-ble --bin ble-demo   (from core/sonar-ble)
//! On macOS the first run triggers the Bluetooth permission prompt for the
//! launching app (Terminal); approve it for scanning to return results.

use btleplug::api::{Central, CentralEvent, Manager as _, Peripheral as _, ScanFilter};
use btleplug::platform::Manager;
use futures::StreamExt;
use std::time::Duration;
use uuid::Uuid;

// bitchat mesh GATT identifiers (must match the iOS/Android apps for real interop).
const BITCHAT_SERVICE: Uuid = Uuid::from_u128(0xF47B5E2D_4A9E_4C5A_9B3F_8E1D2C3A4B5C);

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let scan_secs: u64 = std::env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(8);

    println!("Sonar BLE demo — central scan ({scan_secs}s)\n");

    let manager = Manager::new().await?;
    let adapters = manager.adapters().await?;
    let central = adapters
        .into_iter()
        .next()
        .ok_or("no Bluetooth adapter found")?;
    println!("adapter: {}\n", central.adapter_info().await.unwrap_or_default());

    let mut events = central.events().await?;
    central.start_scan(ScanFilter::default()).await?;
    println!("scanning… (Ctrl-C to stop early)\n");

    let mut seen = 0usize;
    let deadline = tokio::time::sleep(Duration::from_secs(scan_secs));
    tokio::pin!(deadline);

    loop {
        tokio::select! {
            _ = &mut deadline => break,
            Some(ev) = events.next() => {
                if let CentralEvent::DeviceDiscovered(id) = ev {
                    if let Ok(p) = central.peripheral(&id).await {
                        let props = p.properties().await.ok().flatten();
                        let name = props.as_ref().and_then(|pr| pr.local_name.clone())
                            .unwrap_or_else(|| "(no name)".into());
                        let rssi = props.as_ref().and_then(|pr| pr.rssi).unwrap_or(0);
                        let services = props.as_ref().map(|pr| pr.services.clone()).unwrap_or_default();
                        let is_bitchat = services.contains(&BITCHAT_SERVICE);
                        seen += 1;
                        println!(
                            "  {} {:>4} dBm  {}{}",
                            id, rssi, name,
                            if is_bitchat { "   <-- BITCHAT MESH" } else { "" },
                        );
                    }
                }
            }
        }
    }

    central.stop_scan().await?;
    println!("\ndone — discovered {seen} advertisement(s).");
    if seen == 0 {
        println!(
            "0 devices: either nothing is advertising nearby, Bluetooth is off, or\n\
             macOS denied the Bluetooth permission to the launching app (grant it in\n\
             System Settings → Privacy & Security → Bluetooth, then re-run)."
        );
    }
    Ok(())
}
