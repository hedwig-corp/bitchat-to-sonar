//! A member's Leave (MIP-03 SelfRemove) must reach the other members even
//! when MDK queues it behind a commit that is still converging.

use nostr::RelayUrl;
use sonar_core::identity::Identity;
use sonar_core::marmot::MarmotEngine;

/// A Leave sent while a commit is still converging is queued by MDK. The
/// engine must regenerate its SelfRemove proposal once the group settles, or
/// the leaver drops the chat while staying in everyone else's roster.
#[tokio::test]
async fn a_leave_queued_behind_a_converging_commit_still_produces_its_proposal() {
    let relays = vec![RelayUrl::parse("wss://relay.example.com").expect("relay url")];
    let alice = MarmotEngine::in_memory(Identity::generate());
    let bob = MarmotEngine::in_memory(Identity::generate());
    let charlie = MarmotEngine::in_memory(Identity::generate());

    let bob_kp = bob.key_package_event(relays.clone()).await.expect("bob kp");
    let creation = alice
        .create_group("", vec![bob_kp], relays.clone())
        .await
        .expect("alice creates the chat");
    let group = creation.group.id.clone();
    alice
        .merge_pending_commit(&group)
        .await
        .expect("merge creation");
    bob.process_incoming(&creation.welcomes[0].1)
        .await
        .expect("bob joins");

    let charlie_kp = charlie.key_package_event(relays).await.expect("charlie kp");
    let update = alice
        .add_members(&group, vec![charlie_kp])
        .await
        .expect("alice adds charlie");
    alice
        .merge_pending_commit(&group)
        .await
        .expect("merge the add");
    // Bob holds the commit, buffered until the quiescence window closes.
    bob.process_incoming(&update.evolution_event)
        .await
        .expect("bob ingests the add");

    match bob.leave_group(&group).await {
        Err(sonar_core::Error::LeaveQueued) => {}
        Ok(_) => panic!("a leave behind a buffered commit must queue"),
        Err(err) => panic!("unexpected leave error: {err}"),
    }
    let proposal = bob.regenerate_queued_leave(&group).await.expect("converge");
    assert!(
        proposal.is_some(),
        "the queued SelfRemove must regenerate once the commit settles"
    );
}
