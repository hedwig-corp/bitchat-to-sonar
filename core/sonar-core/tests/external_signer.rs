//! External-signer (NIP-55 / Amber) identity coverage.
//!
//! A "remote" [`Identity`] holds no local [`Keys`] — every signature and
//! NIP-44/NIP-59 operation goes through its `NostrSigner`. These tests pin
//! that the whole Marmot lifecycle (KeyPackage envelope, group creation,
//! welcome gift-wrap seal + unseal, messaging) works with such an identity,
//! and that only the explicitly-unsupported operations demand local keys.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use nostr::prelude::*;
use sonar_core::identity::Identity;
use sonar_core::marmot::{Incoming, MarmotEngine};

/// A `NostrSigner` that proxies to in-process [`Keys`] while counting calls —
/// stands in for the Amber bridge. The engine under test must never see the
/// secret; it only talks to this trait object.
#[derive(Debug, Clone)]
struct CountingSigner {
    keys: Keys,
    signs: Arc<AtomicUsize>,
    nip44_encrypts: Arc<AtomicUsize>,
    nip44_decrypts: Arc<AtomicUsize>,
}

impl CountingSigner {
    fn new(keys: Keys) -> Self {
        Self {
            keys,
            signs: Arc::new(AtomicUsize::new(0)),
            nip44_encrypts: Arc::new(AtomicUsize::new(0)),
            nip44_decrypts: Arc::new(AtomicUsize::new(0)),
        }
    }
}

impl NostrSigner for CountingSigner {
    fn backend(&self) -> SignerBackend<'_> {
        SignerBackend::Custom("test-nip55".into())
    }

    fn get_public_key(&self) -> BoxedFuture<'_, Result<PublicKey, SignerError>> {
        Box::pin(async move { Ok(self.keys.public_key()) })
    }

    fn sign_event(&self, unsigned: UnsignedEvent) -> BoxedFuture<'_, Result<Event, SignerError>> {
        self.signs.fetch_add(1, Ordering::SeqCst);
        self.keys.sign_event(unsigned)
    }

    fn nip04_encrypt<'a>(
        &'a self,
        public_key: &'a PublicKey,
        content: &'a str,
    ) -> BoxedFuture<'a, Result<String, SignerError>> {
        self.keys.nip04_encrypt(public_key, content)
    }

    fn nip04_decrypt<'a>(
        &'a self,
        public_key: &'a PublicKey,
        content: &'a str,
    ) -> BoxedFuture<'a, Result<String, SignerError>> {
        self.keys.nip04_decrypt(public_key, content)
    }

    fn nip44_encrypt<'a>(
        &'a self,
        public_key: &'a PublicKey,
        content: &'a str,
    ) -> BoxedFuture<'a, Result<String, SignerError>> {
        self.nip44_encrypts.fetch_add(1, Ordering::SeqCst);
        self.keys.nip44_encrypt(public_key, content)
    }

    fn nip44_decrypt<'a>(
        &'a self,
        public_key: &'a PublicKey,
        content: &'a str,
    ) -> BoxedFuture<'a, Result<String, SignerError>> {
        self.nip44_decrypts.fetch_add(1, Ordering::SeqCst);
        self.keys.nip44_decrypt(public_key, content)
    }
}

fn remote_identity() -> (Identity, CountingSigner) {
    let signer = CountingSigner::new(Keys::generate());
    let identity = Identity::with_remote_signer(
        signer.keys.public_key(),
        Arc::new(signer.clone()),
        [42u8; 32],
    );
    (identity, signer)
}

fn relays() -> Vec<RelayUrl> {
    vec![RelayUrl::parse("wss://relay.example.com").expect("relay url")]
}

#[tokio::test]
async fn remote_identity_key_package_is_signed_via_signer() {
    let (identity, signer) = remote_identity();
    let engine = MarmotEngine::in_memory(identity);

    let kp = engine
        .key_package_event(relays())
        .await
        .expect("key package with remote signer");
    kp.verify().expect("valid signature");
    assert_eq!(kp.pubkey, signer.keys.public_key());
    assert_eq!(signer.signs.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn remote_identity_full_welcome_roundtrip() {
    // Alice's key lives in the "external signer"; Bob is a normal local
    // account. Alice must be able to create the group, seal Bob's welcome,
    // and Bob must be able to join — and vice versa Bob's welcome-back path
    // (a message) must decrypt on Alice's side.
    let (alice_id, alice_signer) = remote_identity();
    let alice = MarmotEngine::in_memory(alice_id);
    let bob = MarmotEngine::in_memory(Identity::generate());

    let bob_kp = bob.key_package_event(relays()).await.expect("bob kp");
    let creation = alice
        .create_group("amber test", vec![bob_kp], relays())
        .expect("alice creates group");
    alice
        .merge_pending_commit(&creation.group.mls_group_id)
        .expect("alice merges");

    let (bob_pk, bob_welcome) = creation.welcomes.first().cloned().expect("bob welcome");
    let wrapped = alice
        .gift_wrap_welcome(&bob_pk, bob_welcome)
        .await
        .expect("remote-signed welcome wrap");
    // The seal is signed by Alice's account key via the signer; the outer
    // 1059 wrap uses a locally generated ephemeral key.
    assert!(alice_signer.signs.load(Ordering::SeqCst) >= 1);
    assert!(alice_signer.nip44_encrypts.load(Ordering::SeqCst) >= 1);

    match bob.process_incoming(&wrapped).await.expect("bob welcome") {
        Incoming::GroupUpdated(gid) => assert_eq!(gid, creation.group.mls_group_id),
        other => panic!("expected joined group, got {other:?}"),
    }

    // Bob → group message; Alice decrypts (MLS path, no account key needed).
    let msg = bob
        .create_text_message(&creation.group.mls_group_id, "hi amber")
        .expect("bob sends");
    match alice.process_incoming(&msg).await.expect("alice processes") {
        Incoming::Message(m) => assert_eq!(m.content, "hi amber"),
        other => panic!("expected message, got {other:?}"),
    }

    // Alice can also unwrap incoming account-level gift wraps (welcome-shaped)
    // via the signer's nip44_decrypt: Bob invites Alice2? Keep it simple —
    // wrap a rumor to Alice and let her engine unwrap it.
    let rumor = EventBuilder::new(Kind::Custom(14), "ping").build(bob.identity().public_key());
    let gift = bob
        .gift_wrap_rumor(&alice.identity().public_key(), rumor)
        .await
        .expect("bob wraps rumor");
    let before = alice_signer.nip44_decrypts.load(Ordering::SeqCst);
    // Non-welcome rumor → Incoming::None, but the unwrap must have gone
    // through the remote signer's nip44_decrypt.
    match alice.process_incoming(&gift).await.expect("alice unwraps") {
        Incoming::None => {}
        other => panic!("expected none, got {other:?}"),
    }
    assert!(alice_signer.nip44_decrypts.load(Ordering::SeqCst) > before);
}

#[tokio::test]
async fn remote_identity_gates_local_key_operations() {
    let (identity, _signer) = remote_identity();
    assert!(!identity.has_local_keys());
    assert!(identity.local_keys().is_err());
    assert!(identity.export_nsec().is_err());
    // Deterministic derivations still work off the device-local root.
    assert_eq!(identity.kdf_root(), &[42u8; 32]);
}

/// Signer whose NIP-44 decrypt fails with a marked external-signer failure —
/// simulates the Amber bridge when the app is backgrounded (transient) or the
/// user rejected the request (permanent).
#[derive(Debug)]
struct FailingDecryptSigner {
    keys: Keys,
    marker: &'static str,
}

impl NostrSigner for FailingDecryptSigner {
    fn backend(&self) -> SignerBackend<'_> {
        SignerBackend::Custom("test-nip55".into())
    }

    fn get_public_key(&self) -> BoxedFuture<'_, Result<PublicKey, SignerError>> {
        Box::pin(async move { Ok(self.keys.public_key()) })
    }

    fn sign_event(&self, unsigned: UnsignedEvent) -> BoxedFuture<'_, Result<Event, SignerError>> {
        self.keys.sign_event(unsigned)
    }

    fn nip04_encrypt<'a>(
        &'a self,
        public_key: &'a PublicKey,
        content: &'a str,
    ) -> BoxedFuture<'a, Result<String, SignerError>> {
        self.keys.nip04_encrypt(public_key, content)
    }

    fn nip04_decrypt<'a>(
        &'a self,
        public_key: &'a PublicKey,
        content: &'a str,
    ) -> BoxedFuture<'a, Result<String, SignerError>> {
        self.keys.nip04_decrypt(public_key, content)
    }

    fn nip44_encrypt<'a>(
        &'a self,
        public_key: &'a PublicKey,
        content: &'a str,
    ) -> BoxedFuture<'a, Result<String, SignerError>> {
        self.keys.nip44_encrypt(public_key, content)
    }

    fn nip44_decrypt<'a>(
        &'a self,
        _public_key: &'a PublicKey,
        _content: &'a str,
    ) -> BoxedFuture<'a, Result<String, SignerError>> {
        let message = format!("external signer {}nip44_decrypt: simulated", self.marker);
        Box::pin(async move { Err(SignerError::from(message)) })
    }
}

/// A TRANSIENT signer failure while unwrapping must surface as
/// `Error::Signer` (retryable — the sync layer leaves the event in the
/// window), while a PERMANENT rejection keeps the terminal `Error::Nip59`
/// shape. Without this split, a backgrounded signer turned every undelivered
/// welcome/DM into silent permanent data loss.
#[tokio::test]
async fn signer_unwrap_failures_classify_transient_vs_permanent() {
    use sonar_core::signer_failure::{PERMANENT_MARKER, TRANSIENT_MARKER};

    let bob = MarmotEngine::in_memory(Identity::generate());

    for (marker, expect_retryable) in [(TRANSIENT_MARKER, true), (PERMANENT_MARKER, false)] {
        let keys = Keys::generate();
        let identity = Identity::with_remote_signer(
            keys.public_key(),
            Arc::new(FailingDecryptSigner {
                keys: keys.clone(),
                marker,
            }),
            [9u8; 32],
        );
        let alice = MarmotEngine::in_memory(identity);
        let rumor =
            EventBuilder::new(Kind::Custom(14), "ping").build(bob.identity().public_key());
        let gift = bob
            .gift_wrap_rumor(&keys.public_key(), rumor)
            .await
            .expect("bob wraps rumor");
        let err = alice
            .unwrap_gift(&gift)
            .await
            .expect_err("decrypt must fail");
        let is_signer = matches!(err, sonar_core::Error::Signer(_));
        assert_eq!(
            is_signer, expect_retryable,
            "marker {marker}: got {err:?}"
        );
    }
}
