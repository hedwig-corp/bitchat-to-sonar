//! Host-side driver for the simulator backup round-trip test.
//!
//! Runs the PRODUCTION backup functions against a real store directory:
//!   MODE=seed      — create a store with conversations to back up
//!   MODE=backup    — seal the DB (+index) and upload to the default Blossom
//!   MODE=restore   — download the newest backup, stage beside DB_PATH, commit
//!   MODE=wipe      — delete the store (delete-and-reinstall)
//!   MODE=stage     — restore WITHOUT committing (crash before commit)
//!   MODE=unmark    — delete the restore-intent marker (staging becomes debris)
//!   MODE=reconcile — boot-time recovery; prints whether staging was promoted
//!   MODE=verify    — list what the live store holds
//!
//! `stage` → `reconcile` is the path a crash between key-persist and commit
//! takes, and `stage` → `unmark` → `reconcile` is unrequested staging, which
//! must be discarded rather than promoted over the live account.
//!
//! Env: NSEC (bech32), DB_PATH, MODE. The db key mirrors the iOS bench
//! derivation: SHA256 over the nsec string, hex-encoded.

use sha2::{Digest, Sha256};
use std::path::Path;

fn main() {
    let nsec = std::env::var("NSEC").expect("NSEC");
    let db_path = std::env::var("DB_PATH").expect("DB_PATH");
    let mode = std::env::var("MODE").expect("MODE");
    let keys = nostr::Keys::parse(nsec.trim()).expect("parse nsec");
    let key_hex = hex::encode(Sha256::digest(nsec.trim().as_bytes()));
    let rt = tokio::runtime::Runtime::new().expect("rt");
    match mode.as_str() {
        "seed" => {
            let path = Path::new(&db_path);
            std::fs::create_dir_all(path.parent().expect("db parent")).expect("mkdir");
            let key: [u8; 32] = hex::decode(&key_hex).unwrap().try_into().unwrap();
            // Main store: SQLCipher with user tables, which is what the seal
            // path requires before it will back anything up.
            {
                let conn = rusqlite::Connection::open(path).expect("open db");
                conn.execute_batch(&format!("PRAGMA key = \"x'{key_hex}'\";"))
                    .expect("key");
                conn.execute_batch(
                    "CREATE TABLE IF NOT EXISTS marmot_state (k TEXT PRIMARY KEY, v TEXT);
                     INSERT OR REPLACE INTO marmot_state VALUES ('seeded','1');",
                )
                .expect("seed db");
            }
            // Use the core's own helper: the suffix is `.sonar-index.db`, and
            // guessing it wrong silently seals a backup with no index at all.
            let index_path = sonar_core::conversation_index::index_db_path_for_db(path);
            let idx = sonar_core::conversation_index::ConversationIndex::open(&index_path, key)
                .expect("open index");
            for (i, (group, name, content)) in [
                ("aa01", "Maya", "see you at eight"),
                ("bb02", "Dad", "landed safely"),
                ("cc03", "Work", "shipping tomorrow"),
            ]
            .iter()
            .enumerate()
            {
                idx.upsert_summary(group, name, content, "them", 1_700_000_000 + i as u64, false, true)
                    .expect("upsert");
            }
            let n = idx.summaries_ordered().expect("read back").len();
            println!("SEEDED conversations={n}");
        }
        "wipe" => {
            let path = Path::new(&db_path);
            let dir = path.parent().expect("db parent");
            std::fs::remove_dir_all(dir).expect("wipe store");
            println!("WIPED dir={}", dir.display());
        }
        "stage" => {
            let restored_key = rt
                .block_on(sonar_core::account_backup::restore_account_files(
                    &keys,
                    Path::new(&db_path),
                    "",
                ))
                .expect("stage");
            assert_eq!(restored_key, key_hex, "db key must match");
            let staged =
                sonar_core::account_backup::account_restore_staging_present(Path::new(&db_path));
            let marker = Path::new(&format!("{db_path}.sonar-restore-intent")).is_file();
            println!("STAGED staging_present={staged} intent_marker={marker}");
        }
        "unmark" => {
            let marker = format!("{db_path}.sonar-restore-intent");
            std::fs::remove_file(&marker).expect("remove intent marker");
            println!("UNMARKED {marker}");
        }
        "reconcile" => {
            let promoted = sonar_core::account_backup::reconcile_staged_account_restore(
                Path::new(&db_path),
                &key_hex,
            )
            .expect("reconcile");
            let live = Path::new(&db_path).is_file();
            let staged =
                sonar_core::account_backup::account_restore_staging_present(Path::new(&db_path));
            println!("RECONCILED promoted={promoted} live_db={live} staging_left={staged}");
        }
        "verify" => {
            let key: [u8; 32] = hex::decode(&key_hex).unwrap().try_into().unwrap();
            let path = Path::new(&db_path);
            let index_path = sonar_core::conversation_index::index_db_path_for_db(path);
            let summaries = sonar_core::conversation_index::ConversationIndex::open(&index_path, key)
                .and_then(|i| i.summaries_ordered())
                .expect("open live index");
            println!("VERIFIED conversations={}", summaries.len());
            for s in summaries {
                println!("  chat name={:?} latest={:?}", s.name, s.latest_content);
            }
        }
        "backup" => {
            let sealed = sonar_core::account_backup::seal_account_backup_files(
                &keys,
                Path::new(&db_path),
                &key_hex,
            )
            .expect("seal");
            let up = rt
                .block_on(sonar_core::account_backup::upload_sealed_backup(
                    &keys, "", sealed,
                ))
                .expect("upload");
            println!("UPLOADED size={} sha256={}", up.size, up.sha256_hex);
        }
        "restore" => {
            let restored_key = rt
                .block_on(sonar_core::account_backup::restore_account_files(
                    &keys,
                    Path::new(&db_path),
                    "",
                ))
                .expect("restore");
            assert_eq!(
                restored_key, key_hex,
                "db key must match the bench derivation"
            );
            sonar_core::account_backup::commit_staged_account_restore(Path::new(&db_path))
                .expect("commit");
            println!("RESTORED key_ok=true");
        }
        "preview" => {
            let preview = rt
                .block_on(sonar_core::account_backup::preview_account_backup(
                    &keys,
                    Path::new(&db_path),
                    "",
                ))
                .expect("preview");
            println!(
                "PREVIEW conversations={} total_messages={} size={}",
                preview.conversations.len(),
                preview.total_messages,
                preview.size_bytes
            );
            for c in preview.conversations {
                println!(
                    "  chat name={:?} count={} latest={:?}",
                    c.name, c.message_count, c.latest_content
                );
            }
        }
        other => panic!("unknown MODE {other}"),
    }
}
