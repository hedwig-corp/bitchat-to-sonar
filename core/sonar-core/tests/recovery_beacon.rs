//! End-to-end tests for the Marmot recovery beacon auto-rejoin flow.
//!
//! Scenario: a peer loses local MLS state, restores from `nsec`, and publishes
//! a recovery beacon (kind 30447). Surviving peers detect it during sync and
//! re-invite the restored peer into a FRESH MLS group (MDK cannot rejoin the
//! old group), retiring the dead group and folding the new leg into the same
//! conversation. These tests run against an in-process relay via the explicit
//! `sync()` path — the only path in-memory sessions use.

use nostr_relay_builder::MockRelay;
use sonar_core::client::SonarClient;
use sonar_core::identity::Identity;

/// A restored peer's beacon heals a 1:1 DM: the survivor retires the dead group,
/// re-invites over a fresh KeyPackage, both sides exchange text on the NEW
/// group, and DM reuse folds into the healed group (not the retired one).
#[tokio::test]
async fn recovery_beacon_heals_dm_after_local_wipe() {
    let relay = MockRelay::run().await.expect("mock relay starts");
    let relay_url = relay.url().await;

    let alice = SonarClient::connect_in_memory(Identity::generate(), vec![relay_url.clone()])
        .await
        .expect("alice connects");
    let bob = SonarClient::connect_in_memory(Identity::generate(), vec![relay_url.clone()])
        .await
        .expect("bob connects");
    let bob_pubkey = bob.identity().public_key();

    // Healthy DM: alice ⇄ bob exchange messages.
    bob.publish_key_package().await.expect("bob publishes kp");
    let alice_old_group = alice
        .start_dm(bob_pubkey, "alice & bob")
        .await
        .expect("alice starts dm");
    alice
        .send_text(&alice_old_group, "Hi Bob!")
        .await
        .expect("alice sends");
    bob.sync().await.expect("bob syncs");
    let bob_old_group = bob.groups().expect("bob groups")[0].mls_group_id.clone();
    bob.send_text(&bob_old_group, "hey Alice")
        .await
        .expect("bob replies");
    alice.sync().await.expect("alice syncs the reply");

    // Bob loses local state and restores from nsec on a brand-new in-memory
    // engine. His MLS store is empty; the old group's ratchet is gone.
    let bob_nsec = bob.identity().export_nsec();
    drop(bob);
    let bob2 = SonarClient::connect_in_memory(
        Identity::import(&bob_nsec).expect("import nsec"),
        vec![relay_url.clone()],
    )
    .await
    .expect("bob restores");
    assert_eq!(bob2.groups().unwrap().len(), 0, "restored bob has no groups");

    // Restored bob publishes a fresh KeyPackage and a recovery beacon.
    bob2.publish_key_package().await.expect("bob2 publishes kp");
    bob2.publish_recovery_beacon()
        .await
        .expect("bob2 publishes beacon");
    assert!(
        bob2.has_outstanding_recovery_beacon(),
        "beacon outstanding until a group heals"
    );

    // Alice syncs: she detects the beacon, retires the dead DM, and re-invites
    // bob into a fresh group.
    alice.sync().await.expect("alice heals from beacon");
    assert_eq!(
        alice.groups().unwrap().len(),
        2,
        "alice keeps the retired transcript and gains the healed group"
    );

    // DM reuse now folds into the HEALED group, never the retired one.
    let alice_new_group = alice
        .start_dm(bob_pubkey, "alice & bob")
        .await
        .expect("alice reuses healed dm");
    assert_ne!(
        alice_new_group, alice_old_group,
        "healed DM is a fresh group, not the retired one"
    );

    // Alice surfaced exactly one conversation-reset notice for the host.
    let resets = alice.drain_conversation_resets();
    assert_eq!(resets.len(), 1, "one healed conversation notice");
    assert_eq!(resets[0].peer_pubkey_hex, bob_pubkey.to_hex());
    assert_eq!(resets[0].old_group_id_hex, hex::encode(alice_old_group.as_slice()));
    assert_eq!(resets[0].new_group_id_hex, hex::encode(alice_new_group.as_slice()));

    // Restored bob accepts the re-invite and clears his outstanding beacon.
    bob2.sync().await.expect("bob2 accepts the re-invite");
    let bob2_group = bob2.groups().expect("bob2 groups");
    assert_eq!(bob2_group.len(), 1, "bob2 joined the healed group");
    let bob2_group = bob2_group[0].mls_group_id.clone();
    assert_eq!(
        bob2_group, alice_new_group,
        "both sides converge on the same healed MLS group"
    );
    assert!(
        !bob2.has_outstanding_recovery_beacon(),
        "beacon cleared once the conversation healed"
    );

    // Text flows both ways on the NEW group.
    alice
        .send_text(&alice_new_group, "welcome back!")
        .await
        .expect("alice sends on healed group");
    bob2.sync().await.expect("bob2 syncs healed text");
    let bob2_view = bob2.messages(&bob2_group).expect("bob2 messages");
    assert!(
        bob2_view.iter().any(|m| m.content == "welcome back!" && !m.mine),
        "bob2 reads alice's message on the healed group"
    );

    bob2.send_text(&bob2_group, "glad to be back")
        .await
        .expect("bob2 replies on healed group");
    alice.sync().await.expect("alice syncs healed reply");
    let alice_view = alice.messages(&alice_new_group).expect("alice messages");
    assert!(
        alice_view
            .iter()
            .any(|m| m.content == "glad to be back" && !m.mine),
        "alice reads bob2's reply on the healed group"
    );
}

/// A duplicate / re-fetched beacon must heal exactly once: re-syncing after a
/// heal does not create a second group or a second reset notice.
#[tokio::test]
async fn recovery_beacon_replay_is_idempotent() {
    let relay = MockRelay::run().await.expect("mock relay starts");
    let relay_url = relay.url().await;

    let alice = SonarClient::connect_in_memory(Identity::generate(), vec![relay_url.clone()])
        .await
        .expect("alice connects");
    let bob = SonarClient::connect_in_memory(Identity::generate(), vec![relay_url.clone()])
        .await
        .expect("bob connects");
    let bob_pubkey = bob.identity().public_key();

    bob.publish_key_package().await.expect("bob publishes kp");
    let alice_old_group = alice
        .start_dm(bob_pubkey, "alice & bob")
        .await
        .expect("alice starts dm");
    alice
        .send_text(&alice_old_group, "hi")
        .await
        .expect("alice sends");
    bob.sync().await.expect("bob syncs");

    let bob_nsec = bob.identity().export_nsec();
    drop(bob);
    let bob2 = SonarClient::connect_in_memory(
        Identity::import(&bob_nsec).expect("import nsec"),
        vec![relay_url.clone()],
    )
    .await
    .expect("bob restores");
    bob2.publish_key_package().await.expect("bob2 publishes kp");
    bob2.publish_recovery_beacon()
        .await
        .expect("bob2 publishes beacon");

    // First sync heals; capture the resulting group count.
    alice.sync().await.expect("alice heals");
    let after_first = alice.groups().unwrap().len();
    assert_eq!(after_first, 2, "one retired + one healed group");
    let first_resets = alice.drain_conversation_resets();
    assert_eq!(first_resets.len(), 1, "exactly one reset on first heal");

    // Re-syncing re-fetches the same (addressable) beacon. The replay guard must
    // ignore it: no third group, no new reset notice.
    alice.sync().await.expect("alice re-syncs");
    alice.sync().await.expect("alice re-syncs again");
    assert_eq!(
        alice.groups().unwrap().len(),
        after_first,
        "replayed beacon does not create another group"
    );
    assert!(
        alice.drain_conversation_resets().is_empty(),
        "replayed beacon produces no new reset notice"
    );
}
