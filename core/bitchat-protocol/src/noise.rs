//! Noise XX for pairwise mesh links, with bitchat's transport framing.
//!
//! Handshake: `Noise_XX_25519_ChaChaPoly_SHA256`, three messages with empty
//! payloads, carried as `0x10` packets. After the handshake both sides hold
//! the standard split keys (`k1`, `k2`; the initiator sends with `k1`).
//!
//! Transport (`0x11` payloads) is **not** plain Noise. Both reference clients
//! split their ciphers with `useExtractedNonce = true`
//! (`NoiseSession.swift`, `NoiseSession.kt`), which frames every message as
//!
//! ```text
//! [ nonce: u32 big-endian ][ ChaCha20-Poly1305 ciphertext || 16-byte tag ]
//! ```
//!
//! The AEAD nonce is the standard Noise one (`00000000 || nonce as u64 LE`)
//! and the AAD is empty. The receiver decrypts with the **extracted** nonce
//! and checks it against a 1024-entry sliding replay window, so a lost or
//! reordered BLE packet does not kill the session: newer nonces are always
//! accepted (gaps allowed), nonces inside the window are accepted once,
//! nonces older than the window are rejected. A sender that reaches the
//! 32-bit nonce limit must rekey.
//!
//! The crate builds the handshake with `snow`, then takes the raw split keys
//! and runs its own cipher states, because `snow`'s transport mode frames
//! messages without the prefix and bounds them at 65535 bytes, while bitchat
//! encrypts whole private files (up to 1 MiB) in one message.

use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use snow::{Builder, HandshakeState};

use crate::{Error, Result};

/// The Noise protocol name.
pub const PARAMS: &str = "Noise_XX_25519_ChaChaPoly_SHA256";
/// Replay window in messages (`REPLAY_WINDOW_SIZE` in both clients).
pub const REPLAY_WINDOW_SIZE: u64 = 1024;
const REPLAY_WINDOW_BYTES: usize = (REPLAY_WINDOW_SIZE / 8) as usize;
/// Width of the explicit nonce prefix.
pub const NONCE_PREFIX_BYTES: usize = 4;
/// Poly1305 tag width.
pub const TAG_BYTES: usize = 16;
/// Largest nonce a sender may use before it must rekey (`UInt32.max - 1`,
/// the Android bound; iOS truncates to four bytes which is the same limit).
pub const MAX_NONCE: u64 = u32::MAX as u64 - 1;

/// A static X25519 keypair for a Noise identity.
#[derive(Clone)]
pub struct NoiseKeypair {
    /// 32-byte private scalar.
    pub private: Vec<u8>,
    /// 32-byte public key (the one announces carry and peer ids derive from).
    pub public: Vec<u8>,
}

impl std::fmt::Debug for NoiseKeypair {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NoiseKeypair").field("public", &hex::encode(&self.public)).finish()
    }
}

impl NoiseKeypair {
    /// Generate from the OS CSPRNG (via `snow`'s resolver).
    pub fn generate() -> Result<Self> {
        let kp = Builder::new(PARAMS.parse()?).generate_keypair()?;
        Ok(Self { private: kp.private, public: kp.public })
    }
}

/// An in-progress XX handshake: `-> e`, `<- e, ee, s, es`, `-> s, se`.
pub struct NoiseHandshake {
    state: HandshakeState,
    initiator: bool,
}

impl NoiseHandshake {
    /// Start as the initiator (we send message 1).
    pub fn initiator(static_private: &[u8]) -> Result<Self> {
        let state = Builder::new(PARAMS.parse()?).local_private_key(static_private).build_initiator()?;
        Ok(Self { state, initiator: true })
    }

    /// Start as the responder (we wait for message 1).
    pub fn responder(static_private: &[u8]) -> Result<Self> {
        let state = Builder::new(PARAMS.parse()?).local_private_key(static_private).build_responder()?;
        Ok(Self { state, initiator: false })
    }

    /// Is it our turn to write?
    pub fn is_my_turn(&self) -> bool {
        self.state.is_my_turn()
    }

    /// Produce the next handshake message (empty payload).
    pub fn write_message(&mut self) -> Result<Vec<u8>> {
        let mut buf = vec![0u8; 1024];
        let n = self.state.write_message(&[], &mut buf)?;
        buf.truncate(n);
        Ok(buf)
    }

    /// Consume the peer's handshake message.
    pub fn read_message(&mut self, msg: &[u8]) -> Result<()> {
        let mut buf = vec![0u8; 1024];
        self.state.read_message(msg, &mut buf)?;
        Ok(())
    }

    /// All three messages processed?
    pub fn is_finished(&self) -> bool {
        self.state.is_handshake_finished()
    }

    /// The peer's authenticated static key, once revealed.
    pub fn remote_static(&self) -> Option<Vec<u8>> {
        self.state.get_remote_static().map(<[u8]>::to_vec)
    }

    /// The handshake hash (channel binding).
    pub fn handshake_hash(&self) -> Vec<u8> {
        self.state.get_handshake_hash().to_vec()
    }

    /// Finish into a transport session. Errors unless the handshake completed.
    pub fn into_session(mut self) -> Result<NoiseSession> {
        if !self.is_finished() {
            return Err(Error::NotEstablished);
        }
        let remote_static = self.remote_static().ok_or(Error::NotEstablished)?;
        let handshake_hash = self.handshake_hash();
        let (k1, k2) = self.state.dangerously_get_raw_split();
        let (send_key, recv_key) = if self.initiator { (k1, k2) } else { (k2, k1) };
        Ok(NoiseSession {
            send: CipherState::new(&send_key),
            recv: CipherState::new(&recv_key),
            remote_static,
            handshake_hash,
        })
    }
}

/// An established session.
pub struct NoiseSession {
    send: CipherState,
    recv: CipherState,
    remote_static: Vec<u8>,
    handshake_hash: Vec<u8>,
}

impl std::fmt::Debug for NoiseSession {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NoiseSession")
            .field("remote_static", &hex::encode(&self.remote_static))
            .field("sending_nonce", &self.send.nonce)
            .field("highest_received_nonce", &self.recv.highest_received)
            .finish()
    }
}

impl NoiseSession {
    /// Build a session directly from split keys (tests, vectors, migration).
    pub fn from_keys(send_key: &[u8; 32], recv_key: &[u8; 32], remote_static: Vec<u8>, handshake_hash: Vec<u8>) -> Self {
        NoiseSession {
            send: CipherState::new(send_key),
            recv: CipherState::new(recv_key),
            remote_static,
            handshake_hash,
        }
    }

    /// The peer's authenticated Noise static public key.
    pub fn remote_static(&self) -> &[u8] {
        &self.remote_static
    }

    /// The handshake hash.
    pub fn handshake_hash(&self) -> &[u8] {
        &self.handshake_hash
    }

    /// Nonce the next `encrypt` will use.
    pub fn sending_nonce(&self) -> u64 {
        self.send.nonce
    }

    /// Highest nonce accepted so far.
    pub fn highest_received_nonce(&self) -> u64 {
        self.recv.highest_received
    }

    /// Encrypt a transport message: `[u32 BE nonce][ct || tag]`.
    pub fn encrypt(&mut self, plaintext: &[u8]) -> Result<Vec<u8>> {
        self.send.encrypt(plaintext)
    }

    /// Decrypt a transport message, enforcing the replay window.
    pub fn decrypt(&mut self, message: &[u8]) -> Result<Vec<u8>> {
        self.recv.decrypt(message)
    }
}

/// One direction of the transport: `NoiseCipherState(useExtractedNonce: true)`.
struct CipherState {
    cipher: ChaCha20Poly1305,
    nonce: u64,
    highest_received: u64,
    window: [u8; REPLAY_WINDOW_BYTES],
}

impl CipherState {
    fn new(key: &[u8; 32]) -> Self {
        CipherState {
            cipher: ChaCha20Poly1305::new(Key::from_slice(key)),
            nonce: 0,
            highest_received: 0,
            window: [0u8; REPLAY_WINDOW_BYTES],
        }
    }

    fn aead_nonce(n: u64) -> Nonce {
        let mut b = [0u8; 12];
        b[4..].copy_from_slice(&n.to_le_bytes());
        Nonce::from(b)
    }

    fn encrypt(&mut self, plaintext: &[u8]) -> Result<Vec<u8>> {
        if self.nonce > MAX_NONCE {
            return Err(Error::NonceExhausted);
        }
        let n = self.nonce;
        let ct = self
            .cipher
            .encrypt(&Self::aead_nonce(n), Payload { msg: plaintext, aad: &[] })
            .map_err(|_| Error::Noise("encrypt failed".into()))?;
        self.nonce += 1;
        let mut out = Vec::with_capacity(NONCE_PREFIX_BYTES + ct.len());
        out.extend_from_slice(&(n as u32).to_be_bytes());
        out.extend_from_slice(&ct);
        Ok(out)
    }

    fn decrypt(&mut self, message: &[u8]) -> Result<Vec<u8>> {
        if message.len() < NONCE_PREFIX_BYTES + TAG_BYTES {
            return Err(Error::Decode("noise transport message too short"));
        }
        let n = u32::from_be_bytes([message[0], message[1], message[2], message[3]]) as u64;
        if !self.is_valid_nonce(n) {
            return Err(Error::Replay(n));
        }
        let pt = self
            .cipher
            .decrypt(&Self::aead_nonce(n), Payload { msg: &message[NONCE_PREFIX_BYTES..], aad: &[] })
            .map_err(|_| Error::Noise("decrypt failed".into()))?;
        // State moves only after a successful open (atomic on failure).
        self.mark_seen(n);
        Ok(pt)
    }

    fn is_valid_nonce(&self, received: u64) -> bool {
        if self.highest_received >= REPLAY_WINDOW_SIZE
            && received <= self.highest_received - REPLAY_WINDOW_SIZE
        {
            return false; // older than the window
        }
        if received > self.highest_received {
            return true; // newer: always accepted
        }
        let offset = (self.highest_received - received) as usize;
        self.window[offset / 8] & (1 << (offset % 8)) == 0
    }

    fn mark_seen(&mut self, received: u64) {
        if received > self.highest_received {
            let shift = received - self.highest_received;
            if shift >= REPLAY_WINDOW_SIZE {
                self.window = [0u8; REPLAY_WINDOW_BYTES];
            } else {
                let shift = shift as usize;
                // Shift the bit set up by `shift` (bit i = highest - i).
                let mut next = [0u8; REPLAY_WINDOW_BYTES];
                for bit in 0..(REPLAY_WINDOW_SIZE as usize - shift) {
                    if self.window[bit / 8] & (1 << (bit % 8)) != 0 {
                        let nb = bit + shift;
                        next[nb / 8] |= 1 << (nb % 8);
                    }
                }
                self.window = next;
            }
            self.highest_received = received;
            self.window[0] |= 1;
        } else {
            let offset = (self.highest_received - received) as usize;
            self.window[offset / 8] |= 1 << (offset % 8);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pair() -> (NoiseSession, NoiseSession) {
        let a = NoiseKeypair::generate().unwrap();
        let b = NoiseKeypair::generate().unwrap();
        let mut ah = NoiseHandshake::initiator(&a.private).unwrap();
        let mut bh = NoiseHandshake::responder(&b.private).unwrap();
        assert!(ah.is_my_turn() && !bh.is_my_turn());
        let m1 = ah.write_message().unwrap();
        bh.read_message(&m1).unwrap();
        let m2 = bh.write_message().unwrap();
        ah.read_message(&m2).unwrap();
        let m3 = ah.write_message().unwrap();
        bh.read_message(&m3).unwrap();
        assert!(ah.is_finished() && bh.is_finished());
        assert_eq!(ah.remote_static().unwrap(), b.public);
        assert_eq!(bh.remote_static().unwrap(), a.public);
        assert_eq!(ah.handshake_hash(), bh.handshake_hash());
        (ah.into_session().unwrap(), bh.into_session().unwrap())
    }

    #[test]
    fn handshake_then_framed_bidirectional_transport() {
        let (mut a, mut b) = pair();
        let ct = a.encrypt(b"hello over the mesh").unwrap();
        assert_eq!(&ct[..4], &[0, 0, 0, 0]);
        assert_eq!(ct.len(), 4 + 19 + 16);
        assert_eq!(b.decrypt(&ct).unwrap(), b"hello over the mesh");
        let ct2 = b.encrypt(b"got it").unwrap();
        assert_eq!(a.decrypt(&ct2).unwrap(), b"got it");
        let ct3 = a.encrypt(b"second").unwrap();
        assert_eq!(&ct3[..4], &[0, 0, 0, 1]);
        assert_eq!(b.decrypt(&ct3).unwrap(), b"second");
    }

    #[test]
    fn large_message_is_a_single_frame() {
        let (mut a, mut b) = pair();
        let big = vec![0x5a; 300_000];
        let ct = a.encrypt(&big).unwrap();
        assert_eq!(ct.len(), 4 + 300_000 + 16);
        assert_eq!(b.decrypt(&ct).unwrap(), big);
    }

    #[test]
    fn tamper_short_and_replay_are_rejected() {
        let (mut a, mut b) = pair();
        let mut ct = a.encrypt(b"secret").unwrap();
        ct[5] ^= 0xff;
        assert!(matches!(b.decrypt(&ct), Err(Error::Noise(_))));
        assert!(b.decrypt(&[0u8; 19]).is_err());
        let ct = a.encrypt(b"once").unwrap();
        assert_eq!(b.decrypt(&ct).unwrap(), b"once");
        assert_eq!(b.decrypt(&ct), Err(Error::Replay(1)));
    }

    #[test]
    fn lost_and_reordered_messages_inside_the_window_are_accepted() {
        let (mut a, mut b) = pair();
        let c0 = a.encrypt(b"zero").unwrap();
        let c1 = a.encrypt(b"one").unwrap();
        let c2 = a.encrypt(b"two").unwrap();
        // c1 lost on the air, c2 arrives first: accepted (gap).
        assert_eq!(b.decrypt(&c2).unwrap(), b"two");
        // Late arrival inside the window: accepted once.
        assert_eq!(b.decrypt(&c0).unwrap(), b"zero");
        assert_eq!(b.decrypt(&c1).unwrap(), b"one");
        assert_eq!(b.decrypt(&c1), Err(Error::Replay(1)));
        assert_eq!(b.decrypt(&c0), Err(Error::Replay(0)));
        assert_eq!(b.highest_received_nonce(), 2);
    }

    #[test]
    fn nonces_older_than_the_window_are_rejected() {
        let (mut a, mut b) = pair();
        let early = a.encrypt(b"early").unwrap();
        for _ in 0..(REPLAY_WINDOW_SIZE as usize + 5) {
            let c = a.encrypt(b"x").unwrap();
            assert_eq!(b.decrypt(&c).unwrap(), b"x");
        }
        assert!(matches!(b.decrypt(&early), Err(Error::Replay(0))));
        // A window-sized jump clears the bitmap but keeps accepting.
        let (mut a2, mut b2) = pair();
        for _ in 0..3000 {
            let _ = a2.encrypt(b"skip").unwrap();
        }
        let far = a2.encrypt(b"far").unwrap();
        assert_eq!(b2.decrypt(&far).unwrap(), b"far");
        assert_eq!(b2.highest_received_nonce(), 3000);
    }

    #[test]
    fn window_bitmap_tracks_seen_nonces_exactly() {
        let mut cs = CipherState::new(&[1u8; 32]);
        for n in [5u64, 3, 9, 4] {
            assert!(cs.is_valid_nonce(n));
            cs.mark_seen(n);
        }
        for n in [5u64, 3, 9, 4] {
            assert!(!cs.is_valid_nonce(n));
        }
        for n in [0u64, 1, 2, 6, 7, 8, 10] {
            assert!(cs.is_valid_nonce(n));
        }
        cs.mark_seen(9 + REPLAY_WINDOW_SIZE - 1);
        assert!(!cs.is_valid_nonce(9)); // exactly at the edge: still inside
        assert!(cs.is_valid_nonce(10));
        cs.mark_seen(9 + REPLAY_WINDOW_SIZE);
        assert!(!cs.is_valid_nonce(9));
        assert!(!cs.is_valid_nonce(8));
    }

    #[test]
    fn known_answer_frame_matches_rfc_8439_aead() {
        // Deterministic session from fixed keys: the frame is the big-endian
        // counter followed by RFC 8439 ChaCha20-Poly1305 output with nonce
        // 00000000 || LE64(counter) and empty AAD. Pinned so the framing can
        // never drift silently.
        let key = [0x42u8; 32];
        let mut s = NoiseSession::from_keys(&key, &key, vec![], vec![]);
        let frame = s.encrypt(b"bitchat").unwrap();
        let mut r = NoiseSession::from_keys(&key, &key, vec![], vec![]);
        assert_eq!(r.decrypt(&frame).unwrap(), b"bitchat");
        let cipher = ChaCha20Poly1305::new(Key::from_slice(&key));
        let expected = cipher.encrypt(&CipherState::aead_nonce(0), Payload { msg: b"bitchat", aad: &[] }).unwrap();
        assert_eq!(&frame[4..], &expected[..]);
        assert_eq!(hex::encode(&frame), format!("00000000{}", hex::encode(expected)));
    }

    #[test]
    fn nonce_exhaustion_is_an_error_not_a_wrap() {
        let mut cs = CipherState::new(&[9u8; 32]);
        cs.nonce = MAX_NONCE;
        assert!(cs.encrypt(b"last").is_ok());
        assert_eq!(cs.encrypt(b"over"), Err(Error::NonceExhausted));
    }
}
