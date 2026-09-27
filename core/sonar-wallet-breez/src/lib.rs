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
    ListenerRegistry, Network, PaymentLookup, PaymentLookupStatus, PaymentStatus, PreparedSend,
    PreparedSendToken, ReceiveMethod, ReceiveRequest, Result, WalletBackend, WalletCapabilities,
    WalletConfig, WalletError, WalletEvent, WalletEventListener,
};

/// Description attached to receive offers/invoices — matches the existing iOS
/// integration (`SonarWallet.createOffer`).
const RECEIVE_DESCRIPTION: &str = "Sonar";

/// Connection state. Kept in ONE mutex so a `disconnect` racing a `connect`
/// always observes either "the SDK is published" or "the connect has not
/// committed yet and will abandon" — never a torn state where it sees neither
/// and returns success over a node that is about to go live.
///
/// The lock is only ever held for short critical sections; the network work in
/// `LiquidSdk::connect` happens with the lock released, so `disconnect` can
/// never be parked behind it.
#[derive(Default)]
struct Lifecycle {
    sdk: Option<Arc<LiquidSdk>>,
    /// A connect is between "claimed the slot" and "committed or abandoned".
    connecting: bool,
    /// A disconnect is between "claimed the teardown" and "slot cleared".
    /// While it is set the SDK is still published (the slot clears in the same
    /// critical section that clears this flag), so without it a concurrent
    /// `connect` would early-return Ok over a node that is mid-teardown —
    /// the mirror image of the connect-in-flight race.
    disconnecting: bool,
    /// Bumped by every `disconnect`. A connect that was in flight compares the
    /// generation it started with, under the same lock it publishes with, so a
    /// disconnect racing a slow connect is honoured rather than silently undone.
    generation: u64,
    /// The published handle is a RETAINED one: its teardown failed and it was
    /// kept only so a later `disconnect` can retry the close. It has no event
    /// forwarder, so it must never satisfy the connected fast path — a wallet
    /// that reports Ok and then delivers no events, forever, is the failure
    /// every rollback in this file exists to prevent.
    defunct: bool,
}

impl Lifecycle {
    /// The established session, if any — fully set up (listener installed),
    /// not mid-teardown, not retained after a failed close. This is the ONE
    /// predicate operational code may use; earlier revisions duplicated these
    /// conditions at call sites and they drifted, which is how a defunct
    /// handle stayed quotable after it was already quarantined elsewhere.
    fn established(&self) -> Option<(Arc<LiquidSdk>, u64)> {
        if self.connecting || self.disconnecting || self.defunct {
            return None;
        }
        self.sdk.clone().map(|sdk| (sdk, self.generation))
    }
}

pub struct BreezWallet {
    config: WalletConfig,
    /// Two workers is enough for the blocking bridge: every public method
    /// issues one `block_on` and waits, and breez spawns its own background
    /// tasks onto this runtime.
    runtime: Option<tokio::runtime::Runtime>,
    state: Mutex<Lifecycle>,
    listeners: Arc<ListenerRegistry>,
    events_tx: mpsc::Sender<WalletEvent>,
    /// Live quotes from `prepare_send`, keyed by the opaque token handed to the
    /// caller. Breez's `PrepareSendResponse` is not `Clone`, so it is parked
    /// here rather than serialized into the token.
    quotes: Mutex<HashMap<String, breez_sdk_liquid::model::PrepareSendResponse>>,
    /// Makes each quote token unique. Two concurrent prepares for the same
    /// destination and amount must not collide: whoever sent first would
    /// otherwise execute the other's quote, at a fee they never saw.
    quote_seq: AtomicU64,
    /// Process-unique id for this wallet object; see the token construction in
    /// `prepare_send`.
    instance: u64,
}

/// Allocator for [`BreezWallet::instance`].
static NEXT_WALLET_INSTANCE: AtomicU64 = AtomicU64::new(0);

/// Cap on parked quotes. A caller that prepares and never sends (an abandoned
/// confirmation sheet) leaves one entry behind; at the cap the oldest is
/// evicted, which bounds memory without an expiry clock and without ever
/// refusing a new preparation.
const MAX_LIVE_QUOTES: usize = 64;

/// Recover the monotonic sequence from a quote token (`{destination}#{seq}`),
/// so eviction can pick the oldest. An unparseable token sorts oldest, which is
/// the safe direction — it gets evicted first.
fn quote_seq_of(token: &str) -> u64 {
    token
        .rsplit_once('#')
        .and_then(|(_, seq)| seq.parse().ok())
        .unwrap_or(0)
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
    /// This backend's capabilities are static metadata — they depend on what
    /// the code routes to, not on any wallet state — so tooling can discover
    /// them without constructing a wallet (i.e. without holding a seed).
    pub const CAPABILITIES: WalletCapabilities = WalletCapabilities {
        node_lifecycle: true,
        webhook: true,
        fiat_rates: true,
        // LNURL-pay and Lightning addresses need breez's separate `lnurl_pay`
        // API, which this wrapper does not route to yet; `send` refuses them
        // explicitly rather than letting `prepare_send_payment` fail with an
        // opaque parse error.
        lnurl_send: false,
        lightning_address_send: false,
        bolt11_send: true,
        bolt12_send: true,
        bolt12_receive: true,
        bolt11_receive: true,
    };

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
            runtime: Some(runtime),
            state: Mutex::new(Lifecycle::default()),
            listeners,
            events_tx,
            quotes: Mutex::new(HashMap::new()),
            quote_seq: AtomicU64::new(0),
            instance: NEXT_WALLET_INSTANCE.fetch_add(1, Ordering::Relaxed),
        })
    }

    fn state(&self) -> std::sync::MutexGuard<'_, Lifecycle> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// The owned runtime. `Option` only so `Drop` can move it out and shut it
    /// down without blocking; it is `Some` for the whole normal lifetime.
    fn rt(&self) -> &tokio::runtime::Runtime {
        self.runtime
            .as_ref()
            .expect("runtime is only taken during drop")
    }

    fn sdk(&self) -> Result<Arc<LiquidSdk>> {
        self.sdk_if_any().ok_or(WalletError::NotConnected)
    }

    /// The established session's handle — the one operational methods may use.
    ///
    /// A setup-phase handle (published, listener registration pending) is
    /// deliberately NOT exposed: setup can still fail and roll back, and a
    /// quote prepared through it in that window would survive as executable
    /// against a session that no longer exists. Lifecycle paths that must see
    /// the handle regardless (disconnect, wipe, drop) read `state.sdk`
    /// directly.
    fn sdk_if_any(&self) -> Option<Arc<LiquidSdk>> {
        // Established sessions only — see `Lifecycle::established` for why a
        // setup-phase, mid-teardown, or retained-after-failed-close handle is
        // excluded. All three stay reachable for lifecycle paths, which read
        // the slot directly.
        self.state().established().map(|(sdk, _)| sdk)
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

    /// Re-parse a destination through the connected SDK when it carries no
    /// amount, so an offline-classified invoice regains the amount encoded in
    /// it. Falls back to the caller's destination if the parse fails or adds
    /// nothing — this is an enrichment step, never a new failure mode.
    fn refine_destination(&self, sdk: &Arc<LiquidSdk>, destination: &Destination) -> Destination {
        if destination.amount_sats.is_some() {
            return destination.clone();
        }
        match self.rt().block_on(sdk.parse(destination.raw.trim())) {
            Ok(input_type) => {
                let refined = map_input_type(&destination.raw, input_type);
                if refined.amount_sats.is_some() {
                    refined
                } else {
                    destination.clone()
                }
            }
            Err(_) => destination.clone(),
        }
    }

    /// Shut an SDK handle down without touching wallet state. Used both by
    /// `disconnect` and to discard a connect that a concurrent disconnect
    /// abandoned.
    fn shutdown(&self, sdk: Arc<LiquidSdk>) -> Result<()> {
        self.rt()
            .block_on(sdk.disconnect())
            .map_err(|e| WalletError::Backend(e.to_string()))
    }
}

impl Drop for BreezWallet {
    fn drop(&mut self) {
        // Dropping the runtime blocks until breez's background tasks finish,
        // which can hang the dropping thread (a main-thread `deinit` on iOS).
        // Close the node first so there is nothing left to wait for.
        //
        // `block_on` panics if we are already inside a runtime — and so does
        // *dropping* the multi-threaded runtime, which happens automatically
        // when our fields drop. Returning early is therefore not enough: the
        // runtime must be moved out and shut down without blocking, or the
        // panic lands anyway and a panic in `drop` aborts the process.
        let runtime = self.runtime.take();
        let sdk = self
            .state
            .get_mut()
            .unwrap_or_else(|e| e.into_inner())
            .sdk
            .take();
        let Some(runtime) = runtime else { return };

        if tokio::runtime::Handle::try_current().is_ok() {
            // Dropped from async context. `shutdown_background` returns
            // immediately and is the one teardown safe to call from here; the
            // node close is abandoned rather than taking the process down.
            // Hosts should `disconnect()` and drop from a blocking context.
            runtime.shutdown_background();
            return;
        }
        // Blocking context: close the node first so dropping the runtime has
        // nothing left to wait on.
        if let Some(sdk) = sdk {
            let _ = runtime.block_on(sdk.disconnect());
        }
    }
}

impl WalletBackend for BreezWallet {
    fn capabilities(&self) -> WalletCapabilities {
        BreezWallet::CAPABILITIES
    }

    fn sync_wallet(&self) -> Result<()> {
        let sdk = self.sdk()?;
        self.rt()
            .block_on(sdk.sync(false))
            .map_err(|e| WalletError::Backend(e.to_string()))
    }

    fn connect(&self) -> Result<()> {
        let started_at = {
            let mut state = self.state();
            if state.disconnecting {
                // The SDK is still published while its teardown runs, so the
                // is-some fast path below would report Ok over a node that is
                // mid-shutdown. Refuse instead; the caller retries after the
                // teardown lands.
                return Err(WalletError::Busy("a disconnect is in progress".into()));
            }
            // Checked BEFORE the is-some fast path: during listener setup the
            // SDK is already published but the connection is not established,
            // and reporting Ok there hands the caller a wallet whose setup can
            // still fail and roll back underneath them.
            if state.connecting {
                // Do NOT report someone else's in-flight attempt as success:
                // the caller would proceed straight to `balance()` and get
                // `NotConnected` after a "successful" connect.
                return Err(WalletError::Busy("a connect is already in progress".into()));
            }
            if state.sdk.is_some() {
                if state.defunct {
                    // Live node, failed close, no event forwarder. Not an
                    // established connection: recovery is a disconnect() retry
                    // (which owns the retained handle), then a fresh connect.
                    return Err(WalletError::Backend(
                        "previous wallet session failed to close; call disconnect() to retry"
                            .into(),
                    ));
                }
                return Ok(());
            }
            state.connecting = true;
            state.generation
        };

        // Network work with the lock released, so `disconnect` never parks.
        let opened = (|| {
            let req = ConnectRequest {
                config: self.breez_config()?,
                mnemonic: None,
                passphrase: None,
                seed: Some(self.config.seed.to_vec()),
            };
            self.rt()
                .block_on(LiquidSdk::connect(req))
                .map_err(|e| WalletError::Backend(e.to_string()))
        })();

        let sdk = match opened {
            Ok(sdk) => sdk,
            Err(e) => {
                self.state().connecting = false;
                return Err(e);
            }
        };

        // Commit, or abandon if a disconnect won. `connecting` stays set until
        // listener setup finishes: the SDK is published (so events can never
        // reach hosts while `is_connected()` is false) but the connection is
        // NOT yet established — a concurrent `connect` must see Busy, not Ok,
        // or it proceeds into a wallet whose setup may still fail.
        {
            let mut state = self.state();
            if state.generation != started_at {
                // A disconnect landed while we were connecting; it wins, and
                // WE own the abandoned node's close. Claim the teardown so no
                // third caller can observe an idle lifecycle and open a second
                // node over the same working dir while this one is shutting
                // down.
                state.connecting = false;
                state.disconnecting = true;
                drop(state);
                let closed = self.shutdown(sdk.clone());
                let mut state = self.state();
                state.disconnecting = false;
                if let Err(close_err) = closed {
                    // Retain the only handle to a still-running node — marked
                    // defunct (no event forwarder) so neither the fast path
                    // nor operational accessors treat it as a session; only a
                    // disconnect() retry can recover it. And tell the caller:
                    // the disconnect that cancelled us has already returned,
                    // so this error is the one signal that recovery is needed.
                    state.sdk = Some(sdk);
                    state.defunct = true;
                    return Err(WalletError::Backend(format!(
                        "connect was cancelled and the abandoned node failed to close: {close_err}"
                    )));
                }
                return Ok(());
            }
            state.sdk = Some(sdk.clone());
        }

        let forwarder = Box::new(ForwardingListener {
            events: self.events_tx.clone(),
        });
        let registered = self.rt().block_on(sdk.add_event_listener(forwarder));

        let mut state = self.state();
        state.connecting = false;
        match registered {
            Ok(_) => {
                // A disconnect can have landed while we were registering. The
                // identity check and the emit share this critical section, so
                // the only orderings hosts can observe are ones that happened.
                let still_ours = state
                    .sdk
                    .as_ref()
                    .is_some_and(|published| Arc::ptr_eq(published, &sdk));
                if still_ours {
                    self.emit(WalletEvent::Connected);
                }
                Ok(())
            }
            Err(e) => {
                // Roll the connection back — a published wallet that delivers
                // no events, forever, is the alternative. Unless a disconnect
                // already owns the teardown: then slot and close are its.
                let ours = !state.disconnecting
                    && state
                        .sdk
                        .as_ref()
                        .is_some_and(|published| Arc::ptr_eq(published, &sdk));
                if ours {
                    // Claim the teardown, keep the SDK published while it
                    // runs, and retain it if the close fails — same
                    // discipline as every other shutdown path, so no window
                    // exists where a retry opens a second node over a
                    // database the first still holds.
                    state.disconnecting = true;
                    drop(state);
                    let closed = self.shutdown(sdk.clone());
                    let mut state = self.state();
                    state.disconnecting = false;
                    if closed.is_ok() {
                        if let Some(published) = state.sdk.as_ref() {
                            if Arc::ptr_eq(published, &sdk) {
                                state.sdk = None;
                            }
                        }
                    } else if state
                        .sdk
                        .as_ref()
                        .is_some_and(|published| Arc::ptr_eq(published, &sdk))
                    {
                        // Close failed: the retained handle has no forwarder.
                        state.defunct = true;
                    }
                }
                Err(WalletError::Backend(e.to_string()))
            }
        }
    }

    fn disconnect(&self) -> Result<()> {
        // Bumping the generation under the same lock `connect` commits with is
        // what makes this safe against an in-flight connect: either we see its
        // published SDK below, or it sees our bump and abandons its handle.
        // Never blocks on the connect itself.
        let sdk = {
            let mut state = self.state();
            state.generation = state.generation.wrapping_add(1);
            if state.disconnecting {
                // Another teardown owns the close; idempotent contract says
                // report success rather than double-closing the same node
                // concurrently.
                return Ok(());
            }
            // Clone rather than take: if teardown fails we must keep the only
            // handle able to retry it. Dropping it would leave a live node
            // holding the working-dir SQLite lock while `is_connected()`
            // reports false — the next connect would open a second node over
            // the same database and `wipe_local_storage` would sail past its
            // guard. This mirrors the invariant `SonarWallet.stopNode()`
            // documents on iOS.
            match state.sdk.clone() {
                Some(sdk) => {
                    state.disconnecting = true;
                    sdk
                }
                None => return Ok(()),
            }
        };
        let teardown = self.shutdown(sdk.clone());
        // Whatever happened, release the teardown claim and (on success) the
        // slot in ONE critical section, so `disconnecting == true` always
        // implies the SDK is still published. The quote purge and the
        // `Disconnected` emit stay inside the same section: emitting after
        // releasing the lock lets a racing connect interleave its `Connected`
        // the wrong way around.
        {
            let mut state = self.state();
            state.disconnecting = false;
            // On teardown failure, keep the handle so the caller can retry.
            // On success, clear by identity: if a rollback already released the
            // slot (or a reconnect published a NEW node — not possible today,
            // since connect refuses while `disconnecting`, but cheap to keep
            // honest), it is not ours to clear or announce.
            if teardown.is_ok()
                && state
                    .sdk
                    .as_ref()
                    .is_some_and(|published| Arc::ptr_eq(published, &sdk))
            {
                state.sdk = None;
                state.defunct = false;
                // Quotes were priced against the session that just ended;
                // executing one after reconnect would pay a stale route/fee.
                // (Lock order is state → quotes, everywhere.)
                self.quotes
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .clear();
                self.emit(WalletEvent::Disconnected);
            }
        }
        teardown
    }

    fn is_connected(&self) -> bool {
        self.sdk_if_any().is_some()
    }

    fn balance(&self) -> Result<Balance> {
        let sdk = self.sdk()?;
        let info = self
            .rt()
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
        self.rt().block_on(async {
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
        match self.rt().block_on(sdk.parse(input.trim())) {
            Ok(input_type) => Ok(map_input_type(input, input_type)),
            Err(e) => {
                // Connected, and the real parser said no. For destinations that
                // are fully self-describing — BOLT11, BOLT12, LNURL all carry
                // their own checksum — that verdict is authoritative and must
                // propagate: the prefix classifier does no checksum check, so
                // returning it as success lets a host advance to the amount or
                // confirmation screen for a corrupt invoice and only fail later
                // in `prepare_send`.
                //
                // Lightning addresses are the exception: resolving one needs
                // DNS/HTTP, so a failure here can be transient network trouble
                // rather than a bad address, and the classification is still
                // the most useful answer we have.
                let self_describing = matches!(
                    fallback.kind,
                    DestinationKind::Bolt11
                        | DestinationKind::Bolt12Offer
                        | DestinationKind::LnurlPay
                );
                if fallback.kind == DestinationKind::Unknown || self_describing {
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
        // Capture the session (handle + generation) the quote will be priced
        // against, so the insertion below can refuse a quote that straddled a
        // disconnect — the purge in `disconnect` only invalidates quotes that
        // are already in the map.
        let (sdk, session_gen) = self
            .state()
            .established()
            .ok_or(WalletError::NotConnected)?;
        // A destination classified offline (the documented pre-connect
        // validation path) carries `amount_sats: None` even for an
        // amount-bearing BOLT11 invoice, because the pure classifier does not
        // decode amounts. Re-parse through the connected SDK before deciding
        // there is no amount anywhere — otherwise a perfectly payable invoice
        // is rejected, and the "never pay one of two disagreeing figures"
        // guarantee has nothing to compare against.
        let destination = &self.refine_destination(&sdk, destination);
        // Breez rejects an explicit amount on a destination that already
        // carries one, so only forward an amount when we must settle an
        // amountless destination.
        let amount = resolve_send_amount(amount_sats, destination.amount_sats)?;
        let prepared = self
            .rt()
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
        // Unique per preparation: two overlapping confirmation flows for the
        // same destination and amount must not share a slot, or the first
        // sender executes the second quote at a fee it never displayed.
        // The instance component keeps a stale `PreparedSend` from an earlier
        // wallet object (a host that rebuilt the wallet under a still-open
        // confirmation sheet) from colliding with this instance's tokens:
        // per-instance sequences both start at zero, so `dest#0` alone could
        // resolve to a quote the user never saw.
        let token = format!(
            "{}#{}#{}",
            self.instance,
            destination.raw,
            self.quote_seq.fetch_add(1, Ordering::Relaxed)
        );
        {
            // The session check and the insertion share one critical section
            // (lock order state → quotes, everywhere): a disconnect that
            // completed while the quote was being priced has already purged
            // the map, and inserting after it would resurrect a quote priced
            // against a session that no longer exists — exactly what the purge
            // is for. Reject instead; the caller reconnects and re-prepares.
            let state = self.state();
            let session_alive = state.generation == session_gen
                && state
                    .sdk
                    .as_ref()
                    .is_some_and(|published| Arc::ptr_eq(published, &sdk));
            if !session_alive {
                return Err(WalletError::NotConnected);
            }
            let mut quotes = self.quotes.lock().unwrap_or_else(|e| e.into_inner());
            // Evict oldest rather than refusing: a user who abandons a
            // confirmation sheet never tells us, and `PreparedSend` has no drop
            // hook, so refusing at the cap would brick preparation for the rest
            // of the process after N cancellations. An evicted quote is
            // single-use and stale anyway, and `send` reports it as expired.
            while quotes.len() >= MAX_LIVE_QUOTES {
                let oldest = quotes.keys().min_by_key(|k| quote_seq_of(k)).cloned();
                match oldest {
                    Some(key) => {
                        quotes.remove(&key);
                    }
                    None => break,
                }
            }
            quotes.insert(token.clone(), prepared);
        }
        Ok(PreparedSend {
            destination: destination.clone(),
            amount_sats: quoted_amount,
            fees_sats,
            token: PreparedSendToken::Opaque(token),
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
            .rt()
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
            .rt()
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

    fn lookup_payment(&self, payment_hash: &str) -> Result<PaymentLookup> {
        let sdk = self.sdk()?;
        let payments = self
            .rt()
            .block_on(sdk.list_payments(&ListPaymentsRequest {
                filters: None,
                states: None,
                from_timestamp: None,
                to_timestamp: None,
                offset: None,
                limit: None,
                details: None,
                sort_ascending: Some(false),
            }))
            .map_err(map_payment_error)?;
        let Some(payment) = payments.iter().find(|payment| {
            payment.payment_type == PaymentType::Send
                && extract_details(payment).payment_hash.as_deref() == Some(payment_hash)
        }) else {
            return Ok(PaymentLookup::unknown());
        };
        Ok(PaymentLookup {
            status: map_lookup_status(payment.status),
            id: stable_id(payment),
            fees_sats: Some(payment.fees_sat),
        })
    }

    fn fetch_fiat_rates(&self) -> Result<Vec<ExchangeRate>> {
        let sdk = self.sdk()?;
        let rates = self
            .rt()
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
        self.rt()
            .block_on(sdk.register_webhook(url.to_string()))
            .map_err(|e| WalletError::Backend(e.to_string()))
    }

    fn unregister_webhook(&self) -> Result<()> {
        let sdk = self.sdk()?;
        self.rt()
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
        // Hold the lifecycle lock across the check AND the delete: otherwise a
        // concurrent `connect` can publish a node midway through
        // `remove_dir_all` and have its database pulled out from under it.
        let state = self.state();
        if state.sdk.is_some() || state.connecting || state.disconnecting {
            return Err(WalletError::Backend(
                "disconnect before wiping local storage".into(),
            ));
        }
        // Recursive delete driven by caller-supplied config: refuse targets
        // that cannot plausibly be one wallet's directory. `WalletConfig`
        // documents that working_dir must be dedicated to this wallet. The
        // guard returns the RESOLVED path, and that is what we delete — never
        // the raw config value, which may traverse.
        let target = guard_wipe_path(&self.config.working_dir)?;
        if target.exists() {
            std::fs::remove_dir_all(&target)
                .map_err(|e| WalletError::Backend(format!("wipe {}: {e}", target.display())))?;
        }
        Ok(())
    }
}

/// Gate on the recursive delete in `wipe_local_storage`. Returns the resolved
/// path that is safe to delete.
///
/// Lexical checks alone are not enough, in two distinct ways:
///
/// 1. **Traversal.** `/tmp/..` is absolute, has a parent, and is not lexically
///    `$HOME` — but `remove_dir_all` resolves it to `/`. Every check therefore
///    runs against the *canonicalized* path, and the canonical path is what the
///    caller deletes.
/// 2. **Over-broad but honest paths.** A host bug that drops one component
///    hands us `~/Library/Application Support`, which survives every rule
///    above. So the directory must additionally *look like* a wallet working
///    dir — empty/absent (nothing to lose) or containing only breez's own
///    artifacts. Anything else is somebody else's data.
fn guard_wipe_path(dir: &std::path::Path) -> Result<std::path::PathBuf> {
    let refuse = |why: &str| {
        Err(WalletError::Backend(format!(
            "refusing to wipe {}: {why}",
            dir.display()
        )))
    };
    if !dir.is_absolute() {
        return refuse("working_dir must be an absolute path");
    }

    // Resolve symlinks and `..` before judging anything. A non-existent path
    // cannot traverse into something that exists, but it can still contain
    // `..`, so reject those rather than guessing at their intent.
    let resolved = match dir.canonicalize() {
        Ok(resolved) => resolved,
        // Only a confirmed ABSENT path is harmless. Any other resolution
        // failure (permissions, I/O) must fail the destructive operation
        // closed: `exists()` returns false under the same access error, so
        // the wipe would otherwise report success while the state remains.
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            if dir
                .components()
                .any(|c| c == std::path::Component::ParentDir)
            {
                return refuse("path contains `..` and cannot be resolved");
            }
            // Absent path with no traversal: nothing to delete, nothing to risk.
            return Ok(dir.to_path_buf());
        }
        Err(e) => {
            return Err(WalletError::Backend(format!(
                "cannot resolve {}: {e}",
                dir.display()
            )))
        }
    };

    if resolved.parent().is_none() {
        return refuse("path resolves to the filesystem root");
    }
    for var in ["HOME", "TMPDIR"] {
        if let Some(value) = std::env::var_os(var) {
            if value.is_empty() {
                continue;
            }
            // Compare canonically: `/tmp` vs `/private/tmp` on macOS.
            let known = std::path::Path::new(&value)
                .canonicalize()
                .unwrap_or_else(|_| std::path::PathBuf::from(&value));
            if resolved == known {
                return refuse(&format!("path resolves to ${var}"));
            }
        }
    }
    // $TMPDIR alone is not enough: when it is unset the platform still has an
    // effective temp root (`/tmp` on Linux), and deleting the SHARED system
    // temp directory must be refused no matter how it was reached.
    let system_tmp = std::env::temp_dir();
    let system_tmp = system_tmp.canonicalize().unwrap_or(system_tmp);
    if resolved == system_tmp {
        return refuse("path resolves to the system temp directory");
    }
    if !resolved.is_dir() {
        return refuse("path is not a directory");
    }
    let entries: Vec<_> = std::fs::read_dir(&resolved)
        .map_err(|e| WalletError::Backend(format!("read {}: {e}", resolved.display())))?
        .flatten()
        .collect();
    if entries.is_empty() {
        return Ok(resolved);
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
    Ok(resolved)
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
            // Every remaining balance-affecting transition maps to `Synced`,
            // whose contract is "re-query state". Dropping these left a
            // pending send or a completed refund invisible until some
            // unrelated later event happened to arrive — the existing Android
            // and JVM bridges refresh the balance on exactly these variants.
            SdkEvent::Synced
            | SdkEvent::DataSynced { .. }
            | SdkEvent::PaymentPending { .. }
            | SdkEvent::PaymentRefunded { .. }
            | SdkEvent::PaymentWaitingConfirmation { .. }
            | SdkEvent::PaymentWaitingFeeAcceptance { .. } => WalletEvent::Synced,
            // A sync failure changes no balance and has no interface event; the
            // next successful sync will emit one.
            SdkEvent::SyncFailed { .. } => return,
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
    // Only a *completed* send reports the fee-exclusive receiver amount. Every
    // other send state — pending, timed out, refundable, and failed alike —
    // still carries the fee-inclusive payer amount, so excluding `Failed` here
    // made a failed row overstate by the fee while a timed-out row beside it
    // did not.
    let unsettled_send =
        p.payment_type == PaymentType::Send && !matches!(p.status, PaymentState::Complete);
    if unsettled_send {
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

fn map_lookup_status(s: PaymentState) -> PaymentLookupStatus {
    match map_status(s) {
        PaymentStatus::Pending => PaymentLookupStatus::Pending,
        PaymentStatus::Complete => PaymentLookupStatus::Complete,
        PaymentStatus::Failed => PaymentLookupStatus::Failed,
        PaymentStatus::Refundable => PaymentLookupStatus::Refundable,
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
    fn wipe_refuses_paths_that_traverse_to_the_root() {
        // Each of these is absolute, has a parent, and is not lexically $HOME —
        // every lexical rule passes — yet each resolves somewhere catastrophic.
        // Which rule catches it is platform-dependent (on macOS `/tmp` is a
        // symlink to `/private/tmp`, so `/tmp/..` lands on `/private`, refused
        // as "not a wallet dir" rather than as the root); what must hold on
        // every platform is that none of them is ever deleted.
        for traversal in ["/tmp/..", "/tmp/../..", "/usr/local/../..", "/etc/.."] {
            assert!(
                guard_wipe_path(std::path::Path::new(traversal)).is_err(),
                "traversal must be refused: {traversal}"
            );
        }
        // A path that unambiguously resolves to `/` is caught by name.
        let err = guard_wipe_path(std::path::Path::new("/../../..")).unwrap_err();
        assert!(
            matches!(err, WalletError::Backend(ref m) if m.contains("filesystem root")),
            "unexpected error: {err}"
        );
        // Traversal in a path that does not exist is refused rather than
        // silently treated as "absent, nothing to lose".
        assert!(guard_wipe_path(std::path::Path::new("/nonexistent-xyz/../..")).is_err());
        // And traversal into $HOME, however it is spelled.
        if std::env::var_os("HOME").is_some() {
            let via_traversal = std::path::Path::new("/tmp/../..").join(
                std::path::Path::new(&std::env::var("HOME").unwrap())
                    .strip_prefix("/")
                    .unwrap(),
            );
            assert!(guard_wipe_path(&via_traversal).is_err());
        }
    }

    #[test]
    fn wipe_returns_the_resolved_path_not_the_raw_one() {
        // The caller must delete what the guard approved, not the raw config
        // value — otherwise the resolution work is decorative.
        let base = std::env::temp_dir().join("sonar-wallet-resolve-test");
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(base.join("wallet").join("mainnet")).unwrap();
        let indirect = base.join("wallet").join("mainnet").join("..");
        let resolved = guard_wipe_path(&indirect).expect("resolvable wallet dir");
        assert!(!resolved.to_string_lossy().contains(".."));
        assert_eq!(resolved, base.join("wallet").canonicalize().unwrap());
        let _ = std::fs::remove_dir_all(&base);
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
    fn every_unsettled_send_state_reports_the_same_net_amount() {
        // Only a completed send carries the fee-exclusive receiver amount.
        // Pending, timed-out, refundable and failed all carry the payer amount,
        // so they must all subtract the fee to agree with the settled row.
        for state in [
            PaymentState::Created,
            PaymentState::Pending,
            PaymentState::Failed,
            PaymentState::TimedOut,
            PaymentState::Refundable,
            PaymentState::RefundPending,
            PaymentState::WaitingFeeAcceptance,
        ] {
            let p = payment(
                PaymentType::Send,
                state,
                1_100,
                100,
                lightning_details(Some("hash-1")),
            );
            assert_eq!(net_amount_sats(&p), 1_000, "state {state:?} disagrees");
        }
        let settled = payment(
            PaymentType::Send,
            PaymentState::Complete,
            1_000,
            100,
            lightning_details(Some("hash-1")),
        );
        assert_eq!(net_amount_sats(&settled), 1_000);
    }

    #[test]
    fn concurrent_connect_is_refused_rather_than_falsely_succeeding() {
        let wallet = BreezWallet::new(config(Network::Mainnet)).unwrap();
        // Simulate an in-flight attempt without doing real network work.
        wallet.state().connecting = true;
        let err = wallet.connect().unwrap_err();
        assert!(
            matches!(err, WalletError::Busy(_)),
            "a second connect must not report success while one is in flight: {err}"
        );
        // And the wallet is still honestly reporting itself disconnected.
        assert!(!wallet.is_connected());
        assert!(matches!(wallet.balance(), Err(WalletError::NotConnected)));
    }

    #[test]
    fn quote_tokens_differ_across_wallet_instances() {
        // A host that rebuilds the wallet under a still-open confirmation
        // sheet must not have the stale PreparedSend resolve against the new
        // instance's quotes: both sequences start at zero, so without the
        // instance component `dest#0` would collide.
        let a = BreezWallet::new(config(Network::Mainnet)).unwrap();
        let b = BreezWallet::new(config(Network::Mainnet)).unwrap();
        assert_ne!(a.instance, b.instance);
        let token_a = format!("{}#{}#{}", a.instance, "lno1dest", 0);
        let token_b = format!("{}#{}#{}", b.instance, "lno1dest", 0);
        assert_ne!(token_a, token_b);
        // Eviction ordering still reads the trailing sequence.
        assert_eq!(quote_seq_of(&token_a), 0);
        assert_eq!(quote_seq_of(&format!("{}#{}#{}", a.instance, "d", 7)), 7);
    }

    #[test]
    fn non_established_lifecycle_states_are_not_operational() {
        // Setup-phase, mid-teardown, and retained-after-failed-close handles
        // must all be invisible to operational accessors — every one of these
        // states has produced its own review finding, so they are pinned as a
        // set: `Lifecycle::established` is the single predicate.
        let dest = Destination {
            raw: "lno1qcp4256ypq".into(),
            kind: DestinationKind::Bolt12Offer,
            amount_sats: None,
            note: None,
        };
        for set_state in [
            (|s: &mut Lifecycle| s.connecting = true) as fn(&mut Lifecycle),
            |s: &mut Lifecycle| s.disconnecting = true,
            |s: &mut Lifecycle| s.defunct = true,
        ] {
            let wallet = BreezWallet::new(config(Network::Mainnet)).unwrap();
            set_state(&mut wallet.state());
            assert!(!wallet.is_connected());
            assert!(matches!(wallet.balance(), Err(WalletError::NotConnected)));
            assert!(matches!(
                wallet.prepare_send(&dest, Some(100)),
                Err(WalletError::NotConnected)
            ));
        }
    }

    #[test]
    fn wipe_refuses_the_system_temp_directory() {
        // With $TMPDIR unset the platform still has an effective temp root;
        // the guard must refuse it by name, not only via the env var.
        let tmp = std::env::temp_dir();
        assert!(guard_wipe_path(&tmp).is_err());
    }

    #[test]
    fn wipe_is_refused_while_a_disconnect_is_in_flight() {
        let wallet = BreezWallet::new(config(Network::Mainnet)).unwrap();
        wallet.state().disconnecting = true;
        let err = wallet.wipe_local_storage().unwrap_err();
        assert!(
            matches!(err, WalletError::Backend(ref m) if m.contains("disconnect before")),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn quote_eviction_picks_the_oldest_and_never_refuses() {
        // The cap must not turn "user abandoned a confirmation sheet" into a
        // wallet that can never prepare another payment.
        assert_eq!(quote_seq_of("lno1abc#7"), 7);
        assert_eq!(quote_seq_of("lno1abc#0"), 0);
        // A destination containing '#' must not confuse the split.
        assert_eq!(quote_seq_of("weird#dest#42"), 42);
        // Unparseable sorts oldest, so it is evicted first rather than pinned.
        assert_eq!(quote_seq_of("no-separator"), 0);

        let keys = ["d#5", "d#2", "d#9"];
        let oldest = keys.iter().min_by_key(|k| quote_seq_of(k)).unwrap();
        assert_eq!(*oldest, "d#2");
    }

    #[test]
    fn connect_is_refused_while_a_disconnect_is_in_flight() {
        // The SDK stays published during teardown, so without the flag the
        // is-some fast path would report Ok over a node mid-shutdown.
        let wallet = BreezWallet::new(config(Network::Mainnet)).unwrap();
        wallet.state().disconnecting = true;
        let err = wallet.connect().unwrap_err();
        assert!(
            matches!(err, WalletError::Busy(ref m) if m.contains("disconnect")),
            "unexpected error: {err}"
        );
        // A second disconnect during the same window is idempotent success,
        // not a concurrent double-close of the same node.
        assert!(wallet.disconnect().is_ok());
    }

    #[test]
    fn wipe_is_refused_while_a_connect_is_in_flight() {
        let wallet = BreezWallet::new(config(Network::Mainnet)).unwrap();
        wallet.state().connecting = true;
        let err = wallet.wipe_local_storage().unwrap_err();
        assert!(
            matches!(err, WalletError::Backend(ref m) if m.contains("disconnect before")),
            "unexpected error: {err}"
        );
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
        assert_eq!(
            map_lookup_status(PaymentState::Complete),
            PaymentLookupStatus::Complete
        );
        assert_eq!(
            map_lookup_status(PaymentState::TimedOut),
            PaymentLookupStatus::Failed
        );
        assert_eq!(
            map_lookup_status(PaymentState::RefundPending),
            PaymentLookupStatus::Refundable
        );
        assert_eq!(
            map_lookup_status(PaymentState::Pending),
            PaymentLookupStatus::Pending
        );
    }
}
