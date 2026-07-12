//! Regression test for the sync-watermark poisoning bug: a kind-445 event that
//! MDK cannot currently process gets a durable Failed record and surfaces as
//! [`Incoming::Failed`] on unchanged re-delivery. The relay sync layer counts
//! that delivery as handled so it does not rewind forever, while deliberately
//! leaving the outer processed-ID unset because an MLS rollback can later move
//! the MDK record to Retryable.

use nostr::RelayUrl;
use nostr::{EventBuilder, Keys, Kind, Tag};
use sonar_core::identity::Identity;
use sonar_core::marmot::{Incoming, MarmotEngine};

fn relays() -> Vec<RelayUrl> {
    vec![RelayUrl::parse("wss://relay.example").unwrap()]
}

#[tokio::test]
async fn undecryptable_group_message_surfaces_as_failed_until_rollback() {
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

    // Re-delivery before any rollback: MDK blocks reprocessing and surfaces
    // Incoming::Failed. Sonar treats this pass as handled for watermark
    // purposes, but must still allow a future relay redelivery to reach MDK if
    // a competing commit rollback changes this record to Retryable.
    let second = alice
        .process_incoming(&garbage)
        .await
        .expect("re-delivery of a failed event must not error");
    assert!(
        matches!(second, Incoming::Failed),
        "re-delivered failed event must remain failed before rollback, got {second:?}"
    );
}
