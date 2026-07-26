use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use crate::destination::{classify_destination, resolve_send_amount};
use crate::error::{Result, WalletError};
use crate::listeners::ListenerRegistry;
use crate::traits::{WalletBackend, WalletEventListener};
use crate::types::{
    Balance, Destination, ExchangeRate, Payment, PaymentStatus, WalletCapabilities, WalletEvent,
};

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
            node_lifecycle: false,
            webhook: false,
            fiat_rates: true,
            bolt11_send: true,
            bolt12_send: true,
            bolt12_receive: true,
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

    fn receive_offer(&self) -> Result<String> {
        self.ensure_connected()?;
        Ok("lno1mockoffermockoffermockoffer".to_string())
    }

    fn parse_destination(&self, input: &str) -> Result<Destination> {
        let destination = classify_destination(input);
        if destination.raw.is_empty() {
            return Err(WalletError::InvalidDestination("empty input".into()));
        }
        Ok(destination)
    }

    fn send(
        &self,
        destination: &Destination,
        amount_sats: Option<u64>,
        note: &str,
    ) -> Result<Payment> {
        self.ensure_connected()?;
        // Same resolution rules every backend uses.
        let amount = resolve_send_amount(amount_sats, destination.amount_sats)?
            .or(destination.amount_sats)
            .expect("resolve_send_amount rejects the no-amount-anywhere case");
        {
            let mut balance = self.balance.lock().expect("balance lock");
            if balance.confirmed_sats < amount {
                return Err(WalletError::InsufficientFunds);
            }
            balance.confirmed_sats -= amount;
        }
        let payment = Payment {
            id: format!("mock-out-{}", self.now()),
            amount_sats: amount,
            fees_sats: Some(0),
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
        let payment = w.send(&dest, Some(2_500), "coffee").unwrap();
        assert!(!payment.incoming);
        assert_eq!(payment.amount_sats, 2_500);
        assert_eq!(payment.note.as_deref(), Some("coffee"));
        assert_eq!(w.balance().unwrap().confirmed_sats, 7_500);
        assert_eq!(*recorder.0.lock().unwrap(), vec!["sent"]);
    }

    #[test]
    fn send_rejects_amountless_and_overdraft() {
        let w = wallet();
        let dest = w.parse_destination("lno1qcp4256ypq").unwrap();
        assert!(matches!(
            w.send(&dest, None, ""),
            Err(WalletError::InvalidDestination(_))
        ));
        assert!(matches!(
            w.send(&dest, Some(1_000_000), ""),
            Err(WalletError::InsufficientFunds)
        ));
        assert_eq!(w.balance().unwrap().confirmed_sats, 10_000);
    }

    #[test]
    fn recent_payments_newest_first_and_wipe_preserves_balance() {
        let w = wallet();
        w.simulate_receive(500);
        let dest = w.parse_destination("user@host.tld").unwrap();
        w.send(&dest, Some(100), "").unwrap();
        let recent = w.list_recent_payments(10).unwrap();
        assert_eq!(recent.len(), 2);
        assert!(!recent[0].incoming, "newest (the send) first");
        assert!(recent[1].incoming);
        let balance = w.balance().unwrap();
        w.wipe_local_storage().unwrap();
        assert!(w.list_recent_payments(10).unwrap().is_empty());
        assert_eq!(w.balance().unwrap(), balance);
    }

    #[test]
    fn minimal_backend_reports_unsupported_for_gated_methods() {
        struct Minimal;
        impl WalletBackend for Minimal {
            fn capabilities(&self) -> WalletCapabilities {
                WalletCapabilities {
                    node_lifecycle: false,
                    webhook: false,
                    fiat_rates: false,
                    bolt11_send: false,
                    bolt12_send: true,
                    bolt12_receive: true,
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
            fn receive_offer(&self) -> crate::Result<String> {
                Ok(String::new())
            }
            fn parse_destination(&self, input: &str) -> crate::Result<Destination> {
                Ok(classify_destination(input))
            }
            fn send(
                &self,
                _destination: &Destination,
                _amount_sats: Option<u64>,
                _note: &str,
            ) -> crate::Result<Payment> {
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
        assert!(matches!(
            backend.fetch_fiat_rates(),
            Err(WalletError::Unsupported("fiat rates"))
        ));
        assert!(matches!(
            backend.register_webhook("https://nds.example"),
            Err(WalletError::Unsupported("webhook"))
        ));
        assert!(matches!(
            backend.unregister_webhook(),
            Err(WalletError::Unsupported("webhook"))
        ));
    }
}
