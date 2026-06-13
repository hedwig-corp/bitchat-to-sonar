//! Persistence integration test: prove that a SQLCipher-backed [`MarmotEngine`]
//! survives being dropped and reopened at the same path with the same key.
//!
//! No network: the engine layer is transport-free, so we exercise it directly.
//! Alice runs on the persistent engine; Bob is a throwaway in-memory engine that
//! only exists to mint a KeyPackage so Alice can form a real MLS group.

use mdk_core::prelude::GroupId;
use nostr::RelayUrl;
use sonar_core::identity::Identity;
use sonar_core::marmot::{Incoming, MarmotEngine};

/// A fixed 32-byte SQLCipher key (the host supplies this at runtime).
const DB_KEY: [u8; 32] = [0x42; 32];

fn relays() -> Vec<RelayUrl> {
    vec![RelayUrl::parse("wss://relay.example").unwrap()]
}

#[tokio::test]
async fn group_and_message_survive_reopen() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("marmot.sqlite");

    // Bob: throwaway engine, only used to produce a KeyPackage.
    let bob = MarmotEngine::in_memory(Identity::generate());
    let bob_kp = bob.key_package_event(relays()).expect("bob key package");

    let alice_identity = Identity::generate();
    let alice_pubkey = alice_identity.public_key();

    // --- Session 1: create the group + send a message on the PERSISTENT engine.
    let (group_id, sent_event) = {
        let alice = MarmotEngine::persistent(alice_identity.clone(), &db_path, DB_KEY)
            .expect("open persistent engine");

        let creation = alice
            .create_group("alice & bob", vec![bob_kp], relays())
            .expect("create group");
        let group_id = creation.group.mls_group_id.clone();

        // Send a message and process it back so it lands in storage as "ours"
        // (mirrors what SonarClient::send_text does after publishing).
        let event = alice
            .create_text_message(&group_id, "persisted hello")
            .expect("create message");
        let processed = alice
            .process_incoming(&event)
            .await
            .expect("process own message");
        assert!(matches!(processed, Incoming::Message(_)));

        // Sanity check within the live session.
        assert_eq!(alice.groups().unwrap().len(), 1);
        assert_eq!(alice.messages(&group_id).unwrap().len(), 1);

        (group_id, event)
    }; // alice dropped here → SQLite handle closed, data flushed to disk.
    let _ = sent_event;

    // The database files must exist on disk.
    assert!(db_path.exists(), "sqlite db file persists on disk");

    // --- Session 2: reopen a BRAND NEW engine at the SAME path + key.
    let alice2 = MarmotEngine::persistent(alice_identity, &db_path, DB_KEY)
        .expect("reopen persistent engine");

    // The group is still there.
    let groups = alice2.groups().expect("groups after reopen");
    assert_eq!(groups.len(), 1, "group survived reopen");
    let reopened_id: GroupId = groups[0].mls_group_id.clone();
    assert_eq!(reopened_id, group_id);
    assert_eq!(groups[0].name, "alice & bob");

    // The message is still there, with the right content + sender.
    let messages = alice2.messages(&group_id).expect("messages after reopen");
    assert_eq!(messages.len(), 1, "message survived reopen");
    assert_eq!(messages[0].content, "persisted hello");
    assert_eq!(messages[0].sender, alice_pubkey);
    assert!(messages[0].mine);
}

#[tokio::test]
async fn wrong_key_cannot_open_existing_db() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("marmot.sqlite");

    {
        let alice = MarmotEngine::persistent(Identity::generate(), &db_path, DB_KEY)
            .expect("open persistent engine");
        // Force the DB to materialize.
        let _ = alice.key_package_event(relays()).expect("key package");
    }

    // A different key must fail to open the encrypted database.
    let wrong_key = [0x13; 32];
    let result = MarmotEngine::persistent(Identity::generate(), &db_path, wrong_key);
    assert!(result.is_err(), "wrong SQLCipher key must be rejected");
}

#[tokio::test]
async fn wipe_removes_the_database() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("marmot.sqlite");

    {
        let alice = MarmotEngine::persistent(Identity::generate(), &db_path, DB_KEY)
            .expect("open persistent engine");
        let _ = alice.key_package_event(relays()).expect("key package");
    }
    assert!(db_path.exists());

    MarmotEngine::wipe(&db_path).expect("wipe");
    assert!(!db_path.exists(), "db file removed by wipe");

    // Wipe is idempotent.
    MarmotEngine::wipe(&db_path).expect("wipe again is a no-op");
}
