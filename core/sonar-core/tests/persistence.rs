//! Persistence integration test: prove that a SQLCipher-backed [`MarmotEngine`]
//! survives being dropped and reopened at the same path with the same key.
//!
//! No network: the engine layer is transport-free, so we exercise it directly.
//! Alice runs on the persistent engine; Bob is a throwaway in-memory engine that
//! only exists to mint a KeyPackage so Alice can form a real MLS group.

use mdk_core::prelude::GroupId;
use nostr::RelayUrl;
use sonar_core::client::SonarClient;
use sonar_core::identity::Identity;
use sonar_core::marmot::{DeliveryState, Incoming, MarmotEngine};
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
        alice
            .merge_pending_commit(&group_id)
            .expect("merge after simulated welcome delivery");

        // Send messages and process them back so they land in storage as "ours"
        // (mirrors what SonarClient::send_text does after publishing).
        let event = alice
            .create_text_message(&group_id, "persisted hello 1")
            .expect("create message");
        let processed = alice
            .process_incoming(&event)
            .await
            .expect("process own message");
        assert!(matches!(processed, Incoming::Message(_)));
        sleep(Duration::from_secs(1)).await;
        let event = alice
            .create_text_message(&group_id, "persisted hello 2")
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
            .expect("charlie key package");
        let update = alice
            .add_members(&group_id, vec![charlie_kp])
            .expect("add charlie");
        assert!(update.requires_commit_merge);
        alice
            .merge_pending_commit(&group_id)
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
    let reopened_id: GroupId = groups[0].mls_group_id.clone();
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
    let bob_kp = bob.key_package_event(relays()).expect("bob key package");

    let alice_identity = Identity::generate();
    let group_id = {
        let client = SonarClient::connect(alice_identity.clone(), Vec::new(), &db_path, DB_KEY)
            .await
            .expect("connect local-only client");
        let creation = client
            .engine()
            .create_group("alice & bob", vec![bob_kp], Vec::new())
            .expect("create local group");
        let group_id = creation.group.mls_group_id.clone();
        client
            .engine()
            .merge_pending_commit(&group_id)
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
    let bob_kp = bob.key_package_event(relays()).expect("bob key package");

    let alice_identity = Identity::generate();
    let (bob_message_secs, alice_later_secs) = {
        let alice = MarmotEngine::persistent(alice_identity.clone(), &db_path, DB_KEY)
            .expect("open persistent engine");
        let creation = alice
            .create_group("alice & bob", vec![bob_kp], relays())
            .expect("create group");
        let group_id = creation.group.mls_group_id.clone();

        let (bob_pubkey, bob_welcome) = creation
            .welcomes
            .into_iter()
            .find(|(pubkey, _)| *pubkey == bob.identity().public_key())
            .expect("bob welcome");
        let bob_wrapped = alice
            .gift_wrap_welcome(&bob_pubkey, bob_welcome)
            .await
            .expect("wrap bob welcome");
        assert!(matches!(
            bob.process_incoming(&bob_wrapped)
                .await
                .expect("bob processes welcome"),
            Incoming::GroupUpdated(_)
        ));
        alice
            .merge_pending_commit(&group_id)
            .expect("merge after simulated welcome delivery");

        let bob_group_id = bob.groups().expect("bob groups")[0].mls_group_id.clone();
        let bob_event = bob
            .create_text_message(&bob_group_id, "peer message while alice was offline")
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
        let bob_kp = bob.key_package_event(relays()).expect("bob key package");
        let creation = alice
            .create_group(&format!("chat {idx}"), vec![bob_kp], relays())
            .expect("create group");
        let group_id = creation.group.mls_group_id.clone();
        alice
            .merge_pending_commit(&group_id)
            .expect("merge after simulated welcome delivery");

        for msg_idx in 0..3 {
            let event = alice
                .create_text_message(&group_id, &format!("chat {idx} message {msg_idx}"))
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
        let _ = alice.key_package_event(relays()).expect("key package");
    }

    // A different key must fail to open the encrypted database.
    let wrong_key = [0x13; 32];
    let result = MarmotEngine::persistent(Identity::generate(), &db_path, wrong_key);
    assert!(result.is_err(), "wrong SQLCipher key must be rejected");
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
        let _ = alice.key_package_event(relays()).expect("key package");
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
    assert!(slot_path.exists(), "publishing a key package must create the slot");
    std::fs::write(&slot_tmp_path, "leftover").expect("stage a crashed rename");

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
        d_first = d_tag_of(&engine.key_package_event(relays()).expect("kp 1"));
        d_second = d_tag_of(&engine.key_package_event(relays()).expect("kp 2"));
    } // engine dropped: the process is "restarted" below.

    assert_eq!(
        d_first, d_second,
        "republishing must reuse the slot, not mint a second one"
    );

    // Reopen at the same path, as a relaunch does.
    // Same identity: the addressable coordinate is (kind, pubkey, d), so
    // reopening under a different pubkey would be a different slot regardless of
    // the d tag, and the assertion below would prove nothing.
    let reopened =
        MarmotEngine::persistent(identity, &db_path, DB_KEY).expect("reopen engine");
    let d_after_restart = d_tag_of(&reopened.key_package_event(relays()).expect("kp 3"));
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

    let d_a = d_tag_of(&a.key_package_event(relays()).expect("kp a"));
    let d_b = d_tag_of(&b.key_package_event(relays()).expect("kp b"));
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
    let d = d_tag_of(&engine.key_package_event(relays()).expect("kp"));
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
        std::fs::read_to_string(&slot_path).expect("slot rewritten").trim(),
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
        let engine = MarmotEngine::persistent(Identity::generate(), &db_path, DB_KEY)
            .expect("engine");
        engine.key_package_event(relays()).expect("kp");
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

    let engine =
        MarmotEngine::persistent(identity.clone(), &db_path, DB_KEY).expect("engine");
    let original = d_tag_of(&engine.key_package_event(relays()).expect("kp"));

    // New engine so the in-process memo cannot mask the read, then make the slot
    // unreadable the way a locked container would.
    drop(engine);
    let engine = MarmotEngine::persistent(identity, &db_path, DB_KEY).expect("reopen");
    std::fs::set_permissions(&slot_path, std::fs::Permissions::from_mode(0o000))
        .expect("chmod");

    let result = engine.key_package_event(relays());

    std::fs::set_permissions(&slot_path, std::fs::Permissions::from_mode(0o600))
        .expect("restore perms");
    assert!(
        result.is_err(),
        "an unreadable slot must fail the publish, not silently pick another slot"
    );
    assert_eq!(
        std::fs::read_to_string(&slot_path).expect("slot readable again").trim(),
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

    let engine =
        MarmotEngine::persistent(identity, dir.path().join("marmot.sqlite"), DB_KEY)
            .expect("engine");
    let slot = d_tag_of(&engine.key_package_event(relays()).expect("kp"));

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
        std::fs::read_to_string(&slot_path).expect("slot must survive").trim(),
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
        let engine = MarmotEngine::persistent(Identity::generate(), &db_path, DB_KEY)
            .expect("engine");
        engine.key_package_event(relays()).expect("kp");
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
        let engine = MarmotEngine::persistent(Identity::generate(), &db_path, DB_KEY)
            .expect("engine");
        engine.key_package_event(relays()).expect("kp");
    }
    let original = std::fs::read_to_string(&slot_path).expect("slot exists");

    // No staging file, no intent marker: nothing to promote.
    sonar_core::account_backup::commit_staged_account_restore(&db_path).expect("no-op commit");

    assert_eq!(
        std::fs::read_to_string(&slot_path).expect("slot must survive").trim(),
        original.trim(),
        "a healthy install must keep its coordinate"
    );
}
