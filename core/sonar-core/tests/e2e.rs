//! End-to-end test: two independent Sonar instances exchange Marmot (MLS over
//! Nostr) messages through an in-process relay. No network, deterministic.
//!
//! This is the M1 acceptance test: KeyPackage publication → group creation →
//! gift-wrapped welcome → bidirectional encrypted messages.

use nostr_relay_builder::MockRelay;
use sonar_core::client::SonarClient;
use sonar_core::identity::Identity;
use tokio::time::{timeout, Duration};

#[tokio::test]
async fn profile_publish_and_fetch_through_a_relay() {
    // A Marmot member's identity is a Nostr pubkey (MIP-00); their display name
    // is resolved via a standard kind-0 profile. Bob publishes his profile; Alice
    // fetches it to show a human name instead of a raw npub.
    let relay = MockRelay::run().await.expect("mock relay starts");
    let relay_url = relay.url().await;

    let alice = SonarClient::connect_in_memory(Identity::generate(), vec![relay_url.clone()])
        .await
        .expect("alice connects");
    let bob = SonarClient::connect_in_memory(Identity::generate(), vec![relay_url.clone()])
        .await
        .expect("bob connects");

    // Before Bob publishes, Alice finds no profile.
    let none = alice
        .fetch_profile(bob.identity().public_key())
        .await
        .expect("fetch ok");
    assert!(none.is_none(), "no profile before Bob publishes");

    bob.publish_profile("Bob the Marmot", Some("hello there"), None)
        .await
        .expect("bob publishes profile");

    let profile = alice
        .fetch_profile(bob.identity().public_key())
        .await
        .expect("fetch ok")
        .expect("Bob's profile is found");
    assert_eq!(profile.best_name(), Some("Bob the Marmot"));
    assert_eq!(profile.name.as_deref(), Some("Bob the Marmot"));
    assert_eq!(profile.about.as_deref(), Some("hello there"));
}

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
    assert_eq!(
        alice_view.len(),
        2,
        "alice sees her message and bob's reply"
    );
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

#[tokio::test]
async fn start_dm_reuses_existing_direct_group() {
    let relay = MockRelay::run().await.expect("mock relay starts");
    let relay_url = relay.url().await;

    let alice = SonarClient::connect_in_memory(Identity::generate(), vec![relay_url.clone()])
        .await
        .expect("alice connects");
    let bob = SonarClient::connect_in_memory(Identity::generate(), vec![relay_url.clone()])
        .await
        .expect("bob connects");

    bob.publish_key_package().await.expect("bob publishes kp");

    let first_group = alice
        .start_dm(bob.identity().public_key(), "alice & bob")
        .await
        .expect("alice starts dm");
    let second_group = alice
        .start_dm(bob.identity().public_key(), "second tap")
        .await
        .expect("alice reuses dm");

    assert_eq!(second_group, first_group);
    assert_eq!(alice.groups().expect("alice groups").len(), 1);
}

#[tokio::test]
async fn start_dm_rejects_self_before_reusing_existing_group() {
    let relay = MockRelay::run().await.expect("mock relay starts");
    let relay_url = relay.url().await;

    let alice = SonarClient::connect_in_memory(Identity::generate(), vec![relay_url.clone()])
        .await
        .expect("alice connects");
    let bob = SonarClient::connect_in_memory(Identity::generate(), vec![relay_url.clone()])
        .await
        .expect("bob connects");

    bob.publish_key_package().await.expect("bob publishes kp");
    alice
        .start_dm(bob.identity().public_key(), "")
        .await
        .expect("alice starts real dm");

    let err = alice
        .start_dm(alice.identity().public_key(), "self")
        .await
        .expect_err("self dm must fail");

    assert!(err
        .to_string()
        .contains("direct message requires another member"));
    assert_eq!(alice.groups().expect("alice groups").len(), 1);
}

#[tokio::test]
async fn start_dm_does_not_reuse_named_group_reduced_to_two_members() {
    let relay = MockRelay::run().await.expect("mock relay starts");
    let relay_url = relay.url().await;

    let alice = SonarClient::connect_in_memory(Identity::generate(), vec![relay_url.clone()])
        .await
        .expect("alice connects");
    let bob = SonarClient::connect_in_memory(Identity::generate(), vec![relay_url.clone()])
        .await
        .expect("bob connects");
    let charlie = SonarClient::connect_in_memory(Identity::generate(), vec![relay_url.clone()])
        .await
        .expect("charlie connects");

    bob.publish_key_package().await.expect("bob publishes kp");
    charlie
        .publish_key_package()
        .await
        .expect("charlie publishes kp");

    let group_chat = alice
        .start_group(
            vec![bob.identity().public_key(), charlie.identity().public_key()],
            "field team",
        )
        .await
        .expect("alice starts group");
    alice
        .remove_group_members(&group_chat, vec![charlie.identity().public_key()])
        .await
        .expect("alice removes charlie");

    let direct_chat = alice
        .start_dm(bob.identity().public_key(), "")
        .await
        .expect("alice starts separate dm");

    assert_ne!(direct_chat, group_chat);
    assert_eq!(alice.groups().expect("alice groups").len(), 2);
}

/// Per-chat delete: deleting a group locally removes ONLY that chat's state on
/// the deleter's device; the peer is unaffected (local-only, no MLS/Nostr
/// publish). Backs the "erase a single chat at a time" feature.
#[tokio::test]
async fn delete_group_removes_a_single_chat_locally() {
    let relay = MockRelay::run().await.expect("mock relay starts");
    let relay_url = relay.url().await;

    let alice = SonarClient::connect_in_memory(Identity::generate(), vec![relay_url.clone()])
        .await
        .expect("alice connects");
    let bob = SonarClient::connect_in_memory(Identity::generate(), vec![relay_url.clone()])
        .await
        .expect("bob connects");
    bob.publish_key_package().await.expect("bob publishes kp");

    let alice_group = alice
        .start_dm(bob.identity().public_key(), "alice & bob")
        .await
        .expect("alice starts dm");
    alice
        .send_text(&alice_group, "Hi Bob!")
        .await
        .expect("alice sends");
    bob.sync().await.expect("bob syncs");

    assert_eq!(alice.groups().unwrap().len(), 1);
    assert_eq!(bob.groups().unwrap().len(), 1);
    let bob_group = bob.groups().unwrap()[0].mls_group_id.clone();

    // Alice deletes the chat from HER device only.
    alice
        .delete_group(&alice_group)
        .await
        .expect("alice deletes the chat");
    assert_eq!(alice.groups().unwrap().len(), 0, "chat is gone for alice");
    assert!(alice.messages(&alice_group).unwrap_or_default().is_empty());

    // Bob is untouched — local-only delete publishes no MLS proposal / Nostr event.
    assert_eq!(bob.groups().unwrap().len(), 1, "bob still has the chat");
    assert_eq!(bob.messages(&bob_group).unwrap().len(), 1);

    // Deleting again is a harmless no-op (idempotent).
    alice
        .delete_group(&alice_group)
        .await
        .expect("idempotent re-delete");
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

    let from_alice = view
        .iter()
        .find(|m| m.content == "hello from alice")
        .unwrap();
    assert_eq!(from_alice.nickname, "alice");
    assert!(!from_alice.mine, "alice's message is not bob's");

    let from_bob = view.iter().find(|m| m.content == "hi from bob").unwrap();
    assert_eq!(from_bob.nickname, "bob");
    assert!(from_bob.mine, "bob's own message detected as mine");

    // A different geohash is an isolated channel.
    let other = bob.fetch_geohash("9q5c", 100).await.expect("other fetch");
    assert!(other.is_empty(), "different geohash sees nothing");
}

/// Presence heartbeats (kind-20001) drive the "N here now" count: each
/// participant who announces is counted once, distinct geohashes are isolated,
/// and re-announcing does not double-count.
#[tokio::test]
async fn geohash_presence_counts_participants() {
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

    // Only alice has announced so far — she counts herself locally.
    alice
        .send_geohash_presence(gh)
        .await
        .expect("alice announces");
    tokio::time::sleep(std::time::Duration::from_millis(400)).await;
    assert_eq!(
        bob.geohash_presence_count(gh).await.unwrap(),
        1,
        "bob sees alice present"
    );

    // Bob announces too; both sides now count two distinct participants.
    bob.send_geohash_presence(gh).await.expect("bob announces");
    tokio::time::sleep(std::time::Duration::from_millis(400)).await;
    assert_eq!(
        alice.geohash_presence_count(gh).await.unwrap(),
        2,
        "alice sees both present"
    );
    assert_eq!(
        bob.geohash_presence_count(gh).await.unwrap(),
        2,
        "bob sees both present"
    );

    // Re-announcing refreshes the heartbeat, it does not double-count.
    alice
        .send_geohash_presence(gh)
        .await
        .expect("alice re-announces");
    tokio::time::sleep(std::time::Duration::from_millis(400)).await;
    assert_eq!(
        bob.geohash_presence_count(gh).await.unwrap(),
        2,
        "still two distinct participants"
    );

    // A different geohash has nobody present.
    assert_eq!(
        bob.geohash_presence_count("9q5c").await.unwrap(),
        0,
        "isolated channel has no presence"
    );
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
    alice
        .send_geohash(gh, "hi from alice", "alice")
        .await
        .unwrap();
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

    let alice_thread = alice
        .fetch_geo_dm(gh, &bob_pk)
        .await
        .expect("alice reads thread");
    assert_eq!(alice_thread.len(), 1);
    assert!(alice_thread[0].mine, "alice's own sent DM is mine");
}

#[tokio::test]
async fn direct_nip17_bitchat_dm_drains_from_account_gift_wraps() {
    let relay = MockRelay::run().await.expect("mock relay starts");
    let url = relay.url().await;
    let alice = SonarClient::connect_in_memory(Identity::generate(), vec![url.clone()])
        .await
        .expect("alice connects");
    let bob = SonarClient::connect_in_memory(Identity::generate(), vec![url.clone()])
        .await
        .expect("bob connects");

    timeout(
        Duration::from_secs(5),
        alice.send_direct_dm(
            &bob.identity().public_key().to_hex(),
            "0102030405060708",
            "",
            "direct-mid-1",
            "plain bitchat fallback",
        ),
    )
    .await
    .expect("direct send completes")
    .expect("alice sends direct nip17 dm");

    timeout(Duration::from_secs(5), bob.sync())
        .await
        .expect("bob sync completes")
        .expect("bob syncs");

    let inbox = bob.drain_direct_dms();
    assert_eq!(inbox.len(), 1, "bob received one direct DM");
    assert_eq!(inbox[0].id, "direct-mid-1");
    assert_eq!(
        inbox[0].sender_pubkey,
        alice.identity().public_key().to_hex()
    );
    assert_eq!(inbox[0].content, "plain bitchat fallback");

    timeout(Duration::from_secs(5), bob.sync())
        .await
        .expect("bob re-sync completes")
        .expect("bob re-syncs");
    assert!(
        bob.drain_direct_dms().is_empty(),
        "processed direct DMs are not duplicated by the gift-wrap lookback"
    );
}
