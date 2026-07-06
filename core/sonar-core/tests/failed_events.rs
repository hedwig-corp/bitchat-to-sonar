//! Regression test for the sync-watermark poisoning bug: a kind-445 event that
//! MDK cannot process gets a durable Failed record, and MDK short-circuits all
//! re-deliveries of it. The engine must surface those re-deliveries as terminal
//! [`Incoming::Failed`] — NOT as retryable — otherwise the relay sync layer
//! rewinds its global watermark behind the event forever and every sync
//! re-downloads weeks of history (observed pinning a real account 18 days in
//! the past, with every app foreground re-fetching 32 groups of backlog).

use nostr::{EventBuilder, Keys, Kind, Tag};
use nostr::RelayUrl;
use sonar_core::identity::Identity;
use sonar_core::marmot::{Incoming, MarmotEngine};

fn relays() -> Vec<RelayUrl> {
    vec![RelayUrl::parse("wss://relay.example").unwrap()]
}

#[tokio::test]
async fn undecryptable_group_message_is_terminal_not_retryable() {
    // Alice forms a real MLS group so the garbage event's `h` tag resolves to
    // a known group (the decrypt itself is what fails, as with a message
    // encrypted for an MLS state we do not have).
    let alice = MarmotEngine::in_memory(Identity::generate());
    let bob = MarmotEngine::in_memory(Identity::generate());
    let bob_kp = bob.key_package_event(relays()).expect("bob key package");
    let creation = alice
        .create_group("alice & bob", vec![bob_kp], relays())
        .expect("create group");
    alice
        .merge_pending_commit(&creation.group.mls_group_id)
        .expect("merge pending commit");

    let group_hex = hex::encode(creation.group.nostr_group_id);
    let garbage = EventBuilder::new(Kind::MlsGroupMessage, "bm90LWFuLW1scy1jaXBoZXJ0ZXh0")
        .tags([Tag::parse(["h", &group_hex]).expect("h tag")])
        .sign_with_keys(&Keys::generate())
        .expect("sign garbage 445");

    // First delivery: MDK fails to process and records a durable Failed state.
    // Depending on where processing fails this surfaces as an error or already
    // as the terminal result; both are fine — what matters is the re-delivery.
    let first = alice.process_incoming(&garbage).await;
    assert!(
        !matches!(first, Ok(Incoming::Message(_))),
        "garbage ciphertext must not decrypt"
    );

    // Re-delivery (same event fetched again by relay sync): MDK blocks
    // reprocessing, so this must map to the terminal Incoming::Failed that the
    // sync layer marks processed, never to a retry that pins the watermark.
    let second = alice
        .process_incoming(&garbage)
        .await
        .expect("re-delivery of a failed event must not error");
    assert!(
        matches!(second, Incoming::Failed),
        "re-delivered failed event must be terminal, got {second:?}"
    );
}
