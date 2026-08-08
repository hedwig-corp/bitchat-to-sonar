use std::path::{Path, PathBuf};

use crate::error::{Result, WalletError};

/// Gate on the recursive delete in `wipe_local_storage`. Returns the resolved
/// path that is safe to delete. Shared across backends so the hazards fixed in
/// the Breez island's review rounds cannot re-diverge per backend.
///
/// `looks_like_ours` receives each entry name of a non-empty directory and
/// must return true only for artifacts the calling backend itself creates.
///
/// Lexical checks alone are not enough, in two distinct ways:
///
/// 1. **Traversal.** `/tmp/..` is absolute, has a parent, and is not lexically
///    `$HOME` — but `remove_dir_all` resolves it to `/`. Every check therefore
///    runs against the *canonicalized* path, and the canonical path is what
///    the caller deletes.
/// 2. **Over-broad but honest paths.** A host bug that drops one component
///    hands us `~/Library/Application Support`, which survives every rule
///    above. So the directory must additionally *look like* the backend's
///    working dir — empty/absent (nothing to lose) or containing only its own
///    artifacts. Anything else is somebody else's data.
pub fn guard_wipe_path(dir: &Path, looks_like_ours: impl Fn(&str) -> bool) -> Result<PathBuf> {
    let refuse = |why: &str| {
        Err(WalletError::Backend(format!(
            "refusing to wipe {}: {why}",
            dir.display()
        )))
    };
    if !dir.is_absolute() {
        return refuse("working_dir must be an absolute path");
    }

    // Resolve symlinks and `..` before judging anything. Only a confirmed
    // ABSENT path is harmless: any other resolution failure (permissions,
    // I/O) must fail the destructive operation closed — `exists()` returns
    // false under the same access error, so the wipe would otherwise report
    // success while the state remains.
    let resolved = match dir.canonicalize() {
        Ok(resolved) => resolved,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            if dir
                .components()
                .any(|c| c == std::path::Component::ParentDir)
            {
                return refuse("path contains `..` and cannot be resolved");
            }
            // Absent path with no traversal: nothing to delete, nothing to
            // risk.
            return Ok(dir.to_path_buf());
        }
        Err(e) => {
            return Err(WalletError::Backend(format!(
                "cannot resolve {}: {e}",
                dir.display()
            )))
        }
    };

    if resolved.parent().is_none() {
        return refuse("path resolves to the filesystem root");
    }
    for var in ["HOME", "TMPDIR"] {
        if let Some(value) = std::env::var_os(var) {
            if value.is_empty() {
                continue;
            }
            // Compare canonically: `/tmp` vs `/private/tmp` on macOS.
            let known = Path::new(&value)
                .canonicalize()
                .unwrap_or_else(|_| PathBuf::from(&value));
            if resolved == known {
                return refuse(&format!("path resolves to ${var}"));
            }
        }
    }
    // $TMPDIR alone is not enough: when it is unset the platform still has an
    // effective temp root (`/tmp` on Linux), and deleting the SHARED system
    // temp directory must be refused no matter how it was reached.
    let system_tmp = std::env::temp_dir();
    let system_tmp = system_tmp.canonicalize().unwrap_or(system_tmp);
    if resolved == system_tmp {
        return refuse("path resolves to the system temp directory");
    }
    if !resolved.is_dir() {
        return refuse("path is not a directory");
    }
    let entries: Vec<_> = std::fs::read_dir(&resolved)
        .map_err(|e| WalletError::Backend(format!("read {}: {e}", resolved.display())))?
        .flatten()
        .collect();
    if entries.is_empty() {
        return Ok(resolved);
    }
    let all_ours = entries.iter().all(|entry| {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        name == ".DS_Store" || looks_like_ours(&name)
    });
    if !all_ours {
        return refuse("directory does not look like this wallet's working dir");
    }
    Ok(resolved)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ours(name: &str) -> bool {
        name == "mainnet" || name.starts_with("wallet.redb")
    }

    #[test]
    fn refuses_dangerous_paths() {
        assert!(guard_wipe_path(Path::new("/"), ours).is_err());
        assert!(guard_wipe_path(Path::new("relative/dir"), ours).is_err());
        if let Some(home) = std::env::var_os("HOME") {
            assert!(guard_wipe_path(Path::new(&home), ours).is_err());
            assert!(guard_wipe_path(&PathBuf::from(home).join(".sw-absent-xyz"), ours).is_ok());
        }
        let tmp = std::env::temp_dir();
        assert!(guard_wipe_path(&tmp, ours).is_err());
    }

    #[test]
    fn refuses_traversal_and_unresolvable() {
        for traversal in ["/tmp/..", "/tmp/../..", "/etc/.."] {
            assert!(
                guard_wipe_path(Path::new(traversal), ours).is_err(),
                "must refuse {traversal}"
            );
        }
        assert!(guard_wipe_path(Path::new("/nonexistent-xyz/../.."), ours).is_err());
    }

    #[test]
    fn refuses_foreign_content_and_returns_resolved_path() {
        let base = std::env::temp_dir().join("sonar-wallet-shared-guard-test");
        let _ = std::fs::remove_dir_all(&base);

        let wallet_dir = base.join("wallet");
        std::fs::create_dir_all(wallet_dir.join("mainnet")).unwrap();
        let via_dotdot = wallet_dir.join("mainnet").join("..");
        let resolved = guard_wipe_path(&via_dotdot, ours).expect("wallet-shaped dir allowed");
        assert!(!resolved.to_string_lossy().contains(".."));

        let container = base.join("container");
        std::fs::create_dir_all(container.join("Documents")).unwrap();
        assert!(guard_wipe_path(&container, ours).is_err());

        let _ = std::fs::remove_dir_all(&base);
    }
}
