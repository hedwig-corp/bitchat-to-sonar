//! Durable encrypted-media upload journal.
//!
//! Blossom BUD-02 only defines an atomic whole-blob PUT, so a process cannot
//! resume the bytes of one interrupted request. Sonar can still make the send
//! process-durable: encrypted blobs and locally encrypted source bytes live here
//! until their message is committed, and each completed album-item URL is
//! checkpointed so it is reused after a restart at the same epoch. Retaining the
//! protected source also lets a delayed job re-encrypt when its MLS group epoch
//! changes; MIP-04 ciphertext is epoch-bound.

use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{ChaCha20Poly1305, Nonce};
use hkdf::Hkdf;
use mdk_core::encrypted_media::EncryptedMediaUpload;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::{Error, Result};

const MEDIA_OUTBOX_DIR_SUFFIX: &str = ".sonar-media-outbox";
const MANIFEST_FILE: &str = "manifest.enc";
const MANIFEST_TMP_FILE: &str = "manifest.enc.tmp";
const MANIFEST_MAGIC: &[u8; 8] = b"SNRMOBX1";
const MANIFEST_VERSION: u32 = 1;
const MANIFEST_KEY_SALT: &[u8] = b"sonar-media-outbox-key-v1";
const MANIFEST_KEY_INFO: &[u8] = b"encrypted upload manifest";
const MANIFEST_AAD: &[u8] = b"sonar-media-outbox-manifest-v1";
const SOURCE_AAD_PREFIX: &[u8] = b"sonar-media-outbox-source-v1";

#[derive(Clone, Debug, Deserialize, Serialize)]
struct MediaOutboxDisk {
    version: u32,
    jobs: Vec<MediaUploadJob>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub(crate) struct MediaUploadJob {
    pub request_id: String,
    pub group_id_hex: String,
    pub caption: String,
    pub server_url: String,
    pub created_at_secs: u64,
    pub expected_items: usize,
    pub items: Vec<MediaUploadItem>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub(crate) struct MediaUploadItem {
    blob_file: String,
    source_file: String,
    source_nonce: [u8; 12],
    pub source_hash: [u8; 32],
    pub source_size: u64,
    pub source_mime: String,
    pub encryption_epoch: u64,
    pub original_hash: [u8; 32],
    pub encrypted_hash: [u8; 32],
    pub mime_type: String,
    pub filename: String,
    pub original_size: u64,
    pub encrypted_size: u64,
    pub dimensions: Option<(u32, u32)>,
    pub blurhash: Option<String>,
    pub thumbhash: Option<String>,
    pub duration_ms: Option<u64>,
    pub waveform: Option<Vec<u8>>,
    pub nonce: [u8; 12],
    pub uploaded_url: Option<String>,
}

impl MediaUploadItem {
    fn from_upload(
        request_id: &str,
        index: usize,
        source: &[u8],
        source_mime: &str,
        source_nonce: [u8; 12],
        encryption_epoch: u64,
        upload: &EncryptedMediaUpload,
    ) -> Self {
        Self {
            blob_file: upload_blob_file(request_id, index, &upload.nonce),
            source_file: format!("{request_id}-{index}.source"),
            source_nonce,
            source_hash: Sha256::digest(source).into(),
            source_size: source.len() as u64,
            source_mime: source_mime.to_string(),
            encryption_epoch,
            original_hash: upload.original_hash,
            encrypted_hash: upload.encrypted_hash,
            mime_type: upload.mime_type.clone(),
            filename: upload.filename.clone(),
            original_size: upload.original_size,
            encrypted_size: upload.encrypted_size,
            dimensions: upload.dimensions,
            blurhash: upload.blurhash.clone(),
            thumbhash: upload.thumbhash.clone(),
            duration_ms: upload.duration_ms,
            waveform: upload.waveform.clone(),
            nonce: upload.nonce,
            uploaded_url: None,
        }
    }

    fn replace_upload(
        &mut self,
        blob_file: String,
        encryption_epoch: u64,
        upload: &EncryptedMediaUpload,
    ) {
        self.blob_file = blob_file;
        self.encryption_epoch = encryption_epoch;
        self.original_hash = upload.original_hash;
        self.encrypted_hash = upload.encrypted_hash;
        self.mime_type = upload.mime_type.clone();
        self.filename = upload.filename.clone();
        self.original_size = upload.original_size;
        self.encrypted_size = upload.encrypted_size;
        self.dimensions = upload.dimensions;
        self.blurhash = upload.blurhash.clone();
        self.thumbhash = upload.thumbhash.clone();
        self.duration_ms = upload.duration_ms;
        self.waveform = upload.waveform.clone();
        self.nonce = upload.nonce;
        self.uploaded_url = None;
    }

    fn into_upload(self, encrypted_data: Vec<u8>) -> EncryptedMediaUpload {
        EncryptedMediaUpload {
            encrypted_data,
            original_hash: self.original_hash,
            encrypted_hash: self.encrypted_hash,
            mime_type: self.mime_type,
            filename: self.filename,
            original_size: self.original_size,
            encrypted_size: self.encrypted_size,
            dimensions: self.dimensions,
            blurhash: self.blurhash,
            thumbhash: self.thumbhash,
            duration_ms: self.duration_ms,
            waveform: self.waveform,
            nonce: self.nonce,
        }
    }
}

pub(crate) struct MediaOutbox {
    dir: Option<PathBuf>,
    key: Option<[u8; 32]>,
    jobs: HashMap<String, MediaUploadJob>,
}

impl MediaOutbox {
    pub fn open(db_path: &Path, db_key: [u8; 32]) -> Result<Self> {
        let dir = media_outbox_dir_for_db(db_path);
        let key = derive_manifest_key(&db_key)?;
        let manifest = dir.join(MANIFEST_FILE);
        let jobs: HashMap<String, MediaUploadJob> = if manifest.exists() {
            let bytes = fs::read(&manifest).map_err(|error| {
                Error::Storage(format!("read media outbox {}: {error}", manifest.display()))
            })?;
            let disk = decrypt_manifest(&key, &bytes)?;
            if disk.version != MANIFEST_VERSION {
                return Err(Error::Storage(format!(
                    "unsupported media outbox version {}",
                    disk.version
                )));
            }
            disk.jobs
                .into_iter()
                .map(|job| (job.request_id.clone(), job))
                .collect()
        } else {
            HashMap::new()
        };
        // A crash after the manifest checkpoint/removal but before blob cleanup
        // can leave harmless ciphertext behind. Reconcile it on every open so
        // repeated failures cannot consume unbounded application storage.
        if dir.exists() {
            let referenced: std::collections::HashSet<_> = jobs
                .values()
                .flat_map(|job| {
                    job.items
                        .iter()
                        .flat_map(|item| [item.blob_file.as_str(), item.source_file.as_str()])
                })
                .collect();
            if let Ok(entries) = fs::read_dir(&dir) {
                for entry in entries.flatten() {
                    let path = entry.path();
                    let is_job_file = matches!(
                        path.extension().and_then(|ext| ext.to_str()),
                        Some("blob" | "source")
                    );
                    let known = path
                        .file_name()
                        .and_then(|name| name.to_str())
                        .is_some_and(|name| referenced.contains(name));
                    if is_job_file && !known {
                        let _ = fs::remove_file(path);
                    }
                }
            }
        }
        Ok(Self {
            dir: Some(dir),
            key: Some(key),
            jobs,
        })
    }

    pub fn disabled() -> Self {
        Self {
            dir: None,
            key: None,
            jobs: HashMap::new(),
        }
    }

    pub fn is_persistent(&self) -> bool {
        self.dir.is_some()
    }

    pub fn contains(&self, request_id: &str) -> bool {
        self.jobs.contains_key(request_id)
    }

    pub fn job(&self, request_id: &str) -> Option<MediaUploadJob> {
        self.jobs.get(request_id).cloned()
    }

    pub fn job_ids(&self) -> Vec<String> {
        let mut jobs: Vec<_> = self
            .jobs
            .values()
            .map(|job| (job.created_at_secs, job.request_id.clone()))
            .collect();
        jobs.sort();
        jobs.into_iter().map(|(_, id)| id).collect()
    }

    #[cfg(test)]
    pub fn enqueue(
        &mut self,
        request_id: String,
        group_id_hex: String,
        caption: String,
        server_url: String,
        created_at_secs: u64,
        uploads: Vec<(Vec<u8>, String, u64, EncryptedMediaUpload)>,
    ) -> Result<()> {
        let expected_items = uploads.len();
        self.begin_job(
            request_id.clone(),
            group_id_hex,
            caption,
            server_url,
            created_at_secs,
            expected_items,
        )?;
        for (source, source_mime, encryption_epoch, upload) in uploads {
            self.append_upload(&request_id, &source, &source_mime, encryption_epoch, upload)?;
        }
        Ok(())
    }

    pub fn begin_job(
        &mut self,
        request_id: String,
        group_id_hex: String,
        caption: String,
        server_url: String,
        created_at_secs: u64,
        expected_items: usize,
    ) -> Result<()> {
        if self.jobs.contains_key(&request_id) {
            return Ok(());
        }
        let Some(dir) = self.dir.as_ref() else {
            return Err(Error::Storage("media outbox is not persistent".into()));
        };
        create_private_dir(dir)?;
        self.jobs.insert(
            request_id.clone(),
            MediaUploadJob {
                request_id: request_id.clone(),
                group_id_hex,
                caption,
                server_url,
                created_at_secs,
                expected_items,
                items: Vec::with_capacity(expected_items),
            },
        );
        if let Err(error) = self.save() {
            self.jobs.remove(&request_id);
            return Err(error);
        }
        Ok(())
    }

    /// Append one encrypted item and checkpoint it immediately. Callers encrypt
    /// sequentially, so a 100 MiB album never needs a second 100 MiB ciphertext
    /// copy resident in memory just to become durable.
    pub fn append_upload(
        &mut self,
        request_id: &str,
        source: &[u8],
        source_mime: &str,
        encryption_epoch: u64,
        upload: EncryptedMediaUpload,
    ) -> Result<()> {
        let (Some(dir), Some(key)) = (self.dir.as_ref(), self.key.as_ref()) else {
            return Err(Error::Storage("media outbox is not persistent".into()));
        };
        let job = self
            .jobs
            .get(request_id)
            .ok_or_else(|| Error::Storage("media upload job is missing".into()))?;
        if job.items.len() >= job.expected_items {
            return Err(Error::Storage("media upload job already complete".into()));
        }
        let index = job.items.len();
        let mut source_nonce = [0_u8; 12];
        getrandom::getrandom(&mut source_nonce)?;
        let item = MediaUploadItem::from_upload(
            request_id,
            index,
            source,
            source_mime,
            source_nonce,
            encryption_epoch,
            &upload,
        );
        let source_path = dir.join(&item.source_file);
        let source_ciphertext = encrypt_source(key, request_id, index, source_nonce, source)?;
        write_private_file(&source_path, &source_ciphertext)?;
        let blob_path = dir.join(&item.blob_file);
        if let Err(error) = write_private_file(&blob_path, &upload.encrypted_data) {
            let _ = fs::remove_file(source_path);
            return Err(error);
        }
        self.jobs
            .get_mut(request_id)
            .expect("job checked above")
            .items
            .push(item);
        if let Err(error) = self.save() {
            self.jobs
                .get_mut(request_id)
                .expect("job checked above")
                .items
                .pop();
            let _ = fs::remove_file(source_path);
            let _ = fs::remove_file(blob_path);
            return Err(error);
        }
        Ok(())
    }

    pub fn load_upload(&self, request_id: &str, index: usize) -> Result<EncryptedMediaUpload> {
        let dir = self
            .dir
            .as_ref()
            .ok_or_else(|| Error::Storage("media outbox is not persistent".into()))?;
        let item = self
            .jobs
            .get(request_id)
            .and_then(|job| job.items.get(index))
            .cloned()
            .ok_or_else(|| Error::Storage("media upload checkpoint is missing".into()))?;
        let path = dir.join(&item.blob_file);
        let encrypted_data = fs::read(&path).map_err(|error| {
            Error::Storage(format!(
                "read media upload blob {}: {error}",
                path.display()
            ))
        })?;
        if encrypted_data.len() as u64 != item.encrypted_size {
            return Err(Error::Storage(format!(
                "media upload blob {} has {} bytes, expected {}",
                path.display(),
                encrypted_data.len(),
                item.encrypted_size
            )));
        }
        if Sha256::digest(&encrypted_data).as_slice() != item.encrypted_hash {
            return Err(Error::Storage(format!(
                "media upload blob {} failed integrity verification",
                path.display()
            )));
        }
        Ok(item.into_upload(encrypted_data))
    }

    pub fn load_source(&self, request_id: &str, index: usize) -> Result<Vec<u8>> {
        let (Some(dir), Some(key)) = (self.dir.as_ref(), self.key.as_ref()) else {
            return Err(Error::Storage("media outbox is not persistent".into()));
        };
        let item = self
            .jobs
            .get(request_id)
            .and_then(|job| job.items.get(index))
            .ok_or_else(|| Error::Storage("media upload source is missing".into()))?;
        let path = dir.join(&item.source_file);
        let ciphertext = fs::read(&path).map_err(|error| {
            Error::Storage(format!(
                "read media upload source {}: {error}",
                path.display()
            ))
        })?;
        let expected_ciphertext_size = item
            .source_size
            .checked_add(16)
            .ok_or_else(|| Error::Storage("media upload source size overflow".into()))?;
        if ciphertext.len() as u64 != expected_ciphertext_size {
            return Err(Error::Storage(format!(
                "media upload source {} has {} bytes, expected {}",
                path.display(),
                ciphertext.len(),
                expected_ciphertext_size
            )));
        }
        let source = decrypt_source(key, request_id, index, item.source_nonce, &ciphertext)?;
        let source_hash: [u8; 32] = Sha256::digest(&source).into();
        if source.len() as u64 != item.source_size || source_hash != item.source_hash {
            return Err(Error::Storage(format!(
                "media upload source {} failed integrity verification",
                path.display()
            )));
        }
        Ok(source)
    }

    pub fn replace_upload(
        &mut self,
        request_id: &str,
        index: usize,
        encryption_epoch: u64,
        upload: EncryptedMediaUpload,
    ) -> Result<()> {
        let Some(dir) = self.dir.as_ref() else {
            return Err(Error::Storage("media outbox is not persistent".into()));
        };
        let old_item = self
            .jobs
            .get(request_id)
            .and_then(|job| job.items.get(index))
            .cloned()
            .ok_or_else(|| Error::Storage("media upload checkpoint is missing".into()))?;
        let blob_file = upload_blob_file(request_id, index, &upload.nonce);
        let blob_path = dir.join(&blob_file);
        write_private_file(&blob_path, &upload.encrypted_data)?;
        self.jobs
            .get_mut(request_id)
            .and_then(|job| job.items.get_mut(index))
            .expect("item checked above")
            .replace_upload(blob_file, encryption_epoch, &upload);
        if let Err(error) = self.save() {
            if let Some(item) = self
                .jobs
                .get_mut(request_id)
                .and_then(|job| job.items.get_mut(index))
            {
                *item = old_item.clone();
            }
            let _ = fs::remove_file(blob_path);
            return Err(error);
        }
        if old_item.blob_file != self.jobs[request_id].items[index].blob_file {
            let _ = fs::remove_file(dir.join(old_item.blob_file));
        }
        Ok(())
    }

    pub fn checkpoint_url(&mut self, request_id: &str, index: usize, url: String) -> Result<()> {
        let item = self
            .jobs
            .get_mut(request_id)
            .and_then(|job| job.items.get_mut(index))
            .ok_or_else(|| Error::Storage("media upload checkpoint is missing".into()))?;
        item.uploaded_url = Some(url);
        self.save()
    }

    pub fn remove(&mut self, request_id: &str) -> Result<()> {
        let Some(job) = self.jobs.remove(request_id) else {
            return Ok(());
        };
        if let Err(error) = self.save() {
            self.jobs.insert(request_id.to_string(), job);
            return Err(error);
        }
        if let Some(dir) = self.dir.as_ref() {
            for item in &job.items {
                let _ = fs::remove_file(dir.join(&item.blob_file));
                let _ = fs::remove_file(dir.join(&item.source_file));
            }
        }
        Ok(())
    }

    pub fn remove_group_jobs(&mut self, group_id_hex: &str) -> Result<()> {
        let request_ids: Vec<_> = self
            .jobs
            .values()
            .filter(|job| job.group_id_hex == group_id_hex)
            .map(|job| job.request_id.clone())
            .collect();
        for request_id in request_ids {
            self.remove(&request_id)?;
        }
        Ok(())
    }

    fn save(&self) -> Result<()> {
        let (Some(dir), Some(key)) = (self.dir.as_ref(), self.key.as_ref()) else {
            return Ok(());
        };
        create_private_dir(dir)?;
        let mut jobs: Vec<_> = self.jobs.values().cloned().collect();
        jobs.sort_by_key(|job| (job.created_at_secs, job.request_id.clone()));
        let plaintext = serde_json::to_vec(&MediaOutboxDisk {
            version: MANIFEST_VERSION,
            jobs,
        })?;
        let encrypted = encrypt_manifest(key, &plaintext)?;
        let tmp = dir.join(MANIFEST_TMP_FILE);
        let manifest = dir.join(MANIFEST_FILE);
        write_private_file(&tmp, &encrypted)?;
        fs::rename(&tmp, &manifest).map_err(|error| {
            Error::Storage(format!(
                "replace media outbox manifest {}: {error}",
                manifest.display()
            ))
        })?;
        #[cfg(unix)]
        fs::File::open(dir)
            .and_then(|directory| directory.sync_all())
            .map_err(|error| {
                Error::Storage(format!(
                    "sync media outbox directory {}: {error}",
                    dir.display()
                ))
            })?;
        Ok(())
    }
}

pub(crate) fn media_outbox_dir_for_db(db_path: &Path) -> PathBuf {
    let file_name = db_path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("sonar");
    db_path.with_file_name(format!("{file_name}{MEDIA_OUTBOX_DIR_SUFFIX}"))
}

pub(crate) fn wipe_media_outbox_for_db(db_path: &Path) -> Result<()> {
    let dir = media_outbox_dir_for_db(db_path);
    match fs::remove_dir_all(&dir) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(Error::Storage(format!(
            "remove media outbox {}: {error}",
            dir.display()
        ))),
    }
}

fn upload_blob_file(request_id: &str, index: usize, nonce: &[u8; 12]) -> String {
    format!("{request_id}-{index}-{}.blob", hex::encode(nonce))
}

fn source_aad(request_id: &str, index: usize) -> Vec<u8> {
    let mut aad = Vec::with_capacity(SOURCE_AAD_PREFIX.len() + request_id.len() + 16);
    aad.extend_from_slice(SOURCE_AAD_PREFIX);
    aad.extend_from_slice(&(request_id.len() as u64).to_be_bytes());
    aad.extend_from_slice(request_id.as_bytes());
    aad.extend_from_slice(&(index as u64).to_be_bytes());
    aad
}

fn encrypt_source(
    key: &[u8; 32],
    request_id: &str,
    index: usize,
    nonce: [u8; 12],
    source: &[u8],
) -> Result<Vec<u8>> {
    let aad = source_aad(request_id, index);
    ChaCha20Poly1305::new(key.into())
        .encrypt(
            Nonce::from_slice(&nonce),
            chacha20poly1305::aead::Payload {
                msg: source,
                aad: &aad,
            },
        )
        .map_err(|_| Error::Storage("encrypt media upload source".into()))
}

fn decrypt_source(
    key: &[u8; 32],
    request_id: &str,
    index: usize,
    nonce: [u8; 12],
    ciphertext: &[u8],
) -> Result<Vec<u8>> {
    let aad = source_aad(request_id, index);
    ChaCha20Poly1305::new(key.into())
        .decrypt(
            Nonce::from_slice(&nonce),
            chacha20poly1305::aead::Payload {
                msg: ciphertext,
                aad: &aad,
            },
        )
        .map_err(|_| Error::Storage("decrypt media upload source".into()))
}

fn derive_manifest_key(db_key: &[u8; 32]) -> Result<[u8; 32]> {
    let hkdf = Hkdf::<Sha256>::new(Some(MANIFEST_KEY_SALT), db_key);
    let mut key = [0_u8; 32];
    hkdf.expand(MANIFEST_KEY_INFO, &mut key)
        .map_err(|error| Error::Storage(format!("derive media outbox key: {error}")))?;
    Ok(key)
}

fn encrypt_manifest(key: &[u8; 32], plaintext: &[u8]) -> Result<Vec<u8>> {
    let mut nonce_bytes = [0_u8; 12];
    getrandom::getrandom(&mut nonce_bytes)?;
    let cipher = ChaCha20Poly1305::new(key.into());
    let ciphertext = cipher
        .encrypt(
            Nonce::from_slice(&nonce_bytes),
            chacha20poly1305::aead::Payload {
                msg: plaintext,
                aad: MANIFEST_AAD,
            },
        )
        .map_err(|_| Error::Storage("encrypt media outbox manifest".into()))?;
    let mut out = Vec::with_capacity(MANIFEST_MAGIC.len() + nonce_bytes.len() + ciphertext.len());
    out.extend_from_slice(MANIFEST_MAGIC);
    out.extend_from_slice(&nonce_bytes);
    out.extend_from_slice(&ciphertext);
    Ok(out)
}

fn decrypt_manifest(key: &[u8; 32], bytes: &[u8]) -> Result<MediaOutboxDisk> {
    let header = MANIFEST_MAGIC.len() + 12;
    if bytes.len() < header || &bytes[..MANIFEST_MAGIC.len()] != MANIFEST_MAGIC {
        return Err(Error::Storage(
            "invalid media outbox manifest header".into(),
        ));
    }
    let nonce = Nonce::from_slice(&bytes[MANIFEST_MAGIC.len()..header]);
    let cipher = ChaCha20Poly1305::new(key.into());
    let plaintext = cipher
        .decrypt(
            nonce,
            chacha20poly1305::aead::Payload {
                msg: &bytes[header..],
                aad: MANIFEST_AAD,
            },
        )
        .map_err(|_| Error::Storage("decrypt media outbox manifest".into()))?;
    serde_json::from_slice(&plaintext).map_err(Into::into)
}

fn create_private_dir(path: &Path) -> Result<()> {
    fs::create_dir_all(path).map_err(|error| {
        Error::Storage(format!("create media outbox {}: {error}", path.display()))
    })?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700)).map_err(|error| {
            Error::Storage(format!(
                "protect media outbox directory {}: {error}",
                path.display()
            ))
        })?;
    }
    Ok(())
}

fn write_private_file(path: &Path, bytes: &[u8]) -> Result<()> {
    let mut options = fs::OpenOptions::new();
    options.create(true).truncate(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(path).map_err(|error| {
        Error::Storage(format!(
            "create media outbox file {}: {error}",
            path.display()
        ))
    })?;
    file.write_all(bytes)
        .and_then(|_| file.sync_all())
        .map_err(|error| {
            Error::Storage(format!(
                "write media outbox file {}: {error}",
                path.display()
            ))
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn upload(byte: u8) -> EncryptedMediaUpload {
        let source = vec![byte; 16];
        let encrypted_data = vec![byte; 32];
        EncryptedMediaUpload {
            encrypted_hash: Sha256::digest(&encrypted_data).into(),
            encrypted_data,
            original_hash: Sha256::digest(&source).into(),
            mime_type: "video/mp4".into(),
            filename: "clip.mp4".into(),
            original_size: 16,
            encrypted_size: 32,
            dimensions: Some((320, 240)),
            blurhash: None,
            thumbhash: None,
            duration_ms: Some(1000),
            waveform: None,
            nonce: [byte; 12],
        }
    }

    fn queued(byte: u8) -> (Vec<u8>, String, u64, EncryptedMediaUpload) {
        (vec![byte; 16], "video/mp4".into(), 7, upload(byte))
    }

    #[test]
    fn persists_encrypted_jobs_and_completed_item_urls() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("marmot.sqlite");
        let key = [7_u8; 32];
        let mut outbox = MediaOutbox::open(&db, key).unwrap();
        outbox
            .enqueue(
                "request".into(),
                "group".into(),
                "caption".into(),
                "https://blossom.example".into(),
                10,
                vec![queued(1), queued(2)],
            )
            .unwrap();
        outbox
            .checkpoint_url("request", 0, "https://blossom.example/a".into())
            .unwrap();

        let reloaded = MediaOutbox::open(&db, key).unwrap();
        let job = reloaded.job("request").unwrap();
        assert_eq!(
            job.items[0].uploaded_url.as_deref(),
            Some("https://blossom.example/a")
        );
        assert_eq!(
            reloaded.load_upload("request", 1).unwrap().encrypted_data,
            vec![2; 32]
        );
        assert_eq!(reloaded.load_source("request", 1).unwrap(), vec![2; 16]);
        let source_file = media_outbox_dir_for_db(&db).join(&job.items[1].source_file);
        assert_ne!(fs::read(source_file).unwrap(), vec![2; 16]);
        let manifest = fs::read(media_outbox_dir_for_db(&db).join(MANIFEST_FILE)).unwrap();
        assert!(!String::from_utf8_lossy(&manifest).contains("caption"));
    }

    #[test]
    fn removal_deletes_ciphertext_blobs() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("marmot.sqlite");
        let mut outbox = MediaOutbox::open(&db, [9_u8; 32]).unwrap();
        outbox
            .enqueue(
                "request".into(),
                "group".into(),
                String::new(),
                String::new(),
                10,
                vec![queued(1)],
            )
            .unwrap();
        let job = outbox.job("request").unwrap();
        let blob = media_outbox_dir_for_db(&db).join(&job.items[0].blob_file);
        let source = media_outbox_dir_for_db(&db).join(&job.items[0].source_file);
        assert!(blob.exists());
        assert!(source.exists());
        outbox.remove("request").unwrap();
        assert!(!blob.exists());
        assert!(!source.exists());
        assert!(MediaOutbox::open(&db, [9_u8; 32])
            .unwrap()
            .job_ids()
            .is_empty());
    }

    #[test]
    fn group_removal_only_deletes_matching_jobs() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("marmot.sqlite");
        let key = [3_u8; 32];
        let mut outbox = MediaOutbox::open(&db, key).unwrap();
        for (request, group, byte) in [("one", "group-a", 1), ("two", "group-b", 2)] {
            outbox
                .enqueue(
                    request.into(),
                    group.into(),
                    String::new(),
                    String::new(),
                    10,
                    vec![queued(byte)],
                )
                .unwrap();
        }
        let removed_job = outbox.job("one").unwrap();
        let removed_blob = removed_job.items[0].blob_file.clone();
        let removed_source = removed_job.items[0].source_file.clone();

        outbox.remove_group_jobs("group-a").unwrap();

        let reloaded = MediaOutbox::open(&db, key).unwrap();
        assert!(reloaded.job("one").is_none());
        let kept_job = reloaded.job("two").unwrap();
        let outbox_dir = media_outbox_dir_for_db(&db);
        assert!(!outbox_dir.join(removed_blob).exists());
        assert!(!outbox_dir.join(removed_source).exists());
        assert!(outbox_dir.join(&kept_job.items[0].blob_file).exists());
        assert!(outbox_dir.join(&kept_job.items[0].source_file).exists());
    }

    #[test]
    fn epoch_replacement_preserves_source_and_clears_uploaded_url() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("marmot.sqlite");
        let mut outbox = MediaOutbox::open(&db, [4_u8; 32]).unwrap();
        outbox
            .enqueue(
                "request".into(),
                "group".into(),
                String::new(),
                String::new(),
                10,
                vec![queued(1)],
            )
            .unwrap();
        outbox
            .checkpoint_url("request", 0, "https://old.example/blob".into())
            .unwrap();
        let old_blob = outbox.job("request").unwrap().items[0].blob_file.clone();

        let mut replacement = upload(9);
        replacement.original_hash = Sha256::digest(vec![1_u8; 16]).into();
        outbox.replace_upload("request", 0, 8, replacement).unwrap();

        let job = outbox.job("request").unwrap();
        assert_eq!(job.items[0].encryption_epoch, 8);
        assert!(job.items[0].uploaded_url.is_none());
        assert_eq!(outbox.load_source("request", 0).unwrap(), vec![1; 16]);
        assert!(!media_outbox_dir_for_db(&db).join(old_blob).exists());
    }
}
