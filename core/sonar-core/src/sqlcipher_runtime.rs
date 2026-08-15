//! SQLCipher process defaults that the Marmot store close path depends on.
//!
//! MDK opens its own `rusqlite::Connection` behind `pub(crate)` and we cannot
//! set per-connection flags on it. Registering an auto-extension here applies
//! `SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE` to every subsequent connection in this
//! process — MDK, the conversation index, and the backup helper alike.
//!
//! TestFlight 1.12.8 (37) was killed with `RUNNINGBOARD 0xdead10cc` while
//! `sqlite3_close` ran a WAL checkpoint (`sqlite3_backup_finish` + `pread`)
//! as `SonarNode` dropped. iOS grants ~30s of background grace; a FULL
//! checkpoint of a large Marmot DB overruns that window and RunningBoard
//! treats the held WAL lock as fatal. Skipping the close-time checkpoint
//! makes drop cheap. WAL recovery still happens on the next open, and the
//! backup path still runs an explicit `PRAGMA wal_checkpoint(TRUNCATE)`
//! before it seals.

use std::os::raw::{c_char, c_int};
use std::sync::OnceLock;

use rusqlite::ffi;

use crate::Error;

static INSTALL: OnceLock<Result<(), String>> = OnceLock::new();

unsafe extern "C" fn disable_checkpoint_on_close(
    db: *mut ffi::sqlite3,
    _pz_err: *mut *mut c_char,
    _api: *const ffi::sqlite3_api_routines,
) -> c_int {
    let mut val: c_int = 0;
    // SAFETY: `db` is the connection SQLite just opened and handed to this
    // auto-extension. `SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE` takes an int flag and
    // an out-int; `val` lives for the call. No other pointer is retained.
    unsafe {
        ffi::sqlite3_db_config(
            db,
            ffi::SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE,
            1 as c_int,
            &mut val,
        )
    }
}

/// Install the process-wide "no WAL checkpoint on close" hook.
///
/// Idempotent and cheap after the first call. Must run *before* MDK or the
/// conversation index opens a SQLCipher file, or those connections keep the
/// default (checkpoint on close) and the 0xdead10cc window stays open.
pub fn ensure_no_checkpoint_on_close() -> Result<(), Error> {
    match INSTALL.get_or_init(|| {
        // SAFETY: sqlite3_auto_extension is process-global and not thread-safe;
        // OnceLock serializes the single registration. The callback type matches
        // the sqlite3_load_extension entry point in libsqlite3-sys's bindgen.
        let rc = unsafe { ffi::sqlite3_auto_extension(Some(disable_checkpoint_on_close)) };
        if rc != ffi::SQLITE_OK {
            Err(format!(
                "sqlite3_auto_extension(NO_CKPT_ON_CLOSE) failed: {rc}"
            ))
        } else {
            Ok(())
        }
    }) {
        Ok(()) => Ok(()),
        Err(msg) => Err(Error::Storage(msg.clone())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::{config::DbConfig, Connection};

    #[test]
    fn new_sqlcipher_connections_skip_checkpoint_on_close() {
        ensure_no_checkpoint_on_close().expect("install auto-extension");
        let conn = Connection::open_in_memory().expect("open");
        assert!(
            conn.db_config(DbConfig::SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE)
                .expect("read db config"),
            "connections opened after ensure_no_checkpoint_on_close must skip WAL checkpoint on close"
        );
    }

    #[test]
    fn file_backed_wal_connection_also_skips_checkpoint_on_close() {
        ensure_no_checkpoint_on_close().expect("install auto-extension");
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("ckpt.sqlite");
        let conn = Connection::open(&path).expect("open");
        conn.execute_batch(
            "PRAGMA journal_mode = WAL; CREATE TABLE t (v INTEGER); INSERT INTO t VALUES (1);",
        )
        .unwrap();
        assert!(conn
            .db_config(DbConfig::SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE)
            .unwrap());
        drop(conn);
        // WAL sidecar may remain — that is the point of skipping close-time
        // checkpoint. Reopen must still see the row.
        let conn = Connection::open(&path).expect("reopen");
        let n: i64 = conn
            .query_row("SELECT v FROM t", [], |row| row.get(0))
            .unwrap();
        assert_eq!(n, 1);
    }
}
