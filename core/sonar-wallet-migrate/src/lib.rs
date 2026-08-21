//! Crash-safe Breez-to-Cashu migration orchestration.

mod journal;

pub use journal::{
    MigrationAttempt, MigrationAttemptState, MigrationJournal, JOURNAL_FILE, JOURNAL_LOCK_FILE,
    JOURNAL_TMP_FILE,
};

use std::str::FromStr;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use sonar_wallet::{
    DestinationKind, Payment, PaymentLookupStatus, PaymentStatus, PreparedSend, ReceiveMethod,
    ReceiveRequest, TrackedReceiveBackend, TrackedReceiveState, WalletBackend, WalletError,
};
use thiserror::Error;

pub type Result<T> = std::result::Result<T, MigrateError>;

#[derive(Debug, Error)]
pub enum MigrateError {
    #[error("source wallet: {0}")]
    Source(WalletError),
    #[error("destination wallet: {0}")]
    Destination(WalletError),
    #[error("migration journal: {0}")]
    Journal(String),
    #[error("amount {amount_sats} sats is above the destination limit of {max_sats} sats")]
    AboveDestinationMax { amount_sats: u64, max_sats: u64 },
    #[error("amount {amount_sats} sats plus fee {fee_sats} exceeds source balance {balance_sats}")]
    ExceedsSourceBalance {
        amount_sats: u64,
        fee_sats: u64,
        balance_sats: u64,
    },
    #[error("quoted source fee {fee_sats} sats exceeds cap {cap_sats} sats")]
    FeeAboveCap { fee_sats: u64, cap_sats: u64 },
    #[error("source quoted no fee; cannot honour fee cap {cap_sats} sats")]
    FeeUnknown { cap_sats: u64 },
    #[error("source balance {balance_sats} sats is too small: {reason}")]
    SourceTooSmall { balance_sats: u64, reason: String },
    #[error("could not find a feasible drain in {attempts} attempts: {last}")]
    DrainNotFeasible { attempts: u32, last: String },
    #[error("destination did not issue a BOLT11 invoice (got {0:?})")]
    UnexpectedInvoiceKind(DestinationKind),
    #[error("invalid destination invoice: {0}")]
    InvalidInvoice(String),
    #[error("source prepared {prepared_sats} sats for a {requested_sats} sat quote")]
    PreparedAmountMismatch {
        prepared_sats: u64,
        requested_sats: u64,
    },
    #[error("migration attempt does not match the supplied plan")]
    AttemptMismatch,
    #[error("migration is in state {0:?}; refusing to send again")]
    UnsafeToResend(MigrationAttemptState),
    #[error("tracked receive settled for {actual_sats} sats, expected {expected_sats} sats")]
    SettlementAmountMismatch {
        actual_sats: u64,
        expected_sats: u64,
    },
    #[error("no migration attempt is journaled")]
    NoAttempt,
    #[error("migration attempt cannot be cancelled in state {0:?}")]
    CannotCancel(MigrationAttemptState),
    #[error("a migration is already in flight ({0:?}); resume or settle it instead of planning another")]
    InFlight(MigrationAttemptState),
}

#[derive(Debug, Clone)]
pub struct MigrationLimits {
    pub dest_max_sats: Option<u64>,
    pub fee_cap_sats: Option<u64>,
}

#[derive(Debug)]
pub struct MigrationPlan {
    pub settlement_id: String,
    pub payment_hash: String,
    pub amount_sats: u64,
    pub source_fee_sats: Option<u64>,
    pub invoice: String,
    pub expires_at_secs: Option<u64>,
    prepared: PreparedSend,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Settlement {
    Settled { amount_sats: u64 },
    Pending { amount_sats: u64 },
}

pub struct MigrationEngine<'a> {
    source: &'a dyn WalletBackend,
    dest: &'a dyn TrackedReceiveBackend,
    limits: MigrationLimits,
    journal: &'a MigrationJournal,
}

impl<'a> MigrationEngine<'a> {
    pub fn new(
        source: &'a dyn WalletBackend,
        dest: &'a dyn TrackedReceiveBackend,
        limits: MigrationLimits,
        journal: &'a MigrationJournal,
    ) -> Self {
        Self {
            source,
            dest,
            limits,
            journal,
        }
    }

    fn src<T>(result: sonar_wallet::Result<T>) -> Result<T> {
        result.map_err(MigrateError::Source)
    }

    fn dst<T>(result: sonar_wallet::Result<T>) -> Result<T> {
        result.map_err(MigrateError::Destination)
    }

    fn refuse_in_flight(&self) -> Result<()> {
        if let Some(existing) = self.journal.load()? {
            match existing.state {
                MigrationAttemptState::AwaitingConsent
                | MigrationAttemptState::ExpiredUnsent
                | MigrationAttemptState::Settled
                | MigrationAttemptState::SourceFailed => Ok(()),
                other => Err(MigrateError::InFlight(other)),
            }
        } else {
            Ok(())
        }
    }

    pub fn plan_amount(&self, amount_sats: u64) -> Result<MigrationPlan> {
        self.refuse_in_flight()?;
        if let Some(max_sats) = self.limits.dest_max_sats {
            if amount_sats > max_sats {
                return Err(MigrateError::AboveDestinationMax {
                    amount_sats,
                    max_sats,
                });
            }
        }
        let balance_sats = Self::src(self.source.balance())?.confirmed_sats;
        let tracked = Self::dst(self.dest.create_tracked_receive(&ReceiveRequest {
            method: ReceiveMethod::Bolt11Invoice,
            amount_sats: Some(amount_sats),
            description: Some("Sonar wallet migration".into()),
        }))?;
        if tracked.amount_sats != amount_sats {
            return Err(MigrateError::SettlementAmountMismatch {
                actual_sats: tracked.amount_sats,
                expected_sats: amount_sats,
            });
        }
        let invoice = lightning_invoice::Bolt11Invoice::from_str(&tracked.request)
            .map_err(|e| MigrateError::InvalidInvoice(e.to_string()))?;
        let payment_hash = invoice.payment_hash().to_string();
        let destination = Self::src(self.source.parse_destination(&tracked.request))?;
        if !matches!(
            destination.kind,
            DestinationKind::Bolt11 | DestinationKind::Unknown
        ) {
            return Err(MigrateError::UnexpectedInvoiceKind(destination.kind));
        }
        let prepared = Self::src(self.source.prepare_send(&destination, Some(amount_sats)))?;
        if prepared.amount_sats != amount_sats {
            return Err(MigrateError::PreparedAmountMismatch {
                prepared_sats: prepared.amount_sats,
                requested_sats: amount_sats,
            });
        }
        self.check_fee_and_capacity(amount_sats, prepared.fees_sats, balance_sats)?;
        let plan = MigrationPlan {
            settlement_id: tracked.id,
            payment_hash,
            amount_sats,
            source_fee_sats: prepared.fees_sats,
            invoice: tracked.request,
            expires_at_secs: tracked.expires_at_secs,
            prepared,
        };
        self.journal.with_lock(|journal| {
            if let Some(existing) = journal.load_unlocked()? {
                match existing.state {
                    MigrationAttemptState::AwaitingConsent
                    | MigrationAttemptState::ExpiredUnsent
                    | MigrationAttemptState::Settled
                    | MigrationAttemptState::SourceFailed => {}
                    other => return Err(MigrateError::InFlight(other)),
                }
            }
            journal.store_unlocked(Some(&attempt_for_plan(&plan)))
        })?;
        Ok(plan)
    }

    pub fn plan_drain(&self) -> Result<MigrationPlan> {
        const MAX_ATTEMPTS: u32 = 5;
        let balance = Self::src(self.source.balance())?.confirmed_sats;
        if balance == 0 {
            return Err(MigrateError::SourceTooSmall {
                balance_sats: 0,
                reason: "balance is zero".into(),
            });
        }
        if let Some(max_sats) = self.limits.dest_max_sats {
            if balance > max_sats {
                return Err(MigrateError::AboveDestinationMax {
                    amount_sats: balance,
                    max_sats,
                });
            }
        }
        let mut candidate = balance;
        let mut last = String::new();
        for attempt in 0..MAX_ATTEMPTS {
            match self.plan_amount(candidate) {
                Ok(plan) => return Ok(plan),
                Err(MigrateError::ExceedsSourceBalance {
                    fee_sats,
                    balance_sats,
                    ..
                }) => {
                    let next = balance_sats
                        .saturating_sub(fee_sats)
                        .saturating_sub(1)
                        .min(candidate.saturating_sub(1));
                    if next == 0 {
                        return Err(MigrateError::SourceTooSmall {
                            balance_sats,
                            reason: format!("fees ({fee_sats} sats) consume the balance"),
                        });
                    }
                    last = format!("{candidate} + {fee_sats} > {balance_sats}");
                    candidate = next;
                }
                Err(MigrateError::Source(ref error)) if insufficient_refusal(error) => {
                    let reserve = ((balance * (1u64 << attempt)) / 100).max(4);
                    let next = balance
                        .saturating_sub(reserve)
                        .min(candidate.saturating_sub(1));
                    if next == 0 {
                        return Err(MigrateError::SourceTooSmall {
                            balance_sats: balance,
                            reason: format!("fees consume the balance ({error})"),
                        });
                    }
                    last = format!("source refused {candidate}: {error}");
                    candidate = next;
                }
                Err(other) => return Err(other),
            }
        }
        Err(MigrateError::DrainNotFeasible {
            attempts: MAX_ATTEMPTS,
            last,
        })
    }

    pub fn execute_once(&self, plan: &MigrationPlan) -> Result<Payment> {
        self.journal.with_lock(|journal| {
            let mut attempt = journal.load_unlocked()?.ok_or(MigrateError::NoAttempt)?;
            if !matches_plan(&attempt, plan) {
                return Err(MigrateError::AttemptMismatch);
            }
            if attempt.state != MigrationAttemptState::AwaitingConsent {
                return Err(MigrateError::UnsafeToResend(attempt.state));
            }
            if expired(attempt.expires_at_secs) {
                attempt.state = MigrationAttemptState::ExpiredUnsent;
                journal.store_unlocked(Some(&attempt))?;
                return Err(MigrateError::UnsafeToResend(attempt.state));
            }
            // Durable take-before-send: after this fsync no restart is allowed
            // to issue the payment again without first reconciling its hash.
            attempt.state = MigrationAttemptState::Sending;
            journal.store_unlocked(Some(&attempt))?;
            match self.source.send(&plan.prepared, "Sonar wallet migration") {
                Ok(payment) => {
                    attempt.source_payment_id = Some(payment.id.clone());
                    attempt.source_fee_sats = payment.fees_sats.or(attempt.source_fee_sats);
                    attempt.state = match payment.status {
                        PaymentStatus::Complete => MigrationAttemptState::SourcePaid,
                        PaymentStatus::Pending => MigrationAttemptState::SourcePending,
                        PaymentStatus::Failed | PaymentStatus::Refundable => {
                            MigrationAttemptState::SourceFailed
                        }
                    };
                    journal.store_unlocked(Some(&attempt))?;
                    Ok(payment)
                }
                Err(error) => {
                    attempt.state = MigrationAttemptState::PaymentUnknown;
                    journal.store_unlocked(Some(&attempt))?;
                    Err(MigrateError::Source(error))
                }
            }
        })
    }

    /// Reconcile source outcome first, then the exact destination quote.
    pub fn resume(&self, request_timeout: Duration) -> Result<Settlement> {
        self.journal.with_lock(|journal| {
            let mut attempt = journal.load_unlocked()?.ok_or(MigrateError::NoAttempt)?;
            if attempt.state == MigrationAttemptState::Settled {
                return Ok(Settlement::Settled {
                    amount_sats: attempt.amount_sats,
                });
            }
            if matches!(
                attempt.state,
                MigrationAttemptState::Sending
                    | MigrationAttemptState::PaymentUnknown
                    | MigrationAttemptState::SourcePending
            ) {
                let lookup = Self::src(self.source.lookup_payment(&attempt.payment_hash))?;
                attempt.source_payment_id = lookup.id.or(attempt.source_payment_id);
                attempt.source_fee_sats = lookup.fees_sats.or(attempt.source_fee_sats);
                attempt.state = match lookup.status {
                    PaymentLookupStatus::Complete => MigrationAttemptState::SourcePaid,
                    PaymentLookupStatus::Pending => MigrationAttemptState::SourcePending,
                    PaymentLookupStatus::Failed | PaymentLookupStatus::Refundable => {
                        MigrationAttemptState::SourceFailed
                    }
                    PaymentLookupStatus::Unknown => MigrationAttemptState::PaymentUnknown,
                };
                journal.store_unlocked(Some(&attempt))?;
            }
            if !matches!(
                attempt.state,
                MigrationAttemptState::SourcePaid | MigrationAttemptState::MintPaid
            ) {
                return Ok(Settlement::Pending {
                    amount_sats: attempt.amount_sats,
                });
            }
            match self
                .dest
                .reconcile_tracked_receive(&attempt.settlement_id, request_timeout)
            {
                Ok(TrackedReceiveState::Pending) | Err(WalletError::Timeout) => {
                    attempt.state = MigrationAttemptState::MintPaid;
                    journal.store_unlocked(Some(&attempt))?;
                    Ok(Settlement::Pending {
                        amount_sats: attempt.amount_sats,
                    })
                }
                Ok(TrackedReceiveState::Settled { amount_sats }) => {
                    if amount_sats != attempt.amount_sats {
                        return Err(MigrateError::SettlementAmountMismatch {
                            actual_sats: amount_sats,
                            expected_sats: attempt.amount_sats,
                        });
                    }
                    attempt.state = MigrationAttemptState::Settled;
                    journal.store_unlocked(Some(&attempt))?;
                    Ok(Settlement::Settled { amount_sats })
                }
                Err(error) => Err(MigrateError::Destination(error)),
            }
        })
    }

    pub fn settle(
        &self,
        settlement_id: &str,
        polls: u32,
        request_timeout: Duration,
    ) -> Result<Settlement> {
        let attempt = self.status()?.ok_or(MigrateError::NoAttempt)?;
        if attempt.settlement_id != settlement_id {
            return Err(MigrateError::AttemptMismatch);
        }
        let mut outcome = Settlement::Pending {
            amount_sats: attempt.amount_sats,
        };
        for _ in 0..polls.max(1) {
            outcome = self.resume(request_timeout)?;
            if matches!(outcome, Settlement::Settled { .. }) {
                break;
            }
        }
        Ok(outcome)
    }

    pub fn status(&self) -> Result<Option<MigrationAttempt>> {
        self.journal.load()
    }

    pub fn cancel_unspent(&self) -> Result<()> {
        self.journal.with_lock(|journal| {
            let attempt = journal.load_unlocked()?.ok_or(MigrateError::NoAttempt)?;
            if !matches!(
                attempt.state,
                MigrationAttemptState::AwaitingConsent | MigrationAttemptState::ExpiredUnsent
            ) {
                return Err(MigrateError::CannotCancel(attempt.state));
            }
            journal.store_unlocked(None)
        })
    }

    fn check_fee_and_capacity(
        &self,
        amount_sats: u64,
        fee_sats: Option<u64>,
        balance_sats: u64,
    ) -> Result<()> {
        match (self.limits.fee_cap_sats, fee_sats) {
            (Some(cap_sats), Some(fee_sats)) if fee_sats > cap_sats => {
                return Err(MigrateError::FeeAboveCap { fee_sats, cap_sats })
            }
            (Some(cap_sats), None) => return Err(MigrateError::FeeUnknown { cap_sats }),
            _ => {}
        }
        let fee_sats = fee_sats.unwrap_or(0);
        if amount_sats.saturating_add(fee_sats) > balance_sats {
            return Err(MigrateError::ExceedsSourceBalance {
                amount_sats,
                fee_sats,
                balance_sats,
            });
        }
        Ok(())
    }
}

fn attempt_for_plan(plan: &MigrationPlan) -> MigrationAttempt {
    MigrationAttempt {
        settlement_id: plan.settlement_id.clone(),
        invoice: plan.invoice.clone(),
        payment_hash: plan.payment_hash.clone(),
        amount_sats: plan.amount_sats,
        source_fee_sats: plan.source_fee_sats,
        expires_at_secs: plan.expires_at_secs,
        source_payment_id: None,
        state: MigrationAttemptState::AwaitingConsent,
    }
}

fn matches_plan(attempt: &MigrationAttempt, plan: &MigrationPlan) -> bool {
    attempt.settlement_id == plan.settlement_id
        && attempt.payment_hash == plan.payment_hash
        && attempt.invoice == plan.invoice
        && attempt.amount_sats == plan.amount_sats
}

fn expired(expires_at_secs: Option<u64>) -> bool {
    expires_at_secs.is_some_and(|expiry| {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|now| now.as_secs() >= expiry)
            .unwrap_or(false)
    })
}

fn insufficient_refusal(error: &WalletError) -> bool {
    match error {
        WalletError::InsufficientFunds => true,
        WalletError::Backend(message) => {
            let message = message.to_ascii_lowercase();
            message.contains("insufficient") || message.contains("not enough funds")
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sonar_wallet::{
        Balance, Destination as WalletDestination, MockWallet, PreparedSend, TrackedReceive,
        WalletCapabilities, WalletEventListener,
    };
    use std::collections::HashMap;
    use std::sync::{Arc, Mutex};

    const INVOICE: &str = "lnbc25m1pvjluezpp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdq5vdhkven9v5sxyetpdeessp5zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygs9q5sqqqqqqqqqqqqqqqpqsq67gye39hfg3zd8rgc80k32tvy9xk2xunwm5lzexnvpx6fd77en8qaq424dxgt56cag2dpt359k3ssyhetktkpqh24jqnjyw6uqd08sgptq44qu";

    #[derive(Default)]
    struct Destination {
        next: Mutex<u64>,
        quotes: Mutex<HashMap<String, (u64, bool)>>,
    }

    impl Destination {
        fn settle(&self, id: &str) {
            self.quotes.lock().unwrap().get_mut(id).unwrap().1 = true;
        }
    }

    impl TrackedReceiveBackend for Destination {
        fn create_tracked_receive(
            &self,
            request: &ReceiveRequest,
        ) -> sonar_wallet::Result<TrackedReceive> {
            let amount_sats = request.amount_sats.unwrap();
            let mut next = self.next.lock().unwrap();
            *next += 1;
            let id = format!("quote-{next}");
            self.quotes
                .lock()
                .unwrap()
                .insert(id.clone(), (amount_sats, false));
            Ok(TrackedReceive {
                id,
                request: INVOICE.into(),
                amount_sats,
                expires_at_secs: None,
            })
        }

        fn reconcile_tracked_receive(
            &self,
            id: &str,
            _request_timeout: Duration,
        ) -> sonar_wallet::Result<TrackedReceiveState> {
            let quotes = self.quotes.lock().unwrap();
            let (amount_sats, settled) = quotes
                .get(id)
                .ok_or_else(|| WalletError::UnknownReceive(id.into()))?;
            Ok(if *settled {
                TrackedReceiveState::Settled {
                    amount_sats: *amount_sats,
                }
            } else {
                TrackedReceiveState::Pending
            })
        }
    }

    struct OpaqueRefusingSource {
        inner: MockWallet,
        fee_sats: u64,
    }

    impl WalletBackend for OpaqueRefusingSource {
        fn capabilities(&self) -> WalletCapabilities {
            self.inner.capabilities()
        }
        fn connect(&self) -> sonar_wallet::Result<()> {
            self.inner.connect()
        }
        fn disconnect(&self) -> sonar_wallet::Result<()> {
            self.inner.disconnect()
        }
        fn is_connected(&self) -> bool {
            self.inner.is_connected()
        }
        fn balance(&self) -> sonar_wallet::Result<Balance> {
            self.inner.balance()
        }
        fn receive(&self, request: &ReceiveRequest) -> sonar_wallet::Result<String> {
            self.inner.receive(request)
        }
        fn parse_destination(&self, input: &str) -> sonar_wallet::Result<WalletDestination> {
            self.inner.parse_destination(input)
        }
        fn prepare_send(
            &self,
            destination: &WalletDestination,
            amount_sats: Option<u64>,
        ) -> sonar_wallet::Result<PreparedSend> {
            let amount = amount_sats.unwrap_or(0);
            if amount.saturating_add(self.fee_sats) > self.balance()?.confirmed_sats {
                return Err(WalletError::Backend("Cannot pay: not enough funds".into()));
            }
            self.inner.prepare_send(destination, amount_sats)
        }
        fn send(&self, prepared: &PreparedSend, note: &str) -> sonar_wallet::Result<Payment> {
            self.inner.send(prepared, note)
        }
        fn list_recent_payments(&self, limit: u32) -> sonar_wallet::Result<Vec<Payment>> {
            self.inner.list_recent_payments(limit)
        }
        fn add_event_listener(&self, listener: Arc<dyn WalletEventListener>) -> u64 {
            self.inner.add_event_listener(listener)
        }
        fn remove_event_listener(&self, id: u64) {
            self.inner.remove_event_listener(id)
        }
        fn wipe_local_storage(&self) -> sonar_wallet::Result<()> {
            self.inner.wipe_local_storage()
        }
    }

    fn setup(balance: u64) -> (MockWallet, Destination, tempfile::TempDir, MigrationJournal) {
        let source = MockWallet::new(balance);
        source.connect().unwrap();
        let destination = Destination::default();
        let dir = tempfile::tempdir().unwrap();
        let journal = MigrationJournal::new(dir.path(), b"account", b"mint").unwrap();
        (source, destination, dir, journal)
    }

    fn limits(max: Option<u64>, cap: Option<u64>) -> MigrationLimits {
        MigrationLimits {
            dest_max_sats: max,
            fee_cap_sats: cap,
        }
    }

    #[test]
    fn exact_quote_not_unrelated_credit_settles() {
        let (source, destination, _dir, journal) = setup(10_000);
        let engine = MigrationEngine::new(&source, &destination, limits(None, Some(10)), &journal);
        let plan = engine.plan_amount(2_000).unwrap();
        engine.execute_once(&plan).unwrap();
        source.simulate_receive(2_000);
        assert_eq!(
            engine.resume(Duration::from_secs(1)).unwrap(),
            Settlement::Pending { amount_sats: 2_000 }
        );
        destination.settle(&plan.settlement_id);
        assert_eq!(
            engine
                .settle(&plan.settlement_id, 1, Duration::from_secs(1))
                .unwrap(),
            Settlement::Settled { amount_sats: 2_000 }
        );
    }

    #[test]
    fn resume_reports_settled_idempotently() {
        let (source, destination, _dir, journal) = setup(10_000);
        let engine = MigrationEngine::new(&source, &destination, limits(None, Some(10)), &journal);
        let plan = engine.plan_amount(1_000).unwrap();
        engine.execute_once(&plan).unwrap();
        destination.settle(&plan.settlement_id);
        assert_eq!(
            engine.resume(Duration::from_secs(1)).unwrap(),
            Settlement::Settled { amount_sats: 1_000 }
        );
        assert_eq!(
            engine.resume(Duration::from_secs(1)).unwrap(),
            Settlement::Settled { amount_sats: 1_000 }
        );
    }

    #[test]
    fn durable_sending_state_prevents_resend() {
        let (source, destination, _dir, journal) = setup(10_000);
        let engine = MigrationEngine::new(&source, &destination, limits(None, None), &journal);
        let plan = engine.plan_amount(1_000).unwrap();
        let mut attempt = journal.load().unwrap().unwrap();
        attempt.state = MigrationAttemptState::Sending;
        journal.store(Some(&attempt)).unwrap();
        assert!(matches!(
            engine.execute_once(&plan),
            Err(MigrateError::UnsafeToResend(MigrationAttemptState::Sending))
        ));
        assert_eq!(source.balance().unwrap().confirmed_sats, 10_000);
    }

    #[test]
    fn drain_refuses_destination_max_and_fee_cap() {
        let (source, destination, _dir, journal) = setup(1_000);
        let engine =
            MigrationEngine::new(&source, &destination, limits(Some(500), Some(0)), &journal);
        assert!(matches!(
            engine.plan_drain(),
            Err(MigrateError::AboveDestinationMax {
                amount_sats: 1_000,
                max_sats: 500
            })
        ));
        let engine = MigrationEngine::new(&source, &destination, limits(None, Some(0)), &journal);
        assert!(matches!(
            engine.plan_amount(100),
            Err(MigrateError::FeeAboveCap { .. })
        ));
    }

    #[test]
    fn drain_steps_down_for_opaque_insufficient_funds() {
        let source = OpaqueRefusingSource {
            inner: MockWallet::new(813),
            fee_sats: 40,
        };
        source.connect().unwrap();
        let destination = Destination::default();
        let dir = tempfile::tempdir().unwrap();
        let journal = MigrationJournal::new(dir.path(), b"account", b"mint").unwrap();
        let engine = MigrationEngine::new(&source, &destination, limits(None, None), &journal);
        let plan = engine.plan_drain().unwrap();
        assert!(plan.amount_sats > 0);
        assert!(plan.amount_sats + 40 <= 813);
    }

    #[test]
    fn corrupt_journal_fails_closed() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join(JOURNAL_FILE), b"{broken").unwrap();
        assert!(matches!(
            MigrationJournal::new(dir.path(), b"account", b"mint"),
            Err(MigrateError::Journal(_))
        ));
    }

    #[test]
    fn planning_refuses_an_in_flight_send() {
        let (source, destination, _dir, journal) = setup(10_000);
        let engine = MigrationEngine::new(&source, &destination, limits(None, None), &journal);
        let plan = engine.plan_amount(1_000).unwrap();
        let mut attempt = journal.load().unwrap().unwrap();
        attempt.state = MigrationAttemptState::Sending;
        journal.store(Some(&attempt)).unwrap();
        assert!(matches!(
            engine.plan_amount(500),
            Err(MigrateError::InFlight(MigrationAttemptState::Sending))
        ));
        assert!(matches!(
            engine.plan_drain(),
            Err(MigrateError::InFlight(MigrationAttemptState::Sending))
        ));
        assert_eq!(source.balance().unwrap().confirmed_sats, 10_000);
        assert_eq!(
            journal.load().unwrap().unwrap().settlement_id,
            plan.settlement_id
        );
    }

    #[cfg(unix)]
    #[test]
    fn journal_lock_is_exclusive_across_instances() {
        let dir = tempfile::tempdir().unwrap();
        let first = MigrationJournal::new(dir.path(), b"account", b"mint").unwrap();
        let second = MigrationJournal::new(dir.path(), b"account", b"mint").unwrap();
        let hold = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(true));
        let ready = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        std::thread::scope(|scope| {
            scope.spawn(|| {
                let hold = hold.clone();
                let ready = ready.clone();
                first
                    .with_lock(|_| {
                        ready.store(true, std::sync::atomic::Ordering::SeqCst);
                        while hold.load(std::sync::atomic::Ordering::SeqCst) {
                            std::thread::yield_now();
                        }
                        Ok(())
                    })
                    .unwrap();
            });
            while !ready.load(std::sync::atomic::Ordering::SeqCst) {
                std::thread::yield_now();
            }
            assert!(matches!(
                second.with_lock(|_| Ok(())),
                Err(MigrateError::Journal(_))
            ));
            hold.store(false, std::sync::atomic::Ordering::SeqCst);
        });
    }
}
