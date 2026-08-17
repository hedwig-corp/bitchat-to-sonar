//! End-to-end test: two independent Sonar instances exchange Marmot (MLS over
//! Nostr) messages through an in-process relay. No network, deterministic.
//!
//! This is the M1 acceptance test: KeyPackage publication → group creation →
//! gift-wrapped welcome → bidirectional encrypted messages.

use nostr::prelude::*;
use nostr_relay_builder::MockRelay;
use nostr_sdk::Client as NostrClient;
use sonar_core::client::SonarClient;
use sonar_core::identity::Identity;
use sonar_core::marmot::KEY_PACKAGE_KIND;
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
async fn kind7_reaction_tallies_and_is_not_a_transcript_row() {
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
        .send_text(&alice_group, "react to me")
        .await
        .expect("alice sends");

    bob.sync().await.expect("bob syncs");
    let bob_group = bob.groups().expect("bob groups")[0].mls_group_id.clone();
    let parent = bob
        .messages(&bob_group)
        .expect("bob messages")
        .into_iter()
        .find(|m| m.content == "react to me")
        .expect("parent");
    bob.send_reaction(&bob_group, &parent.id, &parent.sender, "👍")
        .await
        .expect("bob reacts");
    alice.sync().await.expect("alice syncs reaction");

    let alice_view = alice.messages(&alice_group).expect("alice messages");
    assert_eq!(
        alice_view.len(),
        1,
        "kind-7 must not appear as a chat body row"
    );
    assert_eq!(alice_view[0].content, "react to me");
    assert_eq!(alice_view[0].reactions.len(), 1);
    assert_eq!(alice_view[0].reactions[0].emoji, "👍");
    assert_eq!(alice_view[0].reactions[0].count, 1);
    assert!(!alice_view[0].reactions[0].mine);
    let list_page = alice
        .messages_page(&alice_group, 10, 0)
        .expect("chat-list page");
    assert_eq!(list_page.len(), 1);
    assert!(
        list_page[0].reactions.is_empty(),
        "messages_page must not hydrate tallies (chat-list path)"
    );

    let page = alice
        .messages_cursor_page(&alice_group, None, None, 10)
        .expect("cursor page");
    assert_eq!(page.len(), 1);
    assert_eq!(page[0].reactions.len(), 1);

    bob.send_reaction(&bob_group, &parent.id, &parent.sender, "🔥")
        .await
        .expect("bob second emoji");
    alice.sync().await.expect("alice syncs second emoji");
    let multi = alice.messages(&alice_group).expect("alice messages");
    assert_eq!(multi.len(), 1);
    assert_eq!(multi[0].reactions.len(), 2, "multi-emoji per sender");
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
async fn invite_approval_uses_the_requesters_exact_key_package() {
    let relay = MockRelay::run().await.expect("mock relay starts");
    let relay_url = relay.url().await;

    let admin = SonarClient::connect_in_memory(Identity::generate(), vec![relay_url.clone()])
        .await
        .expect("admin connects");
    let existing_member =
        SonarClient::connect_in_memory(Identity::generate(), vec![relay_url.clone()])
            .await
            .expect("existing member connects");
    let requester = SonarClient::connect_in_memory(Identity::generate(), vec![relay_url.clone()])
        .await
        .expect("requester connects");

    existing_member
        .publish_key_package()
        .await
        .expect("existing member publishes key package");
    let group_id = admin
        .start_group(
            vec![existing_member.identity().public_key()],
            "invite approval",
        )
        .await
        .expect("admin creates group");
    let token = admin
        .create_invite_link(&group_id, "invite approval")
        .expect("admin creates invite link");

    requester
        .request_join_via_link(&token)
        .await
        .expect("requester publishes join request");
    admin.sync().await.expect("admin receives join request");
    let pending = admin.pending_join_requests(&group_id);
    assert_eq!(pending.len(), 1);
    assert!(
        pending[0].key_package_event_id.is_some(),
        "join request identifies the fresh KeyPackage it published"
    );
    assert!(
        pending[0].key_package_d_tag.is_some(),
        "join request identifies the addressable slot that KeyPackage lives in"
    );

    // Publish a NEWER kind-30443 under a DIFFERENT addressable slot, standing
    // in for the requester's other linked device. It must carry its own `d`
    // tag: without one the relay rejects the event outright and the test
    // silently stops testing anything (that is how this regression test first
    // shipped green against the very path it was meant to pin).
    let bad_key_package =
        EventBuilder::new(Kind::Custom(KEY_PACKAGE_KIND), "not a Marmot KeyPackage")
            .tags([Tag::identifier("other-device-slot")])
            .custom_created_at(Timestamp::from_secs(Timestamp::now().as_secs() + 10))
            .build(requester.identity().public_key())
            .sign_with_keys(requester.identity().keys())
            .expect("sign invalid newer key package event");
    let raw_publisher = NostrClient::new(requester.identity().keys().clone());
    raw_publisher
        .add_relay(relay_url)
        .await
        .expect("add mock relay");
    raw_publisher.connect().await;
    let inject = raw_publisher
        .send_event(&bad_key_package)
        .await
        .expect("publish invalid newer key package event");
    assert!(
        !inject.success.is_empty(),
        "relay must ACCEPT the poison event, else this test proves nothing: {:?}",
        inject.failed
    );

    // The premise, asserted rather than assumed: latest-by-author now resolves
    // to the poison event, so an approval that still used it would fail.
    assert_eq!(
        admin
            .fetch_key_package(requester.identity().public_key())
            .await
            .expect("latest-by-author lookup")
            .id,
        bad_key_package.id,
        "poison event must win latest-by-author for this test to have teeth"
    );

    timeout(
        Duration::from_secs(5),
        admin.approve_join_request(&group_id, &requester.identity().public_key()),
    )
    .await
    .expect("approval does not stall")
    .expect("approval uses the requested key package");
    assert!(admin.pending_join_requests(&group_id).is_empty());
}

/// Kind 30443 is addressable and every install republishes into ONE persisted
/// slot, so pinning approval to the join request's exact event id breaks the
/// moment the requester reconnects — the relay drops the replaced event and the
/// request can never be approved. Approval keys on the slot, which rolls
/// forward.
#[tokio::test]
async fn invite_approval_survives_the_requester_republishing_its_key_package() {
    let relay = MockRelay::run().await.expect("mock relay starts");
    let relay_url = relay.url().await;

    let admin = SonarClient::connect_in_memory(Identity::generate(), vec![relay_url.clone()])
        .await
        .expect("admin connects");
    let existing_member =
        SonarClient::connect_in_memory(Identity::generate(), vec![relay_url.clone()])
            .await
            .expect("existing member connects");
    let requester = SonarClient::connect_in_memory(Identity::generate(), vec![relay_url.clone()])
        .await
        .expect("requester connects");

    existing_member
        .publish_key_package()
        .await
        .expect("existing member publishes key package");
    let group_id = admin
        .start_group(
            vec![existing_member.identity().public_key()],
            "invite approval",
        )
        .await
        .expect("admin creates group");
    let token = admin
        .create_invite_link(&group_id, "invite approval")
        .expect("admin creates invite link");

    requester
        .request_join_via_link(&token)
        .await
        .expect("requester publishes join request");
    admin.sync().await.expect("admin receives join request");
    let advertised = admin.pending_join_requests(&group_id)[0]
        .key_package_event_id
        .expect("join request advertises a KeyPackage event");

    // The requester's next relay connect republishes into the same slot. That
    // REPLACES the advertised event; relays drop the one the request names.
    requester
        .publish_key_package()
        .await
        .expect("requester republishes its key package");
    let current = admin
        .fetch_key_package(requester.identity().public_key())
        .await
        .expect("a current key package still exists");
    assert_ne!(
        current.id, advertised,
        "republish must have replaced the advertised event for this test to have teeth"
    );

    timeout(
        Duration::from_secs(5),
        admin.approve_join_request(&group_id, &requester.identity().public_key()),
    )
    .await
    .expect("approval does not stall")
    .expect("approval rolls forward to the current package in the requester's slot");
    assert!(admin.pending_join_requests(&group_id).is_empty());
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

/// Leave must always clear local state without awaiting leave-proposal publish —
/// hosts serialize leave on a work queue, so hanging on relays made Delete/Leave
/// appear stuck in the chat list.
#[tokio::test]
async fn leave_group_removes_local_chat() {
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

    let group = alice
        .start_group(
            vec![bob.identity().public_key(), charlie.identity().public_key()],
            "field team",
        )
        .await
        .expect("alice starts group");

    // Bob must join before leave is meaningful for a multi-member group.
    bob.sync().await.expect("bob syncs welcome");
    let bob_invites = bob.pending_group_invites().expect("bob invites");
    if let Some(invite) = bob_invites.first() {
        bob.accept_group_invite(&invite.id)
            .await
            .expect("bob accepts");
    }

    charlie.sync().await.expect("charlie syncs welcome");
    let charlie_invites = charlie.pending_group_invites().expect("charlie invites");
    if let Some(invite) = charlie_invites.first() {
        charlie
            .accept_group_invite(&invite.id)
            .await
            .expect("charlie accepts");
    }

    let leave = timeout(Duration::from_secs(5), charlie.leave_group(&group));
    leave
        .await
        .expect("leave must not hang on relay")
        .expect("charlie leaves");
    assert_eq!(
        charlie.groups().expect("charlie groups").len(),
        0,
        "leave clears local chat"
    );
    assert!(
        !alice.groups().expect("alice groups").is_empty(),
        "alice still has the group"
    );
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
            None,
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
    assert!(!inbox[0].event_id.is_empty());
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
    assert_eq!(
        bob.drain_direct_dms().len(),
        1,
        "unacknowledged direct DMs remain retryable until the host persists them"
    );

    bob.acknowledge_direct_dms(&[inbox[0].event_id.clone()])
        .expect("ack persisted direct dm");
    timeout(Duration::from_secs(5), bob.sync())
        .await
        .expect("bob post-ack sync completes")
        .expect("bob post-ack syncs");
    assert!(
        bob.drain_direct_dms().is_empty(),
        "acknowledged direct DMs are not duplicated by the gift-wrap lookback"
    );
}

/// Republishing a KeyPackage must REPLACE the addressable event at the relay,
/// not add a second one, and a peer must resolve to the newest.
///
/// This is the relay-visible half of the stable-slot change. The unit tests in
/// `persistence.rs` only prove the `d` tag is reused; whether a relay actually
/// treats that as a NIP-33 replacement, and whether `fetch_key_package` picks
/// the newest of what comes back, can only be shown against a real relay. This
/// runs in CI, unlike the live-relay example harness.
#[tokio::test]
async fn republished_key_package_replaces_the_slot_and_newest_wins() {
    let relay = MockRelay::run().await.expect("mock relay starts");
    let relay_url = relay.url().await;

    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("marmot.sqlite");
    let alice_identity = Identity::generate();
    let alice_pubkey = alice_identity.public_key();

    let alice = SonarClient::connect(
        alice_identity,
        vec![relay_url.clone()],
        &db_path,
        [0x24; 32],
    )
    .await
    .expect("alice connects");

    alice.publish_key_package().await.expect("publish 1");
    // created_at has 1s resolution, so separate the two publishes or "newest"
    // is ambiguous and the assertion below would be luck rather than logic.
    tokio::time::sleep(Duration::from_secs(2)).await;
    alice.publish_key_package().await.expect("publish 2");

    let bob = SonarClient::connect_in_memory(Identity::generate(), vec![relay_url])
        .await
        .expect("bob connects");

    let all = timeout(Duration::from_secs(10), bob.fetch_all_key_packages(alice_pubkey))
        .await
        .expect("fetch did not time out")
        .expect("fetch all key packages");
    assert_eq!(
        all.len(),
        1,
        "two publishes must occupy ONE addressable slot, got {} events",
        all.len()
    );

    let picked = timeout(Duration::from_secs(10), bob.fetch_key_package(alice_pubkey))
        .await
        .expect("fetch did not time out")
        .expect("fetch key package");
    assert_eq!(
        picked.id, all[0].id,
        "fetch_key_package must resolve to the surviving newest event"
    );
}

/// A one-shot in-memory client with a DURABLE identity must not mint a new slot
/// on every run.
///
/// The headless status probe (`sonar-status`) imports a fixed nsec, connects
/// in-memory, publishes a KeyPackage and exits, once per poll. With a random
/// slot per process that accumulated one permanent addressable event per poll
/// forever under a stable npub, and the probe then fetched all of them inside
/// its own degraded threshold. Two independent clients sharing one identity
/// stand in for two polls here.
#[tokio::test]
async fn in_memory_clients_sharing_an_identity_reuse_one_slot() {
    let relay = MockRelay::run().await.expect("mock relay starts");
    let relay_url = relay.url().await;

    let identity = Identity::generate();
    let pubkey = identity.public_key();

    for _ in 0..2 {
        let probe = SonarClient::connect_in_memory(identity.clone(), vec![relay_url.clone()])
            .await
            .expect("probe connects");
        probe.publish_key_package().await.expect("probe publishes");
        tokio::time::sleep(Duration::from_secs(2)).await;
    }

    let observer = SonarClient::connect_in_memory(Identity::generate(), vec![relay_url])
        .await
        .expect("observer connects");
    let all = timeout(Duration::from_secs(10), observer.fetch_all_key_packages(pubkey))
        .await
        .expect("fetch did not time out")
        .expect("fetch all key packages");

    assert_eq!(
        all.len(),
        1,
        "repeat one-shot probes must reuse one slot, got {} events",
        all.len()
    );
}

/// With a candidate on EACH relay, `fetch_key_package` must return the newest.
///
/// This needs two relays. `fetch_key_package` sends `limit(1)`, so a single
/// relay returns only its own newest and the selection is done by the relay, not
/// by us: against one relay `max_by_key` is a choice over one element and a
/// regression to `min_by_key` still passes (verified). The real multi-candidate
/// case is the cross-relay merge, where each relay contributes its newest and
/// the client picks between them.
///
/// The older candidate is published as a raw event under a different `d`, not
/// through the engine, so the stable-slot logic stays out of the way and it
/// behaves like a pre-fix orphan that only one relay retained.
#[tokio::test]
async fn fetch_key_package_picks_the_newest_across_relays() {
    use nostr::{EventBuilder, Kind, Tag, Timestamp};

    let relay_new = MockRelay::run().await.expect("relay A starts");
    let relay_old = MockRelay::run().await.expect("relay B starts");
    let url_new = relay_new.url().await;
    let url_old = relay_old.url().await;

    let dir = tempfile::tempdir().expect("tempdir");
    let alice_identity = Identity::generate();
    let alice_pubkey = alice_identity.public_key();
    let alice_keys = alice_identity.keys().clone();

    // Current slot lives on relay A only.
    let alice = SonarClient::connect(
        alice_identity,
        vec![url_new.clone()],
        &dir.path().join("marmot.sqlite"),
        [0x51; 32],
    )
    .await
    .expect("alice connects");
    alice.publish_key_package().await.expect("publish current");

    // An orphan from a hypothetical older install, on relay B only, with an
    // explicitly OLDER created_at so "newest" is unambiguous.
    let stale = EventBuilder::new(Kind::Custom(30443), "stale-key-package")
        .tags([Tag::identifier("f".repeat(64))])
        .custom_created_at(Timestamp::now() - 3600u64)
        .build(alice_pubkey)
        .sign_with_keys(&alice_keys)
        .expect("sign stale key package");
    let stale_id = stale.id;

    let publisher = nostr_sdk::Client::default();
    publisher.add_relay(url_old.clone()).await.expect("add relay B");
    publisher.connect().await;
    publisher.send_event(&stale).await.expect("publish stale");

    // Bob sees both relays, so the pool merges one candidate from each.
    let bob = SonarClient::connect_in_memory(Identity::generate(), vec![url_new, url_old])
        .await
        .expect("bob connects");

    let all = timeout(Duration::from_secs(10), bob.fetch_all_key_packages(alice_pubkey))
        .await
        .expect("fetch did not time out")
        .expect("fetch all");
    assert_eq!(all.len(), 2, "expected one candidate from each relay");

    let picked = timeout(Duration::from_secs(10), bob.fetch_key_package(alice_pubkey))
        .await
        .expect("fetch did not time out")
        .expect("fetch one");
    assert_ne!(
        picked.id, stale_id,
        "must not resolve to the older orphan from the other relay"
    );
    let newest = all.iter().max_by_key(|e| e.created_at).expect("nonempty");
    assert_eq!(picked.id, newest.id, "must resolve to the newest candidate");
}

/// The empty-fetch wipe guard must be WIRED, not just decided (R-032).
///
/// Unit tests pin the pure `resolve_profile_publish`; this pins the call site:
/// `publish_profile` must persist the own-profile sidecar after publishing,
/// load it on a later publish whose relay fetch comes back empty, use it as
/// the merge floor, and ship the merged event. A refactor that drops the
/// sidecar argument at the call site keeps every unit test green — this one
/// goes red.
#[tokio::test]
async fn profile_republish_against_empty_relay_keeps_sidecar_fields() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("marmot.sqlite");
    let identity = Identity::generate();
    let pubkey = identity.public_key();

    // Session 1: publish a rich profile through relay A; the sidecar records it.
    let relay_a = MockRelay::run().await.expect("mock relay A starts");
    {
        let client = SonarClient::connect(
            identity.clone(),
            vec![relay_a.url().await],
            &db_path,
            [0x24; 32],
        )
        .await
        .expect("session 1 connects");
        client
            .publish_profile(
                "vincenzo",
                Some("bitcoin dev"),
                Some("https://example.com/pic.png"),
            )
            .await
            .expect("rich profile publishes");
    }
    let sidecar = db_path.with_file_name("marmot.sqlite.sonar-profile.json");
    assert!(
        sidecar.exists(),
        "publish must write the own-profile sidecar"
    );

    // Session 2: same account, but the only reachable relay is EMPTY — the
    // flaky-network shape of the wipe. A rename must carry the sidecar
    // fields, not strip the profile back to name-only.
    let relay_b = MockRelay::run().await.expect("mock relay B starts");
    let url_b = relay_b.url().await;
    let client = SonarClient::connect(identity, vec![url_b.clone()], &db_path, [0x24; 32])
        .await
        .expect("session 2 connects");
    client
        .publish_profile("new-name", None, None)
        .await
        .expect("republish against empty relay");

    let viewer = SonarClient::connect_in_memory(Identity::generate(), vec![url_b])
        .await
        .expect("viewer connects");
    let profile = timeout(Duration::from_secs(10), viewer.fetch_profile(pubkey))
        .await
        .expect("fetch did not time out")
        .expect("fetch ok")
        .expect("profile present on relay B");
    assert_eq!(profile.name.as_deref(), Some("new-name"));
    assert_eq!(
        profile.about.as_deref(),
        Some("bitcoin dev"),
        "sidecar floor must survive an empty-fetch republish"
    );
    assert_eq!(
        profile.picture.as_deref(),
        Some("https://example.com/pic.png"),
        "picture must survive an empty-fetch republish"
    );
}
