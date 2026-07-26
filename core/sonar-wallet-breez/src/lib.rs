//! Breez SDK Liquid backend for the `sonar-wallet` interface.
//!
//! Wraps the async `LiquidSdk` behind the sync [`sonar_wallet::WalletBackend`]
//! trait with an owned tokio runtime, the same blocking-bridge shape
//! `SonarNode` uses in sonar-ffi. Wallet identity: the caller passes the
//! nsec-derived entropy from `sonar_wallet::wallet_entropy` and it goes into
//! `ConnectRequest::seed` raw — never through a BIP39 mnemonic, which would
//! derive a different wallet and break restore continuity with the existing
//! iOS/Android integrations.

use std::sync::{Arc, Mutex};

use breez_sdk_liquid::model::{
    ConnectRequest, EventListener, LiquidNetwork, ListPaymentsRequest, PayAmount, Payment,
    PaymentDetails, PaymentMethod, PaymentState, PaymentType, PrepareReceiveRequest,
    PrepareSendRequest, ReceivePaymentRequest, SdkEvent, SendPaymentRequest,
};
use breez_sdk_liquid::sdk::LiquidSdk;
use breez_sdk_liquid::InputType;
use sonar_wallet::{
    classify_destination, resolve_send_amount, Balance, Destination, DestinationKind, ExchangeRate,
    ListenerRegistry, Network, Result, WalletBackend, WalletCapabilities, WalletConfig,
    WalletError, WalletEvent, WalletEventListener,
};

/// Description attached to receive offers/invoices — matches the existing iOS
/// integration (`SonarWallet.createOffer`).
const RECEIVE_DESCRIPTION: &str = "Sonar";

pub struct BreezWallet {
    config: WalletConfig,
    runtime: tokio::runtime::Runtime,
    sdk: Mutex<Option<Arc<LiquidSdk>>>,
    /// Serializes connect/disconnect. Without it two threads racing `connect`
    /// both reach `LiquidSdk::connect` and open the same working dir twice,
    /// leaking a live SDK that still holds the database lock — the shape of
    /// the background-wake crashes this codebase has fought before. Never
    /// taken while holding `sdk`.
    lifecycle: Mutex<()>,
    listeners: Arc<ListenerRegistry>,
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
        Ok(Self {
            config,
            runtime,
            sdk: Mutex::new(None),
            lifecycle: Mutex::new(()),
            listeners: Arc::new(ListenerRegistry::new()),
        })
    }

    fn sdk(&self) -> Result<Arc<LiquidSdk>> {
        self.sdk
            .lock()
            .expect("sdk lock poisoned")
            .clone()
            .ok_or(WalletError::NotConnected)
    }

    fn breez_config(&self) -> Result<breez_sdk_liquid::model::Config> {
        let network = match self.config.network {
            Network::Mainnet => LiquidNetwork::Mainnet,
            // Breez 0.12's default_config rejects testnet; keep the interface
            // honest instead of silently mapping to regtest.
            Network::Testnet => return Err(WalletError::Unsupported("breez testnet")),
        };
        let mut config = LiquidSdk::default_config(network, self.config.api_key.clone())
            .map_err(|e| WalletError::Backend(e.to_string()))?;
        config.working_dir = self.config.working_dir.to_string_lossy().into_owned();
        Ok(config)
    }
}

impl WalletBackend for BreezWallet {
    fn capabilities(&self) -> WalletCapabilities {
        WalletCapabilities {
            node_lifecycle: true,
            webhook: true,
            fiat_rates: true,
            bolt11_send: true,
            bolt12_send: true,
            bolt12_receive: true,
        }
    }

    fn connect(&self) -> Result<()> {
        let _lifecycle = self.lifecycle.lock().expect("lifecycle lock poisoned");
        if self.is_connected() {
            return Ok(());
        }
        let req = ConnectRequest {
            config: self.breez_config()?,
            mnemonic: None,
            passphrase: None,
            seed: Some(self.config.seed.clone()),
        };
        let sdk = self
            .runtime
            .block_on(LiquidSdk::connect(req))
            .map_err(|e| WalletError::Backend(e.to_string()))?;
        let forwarder = Box::new(ForwardingListener {
            listeners: self.listeners.clone(),
        });
        self.runtime
            .block_on(sdk.add_event_listener(forwarder))
            .map_err(|e| WalletError::Backend(e.to_string()))?;
        *self.sdk.lock().expect("sdk lock poisoned") = Some(sdk);
        self.listeners.dispatch(&WalletEvent::Connected);
        Ok(())
    }

    fn disconnect(&self) -> Result<()> {
        let _lifecycle = self.lifecycle.lock().expect("lifecycle lock poisoned");
        let sdk = self.sdk.lock().expect("sdk lock poisoned").take();
        let Some(sdk) = sdk else { return Ok(()) };
        let result = self
            .runtime
            .block_on(sdk.disconnect())
            .map_err(|e| WalletError::Backend(e.to_string()));
        self.listeners.dispatch(&WalletEvent::Disconnected);
        result
    }

    fn is_connected(&self) -> bool {
        self.sdk.lock().expect("sdk lock poisoned").is_some()
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

    fn receive_offer(&self) -> Result<String> {
        let sdk = self.sdk()?;
        self.runtime.block_on(async {
            let prepare_response = sdk
                .prepare_receive_payment(&PrepareReceiveRequest {
                    payment_method: PaymentMethod::Bolt12Offer,
                    amount: None,
                })
                .await
                .map_err(map_payment_error)?;
            let response = sdk
                .receive_payment(&ReceivePaymentRequest {
                    prepare_response,
                    description: Some(RECEIVE_DESCRIPTION.to_string()),
                    description_hash: None,
                    payer_note: None,
                })
                .await
                .map_err(map_payment_error)?;
            Ok(response.destination)
        })
    }

    fn parse_destination(&self, input: &str) -> Result<Destination> {
        let sdk = self.sdk()?;
        let parsed = self.runtime.block_on(sdk.parse(input.trim()));
        match parsed {
            Ok(input_type) => Ok(map_input_type(input, input_type)),
            Err(e) => {
                // Keep pure classification as a fallback so offline parsing of
                // well-formed prefixes still works (LNURL resolution needs the
                // network, for example).
                let fallback = classify_destination(input);
                if fallback.kind == DestinationKind::Unknown {
                    Err(WalletError::InvalidDestination(e.to_string()))
                } else {
                    Ok(fallback)
                }
            }
        }
    }

    fn send(
        &self,
        destination: &Destination,
        amount_sats: Option<u64>,
        note: &str,
    ) -> Result<sonar_wallet::Payment> {
        let sdk = self.sdk()?;
        // Breez rejects an explicit amount on a destination that already
        // carries one, so only forward an amount when we must settle an
        // amountless destination.
        let amount = resolve_send_amount(amount_sats, destination.amount_sats)?;
        self.runtime.block_on(async {
            let prepare_response = sdk
                .prepare_send_payment(&PrepareSendRequest {
                    destination: destination.raw.clone(),
                    amount: amount.map(|receiver_amount_sat| PayAmount::Bitcoin {
                        receiver_amount_sat,
                    }),
                    disable_mrh: None,
                    payment_timeout_sec: None,
                })
                .await
                .map_err(map_payment_error)?;
            let response = sdk
                .send_payment(&SendPaymentRequest {
                    prepare_response,
                    use_asset_fees: None,
                    payer_note: (!note.is_empty()).then(|| note.to_string()),
                })
                .await
                .map_err(map_payment_error)?;
            Ok(map_payment(&response.payment))
        })
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
        Ok(payments.iter().map(map_payment).collect())
    }

    fn fetch_fiat_rates(&self) -> Result<Vec<ExchangeRate>> {
        let sdk = self.sdk()?;
        let rates = self
            .runtime
            .block_on(sdk.fetch_fiat_rates())
            .map_err(|e| WalletError::Network(e.to_string()))?;
        Ok(rates
            .into_iter()
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
        let _lifecycle = self.lifecycle.lock().expect("lifecycle lock poisoned");
        if self.is_connected() {
            return Err(WalletError::Backend(
                "disconnect before wiping local storage".into(),
            ));
        }
        let dir = &self.config.working_dir;
        // This is a recursive delete driven by caller-supplied config, so
        // refuse obviously-wrong targets rather than trusting the path.
        guard_wipe_path(dir)?;
        if dir.exists() {
            std::fs::remove_dir_all(dir)
                .map_err(|e| WalletError::Backend(format!("wipe {}: {e}", dir.display())))?;
        }
        Ok(())
    }
}

/// Reject recursive-delete targets that cannot plausibly be a wallet working
/// directory: the filesystem root, `$HOME` itself, and relative paths (whose
/// meaning depends on the process CWD).
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
    Ok(())
}

struct ForwardingListener {
    listeners: Arc<ListenerRegistry>,
}

#[async_trait::async_trait]
impl EventListener for ForwardingListener {
    async fn on_event(&self, e: SdkEvent) {
        let event = match e {
            SdkEvent::PaymentSucceeded { details } => {
                let payment = map_payment(&details);
                if payment.incoming {
                    WalletEvent::PaymentReceived { payment }
                } else {
                    WalletEvent::PaymentSent { payment }
                }
            }
            SdkEvent::PaymentFailed { details } => WalletEvent::PaymentFailed {
                payment: map_payment(&details),
            },
            SdkEvent::Synced => WalletEvent::Synced,
            _ => return,
        };
        self.listeners.dispatch(&event);
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

fn map_payment(p: &Payment) -> sonar_wallet::Payment {
    let (preimage, note, payment_hash) = match &p.details {
        PaymentDetails::Lightning {
            preimage,
            description,
            payment_hash,
            ..
        } => (
            preimage.clone(),
            (!description.is_empty()).then(|| description.clone()),
            payment_hash.clone(),
        ),
        _ => (None, None, None),
    };
    // Same id precedence the Kotlin bridge uses: txId, else payment hash,
    // else destination.
    let id = p
        .tx_id
        .clone()
        .or(payment_hash)
        .or_else(|| p.destination.clone())
        .unwrap_or_default();
    sonar_wallet::Payment {
        id,
        amount_sats: p.amount_sat,
        fees_sats: Some(p.fees_sat),
        incoming: p.payment_type == PaymentType::Receive,
        timestamp_secs: u64::from(p.timestamp),
        status: map_status(p.status),
        preimage,
        note,
    }
}

fn map_status(s: PaymentState) -> sonar_wallet::PaymentStatus {
    match s {
        PaymentState::Complete => sonar_wallet::PaymentStatus::Complete,
        PaymentState::Failed
        | PaymentState::TimedOut
        | PaymentState::Refundable
        | PaymentState::RefundPending => sonar_wallet::PaymentStatus::Failed,
        PaymentState::Created | PaymentState::Pending | PaymentState::WaitingFeeAcceptance => {
            sonar_wallet::PaymentStatus::Pending
        }
    }
}

fn map_input_type(raw: &str, input_type: InputType) -> Destination {
    let trimmed = raw.trim().to_string();
    match input_type {
        InputType::Bolt11 { invoice } => Destination {
            raw: invoice.bolt11.clone(),
            kind: DestinationKind::Bolt11,
            amount_sats: invoice.amount_msat.map(|msat| msat / 1_000),
            note: invoice.description.clone(),
        },
        InputType::Bolt12Offer { bip353_address, .. } => Destination {
            // Keep what the user typed (a BIP353 address resolves to an offer
            // but the address is the meaningful raw form to display).
            raw: bip353_address.unwrap_or(trimmed),
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
    use std::path::PathBuf;

    fn config(network: Network) -> WalletConfig {
        WalletConfig {
            seed: vec![7u8; 32],
            network,
            api_key: None,
            working_dir: PathBuf::from("/tmp/sonar-wallet-breez-test"),
        }
    }

    #[test]
    fn short_seed_is_rejected() {
        let mut cfg = config(Network::Mainnet);
        cfg.seed = vec![1u8; 16];
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
            Err(WalletError::Unsupported("breez testnet"))
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
    fn wipe_refuses_dangerous_paths() {
        assert!(guard_wipe_path(std::path::Path::new("/")).is_err());
        assert!(guard_wipe_path(std::path::Path::new("relative/dir")).is_err());
        if let Some(home) = std::env::var_os("HOME") {
            assert!(guard_wipe_path(std::path::Path::new(&home)).is_err());
            assert!(guard_wipe_path(&PathBuf::from(home).join(".sonar-wallet")).is_ok());
        }
    }

    #[test]
    fn status_mapping_covers_all_states() {
        use sonar_wallet::PaymentStatus as S;
        assert_eq!(map_status(PaymentState::Complete), S::Complete);
        for failed in [
            PaymentState::Failed,
            PaymentState::TimedOut,
            PaymentState::Refundable,
            PaymentState::RefundPending,
        ] {
            assert_eq!(map_status(failed), S::Failed);
        }
        for pending in [
            PaymentState::Created,
            PaymentState::Pending,
            PaymentState::WaitingFeeAcceptance,
        ] {
            assert_eq!(map_status(pending), S::Pending);
        }
    }
}
