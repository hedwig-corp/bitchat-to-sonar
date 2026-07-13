use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use sonar_core::identity::Identity;
use zeroize::{Zeroize, Zeroizing};

const AAD: &[u8] = b"sonar-bridge-account-v1";

#[derive(Debug, Serialize, Deserialize)]
struct Envelope {
    version: u32,
    nonce: String,
    ciphertext: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct SecretPayload {
    account_id: String,
    nsec: String,
    db_key: String,
}

impl Drop for SecretPayload {
    fn drop(&mut self) {
        self.nsec.zeroize();
        self.db_key.zeroize();
    }
}

pub struct AccountSecrets {
    pub account_id: String,
    pub identity: Identity,
    pub db_key: [u8; 32],
}

impl Drop for AccountSecrets {
    fn drop(&mut self) {
        self.db_key.zeroize();
    }
}

pub fn load_master_key(path: &Path) -> Result<[u8; 32], String> {
    reject_symlink(path)?;
    reject_insecure_permissions(path)?;
    let encoded = Zeroizing::new(
        fs::read_to_string(path).map_err(|error| format!("read master key file: {error}"))?,
    );
    let decoded = Zeroizing::new(
        hex::decode(encoded.trim()).map_err(|_| "master key must be 64 hex characters")?,
    );
    if decoded.len() != 32 {
        return Err("master key must decode to exactly 32 bytes".into());
    }
    let mut key = [0u8; 32];
    key.copy_from_slice(&decoded);
    Ok(key)
}

pub fn load_or_create(state_dir: &Path, master_key: &[u8; 32]) -> Result<AccountSecrets, String> {
    secure_dir(state_dir)?;
    let init_lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(state_dir.join("identity-init.lock"))
        .map_err(|error| format!("open identity initialization lock: {error}"))?;
    init_lock
        .lock_exclusive()
        .map_err(|error| format!("lock identity initialization: {error}"))?;
    let path = state_dir.join("account.sealed.json");
    if path.exists() {
        return load(&path, master_key);
    }

    let identity = Identity::generate();
    let mut db_key = [0u8; 32];
    getrandom::getrandom(&mut db_key).map_err(|error| format!("generate database key: {error}"))?;
    let mut account_bytes = [0u8; 16];
    getrandom::getrandom(&mut account_bytes)
        .map_err(|error| format!("generate account id: {error}"))?;
    let account_id = format!("acct_{}", hex::encode(account_bytes));
    let payload = SecretPayload {
        account_id: account_id.clone(),
        nsec: identity.export_nsec(),
        db_key: hex::encode(db_key),
    };
    save_new(&path, master_key, &payload)?;
    Ok(AccountSecrets {
        account_id,
        identity,
        db_key,
    })
}

fn load(path: &Path, master_key: &[u8; 32]) -> Result<AccountSecrets, String> {
    reject_symlink(path)?;
    reject_insecure_permissions(path)?;
    let data = fs::read(path).map_err(|error| format!("read account secret: {error}"))?;
    let envelope: Envelope =
        serde_json::from_slice(&data).map_err(|_| "account secret envelope is corrupt")?;
    if envelope.version != 1 {
        return Err(format!(
            "unsupported account secret version {}",
            envelope.version
        ));
    }
    let nonce = hex::decode(&envelope.nonce).map_err(|_| "account secret nonce is corrupt")?;
    if nonce.len() != 24 {
        return Err("account secret nonce has the wrong length".into());
    }
    let ciphertext =
        hex::decode(&envelope.ciphertext).map_err(|_| "account secret ciphertext is corrupt")?;
    let cipher = XChaCha20Poly1305::new(master_key.into());
    let plaintext = Zeroizing::new(
        cipher
            .decrypt(
                XNonce::from_slice(&nonce),
                chacha20poly1305::aead::Payload {
                    msg: &ciphertext,
                    aad: AAD,
                },
            )
            .map_err(|_| "account secret could not be decrypted")?,
    );
    let payload: SecretPayload =
        serde_json::from_slice(&plaintext).map_err(|_| "account secret payload is corrupt")?;
    let identity = Identity::import(&payload.nsec).map_err(|_| "account identity is corrupt")?;
    let db_key: [u8; 32] = hex::decode(&payload.db_key)
        .map_err(|_| "account database key is corrupt")?
        .try_into()
        .map_err(|_| "account database key has the wrong length")?;
    Ok(AccountSecrets {
        account_id: payload.account_id.clone(),
        identity,
        db_key,
    })
}

fn save_new(path: &Path, master_key: &[u8; 32], payload: &SecretPayload) -> Result<(), String> {
    let mut nonce = [0u8; 24];
    getrandom::getrandom(&mut nonce).map_err(|error| format!("generate secret nonce: {error}"))?;
    let plaintext = Zeroizing::new(serde_json::to_vec(payload).map_err(|error| error.to_string())?);
    let cipher = XChaCha20Poly1305::new(master_key.into());
    let ciphertext = cipher
        .encrypt(
            XNonce::from_slice(&nonce),
            chacha20poly1305::aead::Payload {
                msg: &plaintext,
                aad: AAD,
            },
        )
        .map_err(|_| "encrypt account secret")?;
    let envelope = Envelope {
        version: 1,
        nonce: hex::encode(nonce),
        ciphertext: hex::encode(ciphertext),
    };
    let bytes = serde_json::to_vec(&envelope).map_err(|error| error.to_string())?;
    let temp = temp_path(path);
    let mut options = OpenOptions::new();
    options.create_new(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options
        .open(&temp)
        .map_err(|error| format!("create account secret: {error}"))?;
    file.write_all(&bytes)
        .and_then(|_| file.sync_all())
        .map_err(|error| format!("persist account secret: {error}"))?;
    fs::rename(&temp, path).map_err(|error| format!("install account secret: {error}"))
}

fn secure_dir(path: &Path) -> Result<(), String> {
    fs::create_dir_all(path).map_err(|error| format!("create state directory: {error}"))?;
    reject_symlink(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))
            .map_err(|error| format!("secure state directory: {error}"))?;
    }
    Ok(())
}

fn reject_symlink(path: &Path) -> Result<(), String> {
    if fs::symlink_metadata(path)
        .map_err(|error| format!("inspect secret path: {error}"))?
        .file_type()
        .is_symlink()
    {
        return Err("secret/state path must not be a symbolic link".into());
    }
    Ok(())
}

fn reject_insecure_permissions(path: &Path) -> Result<(), String> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = fs::metadata(path)
            .map_err(|error| format!("inspect secret permissions: {error}"))?
            .permissions()
            .mode();
        if mode & 0o077 != 0 {
            return Err("secret file must not be readable or writable by group/other".into());
        }
    }
    Ok(())
}

fn temp_path(path: &Path) -> PathBuf {
    path.with_extension(format!("tmp-{}", std::process::id()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encrypted_identity_is_stable_and_not_plaintext() {
        let dir = tempfile::tempdir().unwrap();
        let key = [7u8; 32];
        let first = load_or_create(dir.path(), &key).unwrap();
        let npub = first.identity.npub();
        let nsec = first.identity.export_nsec();
        drop(first);
        let sealed = fs::read_to_string(dir.path().join("account.sealed.json")).unwrap();
        assert!(!sealed.contains(&nsec));
        let second = load_or_create(dir.path(), &key).unwrap();
        assert_eq!(second.identity.npub(), npub);
    }

    #[test]
    fn wrong_key_never_regenerates_identity() {
        let dir = tempfile::tempdir().unwrap();
        let first = load_or_create(dir.path(), &[1u8; 32]).unwrap();
        let npub = first.identity.npub();
        drop(first);
        assert!(load_or_create(dir.path(), &[2u8; 32]).is_err());
        assert_eq!(
            load_or_create(dir.path(), &[1u8; 32])
                .unwrap()
                .identity
                .npub(),
            npub
        );
    }
}
