//! Diagnostic: query the live relays for a peer's Marmot-relevant events.
//! Usage: cargo run -p sonar-core --example query_peer -- <hex_pubkey> [relay ...]
//! Confirms whether a White Noise interop failure is delivery/KeyPackage vs MDK.

use std::time::Duration;

use nostr::prelude::*;
use nostr_sdk::Client;

#[tokio::main]
async fn main() {
    let mut args = std::env::args().skip(1);
    let hex = args.next().expect("pass a hex pubkey");
    let pk = PublicKey::parse(&hex).expect("valid pubkey");
    let timeout = Duration::from_secs(12);
    let mut relays: Vec<String> = args.collect();
    if relays.is_empty() {
        relays = [
            "wss://relay.damus.io",
            "wss://nos.lol",
            "wss://relay.primal.net",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect();
    }

    // Carry a signer so NIP-42 relays can authenticate diagnostic reads. By
    // default this is an ephemeral key; an operator can set SONAR_QUERY_NSEC to
    // inspect recipient-private relay behavior without printing the secret.
    let query_keys = match std::env::var("SONAR_QUERY_NSEC") {
        Ok(secret) => Keys::parse(&secret).expect("SONAR_QUERY_NSEC must be a valid nsec/secret"),
        Err(_) => Keys::generate(),
    };
    let client = Client::new(query_keys);
    for r in &relays {
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

    // Relay lists that govern KeyPackage lookup and WELCOME delivery. Newer
    // Marmot clients use NIP-65 (10002) for KeyPackages; older clients may
    // still advertise the legacy 10051 list. Inbox relays (10050) receive
    // gift-wrapped welcomes.
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
            let relays: Vec<String> = match kind {
                10002 => nostr::nips::nip65::extract_relay_list(e)
                    .map(|(relay, metadata)| match metadata {
                        Some(metadata) => format!("{relay} ({metadata})"),
                        None => relay.to_string(),
                    })
                    .collect(),
                10050 => nostr::nips::nip17::extract_relay_list(e)
                    .map(ToString::to_string)
                    .collect(),
                _ => e
                    .tags
                    .iter()
                    .filter(|tag| tag.kind().as_str() == "relay")
                    .filter_map(|tag| tag.content().map(str::to_owned))
                    .collect(),
            };
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
