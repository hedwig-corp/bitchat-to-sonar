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
