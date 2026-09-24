//! An in-process fake Cashu mint for exercising `CdkWallet`'s real call sites
//! (connect, the watcher, balance, send) without the network.
//!
//! It is a `MintConnector`, not a mint: CDK's own in-process mint would pull a
//! bundled-SQLite mint database into this workspace, which the SQLCipher core
//! cannot share a graph with. It still signs for real — a deterministic keyset
//! and `dhke::sign_message` — so minted proofs pass CDK's unblinding and
//! NUT-09 restore returns signatures the wallet can use. Quote state, melt
//! outcomes, failures, and hangs are scripted per test.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use cdk::nuts::nut00::KnownMethod;
use cdk::nuts::nut04::MintMethodSettings;
use cdk::nuts::nut05::MeltMethodSettings;
use cdk::nuts::nut29::{BatchCheckMintQuoteRequest, BatchMintRequest};
use cdk::nuts::{
    BlindSignature, BlindedMessage, CheckStateRequest, CheckStateResponse, CurrencyUnit, Id,
    KeySet, KeySetInfo, Keys, KeysetResponse, MeltQuoteBolt11Response, MeltQuoteState, MeltRequest,
    MintInfo, MintQuoteBolt11Response, MintQuoteBolt12Response, MintQuoteState, MintRequest,
    MintResponse, NUT04Settings, NUT05Settings, Nuts, PaymentMethod, ProofState, PublicKey,
    RestoreRequest, RestoreResponse, SecretKey, State, SwapRequest, SwapResponse,
};
use cdk::wallet::{AuthWallet, MintConnector};
use cdk::{Amount, Error, MeltQuoteCreateResponse, MeltQuoteRequest, MeltQuoteResponse};
use cdk::{MintQuoteRequest, MintQuoteResponse};

/// How a melt the fake mint executes ends.
#[derive(Debug, Clone)]
pub enum MeltOutcome {
    Paid {
        preimage: Option<String>,
    },
    Pending,
    Failed,
    /// The mint refuses the melt with a generic error (e.g. "request already
    /// paid") and leaves the quote Unpaid — no money moves.
    Refused,
}

#[derive(Debug, Clone)]
struct FakeMintQuote {
    method: PaymentMethod,
    request: String,
    amount: Option<u64>,
    expiry: Option<u64>,
    pubkey: Option<PublicKey>,
    amount_paid: u64,
    amount_issued: u64,
}

#[derive(Debug, Clone)]
struct FakeMeltQuote {
    method: PaymentMethod,
    request: String,
    amount: u64,
    fee_reserve: u64,
    state: MeltQuoteState,
    preimage: Option<String>,
}

#[derive(Default)]
struct FakeState {
    calls: Vec<&'static str>,
    hang: HashSet<&'static str>,
    delay: HashMap<&'static str, std::time::Duration>,
    fail: HashMap<&'static str, u32>,
    mint_quotes: HashMap<String, FakeMintQuote>,
    melt_quotes: HashMap<String, FakeMeltQuote>,
    /// Blinded secret → (the output, our signature), for NUT-09 restore.
    signed: HashMap<PublicKey, (BlindedMessage, BlindSignature)>,
    spent: HashSet<PublicKey>,
    pending: HashSet<PublicKey>,
    melt_outcome: Option<MeltOutcome>,
    melt_quote_requests: Vec<MeltQuoteRequest>,
    fee_reserve: u64,
    next_id: u64,
}

#[derive(Debug)]
pub struct FakeMint {
    keys: BTreeMap<u64, SecretKey>,
    keyset: KeySet,
    state: Mutex<FakeStateDebug>,
}

/// `Mutex<FakeState>` behind a Debug shim (MintConnector requires Debug).
struct FakeStateDebug(FakeState);

impl std::fmt::Debug for FakeStateDebug {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("FakeState")
    }
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

impl Default for FakeMint {
    fn default() -> Self {
        Self::new()
    }
}

impl FakeMint {
    pub fn new() -> Self {
        use sha2::{Digest, Sha256};
        let mut keys = BTreeMap::new();
        let mut public = BTreeMap::new();
        for power in 0..21u32 {
            let amount = 1u64 << power;
            let digest = Sha256::digest(format!("sonar-fake-mint-key-{amount}").as_bytes());
            let secret = SecretKey::from_slice(&digest).expect("sha256 output is a valid scalar");
            public.insert(Amount::from(amount), secret.public_key());
            keys.insert(amount, secret);
        }
        let public = Keys::new(public);
        let keyset = KeySet {
            id: Id::v1_from_keys(&public),
            unit: CurrencyUnit::Sat,
            active: Some(true),
            keys: public,
            input_fee_ppk: 0,
            final_expiry: None,
        };
        Self {
            keys,
            keyset,
            state: Mutex::new(FakeStateDebug(FakeState {
                fee_reserve: 2,
                ..FakeState::default()
            })),
        }
    }

    fn with<R>(&self, f: impl FnOnce(&mut FakeState) -> R) -> R {
        let mut guard = self.state.lock().unwrap_or_else(|e| e.into_inner());
        f(&mut guard.0)
    }

    /// Record the call; then hang forever or fail if the test asked for it.
    async fn enter(&self, method: &'static str) -> Result<(), Error> {
        let (hang, fail, delay) = self.with(|s| {
            s.calls.push(method);
            let fail = match s.fail.get_mut(method) {
                Some(n) if *n > 0 => {
                    *n -= 1;
                    true
                }
                _ => false,
            };
            (s.hang.contains(method), fail, s.delay.get(method).copied())
        });
        if let Some(delay) = delay {
            tokio::time::sleep(delay).await;
        }
        if hang {
            std::future::pending::<()>().await;
        }
        if fail {
            return Err(Error::Custom(format!(
                "fake mint: scripted failure of {method}"
            )));
        }
        Ok(())
    }

    // ---- test controls -------------------------------------------------

    pub fn calls(&self, method: &str) -> usize {
        self.with(|s| s.calls.iter().filter(|m| **m == method).count())
    }

    pub fn hang(&self, method: &'static str) {
        self.with(|s| {
            s.hang.insert(method);
        });
    }

    pub fn unhang(&self, method: &'static str) {
        self.with(|s| {
            s.hang.remove(method);
        });
    }

    /// Answer `method` only after `delay` (a slow, not dead, mint).
    pub fn delay(&self, method: &'static str, delay: std::time::Duration) {
        self.with(|s| {
            s.delay.insert(method, delay);
        });
    }

    pub fn fail_next(&self, method: &'static str, times: u32) {
        self.with(|s| {
            s.fail.insert(method, times);
        });
    }

    pub fn set_melt_outcome(&self, outcome: MeltOutcome) {
        self.with(|s| s.melt_outcome = Some(outcome));
    }

    /// Settle a pending melt (the Lightning payment resolved later).
    pub fn resolve_melt(&self, quote_id: &str, outcome: MeltOutcome) {
        self.with(|s| {
            let pending: Vec<PublicKey> = s.pending.drain().collect();
            if let Some(q) = s.melt_quotes.get_mut(quote_id) {
                match outcome {
                    MeltOutcome::Paid { preimage } => {
                        q.state = MeltQuoteState::Paid;
                        q.preimage = preimage;
                        s.spent.extend(pending);
                    }
                    MeltOutcome::Failed | MeltOutcome::Refused => q.state = MeltQuoteState::Unpaid,
                    MeltOutcome::Pending => {
                        q.state = MeltQuoteState::Pending;
                        s.pending.extend(pending);
                    }
                }
            }
        });
    }

    pub fn melt_quote_requests(&self) -> Vec<MeltQuoteRequest> {
        self.with(|s| s.melt_quote_requests.clone())
    }

    /// A payer paid `sats` into a mint quote (a BOLT11 invoice pays in full
    /// once; a BOLT12 offer accumulates).
    pub fn pay(&self, quote_id: &str, sats: u64) {
        self.with(|s| {
            let q = s.mint_quotes.get_mut(quote_id).expect("known mint quote");
            q.amount_paid += sats;
        });
    }

    pub fn mint_quote_ids(&self) -> Vec<String> {
        self.with(|s| s.mint_quotes.keys().cloned().collect())
    }

    /// Mark a mint quote as expired at the mint.
    pub fn expire(&self, quote_id: &str) {
        self.with(|s| {
            if let Some(q) = s.mint_quotes.get_mut(quote_id) {
                q.expiry = Some(1);
            }
        });
    }

    fn fresh_id(&self, prefix: &str) -> String {
        self.with(|s| {
            s.next_id += 1;
            format!("{prefix}{}", s.next_id)
        })
    }

    fn sign(&self, outputs: &[BlindedMessage]) -> Result<Vec<BlindSignature>, Error> {
        let mut signatures = Vec::with_capacity(outputs.len());
        for output in outputs {
            let amount = u64::from(output.amount);
            let key = self
                .keys
                .get(&amount)
                .ok_or_else(|| Error::Custom(format!("fake mint: no key for {amount}")))?;
            let c = cdk::dhke::sign_message(key, &output.blinded_secret)
                .map_err(|e| Error::Custom(e.to_string()))?;
            let signature = BlindSignature {
                amount: output.amount,
                keyset_id: self.keyset.id,
                c,
                dleq: None,
            };
            self.with(|s| {
                s.signed
                    .insert(output.blinded_secret, (output.clone(), signature.clone()));
            });
            signatures.push(signature);
        }
        Ok(signatures)
    }

    fn mint_quote_response(&self, id: &str) -> Result<MintQuoteResponse<String>, Error> {
        let q = self
            .with(|s| s.mint_quotes.get(id).cloned())
            .ok_or(Error::UnknownQuote)?;
        Ok(match &q.method {
            PaymentMethod::Known(KnownMethod::Bolt12) => {
                MintQuoteResponse::Bolt12(MintQuoteBolt12Response {
                    quote: id.to_string(),
                    request: q.request.clone(),
                    amount: q.amount.map(Amount::from),
                    unit: CurrencyUnit::Sat,
                    expiry: q.expiry,
                    pubkey: q.pubkey.expect("bolt12 quotes carry a pubkey"),
                    amount_paid: Amount::from(q.amount_paid),
                    amount_issued: Amount::from(q.amount_issued),
                })
            }
            _ => {
                let amount = q.amount.unwrap_or(0);
                let state = if q.amount_issued >= amount && amount > 0 {
                    MintQuoteState::Issued
                } else if q.amount_paid >= amount && amount > 0 {
                    MintQuoteState::Paid
                } else {
                    MintQuoteState::Unpaid
                };
                MintQuoteResponse::Bolt11(MintQuoteBolt11Response {
                    quote: id.to_string(),
                    request: q.request.clone(),
                    amount: Some(Amount::from(amount)),
                    unit: Some(CurrencyUnit::Sat),
                    state,
                    expiry: q.expiry,
                    pubkey: q.pubkey,
                })
            }
        })
    }

    fn melt_response(&self, id: &str) -> Result<MeltQuoteBolt11Response<String>, Error> {
        let q = self
            .with(|s| s.melt_quotes.get(id).cloned())
            .ok_or(Error::UnknownQuote)?;
        Ok(MeltQuoteBolt11Response {
            quote: id.to_string(),
            amount: Amount::from(q.amount),
            fee_reserve: Amount::from(q.fee_reserve),
            state: q.state,
            expiry: now() + 3_600,
            payment_preimage: q.preimage.clone(),
            change: None,
            request: Some(q.request.clone()),
            unit: Some(CurrencyUnit::Sat),
        })
    }

    pub fn mint_info() -> MintInfo {
        let limits = |method| {
            (
                method,
                Some(Amount::from(1u64)),
                Some(Amount::from(500_000u64)),
            )
        };
        let mint_methods = [KnownMethod::Bolt11, KnownMethod::Bolt12]
            .into_iter()
            .map(|m| {
                let (method, min_amount, max_amount) = limits(PaymentMethod::Known(m));
                MintMethodSettings {
                    method,
                    unit: CurrencyUnit::Sat,
                    min_amount,
                    max_amount,
                    options: None,
                }
            })
            .collect();
        let melt_methods = [KnownMethod::Bolt11, KnownMethod::Bolt12]
            .into_iter()
            .map(|m| {
                let (method, min_amount, max_amount) = limits(PaymentMethod::Known(m));
                MeltMethodSettings {
                    method,
                    unit: CurrencyUnit::Sat,
                    min_amount,
                    max_amount,
                    options: None,
                }
            })
            .collect();
        MintInfo::new().name("sonar fake mint").nuts(
            Nuts::new()
                .nut04(NUT04Settings::new(mint_methods, false))
                .nut05(NUT05Settings {
                    methods: melt_methods,
                    disabled: false,
                })
                .nut07(true)
                .nut09(true)
                .nut20(true),
        )
    }
}

#[async_trait::async_trait]
impl MintConnector for FakeMint {
    async fn resolve_dns_txt(&self, _domain: &str) -> Result<Vec<String>, Error> {
        self.enter("resolve_dns_txt").await?;
        Ok(Vec::new())
    }

    async fn fetch_lnurl_pay_request(
        &self,
        _url: &str,
    ) -> Result<cdk::wallet::LnurlPayResponse, Error> {
        Err(Error::Custom("fake mint: no lnurl".into()))
    }

    async fn fetch_lnurl_invoice(
        &self,
        _url: &str,
    ) -> Result<cdk::wallet::LnurlPayInvoiceResponse, Error> {
        Err(Error::Custom("fake mint: no lnurl".into()))
    }

    async fn get_mint_keys(&self) -> Result<Vec<KeySet>, Error> {
        self.enter("get_mint_keys").await?;
        Ok(vec![self.keyset.clone()])
    }

    async fn get_mint_keyset(&self, keyset_id: Id) -> Result<KeySet, Error> {
        self.enter("get_mint_keyset").await?;
        if keyset_id == self.keyset.id {
            Ok(self.keyset.clone())
        } else {
            Err(Error::UnknownKeySet)
        }
    }

    async fn get_mint_keysets(&self) -> Result<KeysetResponse, Error> {
        self.enter("get_mint_keysets").await?;
        Ok(KeysetResponse {
            keysets: vec![KeySetInfo {
                id: self.keyset.id,
                unit: CurrencyUnit::Sat,
                active: true,
                input_fee_ppk: 0,
                final_expiry: None,
            }],
        })
    }

    async fn post_mint_quote(
        &self,
        request: MintQuoteRequest,
    ) -> Result<MintQuoteResponse<String>, Error> {
        self.enter("post_mint_quote").await?;
        let (method, amount, pubkey, expiry) = match request {
            MintQuoteRequest::Bolt11(r) => (
                PaymentMethod::Known(KnownMethod::Bolt11),
                Some(u64::from(r.amount)),
                r.pubkey,
                Some(now() + 3_600),
            ),
            MintQuoteRequest::Bolt12(r) => (
                PaymentMethod::Known(KnownMethod::Bolt12),
                r.amount.map(u64::from),
                Some(r.pubkey),
                None,
            ),
            _ => return Err(Error::UnsupportedPaymentMethod),
        };
        let id = self.fresh_id("mq");
        let request = match method {
            PaymentMethod::Known(KnownMethod::Bolt12) => format!("lno1fakeoffer{id}"),
            _ => format!("lnbc1fakeinvoice{id}"),
        };
        self.with(|s| {
            s.mint_quotes.insert(
                id.clone(),
                FakeMintQuote {
                    method,
                    request,
                    amount,
                    expiry,
                    pubkey,
                    amount_paid: 0,
                    amount_issued: 0,
                },
            );
        });
        self.mint_quote_response(&id)
    }

    async fn post_mint(
        &self,
        _method: &PaymentMethod,
        request: MintRequest<String>,
    ) -> Result<MintResponse, Error> {
        self.enter("post_mint").await?;
        let requested: u64 = request.outputs.iter().map(|o| u64::from(o.amount)).sum();
        let (mintable, pubkey) = self
            .with(|s| {
                s.mint_quotes
                    .get(&request.quote)
                    .map(|q| (q.amount_paid.saturating_sub(q.amount_issued), q.pubkey))
            })
            .ok_or(Error::UnknownQuote)?;
        // NUT-20: a locked quote mints only for the holder of its key.
        if let Some(pubkey) = pubkey {
            request
                .verify_signature(pubkey)
                .map_err(|e| Error::Custom(format!("fake mint: NUT-20 signature: {e}")))?;
        }
        if requested > mintable {
            return Err(Error::Custom(format!(
                "fake mint: {requested} requested, {mintable} mintable"
            )));
        }
        let signatures = self.sign(&request.outputs)?;
        self.with(|s| {
            if let Some(q) = s.mint_quotes.get_mut(&request.quote) {
                q.amount_issued += requested;
            }
        });
        Ok(MintResponse { signatures })
    }

    async fn post_batch_check_mint_quote_status(
        &self,
        _method: &PaymentMethod,
        request: BatchCheckMintQuoteRequest<String>,
    ) -> Result<Vec<MintQuoteResponse<String>>, Error> {
        self.enter("post_batch_check_mint_quote_status").await?;
        request
            .quotes
            .iter()
            .map(|id| self.mint_quote_response(id))
            .collect()
    }

    async fn post_batch_mint(
        &self,
        _method: &PaymentMethod,
        _request: BatchMintRequest<String>,
    ) -> Result<MintResponse, Error> {
        Err(Error::Custom("fake mint: batch mint unsupported".into()))
    }

    async fn post_melt_quote(
        &self,
        request: MeltQuoteRequest,
    ) -> Result<MeltQuoteCreateResponse<String>, Error> {
        self.enter("post_melt_quote").await?;
        self.with(|s| s.melt_quote_requests.push(request.clone()));
        let (method, raw, amount) = match &request {
            MeltQuoteRequest::Bolt11(r) => {
                let msat = match &r.options {
                    Some(options) => u64::from(options.amount_msat()),
                    None => r
                        .request
                        .amount_milli_satoshis()
                        .ok_or(Error::AmountUndefined)?,
                };
                (
                    PaymentMethod::Known(KnownMethod::Bolt11),
                    r.request.to_string(),
                    msat / 1_000,
                )
            }
            MeltQuoteRequest::Bolt12(r) => {
                let msat = r
                    .options
                    .as_ref()
                    .map(|o| u64::from(o.amount_msat()))
                    .ok_or(Error::AmountUndefined)?;
                (
                    PaymentMethod::Known(KnownMethod::Bolt12),
                    r.request.clone(),
                    msat / 1_000,
                )
            }
            _ => return Err(Error::UnsupportedPaymentMethod),
        };
        let id = self.fresh_id("melt");
        let fee_reserve = self.with(|s| s.fee_reserve);
        self.with(|s| {
            s.melt_quotes.insert(
                id.clone(),
                FakeMeltQuote {
                    method: method.clone(),
                    request: raw,
                    amount,
                    fee_reserve,
                    state: MeltQuoteState::Unpaid,
                    preimage: None,
                },
            );
        });
        let response = self.melt_response(&id)?;
        Ok(match method {
            PaymentMethod::Known(KnownMethod::Bolt12) => MeltQuoteCreateResponse::Bolt12(response),
            _ => MeltQuoteCreateResponse::Bolt11(response),
        })
    }

    async fn get_mint_quote_status(
        &self,
        _method: PaymentMethod,
        quote_id: &str,
    ) -> Result<MintQuoteResponse<String>, Error> {
        self.enter("get_mint_quote_status").await?;
        self.mint_quote_response(quote_id)
    }

    async fn get_melt_quote_status(
        &self,
        _method: PaymentMethod,
        quote_id: &str,
    ) -> Result<MeltQuoteResponse<String>, Error> {
        self.enter("get_melt_quote_status").await?;
        let method = self
            .with(|s| s.melt_quotes.get(quote_id).map(|q| q.method.clone()))
            .ok_or(Error::UnknownQuote)?;
        let response = self.melt_response(quote_id)?;
        Ok(match method {
            PaymentMethod::Known(KnownMethod::Bolt12) => MeltQuoteResponse::Bolt12(response),
            _ => MeltQuoteResponse::Bolt11(response),
        })
    }

    async fn post_melt(
        &self,
        _method: &PaymentMethod,
        request: MeltRequest<String>,
    ) -> Result<MeltQuoteResponse<String>, Error> {
        self.enter("post_melt").await?;
        let ys: Vec<PublicKey> = request
            .inputs()
            .iter()
            .map(|p| p.y())
            .collect::<Result<_, _>>()
            .map_err(|e| Error::Custom(e.to_string()))?;
        let outcome = self.with(|s| {
            s.melt_outcome
                .clone()
                .unwrap_or(MeltOutcome::Paid { preimage: None })
        });
        let quote_id = request.quote().clone();
        let method = self.with(|s| {
            let q = s.melt_quotes.get_mut(&quote_id)?;
            match &outcome {
                MeltOutcome::Paid { preimage } => {
                    q.state = MeltQuoteState::Paid;
                    q.preimage = preimage.clone();
                    s.spent.extend(ys.iter().copied());
                }
                MeltOutcome::Pending => {
                    q.state = MeltQuoteState::Pending;
                    s.pending.extend(ys.iter().copied());
                }
                MeltOutcome::Failed | MeltOutcome::Refused => q.state = MeltQuoteState::Unpaid,
            }
            Some(q.method.clone())
        });
        let method = method.ok_or(Error::UnknownQuote)?;
        match outcome {
            MeltOutcome::Failed => return Err(Error::PaymentFailed),
            MeltOutcome::Refused => return Err(Error::RequestAlreadyPaid),
            _ => {}
        }
        let response = self.melt_response(&quote_id)?;
        Ok(match method {
            PaymentMethod::Known(KnownMethod::Bolt12) => MeltQuoteResponse::Bolt12(response),
            _ => MeltQuoteResponse::Bolt11(response),
        })
    }

    async fn post_swap(&self, request: SwapRequest) -> Result<SwapResponse, Error> {
        self.enter("post_swap").await?;
        let ys: Vec<PublicKey> = request
            .inputs()
            .iter()
            .map(|p| p.y())
            .collect::<Result<_, _>>()
            .map_err(|e| Error::Custom(e.to_string()))?;
        if self.with(|s| ys.iter().any(|y| s.spent.contains(y))) {
            return Err(Error::TokenAlreadySpent);
        }
        let signatures = self.sign(request.outputs())?;
        self.with(|s| s.spent.extend(ys));
        Ok(SwapResponse { signatures })
    }

    async fn get_mint_info(&self) -> Result<MintInfo, Error> {
        self.enter("get_mint_info").await?;
        Ok(Self::mint_info())
    }

    async fn post_check_state(
        &self,
        request: CheckStateRequest,
    ) -> Result<CheckStateResponse, Error> {
        self.enter("post_check_state").await?;
        let states = self.with(|s| {
            request
                .ys
                .iter()
                .map(|y| ProofState {
                    y: *y,
                    state: if s.spent.contains(y) {
                        State::Spent
                    } else if s.pending.contains(y) {
                        State::Pending
                    } else {
                        State::Unspent
                    },
                    witness: None,
                })
                .collect()
        });
        Ok(CheckStateResponse { states })
    }

    async fn post_restore(&self, request: RestoreRequest) -> Result<RestoreResponse, Error> {
        self.enter("post_restore").await?;
        let (outputs, signatures) = self.with(|s| {
            request
                .outputs
                .iter()
                .filter_map(|o| s.signed.get(&o.blinded_secret).cloned())
                .unzip()
        });
        Ok(RestoreResponse {
            outputs,
            signatures,
        })
    }

    async fn get_auth_wallet(&self) -> Option<AuthWallet> {
        None
    }

    async fn set_auth_wallet(&self, _wallet: Option<AuthWallet>) {}
}
