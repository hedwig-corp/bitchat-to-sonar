use bech32::Hrp;
use hkdf::Hkdf;
use sha2::Sha256;

use crate::error::{Result, WalletError};

/// HKDF salt/info for the nsec→wallet-seed derivation. These constants are the
/// wallet identity: they MUST stay byte-identical to iOS
/// `SonarWalletDerivation` (`ios/bitchat/Views/Sonar/BridgedWallet.swift`) and
/// Kotlin `WalletSeed` (`apps/sonar/.../wallet/WalletSeed.kt`). Changing them
/// silently derives a different wallet — an Account Key Durability violation.
pub const SEED_SALT: &[u8] = b"sonar-wallet";
pub const SEED_INFO: &[u8] = b"sonar-bolt12-v1";

/// Derive the 32-byte wallet entropy from the raw 32-byte Nostr secret key.
///
/// HKDF-SHA256(ikm = secret, salt = `"sonar-wallet"`, info =
/// `"sonar-bolt12-v1"`, L = 32). The result is passed to backends as the raw
/// seed (for Breez: `ConnectRequest::seed`, never a BIP39 mnemonic).
pub fn wallet_entropy(secret: &[u8; 32]) -> [u8; 32] {
    let hk = Hkdf::<Sha256>::new(Some(SEED_SALT), secret);
    let mut out = [0u8; 32];
    hk.expand(SEED_INFO, &mut out)
        .expect("32 bytes is a valid HKDF-SHA256 output length");
    out
}

/// Lower-case hex of [`wallet_entropy`], matching the iOS `entropyHex`.
pub fn entropy_hex(secret: &[u8; 32]) -> String {
    hex::encode(wallet_entropy(secret))
}

/// Decode an account secret from `nsec1…` bech32 or 64-char hex (the same two
/// forms `sonar-cli` accepts for identity import).
pub fn nsec_to_secret(input: &str) -> Result<[u8; 32]> {
    let s = input.trim();
    if s.len() == 64 && s.chars().all(|c| c.is_ascii_hexdigit()) {
        let bytes = hex::decode(s).map_err(|e| WalletError::InvalidInput(e.to_string()))?;
        return bytes
            .try_into()
            .map_err(|_| WalletError::InvalidInput("secret key must be 32 bytes".into()));
    }
    let (hrp, data) =
        bech32::decode(s).map_err(|e| WalletError::InvalidInput(format!("bad bech32: {e}")))?;
    if hrp != Hrp::parse_unchecked("nsec") {
        return Err(WalletError::InvalidInput(format!(
            "expected an nsec key, got hrp \"{hrp}\""
        )));
    }
    data.try_into()
        .map_err(|_| WalletError::InvalidInput("nsec payload must be 32 bytes".into()))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Golden vector shared with
    /// `ios/bitchatTests/Services/SonarWalletDerivationTests.swift` — pins
    /// cross-platform wallet-restore continuity.
    #[test]
    fn entropy_matches_ios_golden_vector() {
        let mut secret = [0u8; 32];
        for (i, b) in secret.iter_mut().enumerate() {
            *b = i as u8;
        }
        assert_eq!(
            entropy_hex(&secret),
            "801a82b16248f5c4c6363cae5ab6b9aff24724cb696ed41d936e53687c282806"
        );
    }

    #[test]
    fn nsec_and_hex_decode_to_same_secret() {
        let secret: [u8; 32] = core::array::from_fn(|i| i as u8);
        let hex_form = hex::encode(secret);
        let nsec_form = bech32::encode::<bech32::Bech32>(Hrp::parse_unchecked("nsec"), &secret)
            .expect("encode nsec");
        assert_eq!(nsec_to_secret(&hex_form).unwrap(), secret);
        assert_eq!(nsec_to_secret(&nsec_form).unwrap(), secret);
    }

    #[test]
    fn rejects_wrong_hrp_and_garbage() {
        let secret = [7u8; 32];
        let npub_form = bech32::encode::<bech32::Bech32>(Hrp::parse_unchecked("npub"), &secret)
            .expect("encode npub");
        assert!(nsec_to_secret(&npub_form).is_err());
        assert!(nsec_to_secret("not-a-key").is_err());
        assert!(nsec_to_secret("").is_err());
    }
}
