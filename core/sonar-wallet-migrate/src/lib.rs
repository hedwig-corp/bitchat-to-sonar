//! Wallet-to-wallet migration engine (PR3 of the wallet train).
//!
//! Drives a single-shot drain from a SOURCE wallet into a DESTINATION wallet
//! over Lightning: the destination issues an invoice (for Cashu, a mint
//! quote), the source pays it, and settlement is confirmed by watching the
//! destination's balance rise. Both ends are `dyn WalletBackend` — the engine
//! never names a backend, which is what lets the same code run headlessly in
//! the island CLI (real Breez + real CDK in one process) and later inside
//! sonar-ffi with the source injected by the host apps.
//!
//! Design rules, from `docs/brainstorms/2026-08-09-breez-to-cashu-migration.md`:
//!
//! - **Single shot, hard bounds.** One invoice, one payment. Amounts outside
//!   the destination's configured bounds or the source's capacity are REFUSED
//!   with a clear error — never silently split or resized beyond the drain
//!   fee-adjustment loop.
//! - **No spend without an explicit fee gate.** Planning quotes the source fee
//!   fail-closed against a caller-supplied cap; `execute` is a separate call so
//!   hosts can put consent between the quote and the payment.
//! - **Crash-safety is derived, not journaled.** Both backends persist the
//!   authoritative state (the source its payment, the destination its quote —
//!   for CDK, a paid quote is minted by its own reconciliation on the next
//!   sync). `settle` therefore just drives destination syncs and reads
//!   balances; re-running it after a crash finishes the migration with no
//!   engine-side ledger to corrupt.
//! - **Custody consent is the caller's job**, and the API shape enforces that
//!   there is a place to put it: `plan` → (show fees, obtain consent) →
//!   `execute` → `settle`.

use sonar_wallet::{
    Balance, DestinationKind, Payment, PreparedSend, ReceiveMethod, ReceiveRequest, WalletBackend,
    WalletError,
};
use thiserror::Error;

pub type Result<T> = std::result::Result<T, MigrateError>;

#[derive(Debug, Error)]
pub enum MigrateError {
    #[error("source wallet: {0}")]
    Source(WalletError),
    #[error("destination wallet: {0}")]
    Destination(WalletError),
    #[error("amount {amount_sats} sats is above the destination limit of {max_sats} sats; migrate the remainder in a later run")]
    AboveDestinationMax { amount_sats: u64, max_sats: u64 },
    #[error("amount {amount_sats} sats plus the {fee_sats} sats fee exceeds the source balance of {balance_sats} sats")]
    ExceedsSourceBalance {
        amount_sats: u64,
        fee_sats: u64,
        balance_sats: u64,
    },
    #[error("quoted source fee {fee_sats} sats exceeds the cap of {cap_sats} sats")]
    FeeAboveCap { fee_sats: u64, cap_sats: u64 },
    #[error("source quoted no fee, cannot honour the fee cap of {cap_sats} sats")]
    FeeUnknown { cap_sats: u64 },
    #[error("source balance of {balance_sats} sats is too small to migrate: {reason}")]
    SourceTooSmall { balance_sats: u64, reason: String },
    #[error(
        "could not find a feasible drain amount within {attempts} attempts; last error: {last}"
    )]
    DrainNotFeasible { attempts: u32, last: String },
    #[error("destination did not issue a Lightning invoice (got a {0:?} destination)")]
    UnexpectedInvoiceKind(DestinationKind),
}

/// Bounds and knobs the caller supplies; the engine has no backend-specific
/// constants baked in.
#[derive(Debug, Clone)]
pub struct MigrationLimits {
    /// Destination-side maximum for one shot (e.g. the mint's per-quote max).
    /// `None` = no known limit.
    pub dest_max_sats: Option<u64>,
    /// Fail-closed cap on the source fee. `None` means the caller accepts any
    /// quoted fee — hosts building consent UIs should always set it.
    pub fee_cap_sats: Option<u64>,
}

/// A priced, consented-to-be-executed migration. Produced by planning; holds
/// the source's prepared send so `execute` pays exactly what was quoted.
#[derive(Debug)]
pub struct MigrationPlan {
    /// Net amount that will arrive at the destination.
    pub amount_sats: u64,
    /// Source-side fee as quoted (the figure shown at consent time).
    pub source_fee_sats: Option<u64>,
    /// The destination-issued invoice being paid.
    pub invoice: String,
    prepared: PreparedSend,
}

/// Outcome of a settlement watch.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Settlement {
    /// Destination confirmed balance rose by at least the expected amount.
    Settled { destination_confirmed_sats: u64 },
    /// Not yet visible after the allotted polls. NOT a failure: the
    /// destination's own reconciliation continues (for CDK, the paid mint
    /// quote is minted by its watcher / next sync) — re-run `settle`.
    Pending { destination_confirmed_sats: u64 },
}

pub struct MigrationEngine<'a> {
    source: &'a dyn WalletBackend,
    dest: &'a dyn WalletBackend,
    limits: MigrationLimits,
}

impl<'a> MigrationEngine<'a> {
    pub fn new(
        source: &'a dyn WalletBackend,
        dest: &'a dyn WalletBackend,
        limits: MigrationLimits,
    ) -> Self {
        Self {
            source,
            dest,
            limits,
        }
    }

    fn src<T>(r: std::result::Result<T, WalletError>) -> Result<T> {
        r.map_err(MigrateError::Source)
    }

    fn dst<T>(r: std::result::Result<T, WalletError>) -> Result<T> {
        r.map_err(MigrateError::Destination)
    }

    /// Plan a migration of an exact amount. No funds move; the returned plan
    /// carries the fee figure for the consent step.
    pub fn plan_amount(&self, amount_sats: u64) -> Result<MigrationPlan> {
        if let Some(max) = self.limits.dest_max_sats {
            if amount_sats > max {
                return Err(MigrateError::AboveDestinationMax {
                    amount_sats,
                    max_sats: max,
                });
            }
        }
        let balance = Self::src(self.source.balance())?;

        let invoice = Self::dst(self.dest.receive(&ReceiveRequest {
            method: ReceiveMethod::Bolt11Invoice,
            amount_sats: Some(amount_sats),
            description: Some("Sonar wallet migration".into()),
        }))?;
        let destination = Self::src(self.source.parse_destination(&invoice))?;
        if !matches!(
            destination.kind,
            DestinationKind::Bolt11 | DestinationKind::Unknown
        ) {
            return Err(MigrateError::UnexpectedInvoiceKind(destination.kind));
        }
        let prepared = Self::src(self.source.prepare_send(&destination, Some(amount_sats)))?;

        // Fee gate, fail-closed: an unknowable fee cannot honour a cap.
        match (self.limits.fee_cap_sats, prepared.fees_sats) {
            (Some(cap), Some(fee)) if fee > cap => {
                return Err(MigrateError::FeeAboveCap {
                    fee_sats: fee,
                    cap_sats: cap,
                })
            }
            (Some(cap), None) => return Err(MigrateError::FeeUnknown { cap_sats: cap }),
            _ => {}
        }
        // Capacity check BEFORE any spend: amount + fee must fit the balance.
        let fee = prepared.fees_sats.unwrap_or(0);
        if amount_sats.saturating_add(fee) > balance.confirmed_sats {
            return Err(MigrateError::ExceedsSourceBalance {
                amount_sats,
                fee_sats: fee,
                balance_sats: balance.confirmed_sats,
            });
        }

        Ok(MigrationPlan {
            amount_sats: prepared.amount_sats,
            source_fee_sats: prepared.fees_sats,
            invoice,
            prepared,
        })
    }

    /// Plan a whole-balance drain: iterate amount = balance − quoted fee until
    /// a feasible plan is found (fees shrink monotonically with amount, so a
    /// few iterations converge). Each infeasible iteration abandons an unpaid
    /// destination invoice, which is harmless — unpaid quotes expire.
    pub fn plan_drain(&self) -> Result<MigrationPlan> {
        // 5 attempts takes the reserve schedule to ~16% of balance, which
        // clears a real Boltz swap fee on a small balance. Each attempt costs
        // one abandoned destination mint quote, so this stays bounded.
        const MAX_ATTEMPTS: u32 = 5;
        let balance = Self::src(self.source.balance())?.confirmed_sats;
        if balance == 0 {
            return Err(MigrateError::SourceTooSmall {
                balance_sats: 0,
                reason: "balance is zero".into(),
            });
        }
        let mut candidate = if let Some(max) = self.limits.dest_max_sats {
            balance.min(max)
        } else {
            balance
        };
        let mut last = String::new();
        for attempt in 0..MAX_ATTEMPTS {
            match self.plan_amount(candidate) {
                Ok(plan) => return Ok(plan),
                Err(MigrateError::ExceedsSourceBalance {
                    fee_sats,
                    balance_sats,
                    ..
                }) => {
                    // Shrink by the quoted fee (plus 1 sat of slack for
                    // fee-of-smaller-amount rounding) and retry.
                    let next = balance_sats
                        .saturating_sub(fee_sats)
                        .saturating_sub(1)
                        .min(candidate.saturating_sub(1));
                    if next == 0 {
                        return Err(MigrateError::SourceTooSmall {
                            balance_sats,
                            reason: format!("fees ({fee_sats} sats) consume the whole balance"),
                        });
                    }
                    last = format!("amount {candidate} + fee {fee_sats} > balance {balance_sats}");
                    candidate = next;
                }
                // Source backends may report capacity as InsufficientFunds at
                // prepare time instead of letting us compare; treat it as the
                // same signal with a conservative step down.
                //
                // A source reached over a host boundary reports the SAME
                // condition as an opaque backend error: the variant does not
                // survive the FFI, so a real Breez wallet refusing a
                // whole-balance drain with "Cannot pay: not enough funds"
                // arrives here as Backend(..). Treating only the typed variant
                // as retryable made drain fail on the first attempt on
                // Android while the identical case retried fine in-process.
                // Both step down; the schedule below is what actually clears a
                // fee, since a 1%-of-balance step never reaches a swap fee on
                // a small balance.
                Err(MigrateError::Source(
                    err @ (WalletError::InsufficientFunds | WalletError::Backend(_)),
                )) => {
                    // Reserve grows per attempt (1% → 2% → 4% …, floor 4 sats)
                    // so a few bounded attempts cross a realistic swap fee
                    // instead of creeping.
                    let reserve = ((balance * (1u64 << attempt)) / 100).max(4);
                    let next = balance.saturating_sub(reserve).min(candidate.saturating_sub(1));
                    if next == 0 {
                        return Err(MigrateError::SourceTooSmall {
                            balance_sats: balance,
                            reason: format!("fees consume the whole balance ({err})"),
                        });
                    }
                    last = format!("source refused {candidate} sats: {err}");
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

    /// Execute a plan: pay the destination invoice from the source. This is
    /// the ONE spending call; everything before it is quotes, everything
    /// after it is reconciliation.
    pub fn execute(&self, plan: &MigrationPlan) -> Result<Payment> {
        Self::src(self.source.send(&plan.prepared, "Sonar wallet migration"))
    }

    /// Read both balances — the resume/status primitive.
    pub fn balances(&self) -> Result<(Balance, Balance)> {
        Ok((
            Self::src(self.source.balance())?,
            Self::dst(self.dest.balance())?,
        ))
    }

    /// Drive destination reconciliation until its confirmed balance reaches
    /// `baseline + expected` or `polls` sync rounds elapse. Safe to call again
    /// any time — including after a crash between `execute` and settlement:
    /// the destination's own persistence finishes the job, this just watches.
    pub fn settle(
        &self,
        baseline_confirmed_sats: u64,
        expected_sats: u64,
        polls: u32,
    ) -> Result<Settlement> {
        let target = baseline_confirmed_sats.saturating_add(expected_sats);
        let mut confirmed = 0;
        for _ in 0..polls.max(1) {
            // Sync errors are tolerated between polls (transient mint
            // hiccups); the balance read is the arbiter.
            if let Err(e) = self.dest.sync_wallet() {
                tracing::warn!("destination sync failed (will re-poll): {e}");
            }
            confirmed = Self::dst(self.dest.balance())?.confirmed_sats;
            if confirmed >= target {
                return Ok(Settlement::Settled {
                    destination_confirmed_sats: confirmed,
                });
            }
        }
        Ok(Settlement::Pending {
            destination_confirmed_sats: confirmed,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sonar_wallet::MockWallet;
    use std::sync::Arc;

    /// A source that refuses to quote more than it can afford, and reports
    /// that refusal as an OPAQUE backend error rather than the typed
    /// `InsufficientFunds`.
    ///
    /// This is not hypothetical: a host-implemented source reaches the engine
    /// through a UniFFI foreign trait whose error is flat, so the variant does
    /// not survive the boundary. A real Breez wallet on Android refusing a
    /// whole-balance drain arrives here as
    /// `Backend("... Cannot pay: not enough funds")`. Before the fix, that
    /// landed in the catch-all arm and `plan_drain` gave up on the first
    /// attempt instead of stepping the amount down.
    struct OpaqueRefusingSource {
        inner: MockWallet,
        /// Refuse any amount whose amount+fee exceeds the balance.
        fee_sats: u64,
    }

    impl WalletBackend for OpaqueRefusingSource {
        fn capabilities(&self) -> sonar_wallet::WalletCapabilities {
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
        fn balance(&self) -> sonar_wallet::Result<sonar_wallet::Balance> {
            self.inner.balance()
        }
        fn receive(&self, request: &sonar_wallet::ReceiveRequest) -> sonar_wallet::Result<String> {
            self.inner.receive(request)
        }
        fn parse_destination(&self, input: &str) -> sonar_wallet::Result<sonar_wallet::Destination> {
            self.inner.parse_destination(input)
        }
        fn prepare_send(
            &self,
            destination: &sonar_wallet::Destination,
            amount_sats: Option<u64>,
        ) -> sonar_wallet::Result<sonar_wallet::PreparedSend> {
            let balance = self.inner.balance()?.confirmed_sats;
            if let Some(amount) = amount_sats {
                if amount.saturating_add(self.fee_sats) > balance {
                    // Exactly what Breez says, flattened to a string on the
                    // way through the FFI.
                    return Err(WalletError::Backend(
                        "host source prepare: Cannot pay: not enough funds".into(),
                    ));
                }
            }
            self.inner.prepare_send(destination, amount_sats)
        }
        fn send(
            &self,
            prepared: &sonar_wallet::PreparedSend,
            note: &str,
        ) -> sonar_wallet::Result<sonar_wallet::Payment> {
            self.inner.send(prepared, note)
        }
        fn list_recent_payments(
            &self,
            limit: u32,
        ) -> sonar_wallet::Result<Vec<sonar_wallet::Payment>> {
            self.inner.list_recent_payments(limit)
        }
        fn add_event_listener(&self, listener: Arc<dyn sonar_wallet::WalletEventListener>) -> u64 {
            self.inner.add_event_listener(listener)
        }
        fn remove_event_listener(&self, id: u64) {
            self.inner.remove_event_listener(id)
        }
        fn wipe_local_storage(&self) -> sonar_wallet::Result<()> {
            self.inner.wipe_local_storage()
        }
    }

    fn engine<'a>(
        source: &'a MockWallet,
        dest: &'a MockWallet,
        limits: MigrationLimits,
    ) -> MigrationEngine<'a> {
        MigrationEngine::new(source, dest, limits)
    }

    fn limits(dest_max: Option<u64>, cap: Option<u64>) -> MigrationLimits {
        MigrationLimits {
            dest_max_sats: dest_max,
            fee_cap_sats: cap,
        }
    }

    fn pair(balance: u64) -> (MockWallet, MockWallet) {
        let source = MockWallet::new(balance);
        source.connect().unwrap();
        let dest = MockWallet::new(0);
        dest.connect().unwrap();
        (source, dest)
    }

    #[test]
    fn plan_quotes_fee_without_spending() {
        let (source, dest) = pair(10_000);
        let e = engine(&source, &dest, limits(None, Some(10)));
        let plan = e.plan_amount(2_500).unwrap();
        assert_eq!(plan.amount_sats, 2_500);
        assert_eq!(plan.source_fee_sats, Some(1));
        assert!(plan.invoice.starts_with("lnbc"));
        // Nothing moved.
        assert_eq!(source.balance().unwrap().confirmed_sats, 10_000);
        assert_eq!(dest.balance().unwrap().confirmed_sats, 0);
    }

    #[test]
    fn fee_cap_aborts_before_any_spend() {
        let (source, dest) = pair(10_000);
        let e = engine(&source, &dest, limits(None, Some(0)));
        assert!(matches!(
            e.plan_amount(2_500),
            Err(MigrateError::FeeAboveCap {
                fee_sats: 1,
                cap_sats: 0
            })
        ));
        assert_eq!(source.balance().unwrap().confirmed_sats, 10_000);
    }

    #[test]
    fn destination_max_is_refused_not_split() {
        let (source, dest) = pair(1_000_000);
        let e = engine(&source, &dest, limits(Some(500_000), None));
        assert!(matches!(
            e.plan_amount(600_000),
            Err(MigrateError::AboveDestinationMax {
                amount_sats: 600_000,
                max_sats: 500_000
            })
        ));
    }

    #[test]
    fn amount_plus_fee_must_fit_the_source_balance() {
        let (source, dest) = pair(1_000);
        let e = engine(&source, &dest, limits(None, None));
        // 1000 + fee 1 > 1000.
        assert!(matches!(
            e.plan_amount(1_000),
            Err(MigrateError::ExceedsSourceBalance {
                amount_sats: 1_000,
                fee_sats: 1,
                balance_sats: 1_000
            })
        ));
    }

    #[test]
    fn drain_converges_to_balance_minus_fee() {
        let (source, dest) = pair(10_000);
        let e = engine(&source, &dest, limits(Some(500_000), None));
        let plan = e.plan_drain().unwrap();
        // Mock fee is a flat 1 sat; the loop steps down by fee + 1 slack.
        assert_eq!(plan.amount_sats, 9_998);
        let payment = e.execute(&plan).unwrap();
        assert!(!payment.incoming);
        assert_eq!(payment.amount_sats, 9_998);
        assert_eq!(source.balance().unwrap().confirmed_sats, 1);
    }

    #[test]
    fn drain_converges_when_the_source_refuses_opaquely() {
        // 813 sats with a 40-sat fee: the real Pixel case. A whole-balance
        // drain is refused, and the refusal carries no recognisable variant.
        let source = OpaqueRefusingSource {
            inner: MockWallet::new(813),
            fee_sats: 40,
        };
        source.connect().unwrap();
        let dest = MockWallet::new(0);
        dest.connect().unwrap();

        let e = MigrationEngine::new(&source, &dest, limits(Some(500_000), None));
        let plan = e
            .plan_drain()
            .expect("drain must step down past an opaque refusal, not give up on attempt one");
        assert!(
            plan.amount_sats > 0 && plan.amount_sats + 40 <= 813,
            "planned {} sats, which the source cannot afford with a 40 sat fee",
            plan.amount_sats
        );
    }

    #[test]
    fn drain_respects_destination_max() {
        let (source, dest) = pair(1_000_000);
        let e = engine(&source, &dest, limits(Some(500_000), None));
        let plan = e.plan_drain().unwrap();
        assert!(plan.amount_sats <= 500_000);
    }

    #[test]
    fn zero_and_dust_balances_refuse_clearly() {
        let (source, dest) = pair(0);
        let e = engine(&source, &dest, limits(None, None));
        assert!(matches!(
            e.plan_drain(),
            Err(MigrateError::SourceTooSmall {
                balance_sats: 0,
                ..
            })
        ));
    }

    #[test]
    fn settle_reports_pending_then_settles_after_reconciliation() {
        let (source, dest) = pair(10_000);
        let e = engine(&source, &dest, limits(None, Some(10)));
        let plan = e.plan_drain().unwrap();
        let baseline = dest.balance().unwrap().confirmed_sats;
        e.execute(&plan).unwrap();

        // Payment sent but the destination has not seen it yet.
        let pending = e.settle(baseline, plan.amount_sats, 2).unwrap();
        assert!(matches!(pending, Settlement::Pending { .. }));

        // The destination's own reconciliation lands the funds (for CDK this
        // is the watcher minting the paid quote); settle observes it — this is
        // also the crash-resume path, driven by a FRESH engine.
        dest.simulate_receive(plan.amount_sats);
        let e2 = engine(&source, &dest, limits(None, Some(10)));
        let settled = e2.settle(baseline, plan.amount_sats, 1).unwrap();
        assert_eq!(
            settled,
            Settlement::Settled {
                destination_confirmed_sats: plan.amount_sats
            }
        );
    }

    #[test]
    fn execute_pays_exactly_the_quoted_plan_once() {
        let (source, dest) = pair(10_000);
        let e = engine(&source, &dest, limits(None, None));
        let plan = e.plan_amount(2_000).unwrap();
        e.execute(&plan).unwrap();
        assert_eq!(source.balance().unwrap().confirmed_sats, 10_000 - 2_000 - 1);
        // The mock re-executes prepared sends, but real backends enforce
        // single-use tokens (#456/#582); the engine contract is one execute
        // per plan and the CLI/hosts hold that line.
    }
}
