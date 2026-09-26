//! Fiat exchange rates for display. Cashu mints publish no rates, so rates
//! come from a public source; parsing lives here (pure, network-free) and the
//! fetch lives with the host-facing FFI.

use crate::error::{Result, WalletError};
use crate::types::ExchangeRate;

/// Yadio's BTC rates endpoint: `{"BTC": {"USD": 84278.61, …}, "base": "BTC",
/// "timestamp": …}` — about 145 ISO 4217 currencies, fiat units per BTC, no
/// API key.
pub const YADIO_BTC_RATES_URL: &str = "https://api.yadio.io/exrates/BTC";

/// Parse a Yadio `exrates/BTC` body into rates, sorted by currency code.
///
/// Anything that is not a live rate is dropped rather than failing the whole
/// table: the BTC→BTC identity entry, non-numbers, zero, negative, and
/// non-finite values (a rate <= 0 must never be shown as a price).
pub fn parse_yadio(body: &str) -> Result<Vec<ExchangeRate>> {
    let value: serde_json::Value = serde_json::from_str(body)
        .map_err(|e| WalletError::Backend(format!("rates response is not JSON: {e}")))?;
    let table = value
        .get("BTC")
        .and_then(|v| v.as_object())
        .ok_or_else(|| WalletError::Backend("rates response has no BTC table".into()))?;
    let mut rates: Vec<ExchangeRate> = table
        .iter()
        .filter(|(code, _)| {
            code.as_str() != "BTC"
                && code.len() == 3
                && code.chars().all(|c| c.is_ascii_uppercase())
        })
        .filter_map(|(code, rate)| {
            let per_btc = rate.as_f64()?;
            (per_btc.is_finite() && per_btc > 0.0).then(|| ExchangeRate {
                currency: code.clone(),
                per_btc,
            })
        })
        .collect();
    if rates.is_empty() {
        return Err(WalletError::Backend(
            "rates response has no usable rates".into(),
        ));
    }
    rates.sort_by(|a, b| a.currency.cmp(&b.currency));
    Ok(rates)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Trimmed from a real `api.yadio.io/exrates/BTC` response (2026-09-23).
    const FIXTURE: &str = r#"{"BTC":{"BTC":1,"AED":309513.19,"ARS":135131482.47,"BRL":435694.37,"CHF":69451.98,"EUR":72012.5,"USD":84278.61,"XXX":0,"BAD":-3,"lower":5,"NUM":"12"},"base":"BTC","timestamp":1790000000000}"#;

    #[test]
    fn parses_live_rates_and_drops_the_rest() {
        let rates = parse_yadio(FIXTURE).unwrap();
        let codes: Vec<&str> = rates.iter().map(|r| r.currency.as_str()).collect();
        assert_eq!(codes, ["AED", "ARS", "BRL", "CHF", "EUR", "USD"]);
        let usd = rates.iter().find(|r| r.currency == "USD").unwrap();
        assert!((usd.per_btc - 84_278.61).abs() < 1e-6);
    }

    #[test]
    fn a_body_without_rates_is_an_error_not_an_empty_table() {
        assert!(parse_yadio("not json").is_err());
        assert!(parse_yadio(r#"{"base":"BTC"}"#).is_err());
        assert!(parse_yadio(r#"{"BTC":{"BTC":1,"XXX":0}}"#).is_err());
    }
}
