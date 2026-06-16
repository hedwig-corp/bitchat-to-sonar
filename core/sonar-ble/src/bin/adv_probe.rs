//! Probe: can a Rust process advertise the bitchat mesh service (BLE peripheral
//! role) on this Mac via CoreBluetooth (bluster)? Verifies advertising starts
//! without error; reception must be checked from another device (phone scanner).

use bluster::gatt::characteristic::{Characteristic, Properties, Read, Secure, Write};
use bluster::gatt::event::{Event, Response};
use bluster::gatt::service::Service;
use bluster::Peripheral;
use futures::{channel::mpsc::channel, StreamExt};
use std::collections::HashSet;
use std::time::Duration;
use uuid08::Uuid; // bluster's UUID version

const SERVICE: u128 = 0xF47B5E2D_4A9E_4C5A_9B3F_8E1D2C3A4B5C;
const CHAR: u128 = 0xA1B2C3D4_E5F6_4A5B_8C9D_0E1F2A3B4C5D;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let svc_uuid = Uuid::from_u128(SERVICE);
    let chr_uuid = Uuid::from_u128(CHAR);

    let peripheral = Peripheral::new().await?;
    println!("peripheral created");

    let (tx, mut rx) = channel(16);
    let characteristic = Characteristic::new(
        chr_uuid,
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
    peripheral.add_service(&Service::new(svc_uuid, true, chars))?;
    peripheral.register_gatt().await?;
    println!("gatt registered");

    tokio::spawn(async move {
        while let Some(ev) = rx.next().await {
            match ev {
                Event::ReadRequest(req) => {
                    println!("READ request");
                    let _ = req.response.send(Response::Success(b"sonar".to_vec()));
                }
                Event::WriteRequest(req) => {
                    println!("WRITE {} bytes from central", req.data.len());
                    let _ = req.response.send(Response::Success(vec![]));
                }
                Event::NotifySubscribe(_) => println!("central SUBSCRIBED"),
                Event::NotifyUnsubscribe => println!("central unsubscribed"),
            }
        }
    });

    let mut tries = 0;
    while !peripheral.is_powered().await? {
        tokio::time::sleep(Duration::from_millis(200)).await;
        tries += 1;
        if tries > 50 {
            return Err("peripheral never powered on (Bluetooth off / unauthorized?)".into());
        }
    }
    println!("powered on");

    peripheral.start_advertising("Sonar", &[svc_uuid]).await?;
    println!("ADVERTISING bitchat service as \"Sonar\" — check your phone scanner (60s)");

    tokio::time::sleep(Duration::from_secs(60)).await;
    peripheral.stop_advertising().await?;
    println!("stopped");
    Ok(())
}
