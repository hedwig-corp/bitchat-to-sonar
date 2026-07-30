//! E2E against REAL relays: prove a device keeps ONE kind-30443 KeyPackage slot
//! across relaunches, and that a peer fetching it gets the newest one.
//!
//! Simulates three app launches of the same install (persistent engine reopened
//! at the same path), publishing a KeyPackage on each "relay connect" the way
//! the hosts do, then queries the relays as a PEER would and counts the slots.
//!
//! Usage: cargo run -p sonar-core --example keypackage_slot_e2e
//! Publishes a handful of events under a throwaway identity. No account data.

use sonar_core::client::SonarClient;
use sonar_core::identity::Identity;
use std::time::Duration;

const DB_KEY: [u8; 32] = [0x37; 32];
const LAUNCHES: usize = 3;

#[tokio::main]
async fn main() {
    let relays: Vec<nostr::RelayUrl> = [
        "wss://relay.damus.io",
        "wss://nos.lol",
        "wss://relay.primal.net",
    ]
    .into_iter()
    .map(|r| nostr::RelayUrl::parse(r).unwrap())
    .collect();

    // One throwaway identity, one on-disk install reopened per "launch".
    let identity = Identity::generate();
    let me = identity.public_key();
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("marmot.sqlite");
    eprintln!("[e2e] identity {}", me.to_hex());

    for launch in 1..=LAUNCHES {
        let client = SonarClient::connect(identity.clone(), relays.clone(), &db_path, DB_KEY)
            .await
            .expect("connect");
        tokio::time::sleep(Duration::from_secs(3)).await;
        client.publish_key_package().await.expect("publish kp");
        eprintln!("[e2e] launch {launch}: published");
        drop(client);
        tokio::time::sleep(Duration::from_secs(1)).await;
    }

    // Let the relays settle, then look at ourselves the way a PEER would.
    tokio::time::sleep(Duration::from_secs(4)).await;
    let peer = SonarClient::connect_in_memory(Identity::generate(), relays)
        .await
        .expect("peer connect");
    tokio::time::sleep(Duration::from_secs(3)).await;

    let all = peer.fetch_all_key_packages(me).await.expect("fetch all");
    let mut slots: Vec<String> = all
        .iter()
        .filter_map(|e| {
            e.tags
                .iter()
                .find(|t| t.kind() == nostr::TagKind::d())
                .and_then(|t| t.content())
                .map(|s| s.to_string())
        })
        .collect();
    slots.sort();
    slots.dedup();

    eprintln!(
        "[e2e] after {LAUNCHES} launches: {} event(s), {} distinct slot(s)",
        all.len(),
        slots.len()
    );
    for e in &all {
        eprintln!("[e2e]   event {} created_at {}", e.id.to_hex(), e.created_at);
    }

    // What a peer starting a DM actually resolves to.
    let picked = peer.fetch_key_package(me).await.expect("fetch one");
    let newest = all.iter().max_by_key(|e| e.created_at).expect("nonempty");
    eprintln!("[e2e] fetch_key_package picked {}", picked.id.to_hex());

    assert_eq!(
        slots.len(),
        1,
        "expected ONE addressable slot after {LAUNCHES} launches, got {}: {slots:?}",
        slots.len()
    );
    assert_eq!(
        picked.id, newest.id,
        "fetch_key_package must resolve to the newest event, not whichever relay replied first"
    );
    eprintln!("[e2e] PASS: one stable slot, newest-wins selection");
}
