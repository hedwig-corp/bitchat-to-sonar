//! Noise XX session for the BLE mesh transport.
//!
//! bitchat secures pairwise mesh links with `Noise_XX_25519_ChaChaPoly_SHA256`
//! (see WHITEPAPER / BRING_THE_NOISE). This wraps the handshake + transport
//! phases so the native shells only move opaque bytes over BLE. The bitchat
//! integration details (identity announce, peer-ID rotation by fingerprint,
//! rekey policy, version negotiation) layer on top of this core session.

use snow::{Builder, HandshakeState, TransportState};

use crate::{Error, Result};

const PARAMS: &str = "Noise_XX_25519_ChaChaPoly_SHA256";

impl From<snow::Error> for Error {
    fn from(e: snow::Error) -> Self {
        Error::Storage(format!("noise: {e:?}"))
    }
}

/// A static X25519 keypair for a Noise identity.
pub struct NoiseKeypair {
    pub private: Vec<u8>,
    pub public: Vec<u8>,
}

impl NoiseKeypair {
    pub fn generate() -> Result<Self> {
        let kp = Builder::new(PARAMS.parse()?).generate_keypair()?;
        Ok(Self {
            private: kp.private,
            public: kp.public,
        })
    }
}

/// In-progress Noise XX handshake. XX is a 3-message pattern:
///   1. initiator → responder
///   2. responder → initiator
///   3. initiator → responder
/// After the third message both sides hold a [`NoiseSession`].
pub struct NoiseHandshake {
    state: HandshakeState,
}

impl NoiseHandshake {
    pub fn initiator(static_private: &[u8]) -> Result<Self> {
        let state = Builder::new(PARAMS.parse()?)
            .local_private_key(static_private)
            .build_initiator()?;
        Ok(Self { state })
    }

    pub fn responder(static_private: &[u8]) -> Result<Self> {
        let state = Builder::new(PARAMS.parse()?)
            .local_private_key(static_private)
            .build_responder()?;
        Ok(Self { state })
    }

    /// Write the next handshake message to send to the peer.
    pub fn write_message(&mut self) -> Result<Vec<u8>> {
        let mut buf = vec![0u8; 1024];
        let len = self.state.write_message(&[], &mut buf)?;
        buf.truncate(len);
        Ok(buf)
    }

    /// Consume a handshake message received from the peer.
    pub fn read_message(&mut self, msg: &[u8]) -> Result<()> {
        let mut buf = vec![0u8; 1024];
        self.state.read_message(msg, &mut buf)?;
        Ok(())
    }

    pub fn is_finished(&self) -> bool {
        self.state.is_handshake_finished()
    }

    /// The peer's authenticated static public key (available after the XX
    /// handshake reveals it). Used to derive the bitchat fingerprint.
    pub fn remote_static(&self) -> Option<Vec<u8>> {
        self.state.get_remote_static().map(|s| s.to_vec())
    }

    /// Transition to the encrypted transport phase.
    pub fn into_session(self) -> Result<NoiseSession> {
        Ok(NoiseSession {
            state: self.state.into_transport_mode()?,
        })
    }
}

/// An established Noise session: encrypt/decrypt application messages.
pub struct NoiseSession {
    state: TransportState,
}

impl NoiseSession {
    pub fn encrypt(&mut self, plaintext: &[u8]) -> Result<Vec<u8>> {
        let mut buf = vec![0u8; plaintext.len() + 16];
        let len = self.state.write_message(plaintext, &mut buf)?;
        buf.truncate(len);
        Ok(buf)
    }

    pub fn decrypt(&mut self, ciphertext: &[u8]) -> Result<Vec<u8>> {
        let mut buf = vec![0u8; ciphertext.len()];
        let len = self.state.read_message(ciphertext, &mut buf)?;
        buf.truncate(len);
        Ok(buf)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn xx_handshake_then_bidirectional_transport() {
        let alice_kp = NoiseKeypair::generate().unwrap();
        let bob_kp = NoiseKeypair::generate().unwrap();

        let mut alice = NoiseHandshake::initiator(&alice_kp.private).unwrap();
        let mut bob = NoiseHandshake::responder(&bob_kp.private).unwrap();

        // XX: -> e ; <- e, ee, s, es ; -> s, se
        let m1 = alice.write_message().unwrap();
        bob.read_message(&m1).unwrap();
        let m2 = bob.write_message().unwrap();
        alice.read_message(&m2).unwrap();
        let m3 = alice.write_message().unwrap();
        bob.read_message(&m3).unwrap();

        assert!(alice.is_finished() && bob.is_finished());

        // Each side learned the other's authenticated static key.
        assert_eq!(alice.remote_static().unwrap(), bob_kp.public);
        assert_eq!(bob.remote_static().unwrap(), alice_kp.public);

        let mut alice_s = alice.into_session().unwrap();
        let mut bob_s = bob.into_session().unwrap();

        let ct = alice_s.encrypt(b"hello over the mesh").unwrap();
        assert_ne!(ct, b"hello over the mesh");
        assert_eq!(bob_s.decrypt(&ct).unwrap(), b"hello over the mesh");

        let ct2 = bob_s.encrypt(b"got it, encrypted").unwrap();
        assert_eq!(alice_s.decrypt(&ct2).unwrap(), b"got it, encrypted");
    }

    #[test]
    fn tampered_ciphertext_is_rejected() {
        let a = NoiseKeypair::generate().unwrap();
        let b = NoiseKeypair::generate().unwrap();
        let mut ah = NoiseHandshake::initiator(&a.private).unwrap();
        let mut bh = NoiseHandshake::responder(&b.private).unwrap();
        let m1 = ah.write_message().unwrap();
        bh.read_message(&m1).unwrap();
        let m2 = bh.write_message().unwrap();
        ah.read_message(&m2).unwrap();
        let m3 = ah.write_message().unwrap();
        bh.read_message(&m3).unwrap();
        let mut a_s = ah.into_session().unwrap();
        let mut b_s = bh.into_session().unwrap();
        let mut ct = a_s.encrypt(b"secret").unwrap();
        ct[0] ^= 0xFF; // tamper
        assert!(b_s.decrypt(&ct).is_err());
    }
}
