use crate::error::{Result, WalletError};
use crate::types::{Destination, DestinationKind};

/// Decide what amount to hand a backend for a send, given what the caller
/// asked for and what the destination already encodes.
///
/// `Ok(Some(n))` means "tell the backend to pay n sats"; `Ok(None)` means
/// "the destination carries its own amount — do not override it". Backends
/// must use this rather than `requested.or(encoded)`: passing an explicit
/// amount alongside an amount-carrying invoice is rejected by Breez, and
/// silently preferring one over the other risks paying the wrong sum.
pub fn resolve_send_amount(requested: Option<u64>, encoded: Option<u64>) -> Result<Option<u64>> {
    match (requested, encoded) {
        (None, None) => Err(WalletError::InvalidDestination(
            "destination has no amount; an explicit amount is required".into(),
        )),
        (Some(0), None) => Err(WalletError::InvalidDestination(
            "amount must be greater than zero".into(),
        )),
        (Some(amount), None) => Ok(Some(amount)),
        // The destination fixes the amount; never override it.
        (None, Some(_)) => Ok(None),
        (Some(amount), Some(fixed)) if amount == fixed => Ok(None),
        (Some(amount), Some(fixed)) => Err(WalletError::InvalidDestination(format!(
            "destination is for {fixed} sats but {amount} sats was requested"
        ))),
    }
}

/// Pure prefix classification of a payment destination — the same rules the
/// iOS `SonarWallet.parseDestination` applies today (`lno` → BOLT12 offer,
/// `lnbc`/`lntb` → BOLT11, `lnurl` → LNURL-pay, contains `@` → Lightning
/// address). An optional `lightning:` URI prefix is stripped first.
///
/// This is classification only: no checksum validation and no amount
/// extraction. Backends refine the result with their real parser in
/// [`crate::WalletBackend::parse_destination`].
pub fn classify_destination(input: &str) -> Destination {
    let trimmed = input.trim();
    // URI schemes are case-insensitive (RFC 3986 §3.1): `Lightning:` from a
    // QR encoder or a copy-pasted deep link must strip the same as
    // `lightning:`.
    const SCHEME: &str = "lightning:";
    let stripped =
        if trimmed.len() >= SCHEME.len() && trimmed[..SCHEME.len()].eq_ignore_ascii_case(SCHEME) {
            &trimmed[SCHEME.len()..]
        } else {
            trimmed
        };
    let lower = stripped.to_ascii_lowercase();
    let kind = if lower.starts_with("lno") {
        DestinationKind::Bolt12Offer
    } else if lower.starts_with("lnbc") || lower.starts_with("lntb") {
        DestinationKind::Bolt11
    } else if lower.starts_with("lnurl") {
        DestinationKind::LnurlPay
    } else if stripped.contains('@') {
        DestinationKind::LightningAddress
    } else {
        DestinationKind::Unknown
    };
    Destination {
        raw: stripped.to_string(),
        kind,
        amount_sats: None,
        note: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_known_prefixes() {
        let cases = [
            ("lno1qcp4256ypq", DestinationKind::Bolt12Offer),
            ("LNO1QCP4256YPQ", DestinationKind::Bolt12Offer),
            ("lnbc1500n1p...", DestinationKind::Bolt11),
            ("lntb20m1p...", DestinationKind::Bolt11),
            ("lnurl1dp68gurn8ghj7", DestinationKind::LnurlPay),
            ("conor@sonar.hedwig.sh", DestinationKind::LightningAddress),
            ("bc1qxyz", DestinationKind::Unknown),
            ("", DestinationKind::Unknown),
        ];
        for (input, expected) in cases {
            assert_eq!(classify_destination(input).kind, expected, "input: {input}");
        }
    }

    #[test]
    fn strips_lightning_uri_prefix_and_whitespace() {
        // Schemes are case-insensitive (RFC 3986 §3.1) — QR encoders and deep
        // links produce every casing.
        for input in [
            "  lightning:lno1abcdef  ",
            "LIGHTNING:lno1abcdef",
            "Lightning:lno1abcdef",
            "LiGhTnInG:lno1abcdef",
        ] {
            let d = classify_destination(input);
            assert_eq!(d.kind, DestinationKind::Bolt12Offer, "input: {input}");
            assert_eq!(d.raw, "lno1abcdef", "input: {input}");
        }
    }

    #[test]
    fn amountless_destination_needs_an_explicit_amount() {
        assert!(matches!(
            resolve_send_amount(None, None),
            Err(WalletError::InvalidDestination(_))
        ));
        assert_eq!(resolve_send_amount(Some(1_000), None).unwrap(), Some(1_000));
        assert!(matches!(
            resolve_send_amount(Some(0), None),
            Err(WalletError::InvalidDestination(_))
        ));
    }

    #[test]
    fn destination_amount_is_never_overridden() {
        // Invoice carries its own amount: don't pass one to the backend.
        assert_eq!(resolve_send_amount(None, Some(2_500)).unwrap(), None);
        // Caller agreeing with the invoice is fine, and still passes nothing.
        assert_eq!(resolve_send_amount(Some(2_500), Some(2_500)).unwrap(), None);
        // Caller disagreeing must fail rather than pay either number.
        let err = resolve_send_amount(Some(10), Some(2_500)).unwrap_err();
        assert!(
            matches!(err, WalletError::InvalidDestination(ref m) if m.contains("2500") && m.contains("10")),
            "unexpected error: {err}"
        );
    }
}
