//! End-to-end typing indicators: two Sonar instances against an in-process
//! relay. Alice types in a DM; Bob's live tail surfaces an ephemeral typing
//! indicator and clears it, with zero transcript/persistence impact.

use std::sync::Arc;

use nostr_relay_builder::MockRelay;
use sonar_core::client::SonarClient;
use sonar_core::identity::Identity;
use sonar_core::typing::TypingListener;
use tokio::time::{timeout, Duration};

struct ChannelListener {
    tx: tokio::sync::mpsc::UnboundedSender<(String, bool)>,
}

impl TypingListener for ChannelListener {
    fn on_typing_changed(&self, group_id_hex: String, typing: bool) {
        let _ = self.tx.send((group_id_hex, typing));
    }
}

#[tokio::test]
async fn typing_indicator_round_trip() {
    let relay = MockRelay::run().await.expect("mock relay starts");
    let relay_url = relay.url().await;

    let alice = SonarClient::connect_in_memory(Identity::generate(), vec![relay_url.clone()])
        .await
        .expect("alice connects");
    let bob = SonarClient::connect_in_memory(Identity::generate(), vec![relay_url.clone()])
        .await
        .expect("bob connects");

    // Establish the DM: Bob reachable, Alice starts + sends, Bob syncs in.
    bob.publish_key_package().await.expect("bob publishes kp");
    let alice_group = alice
        .start_dm(bob.identity().public_key(), "alice & bob")
        .await
        .expect("alice starts dm");
    alice
        .send_text(&alice_group, "hi bob")
        .await
        .expect("alice sends");
    bob.sync().await.expect("bob syncs");
    let bob_groups = bob.groups().expect("bob groups");
    assert_eq!(bob_groups.len(), 1);
    let bob_group_hex = hex::encode(bob_groups[0].mls_group_id.as_slice());
    let transcript_before = bob.messages(&bob_groups[0].mls_group_id).unwrap().len();

    // Bob opens the live tail (in-memory sessions skip this on connect) and
    // registers for typing callbacks.
    bob.subscribe_marmot().await.expect("bob live tail");
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    bob.set_typing_listener(Some(Arc::new(ChannelListener { tx })));

    // Alice's composer produces input.
    alice.notify_typing(&alice_group);

    let (group_hex, typing) = timeout(Duration::from_secs(10), rx.recv())
        .await
        .expect("typing indicator arrives")
        .expect("listener channel open");
    assert!(typing, "first signal is typing=true");
    assert_eq!(group_hex, bob_group_hex, "keyed by Bob's MLS group id");

    // Alice sends the message: STOPPED goes out immediately (Signal
    // semantics), clearing Bob's indicator well before the 15s expiry.
    alice
        .send_text(&alice_group, "done typing")
        .await
        .expect("alice sends again");

    let (group_hex, typing) = timeout(Duration::from_secs(10), rx.recv())
        .await
        .expect("stop indicator arrives")
        .expect("listener channel open");
    assert!(!typing, "second signal is typing=false");
    assert_eq!(group_hex, bob_group_hex);

    // Ephemeral means ephemeral: no transcript rows from typing traffic (only
    // the real message), and typing never advances conversation state. With
    // the live tail open the 445 arrives via the pending buffer; retry until
    // the relay delivers it (bounded), then assert the exact row count.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    loop {
        bob.drain_pending_marmot().await.expect("bob drains live");
        let count = bob.messages(&bob_groups[0].mls_group_id).unwrap().len();
        if count > transcript_before || tokio::time::Instant::now() >= deadline {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let transcript_after = bob.messages(&bob_groups[0].mls_group_id).unwrap().len();
    assert_eq!(
        transcript_after,
        transcript_before + 1,
        "exactly one new transcript row (the real message), none from typing"
    );
}
