//! Host-side driver for the simulator backup round-trip test.
//!
//! Runs the PRODUCTION backup functions against a real store directory:
//!   MODE=backup  — seal the DB (+index) and upload to the default Blossom
//!   MODE=restore — download the newest backup, stage beside DB_PATH, commit
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
