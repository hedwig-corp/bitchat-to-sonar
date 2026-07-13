use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

const MAX_MEDIA_BYTES: u64 = 25 * 1024 * 1024;
const AAD: &[u8] = b"sonar-bridge-media-spool-v1";

pub struct Imported {
    pub path: PathBuf,
    pub content_hash: String,
}

pub fn import(
    state_dir: &Path,
    master_key: &[u8; 32],
    transaction_key: &str,
    source: &Path,
) -> Result<Imported, String> {
    let metadata =
        fs::metadata(source).map_err(|error| format!("inspect media source: {error}"))?;
    if !metadata.is_file() || metadata.len() > MAX_MEDIA_BYTES {
        return Err("media source must be a regular file no larger than 25 MiB".into());
    }
    let dir = state_dir.join("spool");
    secure_dir(&dir)?;
    let digest = Sha256::digest(transaction_key.as_bytes());
    let destination = dir.join(format!("{}.sealed", hex::encode(digest)));
    if fs::symlink_metadata(source)
        .map_err(|error| format!("inspect media source path: {error}"))?
        .file_type()
        .is_symlink()
    {
        return Err("media source must not be a symbolic link".into());
    }
    let plaintext =
        Zeroizing::new(fs::read(source).map_err(|error| format!("read media source: {error}"))?);
    let content_hash = hex::encode(Sha256::digest(&plaintext));
    if destination.exists() {
        return Ok(Imported {
            path: destination,
            content_hash,
        });
    }
    let mut nonce = [0u8; 24];
    getrandom::getrandom(&mut nonce).map_err(|error| format!("generate media nonce: {error}"))?;
    let cipher = XChaCha20Poly1305::new(master_key.into());
    let ciphertext = cipher
        .encrypt(
            XNonce::from_slice(&nonce),
            chacha20poly1305::aead::Payload {
                msg: &plaintext,
                aad: AAD,
            },
        )
        .map_err(|_| "encrypt media spool")?;
    let temporary = destination.with_extension(format!("tmp-{}", std::process::id()));
    let mut output = create_private(&temporary)?;
    let write_result = output
        .write_all(&nonce)
        .and_then(|_| output.write_all(&ciphertext))
        .and_then(|_| output.sync_all());
    drop(output);
    if let Err(error) = write_result {
        let _ = fs::remove_file(&temporary);
        return Err(format!("persist media spool: {error}"));
    }
    fs::rename(&temporary, &destination)
        .map_err(|error| format!("install media spool: {error}"))?;
    Ok(Imported {
        path: destination,
        content_hash,
    })
}

pub fn decrypt_temp(
    state_dir: &Path,
    master_key: &[u8; 32],
    sealed: &Path,
) -> Result<PathBuf, String> {
    let data = fs::read(sealed).map_err(|error| format!("read media spool: {error}"))?;
    if data.len() < 24 {
        return Err("media spool is corrupt".into());
    }
    let cipher = XChaCha20Poly1305::new(master_key.into());
    let plaintext = Zeroizing::new(
        cipher
            .decrypt(
                XNonce::from_slice(&data[..24]),
                chacha20poly1305::aead::Payload {
                    msg: &data[24..],
                    aad: AAD,
                },
            )
            .map_err(|_| "media spool could not be decrypted")?,
    );
    let temp_dir = state_dir.join("tmp");
    secure_dir(&temp_dir)?;
    let mut random = [0u8; 16];
    getrandom::getrandom(&mut random).map_err(|error| format!("generate temp name: {error}"))?;
    let path = temp_dir.join(format!("{}.partial", hex::encode(random)));
    let mut output = create_private(&path)?;
    let write_result = output.write_all(&plaintext).and_then(|_| output.sync_all());
    drop(output);
    if let Err(error) = write_result {
        let _ = fs::remove_file(&path);
        return Err(format!("write decrypted media temp: {error}"));
    }
    Ok(path)
}

pub fn remove(path: &Path) {
    let _ = fs::remove_file(path);
}

pub fn janitor(state_dir: &Path) {
    for directory in ["tmp", "exports"] {
        if let Ok(entries) = fs::read_dir(state_dir.join(directory)) {
            for entry in entries.flatten() {
                let _ = fs::remove_file(entry.path());
            }
        }
    }
    if let Ok(entries) = fs::read_dir(state_dir.join("spool")) {
        for entry in entries.flatten() {
            if entry
                .path()
                .extension()
                .is_some_and(|extension| extension.to_string_lossy().starts_with("tmp-"))
            {
                let _ = fs::remove_file(entry.path());
            }
        }
    }
}

fn secure_dir(path: &Path) -> Result<(), String> {
    fs::create_dir_all(path).map_err(|error| format!("create media directory: {error}"))?;
    if fs::symlink_metadata(path)
        .map_err(|error| format!("inspect media directory: {error}"))?
        .file_type()
        .is_symlink()
    {
        return Err("media directory must not be a symbolic link".into());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))
            .map_err(|error| format!("secure media directory: {error}"))?;
    }
    Ok(())
}

fn create_private(path: &Path) -> Result<std::fs::File, String> {
    let mut options = OpenOptions::new();
    options.create_new(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options
        .open(path)
        .map_err(|error| format!("create private media file: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spool_is_encrypted_and_round_trips_through_private_temp() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("source.bin");
        let plaintext = b"private bridge media payload";
        fs::write(&source, plaintext).unwrap();
        let imported = import(dir.path(), &[9u8; 32], "matrix-event-1", &source).unwrap();

        let sealed = fs::read(&imported.path).unwrap();
        assert!(!sealed
            .windows(plaintext.len())
            .any(|window| window == plaintext));
        let decrypted = decrypt_temp(dir.path(), &[9u8; 32], &imported.path).unwrap();
        assert_eq!(fs::read(&decrypted).unwrap(), plaintext);
        janitor(dir.path());
        assert!(!decrypted.exists());
    }
}
