//! Group invite lifecycle without relay I/O.

use nostr::RelayUrl;
use sonar_core::identity::Identity;
use sonar_core::marmot::{Incoming, MarmotEngine};

#[tokio::test]
async fn multi_member_welcomes_wait_for_accept_or_decline() {
    let relay = RelayUrl::parse("wss://relay.example.com").expect("relay url");
    let relays = vec![relay];

    let alice = MarmotEngine::in_memory(Identity::generate());
    let bob = MarmotEngine::in_memory(Identity::generate());
    let charlie = MarmotEngine::in_memory(Identity::generate());

    let bob_kp = bob.key_package_event(relays.clone()).expect("bob kp");
    let charlie_kp = charlie
        .key_package_event(relays.clone())
        .expect("charlie kp");

    let creation = alice
        .create_group("field team", vec![bob_kp, charlie_kp], relays)
        .expect("alice creates group");
    alice
        .merge_pending_commit(&creation.group.mls_group_id)
        .expect("creator merge after welcome delivery");
    assert_eq!(alice.groups().expect("alice groups").len(), 1);

    let (bob_pubkey, bob_welcome) = creation
        .welcomes
        .iter()
        .find(|(pubkey, _)| *pubkey == bob.identity().public_key())
        .cloned()
        .expect("bob welcome");
    let bob_wrapped = alice
        .gift_wrap_welcome(&bob_pubkey, bob_welcome)
        .await
        .expect("wrap bob welcome");
    match bob
        .process_incoming(&bob_wrapped)
        .await
        .expect("bob processes welcome")
    {
        Incoming::GroupInvitePending(group_id) => assert_eq!(group_id, creation.group.mls_group_id),
        other => panic!("expected pending group invite, got {other:?}"),
    }
    assert_eq!(bob.groups().expect("bob active groups").len(), 0);
    let bob_invites = bob.pending_group_invites().expect("bob invites");
    assert_eq!(bob_invites.len(), 1);
    assert_eq!(bob_invites[0].group_name, "field team");
    assert_eq!(bob_invites[0].member_count, 3);

    let accepted_group = bob
        .accept_group_invite(&bob_invites[0].id)
        .expect("bob accepts invite");
    assert_eq!(accepted_group, creation.group.mls_group_id);
    assert_eq!(bob.groups().expect("bob active groups").len(), 1);
    assert!(bob.pending_group_invites().expect("bob invites").is_empty());

    let (charlie_pubkey, charlie_welcome) = creation
        .welcomes
        .iter()
        .find(|(pubkey, _)| *pubkey == charlie.identity().public_key())
        .cloned()
        .expect("charlie welcome");
    let charlie_wrapped = alice
        .gift_wrap_welcome(&charlie_pubkey, charlie_welcome)
        .await
        .expect("wrap charlie welcome");
    match charlie
        .process_incoming(&charlie_wrapped)
        .await
        .expect("charlie processes welcome")
    {
        Incoming::GroupInvitePending(group_id) => assert_eq!(group_id, creation.group.mls_group_id),
        other => panic!("expected pending group invite, got {other:?}"),
    }
    let charlie_invites = charlie
        .pending_group_invites()
        .expect("charlie pending invites");
    assert_eq!(charlie_invites.len(), 1);
    charlie
        .decline_group_invite(&charlie_invites[0].id)
        .expect("charlie declines");
    assert_eq!(charlie.groups().expect("charlie active groups").len(), 0);
    assert!(charlie
        .pending_group_invites()
        .expect("charlie invites after decline")
        .is_empty());
}

#[tokio::test]
async fn unpublished_group_creation_can_be_discarded() {
    let relay = RelayUrl::parse("wss://relay.example.com").expect("relay url");
    let relays = vec![relay];

    let alice = MarmotEngine::in_memory(Identity::generate());
    let bob = MarmotEngine::in_memory(Identity::generate());
    let charlie = MarmotEngine::in_memory(Identity::generate());

    let bob_kp = bob.key_package_event(relays.clone()).expect("bob kp");
    let charlie_kp = charlie
        .key_package_event(relays.clone())
        .expect("charlie kp");

    let creation = alice
        .create_group("field team", vec![bob_kp, charlie_kp], relays)
        .expect("alice creates group");
    let group_id = creation.group.mls_group_id;
    assert_eq!(
        alice.groups().expect("alice groups").len(),
        1,
        "MDK exposes the staged group before the commit is merged"
    );

    alice
        .clear_pending_commit(&group_id)
        .expect("clear pending creation commit");
    alice.delete_group(&group_id).expect("discard staged group");

    assert!(
        alice
            .groups()
            .expect("alice groups after discard")
            .is_empty(),
        "failed welcome delivery must not leave a non-retryable local group"
    );
}

#[tokio::test]
async fn staged_add_member_commit_can_be_rolled_back() {
    let relay = RelayUrl::parse("wss://relay.example.com").expect("relay url");
    let relays = vec![relay];

    let alice = MarmotEngine::in_memory(Identity::generate());
    let bob = MarmotEngine::in_memory(Identity::generate());
    let charlie = MarmotEngine::in_memory(Identity::generate());
    let charlie_pubkey = charlie.identity().public_key();

    let bob_kp = bob.key_package_event(relays.clone()).expect("bob kp");
    let creation = alice
        .create_group("alice and bob", vec![bob_kp], relays.clone())
        .expect("alice creates group");
    let group_id = creation.group.mls_group_id;
    alice
        .merge_pending_commit(&group_id)
        .expect("merge initial group");

    let charlie_kp = charlie.key_package_event(relays).expect("charlie kp");
    let update = alice
        .add_members(&group_id, vec![charlie_kp])
        .expect("stage add charlie");
    assert_eq!(update.welcomes.len(), 1);
    assert!(
        !alice
            .members(&group_id)
            .expect("members before merge")
            .contains(&charlie_pubkey),
        "staged add-member state stays pending until commit merge"
    );

    alice
        .clear_pending_commit(&group_id)
        .expect("clear staged add-member commit");

    assert!(
        !alice
            .members(&group_id)
            .expect("members after rollback")
            .contains(&charlie_pubkey),
        "failed welcome delivery must not leave the undelivered invitee as a local member"
    );
}

#[tokio::test]
async fn partially_published_group_creation_can_still_be_merged() {
    let relay = RelayUrl::parse("wss://relay.example.com").expect("relay url");
    let relays = vec![relay];

    let alice = MarmotEngine::in_memory(Identity::generate());
    let bob = MarmotEngine::in_memory(Identity::generate());
    let charlie = MarmotEngine::in_memory(Identity::generate());

    let bob_kp = bob.key_package_event(relays.clone()).expect("bob kp");
    let charlie_kp = charlie
        .key_package_event(relays.clone())
        .expect("charlie kp");

    let creation = alice
        .create_group("field team", vec![bob_kp, charlie_kp], relays)
        .expect("alice creates group");
    let group_id = creation.group.mls_group_id;

    assert_eq!(
        creation.welcomes.len(),
        2,
        "test needs multiple welcomes so one can be considered already published"
    );

    alice
        .merge_pending_commit(&group_id)
        .expect("partial welcome publish keeps creator pending commit mergeable");

    let members = alice.members(&group_id).expect("members after merge");
    assert!(members.contains(&bob.identity().public_key()));
    assert!(members.contains(&charlie.identity().public_key()));
}

#[tokio::test]
async fn published_add_member_commit_remains_mergeable_after_welcome_failure() {
    let relay = RelayUrl::parse("wss://relay.example.com").expect("relay url");
    let relays = vec![relay];

    let alice = MarmotEngine::in_memory(Identity::generate());
    let bob = MarmotEngine::in_memory(Identity::generate());
    let charlie = MarmotEngine::in_memory(Identity::generate());
    let charlie_pubkey = charlie.identity().public_key();

    let bob_kp = bob.key_package_event(relays.clone()).expect("bob kp");
    let creation = alice
        .create_group("alice and bob", vec![bob_kp], relays.clone())
        .expect("alice creates group");
    let group_id = creation.group.mls_group_id;
    alice
        .merge_pending_commit(&group_id)
        .expect("merge initial group");

    let charlie_kp = charlie.key_package_event(relays).expect("charlie kp");
    let update = alice
        .add_members(&group_id, vec![charlie_kp])
        .expect("stage add charlie");
    assert_eq!(update.welcomes.len(), 1);
    assert!(
        !alice
            .members(&group_id)
            .expect("members before merge")
            .contains(&charlie_pubkey),
        "staged add-member state stays pending until commit merge"
    );

    alice
        .merge_pending_commit(&group_id)
        .expect("published add-member commit remains mergeable after welcome retry");

    assert!(
        alice
            .members(&group_id)
            .expect("members after merge")
            .contains(&charlie_pubkey),
        "kept pending commit can converge after welcome delivery is recovered"
    );
}
