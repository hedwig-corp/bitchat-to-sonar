//! End-to-end test: two independent Sonar instances exchange Marmot (MLS over
//! Nostr) messages through an in-process relay. No network, deterministic.
//!
//! This is the M1 acceptance test: KeyPackage publication → group creation →
//! gift-wrapped welcome → bidirectional encrypted messages.

use nostr_relay_builder::MockRelay;
use sonar_core::client::SonarClient;
use sonar_core::identity::Identity;

#[tokio::test]
async fn two_instances_exchange_dms_through_a_relay() {
    let relay = MockRelay::run().await.expect("mock relay starts");
    let relay_url = relay.url().await;

    let alice = SonarClient::connect_in_memory(Identity::generate(), vec![relay_url.clone()])
        .await
        .expect("alice connects");
    let bob = SonarClient::connect_in_memory(Identity::generate(), vec![relay_url.clone()])
        .await
        .expect("bob connects");

    // Bob makes himself reachable.
    bob.publish_key_package().await.expect("bob publishes kp");

    // Alice starts the DM and sends the first message.
    let alice_group = alice
        .start_dm(bob.identity().public_key(), "alice & bob")
        .await
        .expect("alice starts dm");
    alice
        .send_text(&alice_group, "Hi Bob! (over Marmot)")
        .await
        .expect("alice sends");

    // Bob polls: welcome lands first, then the message.
    bob.sync().await.expect("bob syncs");
    let bob_groups = bob.groups().expect("bob groups");
    assert_eq!(bob_groups.len(), 1, "bob joined exactly one group");
    let bob_group = &bob_groups[0].mls_group_id;

    let bob_view = bob.messages(bob_group).expect("bob messages");
    assert_eq!(bob_view.len(), 1);
    assert_eq!(bob_view[0].content, "Hi Bob! (over Marmot)");
    assert_eq!(bob_view[0].sender, alice.identity().public_key());
    assert!(!bob_view[0].mine);

    // Bob replies; Alice polls and sees both directions.
    bob.send_text(bob_group, "hey Alice, got it")
        .await
        .expect("bob replies");
    alice.sync().await.expect("alice syncs");

    let alice_view = alice.messages(&alice_group).expect("alice messages");
    assert_eq!(alice_view.len(), 2, "alice sees her message and bob's reply");
    let reply = alice_view
        .iter()
        .find(|m| m.sender == bob.identity().public_key())
        .expect("bob's reply visible to alice");
    assert_eq!(reply.content, "hey Alice, got it");
    assert!(!reply.mine);

    // Re-syncing must not duplicate anything (idempotent processing).
    alice.sync().await.expect("alice re-syncs");
    bob.sync().await.expect("bob re-syncs");
    assert_eq!(alice.messages(&alice_group).unwrap().len(), 2);
    assert_eq!(bob.messages(bob_group).unwrap().len(), 2);

    // Both sides agree on membership.
    let members = bob.groups().unwrap()[0].clone();
    assert_eq!(members.mls_group_id, *bob_group);
}

/// Two instances in the same geohash channel exchange public messages, with
/// correct nickname tags, mine-detection, and channel isolation.
#[tokio::test]
async fn two_instances_exchange_geohash_channel_messages() {
    let relay = MockRelay::run().await.expect("mock relay starts");
    let relay_url = relay.url().await;

    let alice = SonarClient::connect_in_memory(Identity::generate(), vec![relay_url.clone()])
        .await
        .expect("alice connects");
    let bob = SonarClient::connect_in_memory(Identity::generate(), vec![relay_url.clone()])
        .await
        .expect("bob connects");

    let geohash = "u0nd";
    // Geohash messages are ephemeral — both must subscribe before anyone posts,
    // and delivery is live (no relay storage), so allow brief propagation.
    alice.subscribe_geohash(geohash).await.expect("alice joins");
    bob.subscribe_geohash(geohash).await.expect("bob joins");
    tokio::time::sleep(std::time::Duration::from_millis(250)).await;

    alice
        .send_geohash(geohash, "hello from alice", "alice")
        .await
        .expect("alice posts");
    bob.send_geohash(geohash, "hi from bob", "bob")
        .await
        .expect("bob posts");
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;

    let view = bob.fetch_geohash(geohash, 100).await.expect("bob fetches");
    assert_eq!(view.len(), 2, "both public messages visible");

    let from_alice = view.iter().find(|m| m.content == "hello from alice").unwrap();
    assert_eq!(from_alice.nickname, "alice");
    assert!(!from_alice.mine, "alice's message is not bob's");

    let from_bob = view.iter().find(|m| m.content == "hi from bob").unwrap();
    assert_eq!(from_bob.nickname, "bob");
    assert!(from_bob.mine, "bob's own message detected as mine");

    // A different geohash is an isolated channel.
    let other = bob.fetch_geohash("9q5c", 100).await.expect("other fetch");
    assert!(other.is_empty(), "different geohash sees nothing");
}

/// Two channel participants exchange a 1:1 encrypted geohash DM (NIP-17 over
/// their per-geohash keys), learning each other's keys from the public channel.
#[tokio::test]
async fn geohash_dm_between_channel_participants() {
    let relay = MockRelay::run().await.expect("mock relay starts");
    let url = relay.url().await;
    let alice = SonarClient::connect_in_memory(Identity::generate(), vec![url.clone()])
        .await
        .expect("alice connects");
    let bob = SonarClient::connect_in_memory(Identity::generate(), vec![url.clone()])
        .await
        .expect("bob connects");

    let gh = "u0nd";
    alice.subscribe_geohash(gh).await.expect("alice joins");
    bob.subscribe_geohash(gh).await.expect("bob joins");
    tokio::time::sleep(std::time::Duration::from_millis(250)).await;

    // Both post publicly so each learns the other's per-geohash pubkey.
    alice.send_geohash(gh, "hi from alice", "alice").await.unwrap();
    bob.send_geohash(gh, "hi from bob", "bob").await.unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(450)).await;

    let alice_pk = bob
        .fetch_geohash(gh, 50)
        .await
        .unwrap()
        .into_iter()
        .find(|m| m.content == "hi from alice")
        .expect("bob sees alice in channel")
        .sender_pubkey;
    let bob_pk = alice
        .fetch_geohash(gh, 50)
        .await
        .unwrap()
        .into_iter()
        .find(|m| m.content == "hi from bob")
        .expect("alice sees bob in channel")
        .sender_pubkey;

    // Alice DMs bob privately.
    alice
        .send_geo_dm(gh, &bob_pk, "hey bob, privately")
        .await
        .expect("alice dms bob");
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;

    let bob_inbox = bob.fetch_geo_dm(gh, &alice_pk).await.expect("bob reads dm");
    assert_eq!(bob_inbox.len(), 1, "bob received the private DM");
    assert_eq!(bob_inbox[0].content, "hey bob, privately");
    assert!(!bob_inbox[0].mine, "the DM is from alice");

    let alice_thread = alice.fetch_geo_dm(gh, &bob_pk).await.expect("alice reads thread");
    assert_eq!(alice_thread.len(), 1);
    assert!(alice_thread[0].mine, "alice's own sent DM is mine");
}
