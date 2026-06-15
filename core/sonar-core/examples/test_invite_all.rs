//! Diagnostic: invite a peer via EACH of their KeyPackages, so we can see (in the
//! recipient's log) which KeyPackage it accepts vs rejects as "unknown key
//! package". Usage: cargo run -p sonar-core --example test_invite_all -- <hex>

use sonar_core::client::SonarClient;
use sonar_core::identity::Identity;

#[tokio::main]
async fn main() {
    let hex = std::env::args().nth(1).expect("pass a hex pubkey");
    let peer = nostr::PublicKey::parse(&hex).expect("valid pubkey");
    let relays = ["wss://relay.damus.io", "wss://nos.lol", "wss://relay.primal.net"]
        .into_iter()
        .map(|r| nostr::RelayUrl::parse(r).unwrap())
        .collect();

    let me = SonarClient::connect_in_memory(Identity::generate(), relays)
        .await
        .expect("connect");
    tokio::time::sleep(std::time::Duration::from_secs(3)).await;

    let kps = me.fetch_all_key_packages(peer).await.expect("fetch kps");
    eprintln!("[invite_all] {} key package(s) found", kps.len());
    for kp in kps {
        let kp_id = kp.id.to_hex();
        match me.start_dm_with_key_package(kp.clone(), "interop test").await {
            Ok(gid) => eprintln!(
                "[invite_all] invited via kp {} -> group {}",
                &kp_id[..12],
                hex::encode(gid.as_slice())
            ),
            Err(e) => eprintln!("[invite_all] kp {} ERR: {e}", &kp_id[..12]),
        }
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    }
    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
}
