use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use crate::destination::{classify_destination, resolve_send_amount};
use crate::error::{Result, WalletError};
use crate::listeners::ListenerRegistry;
#[cfg(test)]
use crate::traits::prepare_and_send;
use crate::traits::{WalletBackend, WalletEventListener};
use crate::types::{
    Balance, Destination, ExchangeRate, Payment, PaymentStatus, PreparedSend, PreparedSendToken,
    ReceiveMethod, ReceiveRequest, WalletCapabilities, WalletEvent,
};

/// Flat fee the mock charges, so tests exercise the fee path rather than
/// assuming it is always zero.
const MOCK_FEE_SATS: u64 = 1;

/// Deterministic in-memory backend: proves the trait is implementable without
/// any network or storage, and gives hosts/tests a real `dyn WalletBackend`
/// to drive UI and FFI plumbing against.
pub struct MockWallet {
    connected: AtomicBool,
    balance: Mutex<Balance>,
    payments: Mutex<Vec<Payment>>,
    listeners: ListenerRegistry,
    /// Monotonic fake clock so tests are order-stable without real time.
    clock_secs: AtomicU64,
}

impl Default for MockWallet {
    fn default() -> Self {
        Self::new(0)
    }
}

impl MockWallet {
    pub fn new(starting_balance_sats: u64) -> Self {
        Self {
            connected: AtomicBool::new(false),
            balance: Mutex::new(Balance {
                confirmed_sats: starting_balance_sats,
                ..Balance::default()
            }),
            payments: Mutex::new(Vec::new()),
            listeners: ListenerRegistry::new(),
            clock_secs: AtomicU64::new(1_700_000_000),
        }
    }

    fn now(&self) -> u64 {
        self.clock_secs.fetch_add(1, Ordering::Relaxed)
    }

    fn ensure_connected(&self) -> Result<()> {
        if self.connected.load(Ordering::Acquire) {
            Ok(())
        } else {
            Err(WalletError::NotConnected)
        }
    }

    /// Test helper: credit the wallet as if a payment arrived.
    pub fn simulate_receive(&self, amount_sats: u64) -> Payment {
        let payment = Payment {
            id: format!("mock-in-{}", self.now()),
            amount_sats,
            fees_sats: Some(0),
            incoming: true,
            timestamp_secs: self.now(),
            status: PaymentStatus::Complete,
            preimage: None,
            note: None,
        };
        {
            let mut balance = self.balance.lock().expect("balance lock");
            balance.confirmed_sats += amount_sats;
        }
        self.payments
            .lock()
            .expect("payments lock")
            .push(payment.clone());
        self.listeners.dispatch(&WalletEvent::PaymentReceived {
            payment: payment.clone(),
        });
        payment
    }
}

impl WalletBackend for MockWallet {
    fn capabilities(&self) -> WalletCapabilities {
        WalletCapabilities {
            fiat_rates: true,
            lnurl_send: true,
            lightning_address_send: true,
            bolt11_send: true,
            bolt12_send: true,
            bolt12_receive: true,
            bolt11_receive: true,
            ..Default::default()
        }
    }

    fn connect(&self) -> Result<()> {
        if !self.connected.swap(true, Ordering::AcqRel) {
            self.listeners.dispatch(&WalletEvent::Connected);
        }
        Ok(())
    }

    fn disconnect(&self) -> Result<()> {
        if self.connected.swap(false, Ordering::AcqRel) {
            self.listeners.dispatch(&WalletEvent::Disconnected);
        }
        Ok(())
    }

    fn is_connected(&self) -> bool {
        self.connected.load(Ordering::Acquire)
    }

    fn balance(&self) -> Result<Balance> {
        self.ensure_connected()?;
        Ok(*self.balance.lock().expect("balance lock"))
    }

    fn sync_wallet(&self) -> Result<()> {
        self.ensure_connected()?;
        self.listeners.dispatch(&WalletEvent::Synced);
        Ok(())
    }

    fn receive(&self, request: &ReceiveRequest) -> Result<String> {
        self.ensure_connected()?;
        match request.method {
            ReceiveMethod::Bolt12Offer => Ok("lno1mockoffermockoffermockoffer".to_string()),
            ReceiveMethod::Bolt11Invoice => {
                let amount = request.amount_sats.ok_or_else(|| {
                    WalletError::InvalidInput("a BOLT11 invoice needs an amount".into())
                })?;
                Ok(format!("lnbc{amount}n1mockinvoice"))
            }
        }
    }

    fn parse_destination(&self, input: &str) -> Result<Destination> {
        let destination = classify_destination(input);
        if destination.raw.is_empty() {
            return Err(WalletError::InvalidDestination("empty input".into()));
        }
        Ok(destination)
    }

    fn prepare_send(
        &self,
        destination: &Destination,
        amount_sats: Option<u64>,
    ) -> Result<PreparedSend> {
        self.ensure_connected()?;
        if !destination.kind.is_supported_by(&self.capabilities()) {
            return Err(WalletError::Unsupported(format!(
                "sending to a {}",
                destination.kind.label()
            )));
        }
        // Same resolution rules every backend uses.
        let amount = match resolve_send_amount(amount_sats, destination.amount_sats)? {
            Some(explicit) => explicit,
            None => destination.amount_sats.ok_or_else(|| {
                WalletError::InvalidDestination("destination carries no amount".into())
            })?,
        };
        Ok(PreparedSend {
            destination: destination.clone(),
            amount_sats: amount,
            fees_sats: Some(MOCK_FEE_SATS),
            token: PreparedSendToken::None,
        })
    }

    fn send(&self, prepared: &PreparedSend, note: &str) -> Result<Payment> {
        self.ensure_connected()?;
        let amount = prepared.amount_sats;
        let fees = prepared.fees_sats.unwrap_or(0);
        {
            let mut balance = self.balance.lock().expect("balance lock");
            let debit = amount.saturating_add(fees);
            if balance.confirmed_sats < debit {
                return Err(WalletError::InsufficientFunds);
            }
            balance.confirmed_sats -= debit;
        }
        let payment = Payment {
            id: format!("mock-out-{}", self.now()),
            amount_sats: amount,
            fees_sats: Some(fees),
            incoming: false,
            timestamp_secs: self.now(),
            status: PaymentStatus::Complete,
            preimage: Some(format!("{:064x}", amount)),
            note: (!note.is_empty()).then(|| note.to_string()),
        };
        self.payments
            .lock()
            .expect("payments lock")
            .push(payment.clone());
        self.listeners.dispatch(&WalletEvent::PaymentSent {
            payment: payment.clone(),
        });
        Ok(payment)
    }

    fn list_recent_payments(&self, limit: u32) -> Result<Vec<Payment>> {
        self.ensure_connected()?;
        let payments = self.payments.lock().expect("payments lock");
        Ok(payments
            .iter()
            .rev()
            .take(limit as usize)
            .cloned()
            .collect())
    }

    fn fetch_fiat_rates(&self) -> Result<Vec<ExchangeRate>> {
        self.ensure_connected()?;
        Ok(vec![ExchangeRate {
            currency: "USD".to_string(),
            per_btc: 100_000.0,
        }])
    }

    fn add_event_listener(&self, listener: Arc<dyn WalletEventListener>) -> u64 {
        self.listeners.add(listener)
    }

    fn remove_event_listener(&self, id: u64) {
        self.listeners.remove(id);
    }

    fn wipe_local_storage(&self) -> Result<()> {
        // Same precondition the real backends enforce, so hosts cannot depend
        // on the mock being more permissive than what ships.
        if self.is_connected() {
            return Err(WalletError::Backend(
                "disconnect before wiping local storage".into(),
            ));
        }
        // Local state only: the transcript of payments. Funds ("on chain")
        // and the seed survive a wipe by design.
        self.payments.lock().expect("payments lock").clear();
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex as StdMutex;

    struct Recorder(StdMutex<Vec<&'static str>>);
    impl WalletEventListener for Recorder {
        fn on_event(&self, event: WalletEvent) {
            let tag = match event {
                WalletEvent::Connected => "connected",
                WalletEvent::Synced => "synced",
                WalletEvent::PaymentReceived { .. } => "received",
                WalletEvent::PaymentSent { .. } => "sent",
                WalletEvent::PaymentFailed { .. } => "failed",
                WalletEvent::Disconnected => "disconnected",
            };
            self.0.lock().unwrap().push(tag);
        }
    }

    fn wallet() -> MockWallet {
        let w = MockWallet::new(10_000);
        w.connect().unwrap();
        w
    }

    #[test]
    fn requires_connection() {
        let w = MockWallet::new(1_000);
        assert!(matches!(w.balance(), Err(WalletError::NotConnected)));
        w.connect().unwrap();
        assert_eq!(w.balance().unwrap().confirmed_sats, 1_000);
        w.disconnect().unwrap();
        assert!(matches!(w.receive_offer(), Err(WalletError::NotConnected)));
    }

    #[test]
    fn connect_and_disconnect_are_idempotent() {
        let w = MockWallet::new(0);
        let recorder = Arc::new(Recorder(StdMutex::new(Vec::new())));
        w.add_event_listener(recorder.clone());
        w.connect().unwrap();
        w.connect().unwrap();
        w.disconnect().unwrap();
        w.disconnect().unwrap();
        assert_eq!(
            *recorder.0.lock().unwrap(),
            vec!["connected", "disconnected"]
        );
    }

    #[test]
    fn send_decrements_balance_and_emits_event() {
        let w = wallet();
        let recorder = Arc::new(Recorder(StdMutex::new(Vec::new())));
        w.add_event_listener(recorder.clone());
        let dest = w.parse_destination("lno1qcp4256ypq").unwrap();
        let payment = prepare_and_send(&w, &dest, Some(2_500), "coffee").unwrap();
        assert!(!payment.incoming);
        assert_eq!(payment.amount_sats, 2_500);
        assert_eq!(payment.note.as_deref(), Some("coffee"));
        // Amount plus the quoted fee leaves the balance.
        assert_eq!(
            w.balance().unwrap().confirmed_sats,
            10_000 - 2_500 - MOCK_FEE_SATS
        );
        assert_eq!(*recorder.0.lock().unwrap(), vec!["sent"]);
    }

    #[test]
    fn prepare_quotes_the_fee_before_any_money_moves() {
        let w = wallet();
        let dest = w.parse_destination("lno1qcp4256ypq").unwrap();
        let prepared = w.prepare_send(&dest, Some(2_500)).unwrap();
        assert_eq!(prepared.amount_sats, 2_500);
        assert_eq!(prepared.fees_sats, Some(MOCK_FEE_SATS));
        // Preparing alone must not move funds — that is the whole point of
        // the split.
        assert_eq!(w.balance().unwrap().confirmed_sats, 10_000);
    }

    #[test]
    fn send_rejects_amountless_and_overdraft() {
        let w = wallet();
        let dest = w.parse_destination("lno1qcp4256ypq").unwrap();
        assert!(matches!(
            w.prepare_send(&dest, None),
            Err(WalletError::InvalidDestination(_))
        ));
        assert!(matches!(
            prepare_and_send(&w, &dest, Some(1_000_000), ""),
            Err(WalletError::InsufficientFunds)
        ));
        assert_eq!(w.balance().unwrap().confirmed_sats, 10_000);
    }

    #[test]
    fn receive_supports_offers_and_amount_bearing_invoices() {
        let w = wallet();
        assert!(w.receive_offer().unwrap().starts_with("lno1"));
        let invoice = w
            .receive(&ReceiveRequest {
                method: ReceiveMethod::Bolt11Invoice,
                amount_sats: Some(1_000),
                description: None,
            })
            .unwrap();
        assert!(invoice.starts_with("lnbc"));
        // A BOLT11 invoice with no amount is not a thing we can mint.
        assert!(matches!(
            w.receive(&ReceiveRequest {
                method: ReceiveMethod::Bolt11Invoice,
                amount_sats: None,
                description: None,
            }),
            Err(WalletError::InvalidInput(_))
        ));
    }

    #[test]
    fn recent_payments_newest_first_and_wipe_preserves_balance() {
        let w = wallet();
        w.simulate_receive(500);
        let dest = w.parse_destination("user@host.tld").unwrap();
        prepare_and_send(&w, &dest, Some(100), "").unwrap();
        let recent = w.list_recent_payments(10).unwrap();
        assert_eq!(recent.len(), 2);
        assert!(!recent[0].incoming, "newest (the send) first");
        assert!(recent[1].incoming);
        let balance = w.balance().unwrap();
        // Wiping is only allowed once disconnected.
        assert!(matches!(
            w.wipe_local_storage(),
            Err(WalletError::Backend(_))
        ));
        w.disconnect().unwrap();
        w.wipe_local_storage().unwrap();
        w.connect().unwrap();
        assert!(w.list_recent_payments(10).unwrap().is_empty());
        assert_eq!(w.balance().unwrap(), balance);
    }

    #[test]
    fn send_refuses_destination_kinds_the_backend_lacks() {
        struct NoLnurl(MockWallet);
        impl WalletBackend for NoLnurl {
            fn capabilities(&self) -> WalletCapabilities {
                WalletCapabilities {
                    lnurl_send: false,
                    lightning_address_send: false,
                    ..self.0.capabilities()
                }
            }
            fn connect(&self) -> Result<()> {
                self.0.connect()
            }
            fn disconnect(&self) -> Result<()> {
                self.0.disconnect()
            }
            fn is_connected(&self) -> bool {
                self.0.is_connected()
            }
            fn balance(&self) -> Result<Balance> {
                self.0.balance()
            }
            fn receive(&self, request: &ReceiveRequest) -> Result<String> {
                self.0.receive(request)
            }
            fn parse_destination(&self, input: &str) -> Result<Destination> {
                self.0.parse_destination(input)
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
                self.0.prepare_send(destination, amount_sats)
            }
            fn send(&self, prepared: &PreparedSend, note: &str) -> Result<Payment> {
                self.0.send(prepared, note)
            }
            fn list_recent_payments(&self, limit: u32) -> Result<Vec<Payment>> {
                self.0.list_recent_payments(limit)
            }
            fn add_event_listener(&self, listener: Arc<dyn WalletEventListener>) -> u64 {
                self.0.add_event_listener(listener)
            }
            fn remove_event_listener(&self, id: u64) {
                self.0.remove_event_listener(id)
            }
            fn wipe_local_storage(&self) -> Result<()> {
                self.0.wipe_local_storage()
            }
        }
        let w = NoLnurl(MockWallet::new(10_000));
        w.connect().unwrap();
        let address = w.parse_destination("conor@sonar.hedwig.sh").unwrap();
        let err = prepare_and_send(&w, &address, Some(100), "").unwrap_err();
        assert!(
            matches!(err, WalletError::Unsupported(ref m) if m.contains("Lightning address")),
            "unexpected error: {err}"
        );
        // A kind it does support still goes through.
        let offer = w.parse_destination("lno1qcp4256ypq").unwrap();
        assert!(prepare_and_send(&w, &offer, Some(100), "").is_ok());
    }

    #[test]
    fn minimal_backend_reports_unsupported_for_gated_methods() {
        // A backend written against only the required methods. Adding a
        // capability field must not break this — hence `..Default::default()`.
        struct Minimal;
        impl WalletBackend for Minimal {
            fn capabilities(&self) -> WalletCapabilities {
                WalletCapabilities {
                    bolt12_send: true,
                    bolt12_receive: true,
                    ..Default::default()
                }
            }
            fn connect(&self) -> crate::Result<()> {
                Ok(())
            }
            fn disconnect(&self) -> crate::Result<()> {
                Ok(())
            }
            fn is_connected(&self) -> bool {
                true
            }
            fn balance(&self) -> crate::Result<Balance> {
                Ok(Balance::default())
            }
            fn receive(&self, _request: &ReceiveRequest) -> crate::Result<String> {
                Ok("lno1minimal".into())
            }
            fn parse_destination(&self, input: &str) -> crate::Result<Destination> {
                Ok(classify_destination(input))
            }
            fn prepare_send(
                &self,
                _destination: &Destination,
                _amount_sats: Option<u64>,
            ) -> crate::Result<PreparedSend> {
                Err(WalletError::Backend("not implemented".into()))
            }
            fn send(&self, _prepared: &PreparedSend, _note: &str) -> crate::Result<Payment> {
                Err(WalletError::Backend("not implemented".into()))
            }
            fn list_recent_payments(&self, _limit: u32) -> crate::Result<Vec<Payment>> {
                Ok(Vec::new())
            }
            fn add_event_listener(&self, _listener: Arc<dyn WalletEventListener>) -> u64 {
                0
            }
            fn remove_event_listener(&self, _id: u64) {}
            fn wipe_local_storage(&self) -> crate::Result<()> {
                Ok(())
            }
        }
        let backend: Arc<dyn WalletBackend> = Arc::new(Minimal);
        for result in [
            backend.fetch_fiat_rates().map(|_| ()),
            backend.register_webhook("https://nds.example"),
            backend.unregister_webhook(),
            backend.sync_wallet(),
        ] {
            assert!(
                matches!(result, Err(WalletError::Unsupported(_))),
                "expected Unsupported, got {result:?}"
            );
        }
        // The provided receive_offer() delegates to the required receive().
        assert_eq!(backend.receive_offer().unwrap(), "lno1minimal");
    }
}
