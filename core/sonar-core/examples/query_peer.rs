//! Diagnostic: query the live relays for a peer's Marmot-relevant events.
//! Usage: cargo run -p sonar-core --example query_peer -- <hex_pubkey>
//! Confirms whether a White Noise interop failure is delivery/KeyPackage vs MDK.

use std::time::Duration;

use nostr::prelude::*;
use nostr_sdk::Client;

#[tokio::main]
async fn main() {
    let hex = std::env::args().nth(1).expect("pass a hex pubkey");
    let pk = PublicKey::parse(&hex).expect("valid pubkey");
    let timeout = Duration::from_secs(12);

    let client = Client::default();
    for r in [
        "wss://relay.damus.io",
        "wss://nos.lol",
        "wss://relay.primal.net",
    ] {
        client.add_relay(r).await.unwrap();
    }
    client.connect().await;
    tokio::time::sleep(Duration::from_secs(2)).await;

    // kind-0 profile
    let md = client.fetch_metadata(pk, timeout).await.unwrap();
    println!(
        "PROFILE (kind-0): {:?}",
        md.map(|m| (m.name, m.display_name))
    );

    // kind-30443 KeyPackages
    let kps = client
        .fetch_events(Filter::new().kind(Kind::Custom(30443)).author(pk), timeout)
        .await
        .unwrap();
    println!("KEYPACKAGES (kind-30443): {} found", kps.len());
    for e in kps.iter() {
        let d = e.tags.iter().find_map(|t| {
            if t.kind() == TagKind::d() {
                t.content().map(|s| s.to_string())
            } else {
                None
            }
        });
        let relays: Vec<String> = e
            .tags
            .iter()
            .filter(|t| t.kind().as_str() == "relays")
            .flat_map(|t| t.as_slice().iter().skip(1).cloned())
            .collect();
        println!(
            "  kp id={} created_at={} d={:?} relays={:?} content_len={}",
            &e.id.to_hex()[..12],
            e.created_at.as_secs(),
            d,
            relays,
            e.content.len()
        );
    }

    // Relay lists that govern WELCOME delivery: 10051 (KeyPackage relays),
    // 10050 (NIP-17 DM inbox — where gift-wrapped welcomes are read), 10002 (NIP-65).
    for (kind, label) in [
        (10051u16, "KeyPackage 10051"),
        (10050, "DM inbox 10050"),
        (10002, "NIP-65 10002"),
    ] {
        let rl = client
            .fetch_events(Filter::new().kind(Kind::Custom(kind)).author(pk), timeout)
            .await
            .unwrap();
        for e in rl.iter() {
            let relays: Vec<String> = e
                .tags
                .iter()
                .filter(|t| matches!(t.kind().as_str(), "relay" | "r"))
                .flat_map(|t| t.as_slice().iter().skip(1).cloned())
                .collect();
            println!("RELAY LIST ({label}): relays={:?}", relays);
        }
        if rl.is_empty() {
            println!("RELAY LIST ({label}): NONE");
        }
    }

    // kind-1059 gift wraps addressed to the peer (our welcomes land here; encrypted)
    let wraps = client
        .fetch_events(Filter::new().kind(Kind::GiftWrap).pubkey(pk), timeout)
        .await
        .unwrap();
    println!(
        "GIFT WRAPS to peer (kind-1059): {} found (welcomes/DMs, encrypted)",
        wraps.len()
    );
    let mut ts: Vec<u64> = wraps.iter().map(|e| e.created_at.as_secs()).collect();
    ts.sort_unstable();
    println!("  gift-wrap created_at (sorted): {:?}", ts);
}
