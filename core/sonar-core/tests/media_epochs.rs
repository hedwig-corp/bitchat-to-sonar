//! Media stays decryptable after the group's epoch moves on.
//!
//! MDK 0.8 decrypted each attachment with the exporter secret of the epoch its
//! message was sent in. A member add, a leave or a key rotation moves the
//! epoch; the attachment's key must not move with it.

use nostr::RelayUrl;
use sonar_core::identity::Identity;
use sonar_core::marmot::MarmotEngine;
use sonar_core::GroupId;

fn epoch_of(engine: &MarmotEngine, group: &GroupId) -> u64 {
    engine
        .groups()
        .expect("groups")
        .into_iter()
        .find(|g| &g.id == group)
        .expect("group is active")
        .epoch
        .0
}

#[tokio::test]
async fn media_sent_before_a_member_add_still_decrypts_after_it() {
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
    let (_, welcome) = creation.welcomes[0].clone();
    bob.process_incoming(&welcome)
        .await
        .expect("bob joins the DM");

    let url = "https://blossom.example/photo";
    let upload = alice
        .encrypt_media(&group, b"photo before the add", "image/png", "photo.png")
        .expect("encrypt");
    let media_event = alice
        .create_media_event(&group, &upload, url, "")
        .await
        .expect("media event");
    bob.process_incoming(&media_event)
        .await
        .expect("bob receives the photo");
    let epoch_at_send = epoch_of(&bob, &group);

    let charlie_kp = charlie.key_package_event(relays).await.expect("charlie kp");
    let update = alice
        .add_members(&group, vec![charlie_kp])
        .await
        .expect("alice adds charlie");
    alice
        .merge_pending_commit(&group)
        .await
        .expect("merge the add");
    bob.process_incoming(&update.evolution_event)
        .await
        .expect("bob ingests the add");
    tokio::time::sleep(std::time::Duration::from_millis(1_100)).await;
    bob.advance_group_convergence(&group)
        .await
        .expect("bob applies the buffered commit");
    assert!(
        epoch_of(&bob, &group) > epoch_at_send,
        "the add must move bob's epoch for this test to mean anything"
    );
    assert!(epoch_of(&alice, &group) > epoch_at_send);

    let plain = bob
        .decrypt_media_by_url(&group, url, &upload.encrypted_data)
        .expect("receiver opens a photo sent in an earlier epoch");
    assert_eq!(plain, b"photo before the add");
    let plain = alice
        .decrypt_media_by_url(&group, url, &upload.encrypted_data)
        .expect("sender opens its own photo from an earlier epoch");
    assert_eq!(plain, b"photo before the add");
}

/// Receivers derive an attachment's key from the epoch of the message that
/// carries its imeta. Media sealed in epoch N and sent after the group moved
/// to N+1 would be unreadable for everyone, so the send is pinned to N and
/// refused (MDK `expected_epoch`); the host re-encrypts for the new epoch.
#[tokio::test]
async fn media_sealed_before_an_epoch_change_is_refused_not_sent_unreadable() {
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

    let upload = alice
        .encrypt_media(&group, b"sealed in epoch N", "image/png", "n.png")
        .expect("encrypt");
    assert_eq!(upload.source_epoch, Some(epoch_of(&alice, &group)));

    let charlie_kp = charlie.key_package_event(relays).await.expect("charlie kp");
    alice
        .add_members(&group, vec![charlie_kp])
        .await
        .expect("alice adds charlie");
    alice
        .merge_pending_commit(&group)
        .await
        .expect("merge the add");
    assert!(epoch_of(&alice, &group) > upload.source_epoch.unwrap());

    let sent = alice
        .create_media_event(&group, &upload, "https://blossom.example/n", "")
        .await;
    assert!(
        matches!(sent, Err(sonar_core::Error::MediaEpochMoved)),
        "a stale-epoch media send must be refused, got {sent:?}"
    );

    let fresh = alice
        .encrypt_media(&group, b"sealed in epoch N+1", "image/png", "n1.png")
        .expect("re-encrypt for the current epoch");
    alice
        .create_media_event(&group, &fresh, "https://blossom.example/n1", "")
        .await
        .expect("media sealed in the current epoch sends");
}
