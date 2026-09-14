//! Persistence integration test: prove that a SQLCipher-backed [`MarmotEngine`]
//! survives being dropped and reopened at the same path with the same key.
//!
//! No network: the engine layer is transport-free, so we exercise it directly.
//! Alice runs on the persistent engine; Bob is a throwaway in-memory engine that
//! only exists to mint a KeyPackage so Alice can form a real MLS group.

use nostr::RelayUrl;
use sonar_core::client::SonarClient;
use sonar_core::identity::Identity;
use sonar_core::marmot::{DeliveryState, Incoming, MarmotEngine};
use sonar_core::GroupId;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::time::{sleep, Duration};

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
    let bob_kp = bob
        .key_package_event(relays())
        .await
        .expect("bob key package");

    let alice_identity = Identity::generate();
    let alice_pubkey = alice_identity.public_key();

    // --- Session 1: create the group + send a message on the PERSISTENT engine.
    let (group_id, sent_event) = {
        let alice = MarmotEngine::persistent(alice_identity.clone(), &db_path, DB_KEY)
            .expect("open persistent engine");

        let creation = alice
            .create_group("alice & bob", vec![bob_kp], relays())
            .await
            .expect("create group");
        let group_id = creation.group.id.clone();
        alice
            .merge_pending_commit(&group_id)
            .await
            .expect("merge after simulated welcome delivery");

        // Send messages and process them back so they land in storage as "ours"
        // (mirrors what SonarClient::send_text does after publishing).
        let event = alice
            .create_text_message(&group_id, "persisted hello 1")
            .await
            .expect("create message");
        let processed = alice
            .process_incoming(&event)
            .await
            .expect("process own message");
        assert!(matches!(processed, Incoming::Message(_)));
        sleep(Duration::from_secs(1)).await;
        let event = alice
            .create_text_message(&group_id, "persisted hello 2")
            .await
            .expect("create message");
        let processed = alice
            .process_incoming(&event)
            .await
            .expect("process own message");
        assert!(matches!(processed, Incoming::Message(_)));

        // Store a newer non-chat membership row after the chat messages. The
        // paged transcript API must skip this MDK bookkeeping row and still
        // return the latest real chat message.
        sleep(Duration::from_secs(1)).await;
        let charlie = MarmotEngine::in_memory(Identity::generate());
        let charlie_kp = charlie
            .key_package_event(relays())
            .await
            .expect("charlie key package");
        let update = alice
            .add_members(&group_id, vec![charlie_kp])
            .await
            .expect("add charlie");
        assert!(update.requires_commit_merge);
        alice
            .merge_pending_commit(&group_id)
            .await
            .expect("merge after simulated membership delivery");

        // Sanity check within the live session.
        assert_eq!(alice.groups().unwrap().len(), 1);
        assert_eq!(alice.messages(&group_id).unwrap().len(), 2);

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
    let reopened_id: GroupId = groups[0].id.clone();
    assert_eq!(reopened_id, group_id);
    assert_eq!(groups[0].name, "alice & bob");

    // The message is still there, with the right content + sender.
    let messages = alice2.messages(&group_id).expect("messages after reopen");
    assert_eq!(messages.len(), 2, "messages survived reopen");
    assert!(messages.iter().any(|m| m.content == "persisted hello 1"));
    assert!(messages.iter().any(|m| m.content == "persisted hello 2"));
    assert_eq!(messages[0].sender, alice_pubkey);
    assert!(messages[0].mine);
    let latest_page = alice2
        .messages_page(&group_id, 1, 0)
        .expect("latest local message page");
    assert_eq!(latest_page.len(), 1);
    assert_eq!(latest_page[0].content, "persisted hello 2");
    let previous_page = alice2
        .messages_page(&group_id, 1, 1)
        .expect("previous local message page");
    assert_eq!(previous_page.len(), 1);
    assert_eq!(previous_page[0].content, "persisted hello 1");

    // The sync watermark RESUMES from the persisted history (at or after the
    // stored message's timestamp — `latest_message_secs` also counts non-chat
    // membership/commit events) instead of resetting to 0, so a relaunch syncs
    // incrementally rather than re-fetching the whole history from scratch.
    assert!(
        alice2.latest_message_secs() >= messages[0].created_at.as_secs(),
        "watermark resumes at/after the newest stored message after reopen"
    );
    assert!(alice2.latest_message_secs() > 0);
}

#[tokio::test]
async fn local_first_send_persists_pending_message_before_relay_publish() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("marmot.sqlite");
    let outbox_path = db_path.with_file_name("marmot.sqlite.sonar-outbox.json");

    let bob = MarmotEngine::in_memory(Identity::generate());
    let bob_kp = bob
        .key_package_event(relays())
        .await
        .expect("bob key package");

    let alice_identity = Identity::generate();
    let group_id = {
        let client = SonarClient::connect(alice_identity.clone(), Vec::new(), &db_path, DB_KEY)
            .await
            .expect("connect local-only client");
        let creation = client
            .engine()
            .create_group("alice & bob", vec![bob_kp], Vec::new())
            .await
            .expect("create local group");
        let group_id = creation.group.id.clone();
        client
            .engine()
            .merge_pending_commit(&group_id)
            .await
            .expect("merge local group");

        client
            .send_text(&group_id, "visible before relay")
            .await
            .expect("local-first send");
        let page = client
            .messages_page(&group_id, 10, 0)
            .expect("local page after send");
        assert_eq!(page.len(), 1);
        assert_eq!(page[0].content, "visible before relay");
        assert_eq!(page[0].delivery_state, DeliveryState::Pending);
        assert!(outbox_path.exists(), "pending outbox sidecar is durable");
        group_id
    };

    let reopened = SonarClient::connect(alice_identity, Vec::new(), &db_path, DB_KEY)
        .await
        .expect("reopen local-only client");
    let page = reopened
        .messages_page(&group_id, 10, 0)
        .expect("local page after reopen");
    assert_eq!(page.len(), 1);
    assert_eq!(page[0].content, "visible before relay");
    assert_eq!(page[0].delivery_state, DeliveryState::Pending);
}

#[tokio::test]
async fn restart_watermark_ignores_later_local_messages() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("marmot.sqlite");

    let bob = MarmotEngine::in_memory(Identity::generate());
    let bob_kp = bob
        .key_package_event(relays())
        .await
        .expect("bob key package");

    let alice_identity = Identity::generate();
    let (bob_message_secs, alice_later_secs) = {
        let alice = MarmotEngine::persistent(alice_identity.clone(), &db_path, DB_KEY)
            .expect("open persistent engine");
        let creation = alice
            .create_group("alice & bob", vec![bob_kp], relays())
            .await
            .expect("create group");
        let group_id = creation.group.id.clone();

        let (_bob_pubkey, bob_welcome) = creation
            .welcomes
            .into_iter()
            .find(|(pubkey, _)| *pubkey == bob.identity().public_key())
            .expect("bob welcome");
        let bob_wrapped = bob_welcome;
        assert!(matches!(
            bob.process_incoming(&bob_wrapped)
                .await
                .expect("bob processes welcome"),
            Incoming::GroupUpdated(_)
        ));
        alice
            .merge_pending_commit(&group_id)
            .await
            .expect("merge after simulated welcome delivery");

        let bob_group_id = bob.groups().expect("bob groups")[0].id.clone();
        let bob_event = bob
            .create_text_message(&bob_group_id, "peer message while alice was offline")
            .await
            .expect("bob creates message");
        let bob_message_secs = bob_event.created_at.as_secs();
        assert!(matches!(
            alice
                .process_incoming(&bob_event)
                .await
                .expect("alice processes bob message"),
            Incoming::Message(_)
        ));

        // Wait deterministically until the wall clock has advanced past
        // bob_message_secs so alice_later_secs > bob_message_secs is
        // guaranteed regardless of CI runner load (no fixed sleep).
        while SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs()
            <= bob_message_secs
        {
            sleep(Duration::from_millis(100)).await;
        }
        // Use the atomic create+process API so the local transcript row is
        // written under the same MLS write guard as creation — eliminates the
        // race where a separately-processed message could strand.
        let (alice_event, alice_incoming) = alice
            .create_and_process_text_message(&group_id, "later local message")
            .await
            .expect("alice creates and processes later local message");
        let alice_later_secs = alice_event.created_at.as_secs();
        assert!(alice_later_secs > bob_message_secs);
        assert!(matches!(alice_incoming, Incoming::Message(_)));
        assert_eq!(alice.latest_remote_event_secs(), bob_message_secs);
        assert!(
            alice.latest_message_secs() >= alice_later_secs,
            "newest local event is the later outgoing message"
        );

        (bob_message_secs, alice_later_secs)
    };

    let reopened = MarmotEngine::persistent(alice_identity, &db_path, DB_KEY)
        .expect("reopen persistent engine");

    assert_eq!(
        reopened.latest_remote_event_secs(),
        bob_message_secs,
        "restart catch-up must resume from peer history, not later local sends"
    );
    assert!(
        reopened.latest_message_secs() >= alice_later_secs,
        "the full local latest timestamp still includes local outgoing rows"
    );
}

#[tokio::test]
async fn recent_message_pages_returns_newest_groups_with_bounded_windows() {
    let alice = MarmotEngine::in_memory(Identity::generate());
    let mut created = Vec::new();

    for idx in 0..6 {
        let bob = MarmotEngine::in_memory(Identity::generate());
        let bob_kp = bob
            .key_package_event(relays())
            .await
            .expect("bob key package");
        let creation = alice
            .create_group(&format!("chat {idx}"), vec![bob_kp], relays())
            .await
            .expect("create group");
        let group_id = creation.group.id.clone();
        alice
            .merge_pending_commit(&group_id)
            .await
            .expect("merge after simulated welcome delivery");

        for msg_idx in 0..3 {
            let event = alice
                .create_text_message(&group_id, &format!("chat {idx} message {msg_idx}"))
                .await
                .expect("create message");
            assert!(matches!(
                alice
                    .process_incoming(&event)
                    .await
                    .expect("process own message"),
                Incoming::Message(_)
            ));
        }
        created.push(group_id);
        sleep(Duration::from_secs(1)).await;
    }

    let pages = alice
        .recent_message_pages(5, 2)
        .expect("recent local transcript pages");
    assert_eq!(pages.len(), 5);
    assert_eq!(pages[0].group_id, created[5]);
    assert_eq!(pages[4].group_id, created[1]);
    assert!(!pages.iter().any(|page| page.group_id == created[0]));
    assert!(pages.iter().all(|page| page.messages.len() == 2));
    assert!(pages[0]
        .messages
        .iter()
        .all(|message| message.content.starts_with("chat 5 message ")));
}

#[tokio::test]
async fn wrong_key_cannot_open_existing_db() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("marmot.sqlite");

    {
        let alice = MarmotEngine::persistent(Identity::generate(), &db_path, DB_KEY)
            .expect("open persistent engine");
        // Force the DB to materialize.
        let _ = alice
            .key_package_event(relays())
            .await
            .expect("key package");
    }

    // A different key must fail to open the encrypted database.
    let wrong_key = [0x13; 32];
    let result = MarmotEngine::persistent(Identity::generate(), &db_path, wrong_key);
    assert!(result.is_err(), "wrong SQLCipher key must be rejected");
    assert!(
        db_path.exists(),
        "a failed open must not wipe an existing encrypted store"
    );
}

#[tokio::test]
async fn self_heals_an_unencrypted_legacy_database() {
    // Reproduces the field bug: an older build left a PLAINTEXT marmot.sqlite on
    // disk; the current code opens it WITH a SQLCipher key and SQLCipher refuses
    // ("Cannot open unencrypted database with encryption: database was created
    // without encryption"), failing on every launch. `persistent` must self-heal
    // by discarding the unusable file and recreating an encrypted store.
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("marmot.sqlite");

    // Fabricate a plaintext SQLite database at the path (no PRAGMA key → SQLCipher
    // writes a standard, unencrypted file).
    {
        let conn = rusqlite::Connection::open(&db_path).expect("open plaintext db");
        conn.execute_batch("CREATE TABLE legacy (x INTEGER); INSERT INTO legacy VALUES (1);")
            .expect("write plaintext db");
    }
    assert!(db_path.exists(), "plaintext db exists before reopen");

    // Opening with a key must NOT error — it should wipe + recreate encrypted.
    let alice = MarmotEngine::persistent(Identity::generate(), &db_path, DB_KEY)
        .expect("self-heal recreates the database instead of failing");

    // The recreated database is a working encrypted store.
    let _ = alice
        .key_package_event(relays())
        .await
        .expect("usable after self-heal");
    assert_eq!(
        alice.groups().expect("groups").len(),
        0,
        "fresh store starts empty"
    );
    drop(alice);

    // And it now reopens cleanly with the same key (it is genuinely encrypted).
    let alice2 = MarmotEngine::persistent(Identity::generate(), &db_path, DB_KEY)
        .expect("recreated db reopens with the key");
    assert_eq!(alice2.groups().expect("groups").len(), 0);
}

#[tokio::test]
async fn wipe_removes_the_database() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("marmot.sqlite");

    {
        let alice = MarmotEngine::persistent(Identity::generate(), &db_path, DB_KEY)
            .expect("open persistent engine");
        let _ = alice
            .key_package_event(relays())
            .await
            .expect("key package");
    }
    let sync_path = db_path.with_file_name("marmot.sqlite.sonar-sync.json");
    let sync_tmp_path = db_path.with_file_name("marmot.sqlite.sonar-sync.json.tmp");
    let outbox_path = db_path.with_file_name("marmot.sqlite.sonar-outbox.json");
    let outbox_tmp_path = db_path.with_file_name("marmot.sqlite.sonar-outbox.json.tmp");
    // The slot addresses MLS key material inside this database, so a wipe must
    // take it too. Without this assertion, dropping the suffix from
    // sidecar_paths keeps CI green while stranding the coordinate.
    let slot_path = db_path.with_file_name("marmot.sqlite.sonar-keypackage-slot");
    let slot_tmp_path = db_path.with_file_name("marmot.sqlite.sonar-keypackage-slot.tmp");
    std::fs::write(&sync_path, b"{}").expect("fake sync sidecar");
    std::fs::write(&sync_tmp_path, b"{}").expect("fake sync temp sidecar");
    std::fs::write(&outbox_path, b"{}").expect("fake outbox sidecar");
    std::fs::write(&outbox_tmp_path, b"{}").expect("fake outbox temp sidecar");
    assert!(db_path.exists());
    assert!(sync_path.exists());
    assert!(sync_tmp_path.exists());
    assert!(outbox_path.exists());
    assert!(outbox_tmp_path.exists());
    assert!(
        slot_path.exists(),
        "publishing a key package must create the slot"
    );
    std::fs::write(&slot_tmp_path, "leftover").expect("stage a crashed rename");
    let exporter_path =
        db_path.with_file_name("marmot.sqlite.sonar-historical-exporter-secrets.json");
    std::fs::write(&exporter_path, b"{}").expect("fake recovered media secrets");

    MarmotEngine::wipe(&db_path).expect("wipe");
    assert!(!db_path.exists(), "db file removed by wipe");
    assert!(!slot_path.exists(), "KeyPackage slot removed by wipe");
    assert!(
        !slot_tmp_path.exists(),
        "a crashed slot rename must not survive a wipe"
    );
    assert!(!sync_path.exists(), "sync sidecar removed by wipe");
    assert!(!sync_tmp_path.exists(), "sync temp sidecar removed by wipe");
    assert!(!outbox_path.exists(), "outbox sidecar removed by wipe");
    assert!(
        !outbox_tmp_path.exists(),
        "outbox temp sidecar removed by wipe"
    );
    assert!(
        !exporter_path.exists(),
        "recovered 0.8 media secrets must not survive a wipe"
    );

    // Wipe is idempotent.
    MarmotEngine::wipe(&db_path).expect("wipe again is a no-op");
}

/// A KeyPackage must land in the SAME addressable slot across republishes, and
/// that slot must survive a process restart.
///
/// Regression: `key_package_event` used to call MDK's plain
/// `create_key_package_for_event`, which mints a fresh random `d` tag whenever
/// no existing one is supplied. Hosts republish on every relay connect, so every
/// launch left ANOTHER live kind-30443 event on the relays. A peer starting a DM
/// then picks among several slots, and when two devices share one npub the
/// welcome can be addressed to key material held only by the other install,
/// where it can never be decrypted.
#[tokio::test]
async fn key_package_slot_is_stable_across_republish_and_reopen() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("marmot.sqlite");

    let identity = Identity::generate();
    let d_first;
    let d_second;
    {
        let engine = MarmotEngine::persistent(identity.clone(), &db_path, DB_KEY)
            .expect("persistent engine");
        // Two publishes in one session, as a relay reconnect would do.
        d_first = d_tag_of(&engine.key_package_event(relays()).await.expect("kp 1"));
        d_second = d_tag_of(&engine.key_package_event(relays()).await.expect("kp 2"));
    } // engine dropped: the process is "restarted" below.

    assert_eq!(
        d_first, d_second,
        "republishing must reuse the slot, not mint a second one"
    );

    // Reopen at the same path, as a relaunch does.
    // Same identity: the addressable coordinate is (kind, pubkey, d), so
    // reopening under a different pubkey would be a different slot regardless of
    // the d tag, and the assertion below would prove nothing.
    let reopened = MarmotEngine::persistent(identity, &db_path, DB_KEY).expect("reopen engine");
    let d_after_restart = d_tag_of(&reopened.key_package_event(relays()).await.expect("kp 3"));
    assert_eq!(
        d_first, d_after_restart,
        "a relaunch must republish into the same slot, not add a new one"
    );
}

/// Two independent installs must NOT collide on one slot: they are different MLS
/// clients holding different private key material, so they need separate
/// addressable coordinates for multi-device to be possible at all.
#[tokio::test]
async fn separate_installs_get_separate_slots() {
    let dir_a = tempfile::tempdir().expect("tempdir a");
    let dir_b = tempfile::tempdir().expect("tempdir b");
    let identity = Identity::generate();

    let a = MarmotEngine::persistent(identity.clone(), dir_a.path().join("marmot.sqlite"), DB_KEY)
        .expect("engine a");
    let b = MarmotEngine::persistent(identity, dir_b.path().join("marmot.sqlite"), DB_KEY)
        .expect("engine b");

    let d_a = d_tag_of(&a.key_package_event(relays()).await.expect("kp a"));
    let d_b = d_tag_of(&b.key_package_event(relays()).await.expect("kp b"));
    assert_ne!(
        d_a, d_b,
        "two installs of the same identity must occupy distinct slots"
    );
}

/// A corrupt slot file must not wedge publishing: we mint a fresh slot instead
/// of handing MDK a value it will reject.
#[tokio::test]
async fn malformed_stored_slot_is_replaced_not_fatal() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("marmot.sqlite");
    let slot_path = db_path.with_file_name("marmot.sqlite.sonar-keypackage-slot");
    std::fs::write(&slot_path, "not-a-valid-d-tag").expect("write slot");

    let identity = Identity::generate();
    let pubkey_hex = identity.public_key().to_hex();
    let engine = MarmotEngine::persistent(identity, &db_path, DB_KEY).expect("engine");
    let d = d_tag_of(&engine.key_package_event(relays()).await.expect("kp"));
    assert_eq!(d.len(), 64, "expected a freshly minted 32-byte hex slot");
    assert!(d.chars().all(|c| c.is_ascii_hexdigit()));

    // 64 hex chars is also the shape of the identity-derived slot, so the checks
    // above cannot tell a fresh mint from the substitution this test exists to
    // rule out. Recovering from a corrupt sidecar by falling back to the derived
    // slot would collapse every install of an identity onto one coordinate.
    let mut input = b"sonar-keypackage-slot-v1:".to_vec();
    input.extend_from_slice(pubkey_hex.as_bytes());
    let derived = {
        use nostr::hashes::{sha256::Hash as Sha256Hash, Hash as _};
        Sha256Hash::hash(&input).to_string()
    };
    assert_ne!(
        d, derived,
        "a malformed slot must be re-minted, not replaced with the derived slot"
    );

    // And it must be rewritten to disk. Without this, "replaced" could silently
    // mean "re-minted on every launch" while this test stays green.
    assert_eq!(
        std::fs::read_to_string(&slot_path)
            .expect("slot rewritten")
            .trim(),
        d,
        "the malformed slot must be replaced on disk, not just bypassed"
    );
}

/// The `d` tag of a kind-30443 KeyPackage event.
fn d_tag_of(event: &nostr::Event) -> String {
    event
        .tags
        .iter()
        .find(|t| t.kind() == nostr::TagKind::d())
        .and_then(|t| t.content())
        .expect("kind-30443 event must carry a d tag")
        .to_string()
}

/// A staged restore must not promote a new database over the OUTGOING install's
/// KeyPackage slot.
///
/// The restore path stages into `<db>.sonar-restore-staging` and then renames it
/// over `<db>`, so any cleanup keyed on the staging path never touches the live
/// slot. Leaving it means the restored install republishes into the previous
/// install's `(kind, pubkey, d)` coordinate while holding different MLS key
/// material: two installs, one addressable slot, which is the failure the stable
/// slot exists to prevent.
#[tokio::test]
async fn committing_a_staged_restore_drops_the_previous_slot() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("marmot.sqlite");
    let slot_path = db_path.with_file_name("marmot.sqlite.sonar-keypackage-slot");
    let slot_tmp = db_path.with_file_name("marmot.sqlite.sonar-keypackage-slot.tmp");

    // A live install with a published slot.
    {
        let engine =
            MarmotEngine::persistent(Identity::generate(), &db_path, DB_KEY).expect("engine");
        engine.key_package_event(relays()).await.expect("kp");
    }
    assert!(slot_path.exists(), "precondition: live slot exists");
    std::fs::write(&slot_tmp, "leftover").expect("stage a crashed rename");

    // A restore staged beside it, then promoted.
    let staged = db_path.with_file_name("marmot.sqlite.sonar-restore-staging");
    std::fs::copy(&db_path, &staged).expect("stage a restored db");
    sonar_core::account_backup::commit_staged_account_restore(&db_path).expect("commit restore");

    assert!(
        !slot_path.exists(),
        "the outgoing install's slot must not survive the promotion"
    );
    assert!(!slot_tmp.exists(), "nor its staging file");
}

/// A slot that cannot be READ (as opposed to being absent) must fail the publish
/// rather than substituting a different slot id.
///
/// `key_package_event` persists whatever slot it uses, so any substitution here
/// would be written to disk permanently. Substituting the identity-derived slot
/// would be worst: it is a pure function of the npub, so two installs of one
/// identity that each hit a transient read error would converge on ONE
/// coordinate and start replacing each other's KeyPackage.
#[cfg(unix)]
#[tokio::test]
async fn unreadable_slot_fails_the_publish_instead_of_substituting_one() {
    use std::os::unix::fs::PermissionsExt;

    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("marmot.sqlite");
    let slot_path = db_path.with_file_name("marmot.sqlite.sonar-keypackage-slot");
    let identity = Identity::generate();

    let engine = MarmotEngine::persistent(identity.clone(), &db_path, DB_KEY).expect("engine");
    let original = d_tag_of(&engine.key_package_event(relays()).await.expect("kp"));

    // New engine so the in-process memo cannot mask the read, then make the slot
    // unreadable the way a locked container would.
    drop(engine);
    let engine = MarmotEngine::persistent(identity, &db_path, DB_KEY).expect("reopen");
    std::fs::set_permissions(&slot_path, std::fs::Permissions::from_mode(0o000)).expect("chmod");

    let result = engine.key_package_event(relays()).await;

    std::fs::set_permissions(&slot_path, std::fs::Permissions::from_mode(0o600))
        .expect("restore perms");
    assert!(
        result.is_err(),
        "an unreadable slot must fail the publish, not silently pick another slot"
    );
    assert_eq!(
        std::fs::read_to_string(&slot_path)
            .expect("slot readable again")
            .trim(),
        original,
        "the stored slot must be untouched by the failed publish"
    );
}

/// A persistent install must NOT use the identity-derived slot.
///
/// The derived slot is a pure function of the npub, so it is only safe where
/// there is no database to collide with (in-memory engines, which have no
/// persistent install). If someone ever extends that fallback to persistent
/// engines, every install of one identity collapses onto a single
/// `(kind, pubkey, d)` coordinate and they start replacing each other's
/// KeyPackage, which is the failure the stable slot exists to prevent.
///
/// `separate_installs_get_separate_slots` does not catch that: MDK already
/// minted a random `d` per call before this change, so it passes either way.
/// This one bites.
#[tokio::test]
async fn a_persistent_install_does_not_use_the_derived_slot() {
    use nostr::hashes::{sha256::Hash as Sha256Hash, Hash as _};

    let dir = tempfile::tempdir().expect("tempdir");
    let identity = Identity::generate();
    let pubkey_hex = identity.public_key().to_hex();

    let engine = MarmotEngine::persistent(identity, dir.path().join("marmot.sqlite"), DB_KEY)
        .expect("engine");
    let slot = d_tag_of(&engine.key_package_event(relays()).await.expect("kp"));

    // Recomputed here rather than reaching into the engine, so the test also
    // pins the derivation itself.
    let mut input = b"sonar-keypackage-slot-v1:".to_vec();
    input.extend_from_slice(pubkey_hex.as_bytes());
    let derived = Sha256Hash::hash(&input).to_string();

    assert_ne!(
        slot, derived,
        "a persistent install must own a random slot, not the identity-derived one"
    );
}

/// A FAILED restore rename must leave the live install's slot alone.
///
/// `committing_a_staged_restore_drops_the_previous_slot` only exercises a
/// successful rename, where the file is deleted either way, so moving the
/// unlinks back above `fs::rename` keeps it green. This pins the ordering: on a
/// failed rename the old database is still the live install, and dropping its
/// slot would leave it holding key material with no coordinate, so its next
/// publish mints a second one while the relays still carry the first.
///
/// The rename is failed by making the destination a NON-EMPTY DIRECTORY, not by
/// making the parent read-only: a read-only parent also blocks the unlink, so
/// the slot would survive either way and the test would pass against the bug it
/// exists to catch. The parent stays writable so the unlink is possible.
#[tokio::test]
async fn a_failed_restore_rename_keeps_the_live_slot() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("marmot.sqlite");
    let slot_path = db_path.with_file_name("marmot.sqlite.sonar-keypackage-slot");

    // Destination is a non-empty directory, so rename(file -> dir) fails while
    // everything around it stays writable.
    std::fs::create_dir(&db_path).expect("db path as dir");
    std::fs::write(db_path.join("occupied"), b"x").expect("make it non-empty");

    let original = "a".repeat(64);
    std::fs::write(&slot_path, &original).expect("live slot");
    let staged = db_path.with_file_name("marmot.sqlite.sonar-restore-staging");
    std::fs::write(&staged, b"restored db bytes").expect("stage");

    let result = sonar_core::account_backup::commit_staged_account_restore(&db_path);

    assert!(result.is_err(), "a failed rename must surface as an error");
    assert_eq!(
        std::fs::read_to_string(&slot_path)
            .expect("slot must survive")
            .trim(),
        original,
        "the still-live install must keep its coordinate when the rename fails"
    );
}

/// A commit that dies after the rename but before cleanup must still drop the
/// outgoing slot when retried.
///
/// `commit_staged_account_restore` is documented as retry-safe, but on retry
/// staging is gone, so the early-return arm is the only code left that can
/// finish the job. Without the intent-gated cleanup there, the previous
/// install's coordinate sits beside the restored database permanently and no
/// later call can heal it.
#[tokio::test]
async fn a_retried_commit_finishes_dropping_the_outgoing_slot() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("marmot.sqlite");
    let slot_path = db_path.with_file_name("marmot.sqlite.sonar-keypackage-slot");
    let intent_path = db_path.with_file_name("marmot.sqlite.sonar-restore-intent");

    {
        let engine =
            MarmotEngine::persistent(Identity::generate(), &db_path, DB_KEY).expect("engine");
        engine.key_package_event(relays()).await.expect("kp");
    }
    assert!(slot_path.exists(), "precondition: outgoing slot exists");

    // The state a crash between rename and cleanup leaves behind: staging gone
    // (the rename won), intent still set (cleanup never finished).
    std::fs::write(&intent_path, "1").expect("mark intent");

    sonar_core::account_backup::commit_staged_account_restore(&db_path).expect("retry commit");

    assert!(
        !slot_path.exists(),
        "the retry must finish dropping the outgoing slot"
    );
    assert!(!intent_path.exists(), "and clear the intent");
}

/// The inverse: with no restore in flight, the commit must NOT touch the slot.
///
/// The retry cleanup is gated on the intent marker precisely so an ordinary
/// no-op commit cannot strand a healthy install's coordinate.
#[tokio::test]
async fn a_commit_with_no_restore_in_flight_leaves_the_slot_alone() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("marmot.sqlite");
    let slot_path = db_path.with_file_name("marmot.sqlite.sonar-keypackage-slot");

    {
        let engine =
            MarmotEngine::persistent(Identity::generate(), &db_path, DB_KEY).expect("engine");
        engine.key_package_event(relays()).await.expect("kp");
    }
    let original = std::fs::read_to_string(&slot_path).expect("slot exists");

    // No staging file, no intent marker: nothing to promote.
    sonar_core::account_backup::commit_staged_account_restore(&db_path).expect("no-op commit");

    assert_eq!(
        std::fs::read_to_string(&slot_path)
            .expect("slot must survive")
            .trim(),
        original.trim(),
        "a healthy install must keep its coordinate"
    );
}

/// An on-disk MDK 0.8 SQLCipher store (raw-key `x'<hex>'`, `messages` table)
/// must not fail open and must not be wiped. Plaintext chat is copied onto the
/// 0.9 transcript sidecar so existing installs keep readable history.
#[tokio::test]
async fn mdk08_store_decrypts_and_moves_plaintext_without_wiping() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("marmot.sqlite");
    let alice = Identity::generate();
    let bob = Identity::generate();
    let event_id = nostr::EventId::from_slice(&[0xABu8; 32]).expect("event id");
    let group_id = vec![0x11u8; 16];

    {
        let conn = rusqlite::Connection::open(&db_path).expect("open 0.8 file");
        let hex_key = DB_KEY
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>();
        conn.execute_batch(&format!("PRAGMA key = \"x'{hex_key}'\";"))
            .expect("0.8 raw key");
        conn.execute_batch(
            "CREATE TABLE groups (
                mls_group_id BLOB PRIMARY KEY,
                nostr_group_id BLOB NOT NULL,
                name TEXT NOT NULL,
                description TEXT NOT NULL
            );
            CREATE TABLE messages (
                mls_group_id BLOB NOT NULL,
                id BLOB NOT NULL,
                pubkey BLOB NOT NULL,
                kind INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                content TEXT NOT NULL,
                tags TEXT NOT NULL,
                event TEXT NOT NULL,
                wrapper_event_id BLOB NOT NULL,
                state TEXT NOT NULL,
                PRIMARY KEY (mls_group_id, id)
            );",
        )
        .expect("0.8 schema");
        conn.execute(
            "INSERT INTO groups (mls_group_id, nostr_group_id, name, description)
             VALUES (?1, ?2, 'alice & bob', 'sonar.direct-dm.v1')",
            rusqlite::params![group_id.clone(), vec![0x22u8; 32]],
        )
        .expect("group row");
        conn.execute(
            "INSERT INTO messages
                (mls_group_id, id, pubkey, kind, created_at, content, tags, event,
                 wrapper_event_id, state)
             VALUES (?1, ?2, ?3, 9, 1_700_000_000, 'keep this chat', '[]', '{}', ?2, 'processed')",
            rusqlite::params![
                group_id.clone(),
                event_id.as_bytes().to_vec(),
                bob.public_key().to_bytes().to_vec(),
            ],
        )
        .expect("chat row");
    }

    let engine = MarmotEngine::persistent(alice.clone(), &db_path, DB_KEY)
        .expect("0.8 store must migrate instead of failing open");
    let recovered = engine
        .messages(&sonar_core::GroupId::new(group_id.clone()))
        .expect("recovered transcript");
    assert_eq!(recovered.len(), 1, "plaintext chat must be readable");
    assert_eq!(recovered[0].id, event_id);
    assert_eq!(recovered[0].content, "keep this chat");
    assert_eq!(recovered[0].sender, bob.public_key());
    assert_eq!(
        engine
            .historical_group_name(&sonar_core::GroupId::new(group_id.clone()))
            .as_deref(),
        Some("alice & bob")
    );
    assert_eq!(engine.groups().expect("live 0.9 groups").len(), 0);
    let recovered_groups = engine
        .historical_groups()
        .expect("recovered conversations must be listed");
    assert_eq!(recovered_groups.len(), 1);
    assert_eq!(recovered_groups[0].id.as_slice(), group_id.as_slice());
    assert!(
        recovered_groups[0].members.contains(&bob.public_key()),
        "hosts fold by the recovered peer npub"
    );
    let pages = engine
        .recent_message_pages(8, 8)
        .expect("home list pages include recovered chats");
    assert_eq!(pages.len(), 1);
    assert_eq!(pages[0].messages[0].content, "keep this chat");

    let bak = db_path.with_file_name("marmot.sqlite.mdk08.bak");
    assert!(bak.exists(), "0.8 file must be quarantined, not deleted");
    assert!(
        db_path.exists(),
        "a fresh 0.9 store must occupy the original path"
    );

    let index = sonar_core::conversation_index::ConversationIndex::open_in_memory().expect("index");
    index.materialize_from(&engine).expect("seed from sidecar");
    let summaries = index.summaries_ordered().expect("summaries");
    assert_eq!(summaries.len(), 1);
    assert_eq!(summaries[0].latest_content, "keep this chat");
    assert_eq!(summaries[0].name, "alice & bob");
    assert_eq!(summaries[0].unread_count, 0);

    drop(engine);
    let reopened = MarmotEngine::persistent(alice, &db_path, DB_KEY).expect("0.9 reopen");
    assert_eq!(
        reopened
            .messages(&sonar_core::GroupId::new(group_id))
            .expect("sidecar survives reopen")
            .len(),
        1
    );
    assert!(bak.exists(), "quarantine must survive a later 0.9 reopen");
}

/// A backup taken after the 0.8 → 0.9 migrate must carry recovered-chat
/// sidecars. Restore onto a fresh path must still paint the transcript.
#[tokio::test]
async fn mdk08_account_backup_preserves_recovered_transcript() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("marmot.sqlite");
    let alice = Identity::generate();
    let bob = Identity::generate();
    let event_id = nostr::EventId::from_slice(&[0xABu8; 32]).expect("event id");
    let group_id = vec![0x11u8; 16];

    {
        let conn = rusqlite::Connection::open(&db_path).expect("open 0.8 file");
        let hex_key = DB_KEY
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>();
        conn.execute_batch(&format!("PRAGMA key = \"x'{hex_key}'\";"))
            .expect("0.8 raw key");
        conn.execute_batch(
            "CREATE TABLE groups (
                mls_group_id BLOB PRIMARY KEY,
                nostr_group_id BLOB NOT NULL,
                name TEXT NOT NULL,
                description TEXT NOT NULL
            );
            CREATE TABLE messages (
                mls_group_id BLOB NOT NULL,
                id BLOB NOT NULL,
                pubkey BLOB NOT NULL,
                kind INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                content TEXT NOT NULL,
                tags TEXT NOT NULL,
                event TEXT NOT NULL,
                wrapper_event_id BLOB NOT NULL,
                state TEXT NOT NULL,
                PRIMARY KEY (mls_group_id, id)
            );",
        )
        .expect("0.8 schema");
        conn.execute(
            "INSERT INTO groups (mls_group_id, nostr_group_id, name, description)
             VALUES (?1, ?2, 'alice & bob', 'sonar.direct-dm.v1')",
            rusqlite::params![group_id.clone(), vec![0x22u8; 32]],
        )
        .expect("group row");
        conn.execute(
            "INSERT INTO messages
                (mls_group_id, id, pubkey, kind, created_at, content, tags, event,
                 wrapper_event_id, state)
             VALUES (?1, ?2, ?3, 9, 1_700_000_000, 'keep this chat', '[]', '{}', ?2, 'processed')",
            rusqlite::params![
                group_id.clone(),
                event_id.as_bytes().to_vec(),
                bob.public_key().to_bytes().to_vec(),
            ],
        )
        .expect("chat row");
    }

    let engine =
        MarmotEngine::persistent(alice.clone(), &db_path, DB_KEY).expect("0.8 store must migrate");
    drop(engine);

    let key_hex = DB_KEY
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<String>();
    let package = sonar_core::account_backup::read_account_backup_package(&db_path, &key_hex)
        .expect("post-migrate backup must open the 0.9 passphrase store");
    assert!(
        package
            .sidecar_files
            .iter()
            .any(|(name, bytes)| name == ".sonar-transcript.json" && !bytes.is_empty()),
        "recovered transcript must be inside the sealed account"
    );
    assert!(
        !package
            .sidecar_files
            .iter()
            .any(|(name, _)| name == ".mdk08.bak"),
        "first-paint copied every row; packing bak would double the blob"
    );

    let restore_dir = tempfile::tempdir().expect("restore dir");
    let restore_path = restore_dir.path().join("marmot.sqlite");
    sonar_core::account_backup::write_account_backup_package(&restore_path, &package)
        .expect("restore package");
    let restored = MarmotEngine::persistent(alice, &restore_path, DB_KEY)
        .expect("restored 0.9 store plus sidecars");
    let gid = sonar_core::GroupId::new(group_id);
    let recovered = restored.messages(&gid).expect("transcript after restore");
    assert_eq!(recovered.len(), 1);
    assert_eq!(recovered[0].id, event_id);
    assert_eq!(recovered[0].content, "keep this chat");
    let listed = restored
        .historical_groups()
        .expect("restored recovered chats must be listable");
    assert_eq!(listed.len(), 1);
    assert!(
        listed[0].members.contains(&bob.public_key()),
        "resume peers must survive nsec restore"
    );
    assert!(
        package.sidecar_files.iter().any(|(name, bytes)| name
            == ".sonar-historical-descriptions.json"
            && !bytes.is_empty()),
        "DM description must travel with the account backup"
    );
    assert_eq!(
        restored.historical_group_description(&gid).as_deref(),
        Some("sonar.direct-dm.v1")
    );
    assert!(
        restored.historical_resume_is_direct(&gid),
        "nsec restore must keep a recovered DM on start_dm"
    );
    let index = sonar_core::conversation_index::ConversationIndex::open_in_memory().expect("index");
    index
        .materialize_from(&restored)
        .expect("chat-list seed after restore");
    let summaries = index.summaries_ordered().expect("summaries");
    assert_eq!(summaries.len(), 1);
    assert_eq!(summaries[0].latest_content, "keep this chat");
    assert_eq!(summaries[0].name, "alice & bob");
}

/// Leftover bak rows must survive a post-migrate backup. Otherwise nsec
/// restore would keep only the first-paint window.
#[tokio::test]
async fn mdk08_account_backup_preserves_remainder_after_restore() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("marmot.sqlite");
    let alice = Identity::generate();
    let bob = Identity::generate();
    let group_id = vec![0x11u8; 16];
    let total = 530usize;
    {
        let conn = rusqlite::Connection::open(&db_path).expect("open 0.8 file");
        let hex_key = DB_KEY
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>();
        conn.execute_batch(&format!("PRAGMA key = \"x'{hex_key}'\";"))
            .expect("0.8 raw key");
        conn.execute_batch(
            "CREATE TABLE groups (
                mls_group_id BLOB PRIMARY KEY,
                nostr_group_id BLOB NOT NULL,
                name TEXT NOT NULL,
                description TEXT NOT NULL
            );
            CREATE TABLE messages (
                mls_group_id BLOB NOT NULL,
                id BLOB NOT NULL,
                pubkey BLOB NOT NULL,
                kind INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                content TEXT NOT NULL,
                tags TEXT NOT NULL,
                event TEXT NOT NULL,
                wrapper_event_id BLOB NOT NULL,
                state TEXT NOT NULL,
                PRIMARY KEY (mls_group_id, id)
            );",
        )
        .expect("0.8 schema");
        conn.execute(
            "INSERT INTO groups (mls_group_id, nostr_group_id, name, description)
             VALUES (?1, ?2, 'alice & bob', 'sonar.direct-dm.v1')",
            rusqlite::params![group_id.clone(), vec![0x22u8; 32]],
        )
        .expect("group row");
        for i in 0..total {
            let mut id = [0u8; 32];
            id[0] = (i / 256) as u8;
            id[1] = (i % 256) as u8;
            conn.execute(
                "INSERT INTO messages
                    (mls_group_id, id, pubkey, kind, created_at, content, tags, event,
                     wrapper_event_id, state)
                 VALUES (?1, ?2, ?3, 9, ?4, ?5, '[]', '{}', ?2, 'processed')",
                rusqlite::params![
                    group_id.clone(),
                    id.to_vec(),
                    bob.public_key().to_bytes().to_vec(),
                    1_700_000_000 + i as i64,
                    format!("row-{i}"),
                ],
            )
            .expect("chat row");
        }
    }

    let engine =
        MarmotEngine::persistent(alice.clone(), &db_path, DB_KEY).expect("0.8 store must migrate");
    assert!(engine.has_pending_mdk08_remainder());
    drop(engine);

    let key_hex = DB_KEY
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<String>();
    let package = sonar_core::account_backup::read_account_backup_package(&db_path, &key_hex)
        .expect("post-migrate backup must include the quarantined bak");
    assert!(
        package
            .sidecar_files
            .iter()
            .any(|(name, bytes)| name == ".mdk08.bak" && !bytes.is_empty()),
        "remainder lives in the bak; a backup without it drops older history"
    );
    assert!(
        package
            .sidecar_files
            .iter()
            .any(|(name, _)| name == ".sonar-mdk08-migrated.json"),
        "partial-migrate marker must travel so restore keeps remainder pending"
    );

    let restore_dir = tempfile::tempdir().expect("restore dir");
    let restore_path = restore_dir.path().join("marmot.sqlite");
    sonar_core::account_backup::write_account_backup_package(&restore_path, &package)
        .expect("restore package");
    let restored = MarmotEngine::persistent(alice, &restore_path, DB_KEY)
        .expect("restored 0.9 store plus bak");
    assert!(
        restored.has_pending_mdk08_remainder(),
        "first-paint window only; leftover rows stay pending after restore"
    );
    let gid = sonar_core::GroupId::new(group_id);
    let all = restored
        .messages(&gid)
        .expect("drain remainder after restore");
    assert_eq!(all.len(), total);
    assert_eq!(all[0].content, "row-0");
    assert_eq!(all[total - 1].content, "row-529");
    assert!(!restored.has_pending_mdk08_remainder());
}

/// Once leftover rows are in the transcript, a later backup must not
/// upload `*.mdk08.bak`. Restore still paints the full history.
#[tokio::test]
async fn mdk08_account_backup_omits_bak_after_remainder_complete() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("marmot.sqlite");
    let alice = Identity::generate();
    let bob = Identity::generate();
    let group_id = vec![0x11u8; 16];
    let total = 530usize;
    {
        let conn = rusqlite::Connection::open(&db_path).expect("open 0.8 file");
        let hex_key = DB_KEY
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>();
        conn.execute_batch(&format!("PRAGMA key = \"x'{hex_key}'\";"))
            .expect("0.8 raw key");
        conn.execute_batch(
            "CREATE TABLE groups (
                mls_group_id BLOB PRIMARY KEY,
                nostr_group_id BLOB NOT NULL,
                name TEXT NOT NULL,
                description TEXT NOT NULL
            );
            CREATE TABLE messages (
                mls_group_id BLOB NOT NULL,
                id BLOB NOT NULL,
                pubkey BLOB NOT NULL,
                kind INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                content TEXT NOT NULL,
                tags TEXT NOT NULL,
                event TEXT NOT NULL,
                wrapper_event_id BLOB NOT NULL,
                state TEXT NOT NULL,
                PRIMARY KEY (mls_group_id, id)
            );",
        )
        .expect("0.8 schema");
        conn.execute(
            "INSERT INTO groups (mls_group_id, nostr_group_id, name, description)
             VALUES (?1, ?2, 'alice & bob', 'sonar.direct-dm.v1')",
            rusqlite::params![group_id.clone(), vec![0x22u8; 32]],
        )
        .expect("group row");
        for i in 0..total {
            let mut id = [0u8; 32];
            id[0] = (i / 256) as u8;
            id[1] = (i % 256) as u8;
            conn.execute(
                "INSERT INTO messages
                    (mls_group_id, id, pubkey, kind, created_at, content, tags, event,
                     wrapper_event_id, state)
                 VALUES (?1, ?2, ?3, 9, ?4, ?5, '[]', '{}', ?2, 'processed')",
                rusqlite::params![
                    group_id.clone(),
                    id.to_vec(),
                    bob.public_key().to_bytes().to_vec(),
                    1_700_000_000 + i as i64,
                    format!("row-{i}"),
                ],
            )
            .expect("chat row");
        }
    }

    let engine =
        MarmotEngine::persistent(alice.clone(), &db_path, DB_KEY).expect("0.8 store must migrate");
    assert!(engine.has_pending_mdk08_remainder());
    let gid = sonar_core::GroupId::new(group_id);
    let drained = engine.messages(&gid).expect("drain leftover 0.8 rows");
    assert_eq!(drained.len(), total);
    assert!(!engine.has_pending_mdk08_remainder());
    drop(engine);

    let key_hex = DB_KEY
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<String>();
    let package = sonar_core::account_backup::read_account_backup_package(&db_path, &key_hex)
        .expect("post-drain backup must open the 0.9 passphrase store");
    assert!(
        !package
            .sidecar_files
            .iter()
            .any(|(name, _)| name == ".mdk08.bak"),
        "complete remainder is already in the transcript; bak would double the blob"
    );
    assert!(
        package
            .sidecar_files
            .iter()
            .any(|(name, bytes)| name == ".sonar-transcript.json" && !bytes.is_empty()),
        "transcript sidecar is the durable copy after remainder completes"
    );
    assert!(
        db_path.with_file_name("marmot.sqlite.mdk08.bak").exists(),
        "local quarantine stays on disk until a later cleanup release"
    );

    let restore_dir = tempfile::tempdir().expect("restore dir");
    let restore_path = restore_dir.path().join("marmot.sqlite");
    sonar_core::account_backup::write_account_backup_package(&restore_path, &package)
        .expect("restore package");
    assert!(
        !restore_path
            .with_file_name("marmot.sqlite.mdk08.bak")
            .exists(),
        "restore must not recreate a bak the blob omitted"
    );
    let restored = MarmotEngine::persistent(alice, &restore_path, DB_KEY)
        .expect("restored 0.9 store from transcript sidecar");
    assert!(!restored.has_pending_mdk08_remainder());
    let recovered = restored.messages(&gid).expect("full history after restore");
    assert_eq!(recovered.len(), total);
    assert_eq!(recovered[0].content, "row-0");
    assert_eq!(recovered[total - 1].content, "row-529");
    let listed = restored
        .historical_groups()
        .expect("restored recovered chats must be listable without bak");
    assert_eq!(listed.len(), 1);
    let index = sonar_core::conversation_index::ConversationIndex::open_in_memory().expect("index");
    index
        .materialize_from(&restored)
        .expect("chat-list seed after omit-bak restore");
    let summaries = index.summaries_ordered().expect("summaries");
    assert_eq!(summaries.len(), 1);
    assert_eq!(summaries[0].latest_content, "row-529");
}

/// An unreadable remainder bak must not be treated as "all rows copied".
/// Marking complete here would omit the bak from the next backup and drop
/// leftover history.
#[tokio::test]
async fn mdk08_unreadable_bak_keeps_remainder_pending() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("marmot.sqlite");
    let alice = Identity::generate();
    let bob = Identity::generate();
    let group_id = vec![0x11u8; 16];
    {
        let conn = rusqlite::Connection::open(&db_path).expect("open 0.8 file");
        let hex_key = DB_KEY
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>();
        conn.execute_batch(&format!("PRAGMA key = \"x'{hex_key}'\";"))
            .expect("0.8 raw key");
        conn.execute_batch(
            "CREATE TABLE groups (
                mls_group_id BLOB PRIMARY KEY,
                nostr_group_id BLOB NOT NULL,
                name TEXT NOT NULL,
                description TEXT NOT NULL
            );
            CREATE TABLE messages (
                mls_group_id BLOB NOT NULL,
                id BLOB NOT NULL,
                pubkey BLOB NOT NULL,
                kind INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                content TEXT NOT NULL,
                tags TEXT NOT NULL,
                event TEXT NOT NULL,
                wrapper_event_id BLOB NOT NULL,
                state TEXT NOT NULL,
                PRIMARY KEY (mls_group_id, id)
            );",
        )
        .expect("0.8 schema");
        conn.execute(
            "INSERT INTO groups (mls_group_id, nostr_group_id, name, description)
             VALUES (?1, ?2, 'alice & bob', 'sonar.direct-dm.v1')",
            rusqlite::params![group_id.clone(), vec![0x22u8; 32]],
        )
        .expect("group row");
        for i in 0..200 {
            let mut id = [0u8; 32];
            id[0] = (i / 256) as u8;
            id[1] = (i % 256) as u8;
            conn.execute(
                "INSERT INTO messages
                    (mls_group_id, id, pubkey, kind, created_at, content, tags, event,
                     wrapper_event_id, state)
                 VALUES (?1, ?2, ?3, 9, ?4, ?5, '[]', '{}', ?2, 'processed')",
                rusqlite::params![
                    group_id.clone(),
                    id.to_vec(),
                    bob.public_key().to_bytes().to_vec(),
                    1_700_000_000 + i as i64,
                    format!("row-{i}"),
                ],
            )
            .expect("chat row");
        }
    }

    let engine =
        MarmotEngine::persistent(alice.clone(), &db_path, DB_KEY).expect("0.8 store must migrate");
    assert!(engine.has_pending_mdk08_remainder());
    drop(engine);

    let bak = db_path.with_file_name("marmot.sqlite.mdk08.bak");
    std::fs::remove_file(&bak).expect("drop readable bak");
    {
        let conn = rusqlite::Connection::open(&bak).expect("replacement bak");
        conn.execute_batch(&format!(
            "PRAGMA key = \"x'{}'\";",
            [0x99u8; 32]
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect::<String>()
        ))
        .expect("other key");
        conn.execute_batch("CREATE TABLE t (x INTEGER); INSERT INTO t VALUES (1);")
            .expect("dummy 0.8-shaped file under the wrong key");
    }

    let reopened = MarmotEngine::persistent(alice, &db_path, DB_KEY).expect("0.9 reopen");
    assert!(reopened.has_pending_mdk08_remainder());
    assert!(
        reopened.drain_mdk08_remainder().is_err(),
        "unreadable bak must fail open, not look like an empty remainder"
    );
    assert!(
        reopened.has_pending_mdk08_remainder(),
        "leftover rows stay pending so a later readable bak can still copy"
    );
    let marker =
        std::fs::read_to_string(db_path.with_file_name("marmot.sqlite.sonar-mdk08-migrated.json"))
            .expect("marker");
    assert!(
        marker.contains("\"partial\""),
        "must not flip the marker to complete: {marker}"
    );
}

/// If the transcript sidecar is gone, a "complete" marker must not omit the
/// bak — that file is then the only copy of recovered history.
#[tokio::test]
async fn mdk08_account_backup_keeps_bak_when_transcript_is_missing() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("marmot.sqlite");
    let alice = Identity::generate();
    let bob = Identity::generate();
    let event_id = nostr::EventId::from_slice(&[0xABu8; 32]).expect("event id");
    let group_id = vec![0x11u8; 16];
    {
        let conn = rusqlite::Connection::open(&db_path).expect("open 0.8 file");
        let hex_key = DB_KEY
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>();
        conn.execute_batch(&format!("PRAGMA key = \"x'{hex_key}'\";"))
            .expect("0.8 raw key");
        conn.execute_batch(
            "CREATE TABLE groups (
                mls_group_id BLOB PRIMARY KEY,
                nostr_group_id BLOB NOT NULL,
                name TEXT NOT NULL,
                description TEXT NOT NULL
            );
            CREATE TABLE messages (
                mls_group_id BLOB NOT NULL,
                id BLOB NOT NULL,
                pubkey BLOB NOT NULL,
                kind INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                content TEXT NOT NULL,
                tags TEXT NOT NULL,
                event TEXT NOT NULL,
                wrapper_event_id BLOB NOT NULL,
                state TEXT NOT NULL,
                PRIMARY KEY (mls_group_id, id)
            );",
        )
        .expect("0.8 schema");
        conn.execute(
            "INSERT INTO groups (mls_group_id, nostr_group_id, name, description)
             VALUES (?1, ?2, 'alice & bob', 'sonar.direct-dm.v1')",
            rusqlite::params![group_id.clone(), vec![0x22u8; 32]],
        )
        .expect("group row");
        conn.execute(
            "INSERT INTO messages
                (mls_group_id, id, pubkey, kind, created_at, content, tags, event,
                 wrapper_event_id, state)
             VALUES (?1, ?2, ?3, 9, 1_700_000_000, 'keep this chat', '[]', '{}', ?2, 'processed')",
            rusqlite::params![
                group_id.clone(),
                event_id.as_bytes().to_vec(),
                bob.public_key().to_bytes().to_vec(),
            ],
        )
        .expect("chat row");
    }

    let engine =
        MarmotEngine::persistent(alice.clone(), &db_path, DB_KEY).expect("0.8 store must migrate");
    drop(engine);
    std::fs::remove_file(db_path.with_file_name("marmot.sqlite.sonar-transcript.json"))
        .expect("drop transcript");

    let key_hex = DB_KEY
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<String>();
    let package = sonar_core::account_backup::read_account_backup_package(&db_path, &key_hex)
        .expect("backup must fall back to the quarantined bak");
    assert!(
        package
            .sidecar_files
            .iter()
            .any(|(name, bytes)| name == ".mdk08.bak" && !bytes.is_empty()),
        "without a transcript the bak is the last copy of recovered history"
    );

    let restore_dir = tempfile::tempdir().expect("restore dir");
    let restore_path = restore_dir.path().join("marmot.sqlite");
    sonar_core::account_backup::write_account_backup_package(&restore_path, &package)
        .expect("restore package");
    let restored = MarmotEngine::persistent(alice, &restore_path, DB_KEY)
        .expect("restored 0.9 store plus bak");
    let gid = sonar_core::GroupId::new(group_id);
    let recovered = restored
        .messages(&gid)
        .expect("re-copy from bak after transcript loss");
    assert_eq!(recovered.len(), 1);
    assert_eq!(recovered[0].id, event_id);
    assert_eq!(recovered[0].content, "keep this chat");
}

/// A v1-shaped backup taken *before* the 0.8 → 0.9 migrate is only the
/// SQLCipher file. Restoring it onto this build must run decrypt-and-move
/// again so the user still has the transcript.
#[tokio::test]
async fn mdk08_v1_backup_restores_and_migrates() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("marmot.sqlite");
    let alice = Identity::generate();
    let bob = Identity::generate();
    let event_id = nostr::EventId::from_slice(&[0xABu8; 32]).expect("event id");
    let group_id = vec![0x11u8; 16];

    {
        let conn = rusqlite::Connection::open(&db_path).expect("open 0.8 file");
        let hex_key = DB_KEY
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>();
        conn.execute_batch(&format!("PRAGMA key = \"x'{hex_key}'\";"))
            .expect("0.8 raw key");
        conn.execute_batch(
            "CREATE TABLE groups (
                mls_group_id BLOB PRIMARY KEY,
                nostr_group_id BLOB NOT NULL,
                name TEXT NOT NULL,
                description TEXT NOT NULL
            );
            CREATE TABLE messages (
                mls_group_id BLOB NOT NULL,
                id BLOB NOT NULL,
                pubkey BLOB NOT NULL,
                kind INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                content TEXT NOT NULL,
                tags TEXT NOT NULL,
                event TEXT NOT NULL,
                wrapper_event_id BLOB NOT NULL,
                state TEXT NOT NULL,
                PRIMARY KEY (mls_group_id, id)
            );",
        )
        .expect("0.8 schema");
        conn.execute(
            "INSERT INTO groups (mls_group_id, nostr_group_id, name, description)
             VALUES (?1, ?2, 'alice & bob', 'sonar.direct-dm.v1')",
            rusqlite::params![group_id.clone(), vec![0x22u8; 32]],
        )
        .expect("group row");
        conn.execute(
            "INSERT INTO messages
                (mls_group_id, id, pubkey, kind, created_at, content, tags, event,
                 wrapper_event_id, state)
             VALUES (?1, ?2, ?3, 9, 1_700_000_000, 'keep this chat', '[]', '{}', ?2, 'processed')",
            rusqlite::params![
                group_id.clone(),
                event_id.as_bytes().to_vec(),
                bob.public_key().to_bytes().to_vec(),
            ],
        )
        .expect("chat row");
    }

    let key_hex = DB_KEY
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<String>();
    let package = sonar_core::account_backup::read_account_backup_package(&db_path, &key_hex)
        .expect("pre-upgrade 0.8 store must seal under the raw key");
    assert!(
        package.sidecar_files.is_empty(),
        "a backup taken before migrate has no recovered-chat sidecars"
    );

    let restore_dir = tempfile::tempdir().expect("restore dir");
    let restore_path = restore_dir.path().join("marmot.sqlite");
    sonar_core::account_backup::write_account_backup_package(&restore_path, &package)
        .expect("restore v1-shaped 0.8 package");
    let restored = MarmotEngine::persistent(alice, &restore_path, DB_KEY)
        .expect("restored 0.8 file must decrypt-and-move on this build");
    let recovered = restored
        .messages(&sonar_core::GroupId::new(group_id))
        .expect("transcript after v1 restore + migrate");
    assert_eq!(recovered.len(), 1);
    assert_eq!(recovered[0].id, event_id);
    assert_eq!(recovered[0].content, "keep this chat");
}

#[tokio::test]
async fn mdk08_first_paint_defers_older_rows_until_remainder() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("marmot.sqlite");
    let alice = Identity::generate();
    let bob = Identity::generate();
    let group_id = vec![0x11u8; 16];
    let total = 530usize;
    {
        let conn = rusqlite::Connection::open(&db_path).expect("open 0.8 file");
        let hex_key = DB_KEY
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>();
        conn.execute_batch(&format!("PRAGMA key = \"x'{hex_key}'\";"))
            .expect("0.8 raw key");
        conn.execute_batch(
            "CREATE TABLE groups (
                mls_group_id BLOB PRIMARY KEY,
                nostr_group_id BLOB NOT NULL,
                name TEXT NOT NULL,
                description TEXT NOT NULL
            );
            CREATE TABLE messages (
                mls_group_id BLOB NOT NULL,
                id BLOB NOT NULL,
                pubkey BLOB NOT NULL,
                kind INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                content TEXT NOT NULL,
                tags TEXT NOT NULL,
                event TEXT NOT NULL,
                wrapper_event_id BLOB NOT NULL,
                state TEXT NOT NULL,
                PRIMARY KEY (mls_group_id, id)
            );",
        )
        .expect("0.8 schema");
        conn.execute(
            "INSERT INTO groups (mls_group_id, nostr_group_id, name, description)
             VALUES (?1, ?2, 'alice & bob', 'sonar.direct-dm.v1')",
            rusqlite::params![group_id.clone(), vec![0x22u8; 32]],
        )
        .expect("group row");
        for i in 0..total {
            let mut id = [0u8; 32];
            id[0] = (i / 256) as u8;
            id[1] = (i % 256) as u8;
            conn.execute(
                "INSERT INTO messages
                    (mls_group_id, id, pubkey, kind, created_at, content, tags, event,
                     wrapper_event_id, state)
                 VALUES (?1, ?2, ?3, 9, ?4, ?5, '[]', '{}', ?2, 'processed')",
                rusqlite::params![
                    group_id.clone(),
                    id.to_vec(),
                    bob.public_key().to_bytes().to_vec(),
                    1_700_000_000 + i as i64,
                    format!("row-{i}"),
                ],
            )
            .expect("chat row");
        }
    }

    let engine =
        MarmotEngine::persistent(alice.clone(), &db_path, DB_KEY).expect("0.8 store must migrate");
    assert!(
        engine.has_pending_mdk08_remainder(),
        "older rows stay in the bak until remainder"
    );
    let gid = sonar_core::GroupId::new(group_id.clone());
    let page = engine.messages_page(&gid, 40, 0).expect("first-paint page");
    assert_eq!(page.len(), 40);
    assert_eq!(page[0].content, "row-529", "newest row must paint first");
    assert!(
        engine.has_pending_mdk08_remainder(),
        "a bounded page must not force the remainder"
    );

    let window = engine
        .messages_page(&gid, 80, 0)
        .expect("first-paint window");
    assert_eq!(window.len(), 80);
    let oldest_window = window.last().expect("oldest first-paint row");
    let older = engine
        .messages_cursor_page(
            &gid,
            Some(oldest_window.created_at.as_secs()),
            Some(&oldest_window.id),
            10,
        )
        .expect("scroll-up must copy leftover bak rows");
    assert_eq!(older.len(), 10);
    assert_eq!(older[0].content, "row-449");
    assert!(
        engine.has_pending_mdk08_remainder(),
        "filling one older page must not drain the rest of the bak"
    );

    let all = engine.messages(&gid).expect("full history after remainder");
    assert_eq!(all.len(), total);
    assert_eq!(all[0].content, "row-0");
    assert_eq!(all[total - 1].content, "row-529");
    assert!(!engine.has_pending_mdk08_remainder());
}

/// Leave/delete clears the transcript but leaves `*.mdk08.bak` intact. A later
/// remainder tick (idle sync or `messages()` on any other chat) must not copy
/// those rows back onto a dropped group.
#[tokio::test]
async fn delete_then_remainder_does_not_restore_transcript() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("marmot.sqlite");
    let alice = Identity::generate();
    let bob = Identity::generate();
    let keep_id = vec![0x11u8; 16];
    let gone_id = vec![0x33u8; 16];
    let per_group = 90usize;
    {
        let conn = rusqlite::Connection::open(&db_path).expect("open 0.8 file");
        let hex_key = DB_KEY
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>();
        conn.execute_batch(&format!("PRAGMA key = \"x'{hex_key}'\";"))
            .expect("0.8 raw key");
        conn.execute_batch(
            "CREATE TABLE groups (
                mls_group_id BLOB PRIMARY KEY,
                nostr_group_id BLOB NOT NULL,
                name TEXT NOT NULL,
                description TEXT NOT NULL
            );
            CREATE TABLE messages (
                mls_group_id BLOB NOT NULL,
                id BLOB NOT NULL,
                pubkey BLOB NOT NULL,
                kind INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                content TEXT NOT NULL,
                tags TEXT NOT NULL,
                event TEXT NOT NULL,
                wrapper_event_id BLOB NOT NULL,
                state TEXT NOT NULL,
                PRIMARY KEY (mls_group_id, id)
            );",
        )
        .expect("0.8 schema");
        conn.execute(
            "INSERT INTO groups (mls_group_id, nostr_group_id, name, description)
             VALUES (?1, ?2, 'keep', 'sonar.direct-dm.v1'),
                    (?3, ?4, 'deleted room', '')",
            rusqlite::params![
                keep_id.clone(),
                vec![0x22u8; 32],
                gone_id.clone(),
                vec![0x44u8; 32],
            ],
        )
        .expect("group rows");
        for i in 0..per_group {
            let mut keep_msg = [0u8; 32];
            keep_msg[0] = 0xA0;
            keep_msg[1] = i as u8;
            conn.execute(
                "INSERT INTO messages
                    (mls_group_id, id, pubkey, kind, created_at, content, tags, event,
                     wrapper_event_id, state)
                 VALUES (?1, ?2, ?3, 9, ?4, ?5, '[]', '{}', ?2, 'processed')",
                rusqlite::params![
                    keep_id.clone(),
                    keep_msg.to_vec(),
                    bob.public_key().to_bytes().to_vec(),
                    1_700_000_000 + i as i64,
                    format!("keep-{i}"),
                ],
            )
            .expect("keep row");
            let mut gone_msg = [0u8; 32];
            gone_msg[0] = 0xB0;
            gone_msg[1] = i as u8;
            conn.execute(
                "INSERT INTO messages
                    (mls_group_id, id, pubkey, kind, created_at, content, tags, event,
                     wrapper_event_id, state)
                 VALUES (?1, ?2, ?3, 9, ?4, ?5, '[]', '{}', ?2, 'processed')",
                rusqlite::params![
                    gone_id.clone(),
                    gone_msg.to_vec(),
                    bob.public_key().to_bytes().to_vec(),
                    1_800_000_000 + i as i64,
                    format!("gone-{i}"),
                ],
            )
            .expect("gone row");
        }
    }

    let engine =
        MarmotEngine::persistent(alice.clone(), &db_path, DB_KEY).expect("0.8 store must migrate");
    assert!(engine.has_pending_mdk08_remainder());
    let keep = GroupId::new(keep_id);
    let gone = GroupId::new(gone_id);
    engine.purge_fold_family(&gone);
    assert!(
        engine.messages(&gone).expect("deleted chat").is_empty(),
        "Leave must not let messages() drain bak rows back onto the dropped id"
    );
    let kept = engine
        .messages(&keep)
        .expect("other recovered chat must still drain");
    assert_eq!(kept.len(), per_group);
    assert!(kept.iter().all(|m| m.content.starts_with("keep-")));
    assert!(
        engine
            .messages(&gone)
            .expect("deleted after drain")
            .is_empty(),
        "draining another chat must not resurrect the left conversation"
    );
    assert!(
        engine
            .historical_groups()
            .expect("historical groups")
            .iter()
            .all(|g| g.id != gone),
        "dropped recovered row must stay unlistable"
    );
    assert!(
        db_path.with_file_name("marmot.sqlite.mdk08.bak").exists(),
        "quarantine stays on disk; remainder just refuses to copy dropped ids"
    );
    drop(engine);

    let reopened = MarmotEngine::persistent(alice, &db_path, DB_KEY).expect("reopen after Leave");
    assert!(
        reopened.messages(&gone).expect("reopen deleted").is_empty(),
        "cold start must not copy dropped bak rows back into the transcript"
    );
    assert_eq!(
        reopened.messages(&keep).expect("reopen keep").len(),
        per_group
    );
}

/// A 0.8-shaped store with the wrong host key must stay on disk and must not
/// be treated as a migratable store (Account Key Durability).
#[tokio::test]
async fn mdk08_store_wrong_key_is_left_intact() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("marmot.sqlite");
    {
        let conn = rusqlite::Connection::open(&db_path).expect("open");
        let hex_key = DB_KEY
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>();
        conn.execute_batch(&format!("PRAGMA key = \"x'{hex_key}'\";"))
            .expect("0.8 raw key");
        conn.execute_batch("CREATE TABLE messages (id BLOB PRIMARY KEY);")
            .expect("schema");
    }
    let result = MarmotEngine::persistent(Identity::generate(), &db_path, [0x13; 32]);
    assert!(result.is_err(), "wrong key must fail");
    let err = result.err().expect("error").to_string();
    assert!(
        err.contains("protocol migration required"),
        "wrong key is not a successful migrate: {err}"
    );
    assert!(db_path.exists(), "wrong key must not wipe the 0.8 store");
    assert!(
        !db_path.with_file_name("marmot.sqlite.mdk08.bak").exists(),
        "wrong key must not quarantine the store"
    );
}

/// A pending 0.8 welcome cannot be ingested (0.8 wire), but the room name
/// and welcomer must still list so the user can resume on a new 0.9 group.
#[tokio::test]
async fn mdk08_pending_welcome_is_listed_for_resume() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("marmot.sqlite");
    let alice = Identity::generate();
    let welcomer = Identity::generate();
    let group_id = vec![0x77u8; 16];

    {
        let conn = rusqlite::Connection::open(&db_path).expect("open 0.8 file");
        let hex_key = DB_KEY
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>();
        conn.execute_batch(&format!("PRAGMA key = \"x'{hex_key}'\";"))
            .expect("0.8 raw key");
        conn.execute_batch(
            "CREATE TABLE messages (
                mls_group_id BLOB NOT NULL,
                id BLOB NOT NULL,
                pubkey BLOB NOT NULL,
                kind INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                content TEXT NOT NULL,
                tags TEXT NOT NULL,
                event TEXT NOT NULL,
                wrapper_event_id BLOB NOT NULL,
                state TEXT NOT NULL,
                PRIMARY KEY (mls_group_id, id)
            );
            CREATE TABLE welcomes (
                id BLOB PRIMARY KEY,
                event TEXT NOT NULL,
                mls_group_id BLOB NOT NULL,
                nostr_group_id BLOB NOT NULL,
                group_name TEXT NOT NULL,
                group_description TEXT NOT NULL,
                group_admin_pubkeys TEXT NOT NULL,
                group_relays TEXT NOT NULL,
                welcomer BLOB NOT NULL,
                member_count INTEGER NOT NULL,
                state TEXT NOT NULL,
                wrapper_event_id BLOB NOT NULL
            );",
        )
        .expect("0.8 schema");
        let admins =
            serde_json::json!([alice.public_key().to_hex(), welcomer.public_key().to_hex()])
                .to_string();
        conn.execute(
            "INSERT INTO welcomes
                (id, event, mls_group_id, nostr_group_id, group_name, group_description,
                 group_admin_pubkeys, group_relays, welcomer, member_count, state,
                 wrapper_event_id)
             VALUES (?1, '{}', ?2, ?3, 'pending room', '', ?4, '[]', ?5, 3, 'pending', ?1)",
            rusqlite::params![
                vec![0xAAu8; 32],
                group_id.clone(),
                vec![0xBBu8; 32],
                admins,
                welcomer.public_key().to_bytes().to_vec(),
            ],
        )
        .expect("pending welcome");
    }

    let engine = MarmotEngine::persistent(alice.clone(), &db_path, DB_KEY)
        .expect("pending welcome store must migrate");
    let gid = GroupId::new(group_id.clone());
    let listed = engine
        .historical_groups()
        .expect("pending welcome must list");
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].id, gid);
    assert_eq!(listed[0].name, "pending room");
    assert!(
        listed[0].members.contains(&welcomer.public_key()),
        "welcomer must be a resume peer"
    );

    let index = sonar_core::conversation_index::ConversationIndex::open_in_memory().expect("index");
    index.materialize_from(&engine).expect("seed pending room");
    let summaries = index.summaries_ordered().expect("summaries");
    assert_eq!(summaries.len(), 1);
    assert_eq!(summaries[0].name, "pending room");
    drop(engine);

    let key_hex = DB_KEY
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<String>();
    let package = sonar_core::account_backup::read_account_backup_package(&db_path, &key_hex)
        .expect("post-migrate backup");
    assert!(
        package
            .sidecar_files
            .iter()
            .any(|(name, bytes)| { name == ".sonar-historical-groups.json" && !bytes.is_empty() }),
        "pending welcome name must travel with the account backup"
    );
    assert!(
        package
            .sidecar_files
            .iter()
            .any(|(name, bytes)| { name == ".sonar-historical-members.json" && !bytes.is_empty() }),
        "pending welcome members must travel with the account backup"
    );

    let restore_dir = tempfile::tempdir().expect("restore dir");
    let restore_path = restore_dir.path().join("marmot.sqlite");
    sonar_core::account_backup::write_account_backup_package(&restore_path, &package)
        .expect("restore package");
    let restored = MarmotEngine::persistent(alice, &restore_path, DB_KEY)
        .expect("restored store plus pending welcome");
    let listed = restored
        .historical_groups()
        .expect("pending welcome must survive nsec restore");
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].name, "pending room");
    assert!(listed[0].members.contains(&welcomer.public_key()));
}

/// A joined 0.8 named room with only one known peer must stay a room.
/// `member_count` is not on the groups table; the name (and empty
/// non-DM description) is the signal that matches live `group_is_direct`.
#[tokio::test]
async fn mdk08_named_room_with_one_known_peer_is_not_direct() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("marmot.sqlite");
    let alice = Identity::generate();
    let bob = Identity::generate();
    let group_id = vec![0x91u8; 16];

    {
        let conn = rusqlite::Connection::open(&db_path).expect("open 0.8 file");
        let hex_key = DB_KEY
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>();
        conn.execute_batch(&format!("PRAGMA key = \"x'{hex_key}'\";"))
            .expect("0.8 raw key");
        conn.execute_batch(
            "CREATE TABLE groups (
                mls_group_id BLOB PRIMARY KEY,
                nostr_group_id BLOB NOT NULL,
                name TEXT NOT NULL,
                description TEXT NOT NULL
            );
            CREATE TABLE messages (
                mls_group_id BLOB NOT NULL,
                id BLOB NOT NULL,
                pubkey BLOB NOT NULL,
                kind INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                content TEXT NOT NULL,
                tags TEXT NOT NULL,
                event TEXT NOT NULL,
                wrapper_event_id BLOB NOT NULL,
                state TEXT NOT NULL,
                PRIMARY KEY (mls_group_id, id)
            );",
        )
        .expect("0.8 schema");
        conn.execute(
            "INSERT INTO groups (mls_group_id, nostr_group_id, name, description)
             VALUES (?1, ?2, 'weekend hike', '')",
            rusqlite::params![group_id.clone(), vec![0x92u8; 32]],
        )
        .expect("group row");
        conn.execute(
            "INSERT INTO messages
                (mls_group_id, id, pubkey, kind, created_at, content, tags, event,
                 wrapper_event_id, state)
             VALUES (?1, ?2, ?3, 9, 1_700_000_000, 'only bob spoke', '[]', '{}', ?2, 'processed')",
            rusqlite::params![
                group_id.clone(),
                vec![0xABu8; 32],
                bob.public_key().to_bytes().to_vec(),
            ],
        )
        .expect("chat row");
    }

    let engine =
        MarmotEngine::persistent(alice.clone(), &db_path, DB_KEY).expect("named room must migrate");
    let gid = GroupId::new(group_id);
    assert!(
        !engine.historical_resume_is_direct(&gid),
        "named joined room must not resume as start_dm when only one peer is known"
    );
    assert_eq!(
        engine.historical_group_name(&gid).as_deref(),
        Some("weekend hike")
    );
    assert_eq!(engine.historical_group_description(&gid), None);
    drop(engine);

    let key_hex = DB_KEY
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<String>();
    let package = sonar_core::account_backup::read_account_backup_package(&db_path, &key_hex)
        .expect("post-migrate backup");
    let restore_dir = tempfile::tempdir().expect("restore dir");
    let restore_path = restore_dir.path().join("marmot.sqlite");
    sonar_core::account_backup::write_account_backup_package(&restore_path, &package)
        .expect("restore package");
    let restored = MarmotEngine::persistent(alice, &restore_path, DB_KEY)
        .expect("named room must survive nsec restore");
    assert!(
        !restored.historical_resume_is_direct(&gid),
        "nsec restore must keep a named room off start_dm"
    );
}

/// Labeled 0.8 `encrypted-media` exporter secrets must decrypt recovered
/// MIP-04 blobs after migrate and after nsec restore.
#[tokio::test]
async fn mdk08_media_exporter_secret_survives_migrate_and_backup() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("marmot.sqlite");
    let alice = Identity::generate();
    let bob = Identity::generate();
    let group_id = vec![0x88u8; 16];
    let secret = vec![0xABu8; 32];
    let url = "https://blossom.example/old.bin";
    let upload = sonar_core::media_crypto::encrypt_for_upload(
        &secret,
        b"photo-bytes",
        "image/jpeg",
        "old.jpg",
    )
    .expect("encrypt recovered blob");
    let tags = serde_json::json!([[
        "imeta",
        format!("url {url}"),
        "m image/jpeg",
        "filename old.jpg",
        format!(
            "x {}",
            upload
                .original_hash
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect::<String>()
        ),
        format!(
            "n {}",
            upload
                .nonce
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect::<String>()
        ),
        "v mip04-v2"
    ]])
    .to_string();

    {
        let conn = rusqlite::Connection::open(&db_path).expect("open 0.8 file");
        let hex_key = DB_KEY
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>();
        conn.execute_batch(&format!("PRAGMA key = \"x'{hex_key}'\";"))
            .expect("0.8 raw key");
        conn.execute_batch(
            "CREATE TABLE groups (
                mls_group_id BLOB PRIMARY KEY,
                nostr_group_id BLOB NOT NULL,
                name TEXT NOT NULL,
                description TEXT NOT NULL
            );
            CREATE TABLE messages (
                mls_group_id BLOB NOT NULL,
                id BLOB NOT NULL,
                pubkey BLOB NOT NULL,
                kind INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                content TEXT NOT NULL,
                tags TEXT NOT NULL,
                event TEXT NOT NULL,
                wrapper_event_id BLOB NOT NULL,
                state TEXT NOT NULL,
                PRIMARY KEY (mls_group_id, id)
            );
            CREATE TABLE group_exporter_secrets (
                mls_group_id BLOB NOT NULL,
                epoch INTEGER NOT NULL,
                label TEXT NOT NULL,
                secret BLOB NOT NULL,
                PRIMARY KEY (mls_group_id, epoch, label)
            );",
        )
        .expect("0.8 schema");
        conn.execute(
            "INSERT INTO groups (mls_group_id, nostr_group_id, name, description)
             VALUES (?1, ?2, 'photo chat', '')",
            rusqlite::params![group_id.clone(), vec![0x99u8; 32]],
        )
        .expect("group row");
        conn.execute(
            "INSERT INTO messages
                (mls_group_id, id, pubkey, kind, created_at, content, tags, event,
                 wrapper_event_id, state)
             VALUES (?1, ?2, ?3, 9, 1_700_000_000, '', ?4, '{}', ?2, 'processed')",
            rusqlite::params![
                group_id.clone(),
                vec![0xABu8; 32],
                bob.public_key().to_bytes().to_vec(),
                tags,
            ],
        )
        .expect("media row");
        conn.execute(
            "INSERT INTO group_exporter_secrets (mls_group_id, epoch, label, secret)
             VALUES (?1, 1, 'encrypted-media', ?2), (?1, 1, 'group-event', ?3)",
            rusqlite::params![group_id.clone(), secret.clone(), vec![0xEFu8; 32]],
        )
        .expect("exporter rows");
    }

    let engine = MarmotEngine::persistent(alice.clone(), &db_path, DB_KEY)
        .expect("0.8 store with media secrets must migrate");
    let gid = GroupId::new(group_id.clone());
    assert!(
        !engine.recovered_08_media_unavailable(&gid, url),
        "labeled exporter secret must make the blob openable"
    );
    let plain = engine
        .decrypt_media_by_url(&gid, url, &upload.encrypted_data)
        .expect("stored 0.8 exporter must open the blob after migrate");
    assert_eq!(plain, b"photo-bytes");
    drop(engine);

    let key_hex = DB_KEY
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<String>();
    let package = sonar_core::account_backup::read_account_backup_package(&db_path, &key_hex)
        .expect("post-migrate backup");
    assert!(
        package.sidecar_files.iter().any(|(name, bytes)| {
            name == ".sonar-historical-exporter-secrets.json" && !bytes.is_empty()
        }),
        "MIP-04 secrets must travel with the account backup"
    );

    let restore_dir = tempfile::tempdir().expect("restore dir");
    let restore_path = restore_dir.path().join("marmot.sqlite");
    sonar_core::account_backup::write_account_backup_package(&restore_path, &package)
        .expect("restore package");
    let restored = MarmotEngine::persistent(alice, &restore_path, DB_KEY)
        .expect("restored store plus media secrets");
    let plain = restored
        .decrypt_media_by_url(&gid, url, &upload.encrypted_data)
        .expect("restored exporter must still open the blob");
    assert_eq!(plain, b"photo-bytes");
}

/// An earlier 0.9 open may have quarantined the 0.8 file before welcomes
/// and labeled media secrets were copied. The next open must backfill
/// those from `*.mdk08.bak` without waiting for a remainder tick.
#[tokio::test]
async fn mdk08_bak_backfills_welcome_and_media_secrets_on_reopen() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("marmot.sqlite");
    let alice = Identity::generate();
    let welcomer = Identity::generate();
    let bob = Identity::generate();
    let chat_id = vec![0x11u8; 16];
    let welcome_id = vec![0x77u8; 16];
    let secret = vec![0xABu8; 32];
    let url = "https://blossom.example/old.bin";
    let upload = sonar_core::media_crypto::encrypt_for_upload(
        &secret,
        b"photo-bytes",
        "image/jpeg",
        "old.jpg",
    )
    .expect("encrypt");
    let tags = serde_json::json!([[
        "imeta",
        format!("url {url}"),
        "m image/jpeg",
        "filename old.jpg",
        format!(
            "x {}",
            upload
                .original_hash
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect::<String>()
        ),
        format!(
            "n {}",
            upload
                .nonce
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect::<String>()
        ),
        "v mip04-v2"
    ]])
    .to_string();

    {
        let conn = rusqlite::Connection::open(&db_path).expect("open 0.8 file");
        let hex_key = DB_KEY
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>();
        conn.execute_batch(&format!("PRAGMA key = \"x'{hex_key}'\";"))
            .expect("0.8 raw key");
        conn.execute_batch(
            "CREATE TABLE groups (
                mls_group_id BLOB PRIMARY KEY,
                nostr_group_id BLOB NOT NULL,
                name TEXT NOT NULL,
                description TEXT NOT NULL
            );
            CREATE TABLE messages (
                mls_group_id BLOB NOT NULL,
                id BLOB NOT NULL,
                pubkey BLOB NOT NULL,
                kind INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                content TEXT NOT NULL,
                tags TEXT NOT NULL,
                event TEXT NOT NULL,
                wrapper_event_id BLOB NOT NULL,
                state TEXT NOT NULL,
                PRIMARY KEY (mls_group_id, id)
            );
            CREATE TABLE welcomes (
                id BLOB PRIMARY KEY,
                event TEXT NOT NULL,
                mls_group_id BLOB NOT NULL,
                nostr_group_id BLOB NOT NULL,
                group_name TEXT NOT NULL,
                group_description TEXT NOT NULL,
                group_admin_pubkeys TEXT NOT NULL,
                group_relays TEXT NOT NULL,
                welcomer BLOB NOT NULL,
                member_count INTEGER NOT NULL,
                state TEXT NOT NULL,
                wrapper_event_id BLOB NOT NULL
            );
            CREATE TABLE group_exporter_secrets (
                mls_group_id BLOB NOT NULL,
                epoch INTEGER NOT NULL,
                label TEXT NOT NULL,
                secret BLOB NOT NULL,
                PRIMARY KEY (mls_group_id, epoch, label)
            );",
        )
        .expect("0.8 schema");
        conn.execute(
            "INSERT INTO groups (mls_group_id, nostr_group_id, name, description)
             VALUES (?1, ?2, 'alice & bob', 'sonar.direct-dm.v1')",
            rusqlite::params![chat_id.clone(), vec![0x22u8; 32]],
        )
        .expect("group");
        conn.execute(
            "INSERT INTO messages
                (mls_group_id, id, pubkey, kind, created_at, content, tags, event,
                 wrapper_event_id, state)
             VALUES (?1, ?2, ?3, 9, 1_700_000_000, '', ?4, '{}', ?2, 'processed')",
            rusqlite::params![
                chat_id.clone(),
                vec![0xABu8; 32],
                bob.public_key().to_bytes().to_vec(),
                tags,
            ],
        )
        .expect("media row");
        let admins =
            serde_json::json!([alice.public_key().to_hex(), welcomer.public_key().to_hex()])
                .to_string();
        conn.execute(
            "INSERT INTO welcomes
                (id, event, mls_group_id, nostr_group_id, group_name, group_description,
                 group_admin_pubkeys, group_relays, welcomer, member_count, state,
                 wrapper_event_id)
             VALUES (?1, '{}', ?2, ?3, 'pending room', '', ?4, '[]', ?5, 3, 'pending', ?1)",
            rusqlite::params![
                vec![0xAAu8; 32],
                welcome_id.clone(),
                vec![0xBBu8; 32],
                admins,
                welcomer.public_key().to_bytes().to_vec(),
            ],
        )
        .expect("pending welcome");
        conn.execute(
            "INSERT INTO group_exporter_secrets (mls_group_id, epoch, label, secret)
             VALUES (?1, 1, 'encrypted-media', ?2)",
            rusqlite::params![chat_id.clone(), secret.clone()],
        )
        .expect("media secret");
    }

    let engine = MarmotEngine::persistent(alice.clone(), &db_path, DB_KEY).expect("first migrate");
    drop(engine);

    std::fs::remove_file(
        db_path.with_file_name("marmot.sqlite.sonar-historical-exporter-secrets.json"),
    )
    .expect("drop secrets sidecar to simulate a pre-welcome extract");
    let _ = std::fs::remove_file(
        db_path.with_file_name("marmot.sqlite.sonar-historical-member-counts.json"),
    );
    let _ = std::fs::remove_file(
        db_path.with_file_name("marmot.sqlite.sonar-historical-descriptions.json"),
    );
    let chat_hex = chat_id
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<String>();
    std::fs::write(
        db_path.with_file_name("marmot.sqlite.sonar-historical-groups.json"),
        format!("{{\"{chat_hex}\":\"alice & bob\"}}"),
    )
    .expect("keep only the chat name");
    std::fs::write(
        db_path.with_file_name("marmot.sqlite.sonar-historical-members.json"),
        format!("{{\"{chat_hex}\":[\"{}\"]}}", bob.public_key().to_hex()),
    )
    .expect("keep only the chat peer");
    std::fs::write(
        db_path.with_file_name("marmot.sqlite.sonar-mdk08-migrated.json"),
        serde_json::json!({ "status": "complete", "from": "mdk-0.8" }).to_string(),
    )
    .expect("old marker without metadata_backfill");

    // Real upgraded installs already have a conversation-index file. Seed only
    // the chat that the old extract knew about so connect() has to
    // seed_missing_recovered — not materialize_from on an empty index.
    let index_path = sonar_core::conversation_index::index_db_path_for_db(&db_path);
    let index = sonar_core::conversation_index::ConversationIndex::open(&index_path, DB_KEY)
        .expect("0.8-era index");
    index
        .upsert_summary(
            &chat_hex,
            "alice & bob",
            "photo",
            &bob.public_key().to_string(),
            1_700_000_000,
            false,
            true,
        )
        .expect("existing chat row");
    drop(index);

    let key_hex = DB_KEY
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<String>();
    let package = sonar_core::account_backup::read_account_backup_package(&db_path, &key_hex)
        .expect("early-0.9 backup must still pack the bak");
    assert!(
        package
            .sidecar_files
            .iter()
            .any(|(name, _)| name == ".mdk08.bak"),
        "metadata_backfill is not complete; restore needs the bak: {:?}",
        package
            .sidecar_files
            .iter()
            .map(|(name, _)| name.as_str())
            .collect::<Vec<_>>()
    );
    let preview = sonar_core::account_backup::preview_conversations(&db_path, &package);
    assert!(
        preview.iter().any(|c| c.name == "pending room"),
        "Settings preview must list a bak-only invite: {preview:?}"
    );

    let restore_dir = tempfile::tempdir().expect("restore dir");
    let restore_path = restore_dir.path().join("marmot.sqlite");
    // Hosts stage via restore_account_from_blossom, then commit_account_restore.
    let mut staged = restore_path.as_os_str().to_owned();
    staged.push(".sonar-restore-staging");
    let staged = std::path::PathBuf::from(staged);
    sonar_core::account_backup::write_account_backup_package(&staged, &package)
        .expect("host stages beside the live path");
    sonar_core::account_backup::commit_staged_account_restore(&restore_path)
        .expect("commit_account_restore must promote the packed bak");
    assert!(
        restore_path
            .with_file_name("marmot.sqlite.mdk08.bak")
            .exists(),
        "staged restore must rename the bak onto the live store"
    );
    let restored = SonarClient::connect(alice.clone(), Vec::new(), &restore_path, DB_KEY)
        .await
        .expect("restore connectLocal must backfill from the packed bak");
    let welcome = GroupId::new(welcome_id.clone());
    let restored_listed = restored
        .historical_groups()
        .expect("list after nsec restore");
    let restored_welcome = restored_listed
        .iter()
        .find(|g| g.id == welcome && g.name == "pending room")
        .expect("pending welcome must survive nsec restore from bak");
    assert!(
        restored_welcome
            .members
            .iter()
            .any(|pk| *pk == welcomer.public_key()),
        "restored invite must still have a resume peer: {restored_welcome:?}"
    );
    assert!(
        !restored.engine().historical_resume_is_direct(&welcome),
        "restored 3-member pending room must not resume as a DM"
    );
    let restored_summaries = restored.conversation_summaries();
    let restored_chat = restored_summaries
        .iter()
        .find(|s| s.name == "alice & bob")
        .expect("restored upgraded chat row must stay");
    assert_eq!(
        restored_chat.unread_count, 1,
        "nsec restore must not reset unread: {restored_chat:?}"
    );
    assert!(
        restored_summaries.iter().any(|s| s.name == "pending room"),
        "nsec restore must seed the invite onto the home list: {restored_summaries:?}"
    );
    let chat = GroupId::new(chat_id.clone());
    let restored_plain = restored
        .engine()
        .decrypt_media_by_url(&chat, url, &upload.encrypted_data)
        .expect("labeled secret must survive nsec restore from bak");
    assert_eq!(restored_plain, b"photo-bytes");
    drop(restored);

    let client = SonarClient::connect(alice, Vec::new(), &db_path, DB_KEY)
        .await
        .expect("connectLocal must backfill then seed the chat list");
    let welcome = GroupId::new(welcome_id);
    let listed = client.historical_groups().expect("list after backfill");
    let welcome_row = listed
        .iter()
        .find(|g| g.id == welcome && g.name == "pending room")
        .expect("pending welcome must come back from the quarantined bak");
    assert!(
        welcome_row
            .members
            .iter()
            .any(|pk| *pk == welcomer.public_key()),
        "backfill must restore the welcomer so resume has a peer: {welcome_row:?}"
    );
    assert!(
        !client.engine().historical_resume_is_direct(&welcome),
        "a 3-member pending room must not resume as a DM"
    );
    let summaries = client.conversation_summaries();
    let chat_row = summaries
        .iter()
        .find(|s| s.name == "alice & bob")
        .expect("upgraded chat row must stay");
    assert_eq!(
        chat_row.unread_count, 1,
        "backfill must not reset unread on the existing index row: {chat_row:?}"
    );
    assert!(
        summaries.iter().any(|s| s.name == "pending room"),
        "connect() must seed the recovered invite onto the home list: {summaries:?}"
    );
    let chat = GroupId::new(chat_id);
    assert_eq!(
        client
            .engine()
            .historical_group_description(&chat)
            .as_deref(),
        Some("sonar.direct-dm.v1"),
        "v2 bak backfill must restore the DM description"
    );
    assert!(
        client.engine().historical_resume_is_direct(&chat),
        "a recovered DM must stay a DM after description backfill"
    );
    let plain = client
        .engine()
        .decrypt_media_by_url(&chat, url, &upload.encrypted_data)
        .expect("labeled secret must come back from the bak");
    assert_eq!(plain, b"photo-bytes");
}
