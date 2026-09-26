//! The mint connection, with one thing recorded on the side: which melt
//! requests ended without an answer from the mint.
//!
//! CDK cannot tell those apart once it has handled them. When the melt POST
//! fails, CDK asks the mint for the quote's state and, if it reads Unpaid,
//! compensates the proofs and returns `PaymentFailed`, the same error a mint
//! that genuinely failed the payment produces. But Unpaid is also what a mint
//! reports before it has started on a request that is still on its way (held
//! by a proxy, say), and that request can then be paid over the compensation.
//! Reporting it Failed invites the user to pay again. Only the connector sees
//! whether the mint answered, so it records the quote ids of melts that got
//! no answer and the wallet treats those as ambiguous.

use std::collections::HashSet;
use std::fmt::Debug;
use std::sync::{Arc, Mutex};

use cdk::mint_url::MintUrl;
use cdk::nuts::{
    AuthToken, BatchCheckMintQuoteRequest, BatchMintRequest, CheckStateRequest, CheckStateResponse,
    Id, KeySet, KeysetResponse, MeltRequest, MintInfo, MintRequest, MintResponse, PaymentMethod,
    RestoreRequest, RestoreResponse, SwapRequest, SwapResponse,
};
use cdk::wallet::{
    AuthMintConnector, AuthWallet, BaseHttpClient, LnurlPayInvoiceResponse, LnurlPayResponse,
    MintConnector, RateLimitConfig, RateLimiterManager,
};
use cdk::{
    Error, MeltQuoteCreateResponse, MeltQuoteRequest, MeltQuoteResponse, MintQuoteRequest,
    MintQuoteResponse, OidcClient,
};

/// Quote ids of melt requests the mint never answered.
#[derive(Debug, Default)]
pub(crate) struct UnansweredMelts(Mutex<HashSet<String>>);

impl UnansweredMelts {
    fn set(&self) -> std::sync::MutexGuard<'_, HashSet<String>> {
        self.0.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn record(&self, quote_id: &str) {
        self.set().insert(quote_id.to_string());
    }

    fn clear(&self, quote_id: &str) {
        self.set().remove(quote_id);
    }

    /// Whether the last melt request for `quote_id` went unanswered; forgets it.
    pub(crate) fn take(&self, quote_id: &str) -> bool {
        self.set().remove(quote_id)
    }
}

/// The mint answered the request with a Cashu error: it read the request
/// and turned it down. Anything else (a reset, a timeout, a proxy's 5xx, a
/// body that is not a Cashu error) means the answer, if any, never arrived.
pub(crate) fn mint_answered(e: &Error) -> bool {
    matches!(
        e,
        Error::PaymentFailed
            | Error::PendingQuote
            | Error::TokenPending
            | Error::UnknownErrorResponse(_)
    ) || mint_refused(e)
}

/// The Cashu errors a mint answers a melt it refused outright with: nothing
/// of that request is left to be applied later.
pub(crate) fn mint_refused(e: &Error) -> bool {
    matches!(
        e,
        Error::RequestAlreadyPaid
            | Error::TokenAlreadySpent
            | Error::TransactionUnbalanced(..)
            | Error::AmountOutofLimitRange(..)
            | Error::DuplicateInputs
            | Error::DuplicateOutputs
            | Error::UnknownKeySet
            | Error::InactiveKeyset
            | Error::ExpiredKeyset
            | Error::ExpiredQuote(..)
            | Error::UnknownQuote
            | Error::MeltingDisabled
            | Error::UnsupportedUnit
            | Error::IncorrectQuoteAmount
            | Error::SignatureMissingOrInvalid
            | Error::DHKE(_)
    )
}

/// CDK's own default client, as `WalletBuilder` builds it when none is given:
/// HTTP over a rate-limited transport whose budget persists in the store.
pub(crate) fn default_client(
    mint_url: MintUrl,
    localstore: Arc<dyn cdk::cdk_database::WalletDatabase<cdk::cdk_database::Error> + Send + Sync>,
) -> Arc<dyn MintConnector + Send + Sync> {
    let limiter = RateLimiterManager::new(RateLimitConfig::default(), Some(localstore));
    let transport = cdk_common::rate_limit::RateLimitedTransport::with_manager(
        cdk_http_client::Async::default(),
        limiter,
    );
    Arc::new(BaseHttpClient::with_shared_transport(
        mint_url,
        Arc::new(transport),
        None,
    ))
}

/// `inner` with unanswered melt requests recorded in `unanswered`.
#[derive(Debug)]
pub(crate) struct RecordingConnector {
    pub(crate) inner: Arc<dyn MintConnector + Send + Sync>,
    pub(crate) unanswered: Arc<UnansweredMelts>,
}

#[cfg_attr(target_arch = "wasm32", async_trait::async_trait(?Send))]
#[cfg_attr(not(target_arch = "wasm32"), async_trait::async_trait)]
impl MintConnector for RecordingConnector {
    fn auth_connector(
        &self,
        mint_url: MintUrl,
        cat: Option<AuthToken>,
    ) -> Arc<dyn AuthMintConnector + Send + Sync> {
        self.inner.auth_connector(mint_url, cat)
    }

    fn oidc_client(&self, openid_discovery: String, client_id: Option<String>) -> OidcClient {
        self.inner.oidc_client(openid_discovery, client_id)
    }

    async fn connect_websocket(
        &self,
        url: &str,
        headers: &[(&str, &str)],
    ) -> Result<
        (
            cdk_common::ws_client::WsSender,
            cdk_common::ws_client::WsReceiver,
        ),
        cdk_common::ws_client::WsError,
    > {
        self.inner.connect_websocket(url, headers).await
    }

    #[cfg(not(target_arch = "wasm32"))]
    async fn resolve_dns_txt(&self, domain: &str) -> Result<Vec<String>, Error> {
        self.inner.resolve_dns_txt(domain).await
    }

    async fn fetch_lnurl_pay_request(&self, url: &str) -> Result<LnurlPayResponse, Error> {
        self.inner.fetch_lnurl_pay_request(url).await
    }

    async fn fetch_lnurl_invoice(&self, url: &str) -> Result<LnurlPayInvoiceResponse, Error> {
        self.inner.fetch_lnurl_invoice(url).await
    }

    async fn get_mint_keys(&self) -> Result<Vec<KeySet>, Error> {
        self.inner.get_mint_keys().await
    }

    async fn get_mint_keyset(&self, keyset_id: Id) -> Result<KeySet, Error> {
        self.inner.get_mint_keyset(keyset_id).await
    }

    async fn get_mint_keysets(&self) -> Result<KeysetResponse, Error> {
        self.inner.get_mint_keysets().await
    }

    async fn post_mint_quote(
        &self,
        request: MintQuoteRequest,
    ) -> Result<MintQuoteResponse<String>, Error> {
        self.inner.post_mint_quote(request).await
    }

    async fn post_mint(
        &self,
        method: &PaymentMethod,
        request: MintRequest<String>,
    ) -> Result<MintResponse, Error> {
        self.inner.post_mint(method, request).await
    }

    async fn post_batch_check_mint_quote_status(
        &self,
        method: &PaymentMethod,
        request: BatchCheckMintQuoteRequest<String>,
    ) -> Result<Vec<MintQuoteResponse<String>>, Error> {
        self.inner
            .post_batch_check_mint_quote_status(method, request)
            .await
    }

    async fn post_batch_mint(
        &self,
        method: &PaymentMethod,
        request: BatchMintRequest<String>,
    ) -> Result<MintResponse, Error> {
        self.inner.post_batch_mint(method, request).await
    }

    async fn post_melt_quote(
        &self,
        request: MeltQuoteRequest,
    ) -> Result<MeltQuoteCreateResponse<String>, Error> {
        self.inner.post_melt_quote(request).await
    }

    async fn get_mint_quote_status(
        &self,
        method: PaymentMethod,
        quote_id: &str,
    ) -> Result<MintQuoteResponse<String>, Error> {
        self.inner.get_mint_quote_status(method, quote_id).await
    }

    async fn get_melt_quote_status(
        &self,
        method: PaymentMethod,
        quote_id: &str,
    ) -> Result<MeltQuoteResponse<String>, Error> {
        self.inner.get_melt_quote_status(method, quote_id).await
    }

    async fn post_melt(
        &self,
        method: &PaymentMethod,
        request: MeltRequest<String>,
    ) -> Result<MeltQuoteResponse<String>, Error> {
        let quote_id = request.quote().clone();
        let result = self.inner.post_melt(method, request).await;
        match &result {
            Err(e) if !mint_answered(e) => {
                tracing::warn!("melt {quote_id}: no answer from the mint ({e})");
                self.unanswered.record(&quote_id);
            }
            _ => self.unanswered.clear(&quote_id),
        }
        result
    }

    async fn post_swap(&self, request: SwapRequest) -> Result<SwapResponse, Error> {
        self.inner.post_swap(request).await
    }

    async fn get_mint_info(&self) -> Result<MintInfo, Error> {
        self.inner.get_mint_info().await
    }

    async fn post_check_state(
        &self,
        request: CheckStateRequest,
    ) -> Result<CheckStateResponse, Error> {
        self.inner.post_check_state(request).await
    }

    async fn post_restore(&self, request: RestoreRequest) -> Result<RestoreResponse, Error> {
        self.inner.post_restore(request).await
    }

    async fn get_auth_wallet(&self) -> Option<AuthWallet> {
        self.inner.get_auth_wallet().await
    }

    async fn set_auth_wallet(&self, wallet: Option<AuthWallet>) {
        self.inner.set_auth_wallet(wallet).await
    }
}
