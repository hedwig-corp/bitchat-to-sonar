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
use std::sync::atomic::{AtomicBool, Ordering};
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

/// Builds a fresh `inner` client; see [`RecordingConnector`].
pub(crate) type Rebuild = Box<dyn Fn() -> Arc<dyn MintConnector + Send + Sync> + Send + Sync>;

/// `inner` with two things added:
///
/// - Melt requests the mint never answered are recorded in `unanswered`
///   (see the module doc).
/// - A call abandoned mid-flight (its future dropped, as the wallet's
///   deadlines do) rebuilds `inner` before the next call. The HTTP client
///   under CDK (bitreq 0.3) keeps one cached connection per host, and a
///   request dropped after it was written but before its answer was read
///   leaves that connection with an open request for good: every later
///   request on it waits for that answer, and times out in turn. One slow
///   mint answer left the wallet unable to reach the mint until the whole
///   wallet was rebuilt. A fresh client means a fresh connection pool.
pub(crate) struct RecordingConnector {
    inner: std::sync::RwLock<Arc<dyn MintConnector + Send + Sync>>,
    rebuild: Option<Rebuild>,
    /// A call was abandoned mid-flight since `inner` was built.
    tainted: AtomicBool,
    unanswered: Arc<UnansweredMelts>,
}

impl std::fmt::Debug for RecordingConnector {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RecordingConnector")
            .field("tainted", &self.tainted.load(Ordering::Relaxed))
            .finish()
    }
}

/// Marks the connector tainted if the call it guards never finished.
struct InFlight<'a> {
    tainted: &'a AtomicBool,
    finished: bool,
}

impl Drop for InFlight<'_> {
    fn drop(&mut self) {
        if !self.finished {
            self.tainted.store(true, Ordering::Release);
        }
    }
}

impl RecordingConnector {
    /// `rebuild`: how to make a fresh `inner` after an abandoned call; `None`
    /// keeps `inner` (an in-process test mint has no connection to poison).
    pub(crate) fn new(
        inner: Arc<dyn MintConnector + Send + Sync>,
        rebuild: Option<Rebuild>,
        unanswered: Arc<UnansweredMelts>,
    ) -> Self {
        Self {
            inner: std::sync::RwLock::new(inner),
            rebuild,
            tainted: AtomicBool::new(false),
            unanswered,
        }
    }

    /// The client for the next call: a fresh one if a call was abandoned.
    fn client(&self) -> Arc<dyn MintConnector + Send + Sync> {
        if self.tainted.swap(false, Ordering::AcqRel) {
            if let Some(rebuild) = &self.rebuild {
                tracing::warn!("a mint call was abandoned mid-flight: opening a fresh connection");
                let fresh = rebuild();
                *self.inner.write().unwrap_or_else(|e| e.into_inner()) = fresh;
            }
        }
        self.inner.read().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// Run one call on the current client, noting it if it never finishes.
    async fn call<T, F>(&self, f: impl FnOnce(Arc<dyn MintConnector + Send + Sync>) -> F) -> T
    where
        F: std::future::Future<Output = T>,
    {
        let mut guard = InFlight {
            tainted: &self.tainted,
            finished: false,
        };
        let out = f(self.client()).await;
        guard.finished = true;
        out
    }
}

#[cfg_attr(target_arch = "wasm32", async_trait::async_trait(?Send))]
#[cfg_attr(not(target_arch = "wasm32"), async_trait::async_trait)]
impl MintConnector for RecordingConnector {
    fn auth_connector(
        &self,
        mint_url: MintUrl,
        cat: Option<AuthToken>,
    ) -> Arc<dyn AuthMintConnector + Send + Sync> {
        self.client().auth_connector(mint_url, cat)
    }

    fn oidc_client(&self, openid_discovery: String, client_id: Option<String>) -> OidcClient {
        self.client().oidc_client(openid_discovery, client_id)
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
        self.call(|c| async move { c.connect_websocket(url, headers).await })
            .await
    }

    #[cfg(not(target_arch = "wasm32"))]
    async fn resolve_dns_txt(&self, domain: &str) -> Result<Vec<String>, Error> {
        self.call(|c| async move { c.resolve_dns_txt(domain).await })
            .await
    }

    async fn fetch_lnurl_pay_request(&self, url: &str) -> Result<LnurlPayResponse, Error> {
        self.call(|c| async move { c.fetch_lnurl_pay_request(url).await })
            .await
    }

    async fn fetch_lnurl_invoice(&self, url: &str) -> Result<LnurlPayInvoiceResponse, Error> {
        self.call(|c| async move { c.fetch_lnurl_invoice(url).await })
            .await
    }

    async fn get_mint_keys(&self) -> Result<Vec<KeySet>, Error> {
        self.call(|c| async move { c.get_mint_keys().await }).await
    }

    async fn get_mint_keyset(&self, keyset_id: Id) -> Result<KeySet, Error> {
        self.call(|c| async move { c.get_mint_keyset(keyset_id).await })
            .await
    }

    async fn get_mint_keysets(&self) -> Result<KeysetResponse, Error> {
        self.call(|c| async move { c.get_mint_keysets().await })
            .await
    }

    async fn post_mint_quote(
        &self,
        request: MintQuoteRequest,
    ) -> Result<MintQuoteResponse<String>, Error> {
        self.call(|c| async move { c.post_mint_quote(request).await })
            .await
    }

    async fn post_mint(
        &self,
        method: &PaymentMethod,
        request: MintRequest<String>,
    ) -> Result<MintResponse, Error> {
        self.call(|c| async move { c.post_mint(method, request).await })
            .await
    }

    async fn post_batch_check_mint_quote_status(
        &self,
        method: &PaymentMethod,
        request: BatchCheckMintQuoteRequest<String>,
    ) -> Result<Vec<MintQuoteResponse<String>>, Error> {
        self.call(|c| async move { c.post_batch_check_mint_quote_status(method, request).await })
            .await
    }

    async fn post_batch_mint(
        &self,
        method: &PaymentMethod,
        request: BatchMintRequest<String>,
    ) -> Result<MintResponse, Error> {
        self.call(|c| async move { c.post_batch_mint(method, request).await })
            .await
    }

    async fn post_melt_quote(
        &self,
        request: MeltQuoteRequest,
    ) -> Result<MeltQuoteCreateResponse<String>, Error> {
        self.call(|c| async move { c.post_melt_quote(request).await })
            .await
    }

    async fn get_mint_quote_status(
        &self,
        method: PaymentMethod,
        quote_id: &str,
    ) -> Result<MintQuoteResponse<String>, Error> {
        self.call(|c| async move { c.get_mint_quote_status(method, quote_id).await })
            .await
    }

    async fn get_melt_quote_status(
        &self,
        method: PaymentMethod,
        quote_id: &str,
    ) -> Result<MeltQuoteResponse<String>, Error> {
        self.call(|c| async move { c.get_melt_quote_status(method, quote_id).await })
            .await
    }

    async fn post_melt(
        &self,
        method: &PaymentMethod,
        request: MeltRequest<String>,
    ) -> Result<MeltQuoteResponse<String>, Error> {
        let quote_id = request.quote().clone();
        let result = self
            .call(|c| async move { c.post_melt(method, request).await })
            .await;
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
        self.call(|c| async move { c.post_swap(request).await })
            .await
    }

    async fn get_mint_info(&self) -> Result<MintInfo, Error> {
        self.call(|c| async move { c.get_mint_info().await }).await
    }

    async fn post_check_state(
        &self,
        request: CheckStateRequest,
    ) -> Result<CheckStateResponse, Error> {
        self.call(|c| async move { c.post_check_state(request).await })
            .await
    }

    async fn post_restore(&self, request: RestoreRequest) -> Result<RestoreResponse, Error> {
        self.call(|c| async move { c.post_restore(request).await })
            .await
    }

    async fn get_auth_wallet(&self) -> Option<AuthWallet> {
        self.call(|c| async move { c.get_auth_wallet().await })
            .await
    }

    async fn set_auth_wallet(&self, wallet: Option<AuthWallet>) {
        self.call(|c| async move { c.set_auth_wallet(wallet).await })
            .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_mint::FakeMint;
    use std::sync::atomic::AtomicUsize;
    use std::time::Duration;

    /// One abandoned call rebuilds the client before the next one; finished
    /// calls (successful or failed) never do.
    #[test]
    fn a_call_abandoned_mid_flight_rebuilds_the_client_once() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let mint = Arc::new(FakeMint::new());
        let builds = Arc::new(AtomicUsize::new(0));
        let rebuild: Rebuild = {
            let mint = mint.clone();
            let builds = builds.clone();
            Box::new(move || {
                builds.fetch_add(1, Ordering::SeqCst);
                mint.clone()
            })
        };
        let conn = RecordingConnector::new(
            mint.clone(),
            Some(rebuild),
            Arc::new(UnansweredMelts::default()),
        );
        rt.block_on(async {
            conn.get_mint_info().await.unwrap();
            mint.fail_next("get_mint_info", 1);
            assert!(conn.get_mint_info().await.is_err());
            assert_eq!(
                builds.load(Ordering::SeqCst),
                0,
                "finished calls keep the client"
            );

            mint.hang("get_mint_info");
            let abandoned =
                tokio::time::timeout(Duration::from_millis(100), conn.get_mint_info()).await;
            assert!(abandoned.is_err(), "the deadline dropped the call");
            mint.unhang("get_mint_info");
            conn.get_mint_info().await.unwrap();
            assert_eq!(
                builds.load(Ordering::SeqCst),
                1,
                "a fresh client after the abandoned call"
            );
            conn.get_mint_info().await.unwrap();
            assert_eq!(builds.load(Ordering::SeqCst), 1, "and only once");
        });
    }
}
