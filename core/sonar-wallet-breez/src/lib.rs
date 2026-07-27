//! Breez SDK Liquid backend for the `sonar-wallet` interface.
//!
//! Wraps the async `LiquidSdk` behind the sync [`sonar_wallet::WalletBackend`]
//! trait with an owned tokio runtime, the same blocking-bridge shape
//! `SonarNode` uses in sonar-ffi. Wallet identity: the caller passes the
//! nsec-derived entropy from `sonar_wallet::wallet_entropy` and it goes into
//! `ConnectRequest::seed` raw — never through a BIP39 mnemonic, which would
//! derive a different wallet and break restore continuity with the existing
//! iOS/Android integrations.
//!
//! Two structural rules keep this safe to call from app lifecycle hooks:
//!
//! 1. **Host callbacks never run on a runtime thread.** Breez delivers events
//!    on its own async tasks; forwarding them to hosts from there would mean a
//!    host calling back into any method (`balance()` on `Synced`, say) hits
//!    `Runtime::block_on` from inside the runtime, which panics. Events are
//!    handed to a dedicated OS thread and dispatched from there, which also
//!    stops a slow host callback from stalling breez's event loop.
//! 2. **`disconnect` never waits for `connect`.** Lifecycle state is a short
//!    critical section plus a generation counter, not a mutex held across the
//!    network work — a close that can be delayed behind a slow connect is the
//!    0xdead10cc shape this repo has already been burned by three times.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex};

use breez_sdk_liquid::model::{
    ConnectRequest, EventListener, LiquidNetwork, ListPaymentsRequest, PayAmount, Payment,
    PaymentDetails, PaymentMethod, PaymentState, PaymentType, PrepareReceiveRequest,
    PrepareSendRequest, ReceiveAmount, ReceivePaymentRequest, SdkEvent, SendPaymentRequest,
};
use breez_sdk_liquid::sdk::LiquidSdk;
use breez_sdk_liquid::InputType;
use sonar_wallet::{
    classify_destination, resolve_send_amount, Balance, Destination, DestinationKind, ExchangeRate,
    ListenerRegistry, Network, PaymentStatus, PreparedSend, PreparedSendToken, ReceiveMethod,
    ReceiveRequest, Result, WalletBackend, WalletCapabilities, WalletConfig, WalletError,
    WalletEvent, WalletEventListener,
};

/// Description attached to receive offers/invoices — matches the existing iOS
/// integration (`SonarWallet.createOffer`).
const RECEIVE_DESCRIPTION: &str = "Sonar";

pub struct BreezWallet {
    config: WalletConfig,
    /// Two workers is enough for the blocking bridge: every public method
    /// issues one `block_on` and waits, and breez spawns its own background
    /// tasks onto this runtime.
    runtime: tokio::runtime::Runtime,
    sdk: Mutex<Option<Arc<LiquidSdk>>>,
    /// Bumped by every `disconnect`. A `connect` that was in flight compares
    /// the generation it started with against this before publishing its SDK,
    /// so a disconnect racing a slow connect is honoured instead of being
    /// silently undone.
    generation: AtomicU64,
    /// Held only for short critical sections, never across network work, so
    /// `disconnect` cannot be parked behind a slow `connect`.
    connecting: Mutex<bool>,
    listeners: Arc<ListenerRegistry>,
    events_tx: mpsc::Sender<WalletEvent>,
    /// Live quotes from `prepare_send`, keyed by the token handed to the
    /// caller. Breez's `PrepareSendResponse` is not `Clone`, so it is parked
    /// here rather than serialized into the token.
    quotes: Mutex<HashMap<String, breez_sdk_liquid::model::PrepareSendResponse>>,
}

/// Identifies one quote. Not a security boundary — quotes never leave the
/// process — just a stable handle that ties a `PreparedSend` to the exact
/// `PrepareSendResponse` that priced it.
fn quote_key(destination: &Destination, amount_sats: u64) -> String {
    format!("{}|{}", destination.raw, amount_sats)
}

/// Amount the backend itself quoted, when the caller supplied none and the
/// destination carried none.
fn prepared_amount_sats(p: &breez_sdk_liquid::model::PrepareSendResponse) -> Option<u64> {
    match p.amount {
        Some(PayAmount::Bitcoin {
            receiver_amount_sat,
        }) => Some(receiver_amount_sat),
        _ => None,
    }
}

impl BreezWallet {
    pub fn new(config: WalletConfig) -> Result<Self> {
        if config.seed.len() < 32 {
            return Err(WalletError::InvalidInput(
                "wallet seed must be at least 32 bytes".into(),
            ));
        }
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .map_err(|e| WalletError::Backend(format!("tokio runtime: {e}")))?;

        // Host callbacks run here, off the runtime, so they may re-enter the
        // backend. The thread ends when the wallet drops and the sender goes
        // with it.
        let listeners = Arc::new(ListenerRegistry::new());
        let (events_tx, events_rx) = mpsc::channel::<WalletEvent>();
        let dispatch_listeners = listeners.clone();
        std::thread::Builder::new()
            .name("sonar-wallet-events".into())
            .spawn(move || {
                while let Ok(event) = events_rx.recv() {
                    dispatch_listeners.dispatch(&event);
                }
            })
            .map_err(|e| WalletError::Backend(format!("event thread: {e}")))?;

        Ok(Self {
            config,
            runtime,
            sdk: Mutex::new(None),
            generation: AtomicU64::new(0),
            connecting: Mutex::new(false),
            listeners,
            events_tx,
            quotes: Mutex::new(HashMap::new()),
        })
    }

    fn sdk(&self) -> Result<Arc<LiquidSdk>> {
        self.sdk_if_any().ok_or(WalletError::NotConnected)
    }

    fn sdk_if_any(&self) -> Option<Arc<LiquidSdk>> {
        self.sdk
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
            .cloned()
    }

    fn emit(&self, event: WalletEvent) {
        // A closed channel just means the wallet is going away.
        let _ = self.events_tx.send(event);
    }

    fn breez_config(&self) -> Result<breez_sdk_liquid::model::Config> {
        let network = match self.config.network {
            Network::Mainnet => LiquidNetwork::Mainnet,
            // Breez 0.12's default_config rejects testnet; keep the interface
            // honest instead of silently mapping to regtest.
            Network::Testnet => return Err(WalletError::Unsupported("breez testnet".into())),
        };
        let mut config = LiquidSdk::default_config(network, self.config.api_key.clone())
            .map_err(|e| WalletError::Backend(e.to_string()))?;
        config.working_dir = self.config.working_dir.to_string_lossy().into_owned();
        Ok(config)
    }

    /// Shut an SDK handle down without touching wallet state. Used both by
    /// `disconnect` and to discard a connect that a concurrent disconnect
    /// abandoned.
    fn shutdown(&self, sdk: Arc<LiquidSdk>) -> Result<()> {
        self.runtime
            .block_on(sdk.disconnect())
            .map_err(|e| WalletError::Backend(e.to_string()))
    }
}

impl Drop for BreezWallet {
    fn drop(&mut self) {
        // Dropping the runtime blocks until breez's background tasks finish,
        // which can hang the dropping thread (a main-thread `deinit` on iOS).
        // Close the node first so there is nothing left to wait for.
        if let Some(sdk) = self.sdk.get_mut().unwrap_or_else(|e| e.into_inner()).take() {
            let _ = self.runtime.block_on(sdk.disconnect());
        }
    }
}

impl WalletBackend for BreezWallet {
    fn capabilities(&self) -> WalletCapabilities {
        WalletCapabilities {
            node_lifecycle: true,
            webhook: true,
            fiat_rates: true,
            // LNURL-pay and Lightning addresses need breez's separate
            // `lnurl_pay` API, which this wrapper does not route to yet;
            // `send` refuses them explicitly rather than letting
            // `prepare_send_payment` fail with an opaque parse error.
            lnurl_send: false,
            bolt11_send: true,
            bolt12_send: true,
            bolt12_receive: true,
            bolt11_receive: true,
        }
    }

    fn sync_wallet(&self) -> Result<()> {
        let sdk = self.sdk()?;
        self.runtime
            .block_on(sdk.sync(false))
            .map_err(|e| WalletError::Backend(e.to_string()))
    }

    fn connect(&self) -> Result<()> {
        {
            let mut connecting = self.connecting.lock().unwrap_or_else(|e| e.into_inner());
            if self.sdk_if_any().is_some() || *connecting {
                // Already connected, or another thread is doing it.
                return Ok(());
            }
            *connecting = true;
        }
        let started_at = self.generation.load(Ordering::Acquire);
        let result = (|| {
            let req = ConnectRequest {
                config: self.breez_config()?,
                mnemonic: None,
                passphrase: None,
                seed: Some(self.config.seed.to_vec()),
            };
            self.runtime
                .block_on(LiquidSdk::connect(req))
                .map_err(|e| WalletError::Backend(e.to_string()))
        })();
        *self.connecting.lock().unwrap_or_else(|e| e.into_inner()) = false;

        let sdk = result?;
        // A disconnect that landed while we were connecting wins: throw the
        // fresh handle away instead of publishing a node nobody asked for.
        if self.generation.load(Ordering::Acquire) != started_at {
            let _ = self.shutdown(sdk);
            return Ok(());
        }
        // Publish before registering the forwarder, so an event cannot reach a
        // host while `is_connected()` still reports false.
        *self.sdk.lock().unwrap_or_else(|e| e.into_inner()) = Some(sdk.clone());
        let forwarder = Box::new(ForwardingListener {
            events: self.events_tx.clone(),
        });
        if let Err(e) = self.runtime.block_on(sdk.add_event_listener(forwarder)) {
            return Err(WalletError::Backend(e.to_string()));
        }
        self.emit(WalletEvent::Connected);
        Ok(())
    }

    fn disconnect(&self) -> Result<()> {
        // Never blocks on an in-flight connect; the generation bump tells it
        // to discard whatever it produces.
        self.generation.fetch_add(1, Ordering::AcqRel);
        // Clone rather than take: if teardown fails we must keep the only
        // handle able to retry it. Dropping it would leave a live node
        // holding the working-dir SQLite lock while `is_connected()` reports
        // false — the next connect would open a second node over the same
        // database and `wipe_local_storage` would sail past its guard. This
        // mirrors the invariant `SonarWallet.stopNode()` documents on iOS.
        let Some(sdk) = self.sdk_if_any() else {
            return Ok(());
        };
        self.shutdown(sdk)?;
        *self.sdk.lock().unwrap_or_else(|e| e.into_inner()) = None;
        self.emit(WalletEvent::Disconnected);
        Ok(())
    }

    fn is_connected(&self) -> bool {
        self.sdk_if_any().is_some()
    }

    fn balance(&self) -> Result<Balance> {
        let sdk = self.sdk()?;
        let info = self
            .runtime
            .block_on(sdk.get_info())
            .map_err(|e| WalletError::Backend(e.to_string()))?;
        Ok(Balance {
            confirmed_sats: info.wallet_info.balance_sat,
            pending_receive_sats: info.wallet_info.pending_receive_sat,
            pending_send_sats: info.wallet_info.pending_send_sat,
        })
    }

    fn receive(&self, request: &ReceiveRequest) -> Result<String> {
        let sdk = self.sdk()?;
        let payment_method = match request.method {
            ReceiveMethod::Bolt12Offer => PaymentMethod::Bolt12Offer,
            ReceiveMethod::Bolt11Invoice => PaymentMethod::Bolt11Invoice,
            other => return Err(WalletError::Unsupported(format!("receiving via {other:?}"))),
        };
        if request.method == ReceiveMethod::Bolt11Invoice && request.amount_sats.is_none() {
            return Err(WalletError::InvalidInput(
                "a BOLT11 invoice needs an amount".into(),
            ));
        }
        let amount = request
            .amount_sats
            .map(|payer_amount_sat| ReceiveAmount::Bitcoin { payer_amount_sat });
        let description = request
            .description
            .clone()
            .unwrap_or_else(|| RECEIVE_DESCRIPTION.to_string());
        self.runtime.block_on(async {
            let prepare_response = sdk
                .prepare_receive_payment(&PrepareReceiveRequest {
                    payment_method,
                    amount,
                })
                .await
                .map_err(map_payment_error)?;
            let response = sdk
                .receive_payment(&ReceivePaymentRequest {
                    prepare_response,
                    description: Some(description),
                    description_hash: None,
                    payer_note: None,
                })
                .await
                .map_err(map_payment_error)?;
            Ok(response.destination)
        })
    }

    fn parse_destination(&self, input: &str) -> Result<Destination> {
        let fallback = classify_destination(input);
        // Offline (or pre-connect, which is normal on iOS where the node is
        // foreground-gated) still classifies well-formed prefixes.
        let Some(sdk) = self.sdk_if_any() else {
            return if fallback.kind == DestinationKind::Unknown {
                Err(WalletError::InvalidDestination(
                    "unrecognized destination".into(),
                ))
            } else {
                Ok(fallback)
            };
        };
        match self.runtime.block_on(sdk.parse(input.trim())) {
            Ok(input_type) => Ok(map_input_type(input, input_type)),
            Err(e) => {
                if fallback.kind == DestinationKind::Unknown {
                    Err(WalletError::InvalidDestination(e.to_string()))
                } else {
                    Ok(fallback)
                }
            }
        }
    }

    fn prepare_send(
        &self,
        destination: &Destination,
        amount_sats: Option<u64>,
    ) -> Result<PreparedSend> {
        if !destination.kind.is_supported_by(&self.capabilities()) {
            return Err(WalletError::Unsupported(format!(
                "sending to a {}",
                destination.kind.label()
            )));
        }
        let sdk = self.sdk()?;
        // Breez rejects an explicit amount on a destination that already
        // carries one, so only forward an amount when we must settle an
        // amountless destination.
        let amount = resolve_send_amount(amount_sats, destination.amount_sats)?;
        let prepared = self
            .runtime
            .block_on(sdk.prepare_send_payment(&PrepareSendRequest {
                destination: destination.raw.clone(),
                amount: amount.map(|receiver_amount_sat| PayAmount::Bitcoin {
                    receiver_amount_sat,
                }),
                disable_mrh: None,
                payment_timeout_sec: None,
            }))
            .map_err(map_payment_error)?;
        // The quote is what will actually be executed; hold it verbatim so
        // `send` cannot silently re-price.
        let quoted_amount = amount
            .or(destination.amount_sats)
            .or_else(|| prepared_amount_sats(&prepared))
            .ok_or_else(|| WalletError::InvalidDestination("backend quoted no amount".into()))?;
        let fees_sats = prepared.fees_sat;
        self.quotes
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(quote_key(destination, quoted_amount), prepared);
        Ok(PreparedSend {
            destination: destination.clone(),
            amount_sats: quoted_amount,
            fees_sats,
            token: PreparedSendToken::Opaque(quote_key(destination, quoted_amount)),
        })
    }

    fn send(&self, prepared: &PreparedSend, note: &str) -> Result<sonar_wallet::Payment> {
        let sdk = self.sdk()?;
        let PreparedSendToken::Opaque(key) = &prepared.token else {
            return Err(WalletError::InvalidInput(
                "this prepared send did not come from the Breez backend".into(),
            ));
        };
        // Consume the quote: a PreparedSend is single-use, so a double-tap on
        // a confirm button cannot pay twice off one quote.
        let quote = self
            .quotes
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(key)
            .ok_or_else(|| {
                WalletError::InvalidInput("prepared send is expired or already used".into())
            })?;
        let response = self
            .runtime
            .block_on(sdk.send_payment(&SendPaymentRequest {
                prepare_response: quote,
                use_asset_fees: None,
                payer_note: (!note.is_empty()).then(|| note.to_string()),
            }))
            .map_err(map_payment_error)?;
        // A just-sent payment always has an identity to fall back on: the
        // destination we paid.
        Ok(map_payment(&response.payment).unwrap_or_else(|| {
            payment_with_id(&response.payment, prepared.destination.raw.clone())
        }))
    }

    fn list_recent_payments(&self, limit: u32) -> Result<Vec<sonar_wallet::Payment>> {
        let sdk = self.sdk()?;
        let payments = self
            .runtime
            .block_on(sdk.list_payments(&ListPaymentsRequest {
                filters: None,
                states: None,
                from_timestamp: None,
                to_timestamp: None,
                offset: None,
                limit: Some(limit),
                details: None,
                sort_ascending: Some(false),
            }))
            .map_err(map_payment_error)?;
        Ok(payments.iter().filter_map(map_payment).collect())
    }

    fn fetch_fiat_rates(&self) -> Result<Vec<ExchangeRate>> {
        let sdk = self.sdk()?;
        let rates = self
            .runtime
            .block_on(sdk.fetch_fiat_rates())
            .map_err(|e| WalletError::Network(e.to_string()))?;
        Ok(rates
            .into_iter()
            // Drop non-live rates at the boundary: `ExchangeRate` documents
            // that <= 0.0 is not live, and a zero rate reaching a UI renders
            // every balance as 0.00.
            .filter(|rate| rate.value > 0.0 && rate.value.is_finite())
            .map(|rate| ExchangeRate {
                currency: rate.coin.to_uppercase(),
                per_btc: rate.value,
            })
            .collect())
    }

    fn register_webhook(&self, url: &str) -> Result<()> {
        let sdk = self.sdk()?;
        self.runtime
            .block_on(sdk.register_webhook(url.to_string()))
            .map_err(|e| WalletError::Backend(e.to_string()))
    }

    fn unregister_webhook(&self) -> Result<()> {
        let sdk = self.sdk()?;
        self.runtime
            .block_on(sdk.unregister_webhook())
            .map_err(|e| WalletError::Backend(e.to_string()))
    }

    fn add_event_listener(&self, listener: Arc<dyn WalletEventListener>) -> u64 {
        self.listeners.add(listener)
    }

    fn remove_event_listener(&self, id: u64) {
        self.listeners.remove(id);
    }

    fn wipe_local_storage(&self) -> Result<()> {
        if self.is_connected() {
            return Err(WalletError::Backend(
                "disconnect before wiping local storage".into(),
            ));
        }
        let dir = &self.config.working_dir;
        // Recursive delete driven by caller-supplied config: refuse targets
        // that cannot plausibly be one wallet's directory. `WalletConfig`
        // documents that working_dir must be dedicated to this wallet.
        guard_wipe_path(dir)?;
        if dir.exists() {
            std::fs::remove_dir_all(dir)
                .map_err(|e| WalletError::Backend(format!("wipe {}: {e}", dir.display())))?;
        }
        Ok(())
    }
}

/// Gate on the recursive delete in `wipe_local_storage`.
///
/// Rejecting the filesystem root and `$HOME` is not enough on its own: a host
/// bug that drops one path component hands us something like
/// `~/Library/Application Support`, which is absolute, has a parent, and is
/// not `$HOME`. So the directory must additionally *look like* a wallet
/// working dir — either empty/absent (nothing to lose) or containing breez's
/// own artifacts. Anything else is somebody else's data.
fn guard_wipe_path(dir: &std::path::Path) -> Result<()> {
    let refuse = |why: &str| {
        Err(WalletError::Backend(format!(
            "refusing to wipe {}: {why}",
            dir.display()
        )))
    };
    if !dir.is_absolute() {
        return refuse("working_dir must be an absolute path");
    }
    if dir.parent().is_none() {
        return refuse("path is the filesystem root");
    }
    if let Some(home) = std::env::var_os("HOME") {
        if !home.is_empty() && dir == std::path::Path::new(&home) {
            return refuse("path is the home directory");
        }
    }
    if !dir.exists() {
        return Ok(());
    }
    if !dir.is_dir() {
        return refuse("path is not a directory");
    }
    let entries: Vec<_> = std::fs::read_dir(dir)
        .map_err(|e| WalletError::Backend(format!("read {}: {e}", dir.display())))?
        .flatten()
        .collect();
    if entries.is_empty() {
        return Ok(());
    }
    // Breez nests per-network then per-fingerprint directories under the
    // working dir, and keeps its sqlite store inside.
    let looks_like_wallet_dir = entries.iter().all(|entry| {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        matches!(
            name.as_ref(),
            "mainnet" | "testnet" | "regtest" | "logs" | ".DS_Store"
        ) || name.starts_with("storage.sql")
    });
    if !looks_like_wallet_dir {
        return refuse("directory does not look like a wallet working dir");
    }
    Ok(())
}

/// Bridges breez's async event listener onto the wallet's own dispatch thread.
/// Deliberately does no host work itself: breez awaits listeners sequentially
/// while holding a lock, so anything slow here stalls its whole event loop.
struct ForwardingListener {
    events: mpsc::Sender<WalletEvent>,
}

#[async_trait::async_trait]
impl EventListener for ForwardingListener {
    async fn on_event(&self, e: SdkEvent) {
        let event = match e {
            SdkEvent::PaymentSucceeded { details } => match map_payment(&details) {
                Some(payment) if payment.incoming => WalletEvent::PaymentReceived { payment },
                Some(payment) => WalletEvent::PaymentSent { payment },
                None => return,
            },
            SdkEvent::PaymentFailed { details }
            | SdkEvent::PaymentRefundable { details }
            | SdkEvent::PaymentRefundPending { details } => match map_payment(&details) {
                Some(payment) => WalletEvent::PaymentFailed { payment },
                None => return,
            },
            SdkEvent::Synced => WalletEvent::Synced,
            _ => return,
        };
        let _ = self.events.send(event);
    }
}

fn map_payment_error(e: breez_sdk_liquid::error::PaymentError) -> WalletError {
    use breez_sdk_liquid::error::PaymentError as PE;
    match e {
        PE::InsufficientFunds => WalletError::InsufficientFunds,
        PE::InvalidInvoice { .. }
        | PE::InvalidNetwork { .. }
        | PE::AmountMissing { .. }
        | PE::AmountOutOfRange { .. } => WalletError::InvalidDestination(e.to_string()),
        other => WalletError::Backend(other.to_string()),
    }
}

/// Details common to both payment mappings.
struct Extracted {
    preimage: Option<String>,
    note: Option<String>,
    payment_hash: Option<String>,
}

fn extract_details(p: &Payment) -> Extracted {
    match &p.details {
        PaymentDetails::Lightning {
            preimage,
            description,
            payment_hash,
            payer_note,
            ..
        } => Extracted {
            preimage: preimage.clone(),
            // The payer note is the "message with the payment" the sender
            // attached; prefer it over the invoice description, which for our
            // own receives is the constant "Sonar".
            note: non_empty(payer_note.clone()).or_else(|| non_empty(Some(description.clone()))),
            payment_hash: payment_hash.clone(),
        },
        PaymentDetails::Liquid { description, .. } => Extracted {
            preimage: None,
            note: non_empty(Some(description.clone())),
            payment_hash: None,
        },
        _ => Extracted {
            preimage: None,
            note: None,
            payment_hash: None,
        },
    }
}

fn non_empty(s: Option<String>) -> Option<String> {
    s.filter(|s| !s.is_empty())
}

/// Net amount actually moved, excluding fees, consistent across the payment's
/// lifetime. Breez reports a fee-inclusive payer amount while a send is
/// pending and a fee-exclusive receiver amount once it settles, so without
/// this the figure shown to the user changes between "Sending" and "Sent".
fn net_amount_sats(p: &Payment) -> u64 {
    let pending_send = p.payment_type == PaymentType::Send
        && !matches!(p.status, PaymentState::Complete | PaymentState::Failed);
    if pending_send {
        p.amount_sat.saturating_sub(p.fees_sat)
    } else {
        p.amount_sat
    }
}

/// Map a breez payment, or `None` when it has no stable identity.
///
/// Deliberately mirrors `WalletBridge.android.kt`, which skips such events
/// rather than minting an id: an empty or invented id collides with other
/// unidentifiable payments, and hosts dedupe ledger rows by id, so the second
/// real payment would be silently dropped.
fn map_payment(p: &Payment) -> Option<sonar_wallet::Payment> {
    Some(payment_with_id(p, stable_id(p)?))
}

/// The payment hash comes first, unlike the Kotlin bridge's tx-id-first order:
/// breez leaves `tx_id` empty on a pending swap and fills it once confirmed,
/// so keying on it would give the same payment two different ids across its
/// lifetime and show the user duplicate rows.
fn stable_id(p: &Payment) -> Option<String> {
    // Each candidate is emptiness-checked in turn: filtering only at the end
    // lets a present-but-empty field (breez writes `Some("")` for an
    // unconfirmed tx_id) shadow a perfectly good destination.
    [
        extract_details(p).payment_hash,
        p.tx_id.clone(),
        p.destination.clone(),
    ]
    .into_iter()
    .flatten()
    .find(|id| !id.is_empty())
}

fn payment_with_id(p: &Payment, id: String) -> sonar_wallet::Payment {
    let details = extract_details(p);
    sonar_wallet::Payment {
        id,
        amount_sats: net_amount_sats(p),
        fees_sats: Some(p.fees_sat),
        incoming: p.payment_type == PaymentType::Receive,
        timestamp_secs: u64::from(p.timestamp),
        status: map_status(p.status),
        preimage: details.preimage,
        note: details.note,
    }
}

fn map_status(s: PaymentState) -> PaymentStatus {
    match s {
        PaymentState::Complete => PaymentStatus::Complete,
        PaymentState::Failed | PaymentState::TimedOut => PaymentStatus::Failed,
        // The money is recoverable but needs an explicit refund; calling this
        // "failed" makes users stop looking for funds that are still there.
        PaymentState::Refundable | PaymentState::RefundPending => PaymentStatus::Refundable,
        PaymentState::Created | PaymentState::Pending | PaymentState::WaitingFeeAcceptance => {
            PaymentStatus::Pending
        }
    }
}

fn map_input_type(raw: &str, input_type: InputType) -> Destination {
    let trimmed = raw.trim().to_string();
    match input_type {
        InputType::Bolt11 { invoice } => Destination {
            raw: invoice.bolt11.clone(),
            kind: DestinationKind::Bolt11,
            // Round sub-sat amounts up: this figure is what the user is shown
            // and confirms, and it must never understate what will be paid.
            amount_sats: invoice.amount_msat.map(|msat| msat.div_ceil(1_000)),
            note: invoice.description.clone(),
        },
        InputType::Bolt12Offer { offer, .. } => Destination {
            // Keep the resolved offer, not a BIP353 address: `send` hands this
            // straight back to the backend, and re-resolving the address would
            // be another DNS round trip that can fail or resolve differently.
            raw: offer.offer.clone(),
            kind: DestinationKind::Bolt12Offer,
            amount_sats: None,
            note: None,
        },
        InputType::LnUrlPay { bip353_address, .. } => Destination {
            kind: if bip353_address.is_some() || trimmed.contains('@') {
                DestinationKind::LightningAddress
            } else {
                DestinationKind::LnurlPay
            },
            raw: trimmed,
            amount_sats: None,
            note: None,
        },
        _ => classify_destination(raw),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sonar_wallet::Zeroizing;
    use std::path::PathBuf;

    fn config(network: Network) -> WalletConfig {
        WalletConfig {
            seed: Zeroizing::new(vec![7u8; 32]),
            network,
            api_key: None,
            working_dir: PathBuf::from("/tmp/sonar-wallet-breez-test"),
        }
    }

    fn lightning_details(payment_hash: Option<&str>) -> PaymentDetails {
        PaymentDetails::Lightning {
            swap_id: "swap-1".into(),
            description: "invoice description".into(),
            liquid_expiration_blockheight: 0,
            preimage: Some("beef".into()),
            invoice: None,
            payment_hash: payment_hash.map(str::to_string),
            destination_pubkey: None,
            lnurl_info: None,
            payer_note: None,
            claim_tx_id: None,
            refund_tx_id: None,
            refund_tx_amount_sat: None,
            bip353_address: None,
            bolt12_offer: None,
            settled_at: None,
        }
    }

    fn payment(
        payment_type: PaymentType,
        status: PaymentState,
        amount_sat: u64,
        fees_sat: u64,
        details: PaymentDetails,
    ) -> Payment {
        Payment {
            destination: None,
            tx_id: None,
            unblinding_data: None,
            timestamp: 1_700_000_000,
            amount_sat,
            fees_sat,
            swapper_fees_sat: None,
            payment_type,
            status,
            details,
        }
    }

    #[test]
    fn pending_send_amount_excludes_fees_so_it_does_not_change_on_settle() {
        // Breez reports a fee-INCLUSIVE payer amount while a send is pending
        // and a fee-EXCLUSIVE receiver amount once it lands. Both must map to
        // the same net figure, or the number moves under the user between
        // "Sending" and "Sent".
        let pending = payment(
            PaymentType::Send,
            PaymentState::Pending,
            1_100,
            100,
            lightning_details(Some("hash-1")),
        );
        let settled = payment(
            PaymentType::Send,
            PaymentState::Complete,
            1_000,
            100,
            lightning_details(Some("hash-1")),
        );
        assert_eq!(net_amount_sats(&pending), 1_000);
        assert_eq!(net_amount_sats(&settled), 1_000);

        // Receives are already net in both states.
        let received = payment(
            PaymentType::Receive,
            PaymentState::Pending,
            500,
            10,
            lightning_details(Some("hash-2")),
        );
        assert_eq!(net_amount_sats(&received), 500);
    }

    #[test]
    fn payment_id_is_stable_across_pending_and_settled() {
        // tx_id is absent while the swap is pending and present once
        // confirmed; keying on it would give one payment two ids and show the
        // user duplicate rows.
        let pending = payment(
            PaymentType::Send,
            PaymentState::Pending,
            1_000,
            0,
            lightning_details(Some("hash-1")),
        );
        let mut settled = payment(
            PaymentType::Send,
            PaymentState::Complete,
            1_000,
            0,
            lightning_details(Some("hash-1")),
        );
        settled.tx_id = Some("tx-abc".into());
        assert_eq!(stable_id(&pending), stable_id(&settled));
        assert_eq!(stable_id(&pending).as_deref(), Some("hash-1"));
    }

    #[test]
    fn unidentifiable_payments_are_skipped_not_given_an_empty_id() {
        // Two different payments with no stable identity must not both map to
        // "" — hosts dedupe by id, so the second would vanish from the ledger.
        let mut anonymous = payment(
            PaymentType::Receive,
            PaymentState::Complete,
            10,
            0,
            lightning_details(None),
        );
        anonymous.destination = None;
        assert!(stable_id(&anonymous).is_none());
        assert!(map_payment(&anonymous).is_none());

        // An empty string is not an identity either.
        anonymous.tx_id = Some(String::new());
        assert!(map_payment(&anonymous).is_none());

        // With a destination it becomes identifiable.
        anonymous.destination = Some("lno1xyz".into());
        assert_eq!(map_payment(&anonymous).unwrap().id, "lno1xyz");
    }

    #[test]
    fn payer_note_wins_over_the_invoice_description() {
        // Our own receives carry the constant "Sonar" description; the note
        // the sender attached is the interesting one.
        let mut details = lightning_details(Some("hash-1"));
        if let PaymentDetails::Lightning {
            ref mut payer_note, ..
        } = details
        {
            *payer_note = Some("pizza money".into());
        }
        let p = payment(
            PaymentType::Receive,
            PaymentState::Complete,
            100,
            0,
            details,
        );
        assert_eq!(
            map_payment(&p).unwrap().note.as_deref(),
            Some("pizza money")
        );

        // Falls back to the description when there is no note.
        let plain = payment(
            PaymentType::Receive,
            PaymentState::Complete,
            100,
            0,
            lightning_details(Some("hash-2")),
        );
        assert_eq!(
            map_payment(&plain).unwrap().note.as_deref(),
            Some("invoice description")
        );
    }

    #[test]
    fn mapped_payment_reports_fees_separately_from_the_amount() {
        let p = payment(
            PaymentType::Send,
            PaymentState::Complete,
            1_000,
            25,
            lightning_details(Some("hash-1")),
        );
        let mapped = map_payment(&p).unwrap();
        assert_eq!(mapped.amount_sats, 1_000);
        assert_eq!(mapped.fees_sats, Some(25));
        assert!(!mapped.incoming);
        assert_eq!(mapped.status, PaymentStatus::Complete);
        assert_eq!(mapped.preimage.as_deref(), Some("beef"));
    }

    #[test]
    fn short_seed_is_rejected() {
        let mut cfg = config(Network::Mainnet);
        cfg.seed = Zeroizing::new(vec![1u8; 16]);
        assert!(matches!(
            BreezWallet::new(cfg),
            Err(WalletError::InvalidInput(_))
        ));
    }

    #[test]
    fn testnet_is_reported_unsupported() {
        let wallet = BreezWallet::new(config(Network::Testnet)).unwrap();
        assert!(matches!(
            wallet.breez_config(),
            Err(WalletError::Unsupported(_))
        ));
    }

    #[test]
    fn disconnected_wallet_reports_not_connected() {
        let wallet = BreezWallet::new(config(Network::Mainnet)).unwrap();
        assert!(!wallet.is_connected());
        assert!(matches!(wallet.balance(), Err(WalletError::NotConnected)));
        // Idempotent disconnect on a never-connected wallet.
        assert!(wallet.disconnect().is_ok());
    }

    #[test]
    fn parse_works_offline_for_known_prefixes() {
        let wallet = BreezWallet::new(config(Network::Mainnet)).unwrap();
        assert!(!wallet.is_connected());
        let d = wallet.parse_destination("lno1qcp4256ypq").unwrap();
        assert_eq!(d.kind, DestinationKind::Bolt12Offer);
        assert!(matches!(
            wallet.parse_destination("total garbage"),
            Err(WalletError::InvalidDestination(_))
        ));
    }

    #[test]
    fn lnurl_destinations_are_refused_with_a_clear_error() {
        let wallet = BreezWallet::new(config(Network::Mainnet)).unwrap();
        let address = wallet.parse_destination("conor@sonar.hedwig.sh").unwrap();
        assert_eq!(address.kind, DestinationKind::LightningAddress);
        let err = wallet.prepare_send(&address, Some(100)).unwrap_err();
        assert!(
            matches!(err, WalletError::Unsupported(ref m) if m.contains("Lightning address")),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn wipe_refuses_dangerous_paths() {
        assert!(guard_wipe_path(std::path::Path::new("/")).is_err());
        assert!(guard_wipe_path(std::path::Path::new("relative/dir")).is_err());
        if let Some(home) = std::env::var_os("HOME") {
            assert!(guard_wipe_path(std::path::Path::new(&home)).is_err());
            // Absent path: nothing to lose.
            assert!(guard_wipe_path(&PathBuf::from(home).join(".sonar-wallet-absent")).is_ok());
        }
    }

    #[test]
    fn wipe_refuses_a_directory_full_of_someone_elses_data() {
        let base = std::env::temp_dir().join("sonar-wallet-guard-test");
        let _ = std::fs::remove_dir_all(&base);

        // Looks like a wallet dir: breez's own per-network subdirectory.
        let wallet_dir = base.join("wallet");
        std::fs::create_dir_all(wallet_dir.join("mainnet")).unwrap();
        assert!(guard_wipe_path(&wallet_dir).is_ok());

        // The realistic accident: a host drops a path component and hands us
        // the parent, which holds unrelated data.
        let container = base.join("container");
        std::fs::create_dir_all(container.join("Photos")).unwrap();
        std::fs::create_dir_all(container.join("Documents")).unwrap();
        let err = guard_wipe_path(&container).unwrap_err();
        assert!(
            matches!(err, WalletError::Backend(ref m) if m.contains("does not look like")),
            "unexpected error: {err}"
        );

        // Empty directory is harmless.
        let empty = base.join("empty");
        std::fs::create_dir_all(&empty).unwrap();
        assert!(guard_wipe_path(&empty).is_ok());

        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn status_mapping_covers_all_states() {
        assert_eq!(map_status(PaymentState::Complete), PaymentStatus::Complete);
        for failed in [PaymentState::Failed, PaymentState::TimedOut] {
            assert_eq!(map_status(failed), PaymentStatus::Failed);
        }
        for refundable in [PaymentState::Refundable, PaymentState::RefundPending] {
            assert_eq!(map_status(refundable), PaymentStatus::Refundable);
        }
        for pending in [
            PaymentState::Created,
            PaymentState::Pending,
            PaymentState::WaitingFeeAcceptance,
        ] {
            assert_eq!(map_status(pending), PaymentStatus::Pending);
        }
    }
}
