//! Diagnostic: reproduce a Sonar -> White Noise group invite on the Mac with full
//! visibility (the device hides the send_event result). Connects a fresh ephemeral
//! identity to the real relays, fetches the peer's KeyPackage, creates a group and
//! publishes the welcome, printing how many welcomes + per-relay send results.
//! Usage: cargo run -p sonar-core --example test_invite -- <hex_pubkey>

use sonar_core::client::SonarClient;
use sonar_core::identity::Identity;

#[tokio::main]
async fn main() {
    let hex = std::env::args().nth(1).expect("pass a hex pubkey");
    let peer = nostr::PublicKey::parse(&hex).expect("valid pubkey");

    let relays = [
        "wss://relay.damus.io",
        "wss://nos.lol",
        "wss://relay.primal.net",
    ]
    .into_iter()
    .map(|r| nostr::RelayUrl::parse(r).unwrap())
    .collect();

    let me = SonarClient::connect_in_memory(Identity::generate(), relays)
        .await
        .expect("connect");
    // Give the relays a moment to actually connect before publishing.
    tokio::time::sleep(std::time::Duration::from_secs(3)).await;

    match me.start_dm(peer, "interop test").await {
        Ok(gid) => eprintln!(
            "[test_invite] start_dm OK, group {}",
            hex::encode(gid.as_slice())
        ),
        Err(e) => eprintln!("[test_invite] start_dm ERR: {e}"),
    }
    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
}
