//! Large-account QA fixture: one Sonar account in hundreds of Marmot groups,
//! seeded against a LOCAL relay, written to an encrypted store the iOS
//! simulator app can adopt (see `scripts/qa/large-account.sh`).
//!
//! Small QA accounts hid four bugs that only show at ~400 groups (R-054,
//! R-055, R-056): O(groups) and O(groups²) work is microseconds on five
//! groups. This builds the account shape the reporter's iPhone had:
//!
//! - `FIXTURE_PEERS` 1:1 chats (default 400), the account sending a message in
//!   each, `FIXTURE_REPLY_PEERS` of them (default 40) replying, so recent
//!   chats have peer rows and the rest have only our own;
//! - a second 1:1 group with `FIXTURE_DUP_PEERS` of those peers (default 20),
//!   the duplicate-conversation shape the timezone alias path handles;
//! - `FIXTURE_GROUPS` multi-member groups (default 5) of three fresh peers.
//!
//! Nothing touches public relays: a `LocalRelay` on `FIXTURE_RELAY_PORT`
//! (default 7447) carries every event, and with `FIXTURE_SERVE=1` (default)
//! it keeps serving after seeding so the app gets live traffic from it.
//!
//! The store is opened the way the iOS DEBUG bench path opens it: identity
//! from `FIXTURE_NSEC` (generated when unset), DB key = SHA-256 over the
//! nsec string, hex. Output in `FIXTURE_DIR`: `marmot.sqlite` plus its
//! sidecars, and `fixture.json` (nsec, npub, relay, group ids by kind).
//!
//! Usage:
//!   FIXTURE_DIR=/tmp/sonar-large cargo run -p sonar-core --release \
//!     --example seed_large_account

use std::net::{IpAddr, Ipv4Addr};
use std::path::PathBuf;
use std::time::{Duration, Instant};

use nostr::{Keys, RelayUrl, ToBech32};
use nostr_relay_builder::prelude::*;
use sha2::{Digest, Sha256};
use sonar_core::client::SonarClient;
use sonar_core::identity::Identity;
use sonar_core::marmot::MarmotEngine;

fn env_usize(key: &str, default: usize) -> usize {
    std::env::var(key)
        .ok()
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or(default)
}

#[tokio::main]
async fn main() {
    let dir = PathBuf::from(std::env::var("FIXTURE_DIR").expect("set FIXTURE_DIR"));
    let peers_n = env_usize("FIXTURE_PEERS", 400);
    let reply_n = env_usize("FIXTURE_REPLY_PEERS", 40).min(peers_n);
    let dup_n = env_usize("FIXTURE_DUP_PEERS", 20).min(peers_n);
    let groups_n = env_usize("FIXTURE_GROUPS", 5);
    let port = env_usize("FIXTURE_RELAY_PORT", 7447) as u16;
    let serve = std::env::var("FIXTURE_SERVE").map(|v| v != "0").unwrap_or(true);
    std::fs::create_dir_all(&dir).expect("create FIXTURE_DIR");
    let db = dir.join("marmot.sqlite");
    if db.exists() {
        panic!("{} already exists; seed into an empty FIXTURE_DIR", db.display());
    }

    // The default 60 notes/minute would throttle seeding (one account sends
    // a welcome and a message per group). Filter limits keep their defaults,
    // so result caps behave like a public relay's.
    let relay = LocalRelay::new(
        RelayBuilder::default()
            .addr(IpAddr::V4(Ipv4Addr::LOCALHOST))
            .port(port)
            .rate_limit(RateLimit {
                max_reqs: 10_000,
                notes_per_minute: 1_000_000,
            }),
    );
    relay.run().await.expect("local relay starts");
    let relay_url: RelayUrl = relay.url().await;
    let relays = vec![relay_url.clone()];
    eprintln!("[seed] local relay {relay_url}");

    // The account under test.
    let nsec = match std::env::var("FIXTURE_NSEC") {
        Ok(v) if !v.trim().is_empty() => v.trim().to_owned(),
        _ => Keys::generate().secret_key().to_bech32().expect("bech32 nsec"),
    };
    let me_identity = Identity::import(&nsec).expect("FIXTURE_NSEC parses");
    let mut key = [0u8; 32];
    key.copy_from_slice(&hex::decode(hex::encode(Sha256::digest(nsec.as_bytes()))).unwrap());
    let me = SonarClient::connect(me_identity.clone(), relays.clone(), &db, key)
        .await
        .expect("account store opens");
    me.publish_key_package().await.expect("own key package");

    // Silent peers: key packages only, published through one shared client.
    let publisher = nostr_sdk::Client::default();
    publisher.add_relay(relay_url.clone()).await.expect("publisher relay");
    publisher.connect().await;

    let started = Instant::now();
    let mut reply_peers = Vec::with_capacity(reply_n);
    let mut silent_peers = Vec::with_capacity(peers_n - reply_n);
    for i in 0..peers_n {
        if i < reply_n {
            let peer = SonarClient::connect_in_memory(Identity::generate(), relays.clone())
                .await
                .expect("reply peer connects");
            peer.publish_key_package().await.expect("reply peer key package");
            reply_peers.push(peer);
        } else {
            let peer = MarmotEngine::in_memory(Identity::generate());
            let kp = peer.key_package_event(relays.clone()).expect("peer key package");
            publisher.send_event(&kp).await.expect("publish peer key package");
            silent_peers.push(peer);
        }
    }
    eprintln!("[seed] {peers_n} peers ready in {:?}", started.elapsed());

    let mut manifest_groups = Vec::new();
    let peer_keys: Vec<nostr::PublicKey> = reply_peers
        .iter()
        .map(|p| p.identity().public_key())
        .chain(silent_peers.iter().map(|p| p.identity().public_key()))
        .collect();

    // One 1:1 chat per peer, our message in each.
    let started = Instant::now();
    for (i, peer) in peer_keys.iter().enumerate() {
        let group = me
            .start_dm(*peer, &format!("chat {i}"))
            .await
            .unwrap_or_else(|e| panic!("start_dm {i}: {e}"));
        me.send_text(&group, &format!("hello {i}"))
            .await
            .unwrap_or_else(|e| panic!("send {i}: {e}"));
        manifest_groups.push(serde_json::json!({
            "kind": "dm",
            "mls_group_id": hex::encode(group.as_slice()),
            "peer_npub": peer.to_bech32().unwrap(),
        }));
        if (i + 1) % 50 == 0 {
            eprintln!("[seed] {} chats in {:?}", i + 1, started.elapsed());
        }
    }

    // A second 1:1 group with some peers (a later duplicate of the same chat).
    for (i, peer) in silent_peers.iter().take(dup_n).enumerate() {
        let kp = peer.key_package_event(relays.clone()).expect("second key package");
        let group = me
            .start_dm_with_key_package(kp, &format!("dup {i}"))
            .await
            .unwrap_or_else(|e| panic!("dup start_dm {i}: {e}"));
        me.send_text(&group, &format!("again {i}")).await.expect("dup send");
        manifest_groups.push(serde_json::json!({
            "kind": "dup",
            "mls_group_id": hex::encode(group.as_slice()),
            "peer_npub": peer.identity().public_key().to_bech32().unwrap(),
        }));
    }

    // A few multi-member groups of fresh peers.
    for g in 0..groups_n {
        let mut members = Vec::new();
        for _ in 0..3 {
            let peer = MarmotEngine::in_memory(Identity::generate());
            let kp = peer.key_package_event(relays.clone()).expect("member key package");
            publisher.send_event(&kp).await.expect("publish member key package");
            members.push(peer.identity().public_key());
        }
        let group = me
            .start_group(members, &format!("team {g}"))
            .await
            .unwrap_or_else(|e| panic!("start_group {g}: {e}"));
        me.send_text(&group, &format!("team hello {g}")).await.expect("group send");
        manifest_groups.push(serde_json::json!({
            "kind": "group",
            "mls_group_id": hex::encode(group.as_slice()),
        }));
    }

    // Reply peers join (1:1 welcomes auto-accept) and answer.
    for (i, peer) in reply_peers.iter().enumerate() {
        let mut joined = None;
        for _ in 0..40 {
            let _ = peer.sync().await;
            if let Some(group) = peer.groups().ok().and_then(|g| g.into_iter().next()) {
                joined = Some(group.mls_group_id);
                break;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        let group = joined.unwrap_or_else(|| panic!("reply peer {i} never joined"));
        peer.send_text(&group, &format!("reply {i}")).await.expect("reply");
    }
    me.sync_force().await.expect("pull replies");

    // Map MLS ids to the nostr (`#h`) ids the logs print.
    let nostr_ids: std::collections::HashMap<String, String> = me
        .groups()
        .expect("groups")
        .into_iter()
        .map(|g| {
            (
                hex::encode(g.mls_group_id.as_slice()),
                hex::encode(g.nostr_group_id),
            )
        })
        .collect();
    for entry in &mut manifest_groups {
        let mls = entry["mls_group_id"].as_str().unwrap().to_owned();
        if let Some(nostr) = nostr_ids.get(&mls) {
            entry["nostr_group_id"] = serde_json::Value::String(nostr.clone());
        }
    }
    let manifest = serde_json::json!({
        "nsec": nsec,
        "npub": me_identity.npub(),
        "relay": relay_url.to_string(),
        "db": "marmot.sqlite",
        "groups": manifest_groups,
    });
    std::fs::write(
        dir.join("fixture.json"),
        serde_json::to_vec_pretty(&manifest).unwrap(),
    )
    .expect("write fixture.json");
    eprintln!(
        "[seed] done: {} groups ({} reply chats) -> {}",
        nostr_ids.len(),
        reply_n,
        dir.display()
    );
    // Close the store so the files are complete before anyone copies them.
    drop(me);
    println!("READY {}", dir.join("fixture.json").display());

    if serve {
        eprintln!("[seed] serving {relay_url} until killed");
        loop {
            tokio::time::sleep(Duration::from_secs(3600)).await;
        }
    }
}
