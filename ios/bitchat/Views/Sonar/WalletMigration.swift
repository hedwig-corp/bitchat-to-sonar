#if os(iOS) || os(macOS)

import Foundation
import CryptoKit
import SonarCore
import SwiftUI
@preconcurrency import WalletKit

/// Breez→Cashu migration on Apple.
///
/// The engine is Rust (`sonar-wallet-migrate`, driven through
/// `SonarMigration` in sonarffi). Breez cannot live in that library — its
/// forked SQLite would collide with the SQLCipher core — so this file supplies
/// the SOURCE side: `BreezMigrationSource` implements the FFI foreign trait
/// `HostMigrationSource` over the app's existing `SonarWallet`.
///
/// Threading contract, and it matters: the foreign-trait methods are called
/// synchronously from the Rust thread that invoked `plan`/`execute`, so this
/// type blocks. `SonarMigrationModel` therefore only ever calls the engine
/// from a detached task — never the main actor, or the semaphore below would
/// deadlock against `SonarWallet`'s own continuations.
final class BreezMigrationSource: HostMigrationSource, @unchecked Sendable {
    /// Non-Sendable by WalletKit's own annotations, but every use here goes
    /// through `blocking`, which hands the call to a detached task, and
    /// `SonarWallet` serialises its Breez work on a private queue. Hence
    /// `@unchecked` rather than weakening the wallet's annotations.
    private let wallet: SonarWallet

    init(wallet: SonarWallet) {
        self.wallet = wallet
    }

    /// Bridge one async WalletKit call into the blocking shape UniFFI expects.
    private func blocking<T>(_ body: @escaping () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached {
            do { box.value = .success(try await body()) } catch { box.value = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        switch box.value {
        case .success(let value): return value
        case .failure(let error): throw hostError(error)
        case .none: throw HostWalletError.Failed(reason: "wallet call produced no result")
        }
    }

    private func hostError(_ error: Error) -> HostWalletError {
        if let walletError = error as? SonarWallet.WalletError,
           case .insufficientAfterFee = walletError {
            return .InsufficientFunds
        }
        let message = "\(error)"
        if message.localizedCaseInsensitiveContains("insufficient")
            || message.localizedCaseInsensitiveContains("not enough funds")
            || message.localizedCaseInsensitiveContains("balance too low") {
            return .InsufficientFunds
        }
        return .Failed(reason: message)
    }

    func balanceSats() throws -> UInt64 {
        let sats = try blocking { [wallet] in try await wallet.balanceSnapshot() }
        return UInt64(max(0, sats))
    }

    func prepare(invoice: String, amountSats: UInt64) throws -> HostSendQuote {
        let prepared = try blocking { [wallet] in
            try await wallet.prepareSend(destination: invoice, amountSats: Int64(amountSats))
        }
        return HostSendQuote(
            amountSats: UInt64(max(0, prepared.amountSats)),
            feesSats: prepared.feesSats.map { UInt64(max(0, $0)) },
            token: prepared.id
        )
    }

    func send(token: String, note: String) throws -> HostPayment {
        let payment = try blocking { [wallet] in
            try await wallet.sendPrepared(id: token, note: note)
        }
        return HostPayment(
            id: payment.id,
            amountSats: UInt64(max(0, payment.amountSats)),
            feesSats: payment.feesSats.map { UInt64(max(0, $0)) },
            // WalletKit returns a Payment only once Breez accepted it; the
            // engine treats "not complete" as pending, which is the safe
            // direction for an outgoing payment.
            complete: true
        )
    }

    func lookupPayment(paymentHash: String) throws -> HostPaymentLookup {
        let lookup = try blocking { [wallet] in
            try await wallet.lookupPayment(paymentHash: paymentHash)
        }
        let status: HostPaymentLookupStatus = switch lookup.status {
        case .pending: .pending
        case .complete: .complete
        case .failed: .failed
        case .refundable: .refundable
        case .unknown: .unknown
        }
        return HostPaymentLookup(
            status: status,
            id: lookup.id,
            feesSats: lookup.feesSats.map { UInt64(max(0, $0)) }
        )
    }
}

/// Mutable box so the detached task can hand a value back across the semaphore.
private final class ResultBox<T>: @unchecked Sendable {
    var value: Result<T, Error>?
}

struct SonarWalletMigrationRoute: View {
    @EnvironmentObject private var store: SonarAppStore
    @State private var model: SonarMigrationModel?
    @State private var source: BreezMigrationSource?
    @State private var nsec: String?
    @State private var failure: String?

    private let mintUrl = "https://mint.hedwig.sh"

    var body: some View {
        Group {
            if let model, let source, let nsec {
                SonarWalletMigrationScreen(
                    model: model,
                    mintHost: "mint.hedwig.sh",
                    source: source,
                    nsec: nsec
                )
            } else if let failure {
                Text(failure).padding()
            } else {
                ProgressView().task { await load() }
            }
        }
    }

    @MainActor
    private func load() async {
        guard let bridged = store.wallet as? BridgedWallet,
              let nsec = await store.exportNsec()
        else {
            failure = String(localized: "The Lightning wallet is not available on this device.")
            return
        }
        let digest = SHA256.hash(data: Data(nsec.utf8))
        let accountId = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            failure = String(localized: "Could not locate wallet storage.")
            return
        }
        let directory = support
            .appendingPathComponent("sonar-cashu", isDirectory: true)
            .appendingPathComponent(accountId, isDirectory: true)
            .appendingPathComponent("mainnet", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            failure = String(localized: "Could not locate wallet storage.")
            return
        }
        self.nsec = nsec
        source = BreezMigrationSource(wallet: bridged.walletService.migrationWallet)
        model = SonarMigrationModel(
            mintUrl: mintUrl,
            walletDir: directory.path,
            feeCapSats: 5_000
        )
    }
}

// MARK: - Model

@MainActor
final class SonarMigrationModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case quoting
        /// Quote in hand; the consent screen is showing these numbers.
        case awaitingConsent(amountSats: UInt64, feeSats: UInt64?)
        case paying
        case watching
        case settled(cashuSats: UInt64)
        /// Paid, funds not visible yet. Recoverable — not a failure.
        case pendingSettlement(cashuSats: UInt64)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var breezBalanceSats: UInt64 = 0
    @Published private(set) var cashuBalanceSats: UInt64 = 0

    private let mintUrl: String
    private let walletDir: String
    private var engine: SonarMigration?
    private var cashu: SonarCashuWallet?
    private var planId: String?

    /// The mint's per-quote ceiling and the fail-closed fee cap. A quote above
    /// the cap — or a source that cannot quote a fee at all — refuses to plan.
    private let destMaxSats: UInt64
    private let feeCapSats: UInt64

    init(mintUrl: String, walletDir: String, destMaxSats: UInt64 = 500_000, feeCapSats: UInt64) {
        self.mintUrl = mintUrl
        self.walletDir = walletDir
        self.destMaxSats = destMaxSats
        self.feeCapSats = feeCapSats
    }

    /// Open the Cashu wallet and price a whole-balance drain. Nothing is paid.
    func quote(nsec: String, source: BreezMigrationSource) async {
        phase = .quoting
        let mintUrl = self.mintUrl
        let walletDir = self.walletDir
        let destMax = self.destMaxSats
        let feeCap = self.feeCapSats
        do {
            // Detached: the engine calls back into `source` synchronously, so
            // this must not run on the main actor.
            let (engine, cashu, quote, status) = try await Task.detached {
                () -> (SonarMigration, SonarCashuWallet, MigrationQuote?, MigrationAttemptStatus?) in
                let cashu = try SonarCashuWallet.open(
                    nsec: nsec, mintUrl: mintUrl, workingDir: walletDir
                )
                let engine = SonarMigration(
                    source: source,
                    destination: cashu,
                    destMaxSats: destMax,
                    feeCapSats: feeCap
                )
                let status = try engine.status()
                if let status {
                    switch status.state {
                    case .awaitingConsent, .expiredUnsent:
                        try engine.cancelUnspent()
                    case .sourceFailed:
                        break
                    default:
                        return (engine, cashu, nil, status)
                    }
                }
                return (engine, cashu, try engine.plan(amountSats: nil), nil)
            }.value
            self.engine = engine
            self.cashu = cashu
            if let status {
                apply(status)
                return
            }
            guard let quote else {
                phase = .failed(String(localized: "The migration could not be opened."))
                return
            }
            self.planId = quote.planId
            phase = .awaitingConsent(amountSats: quote.amountSats, feeSats: quote.sourceFeeSats)
        } catch {
            phase = .failed(
                String(
                    format: String(localized: "Could not price the migration: %@"),
                    String(describing: error)
                )
            )
        }
    }

    /// Pay. Only reachable from the consent screen's explicit confirm.
    func confirmAndMigrate() async {
        guard let engine, let planId else {
            phase = .failed(String(localized: "No migration plan; check the amount and fee again."))
            return
        }
        phase = .paying
        do {
            _ = try await Task.detached { try engine.execute(planId: planId) }.value
            self.planId = nil
            phase = .watching
            let outcome = try await Task.detached {
                try engine.resume(polls: 24)
            }.value
            apply(outcome)
        } catch {
            let status = try? await Task.detached { try engine.status() }.value
            if let status, status.state != .awaitingConsent, status.state != .expiredUnsent,
               status.state != .sourceFailed {
                phase = .pendingSettlement(cashuSats: cashuBalanceSats)
            } else {
                phase = .failed(
                    String(
                        format: String(localized: "The payment did not go through: %@"),
                        String(describing: error)
                    )
                )
            }
        }
    }

    /// Resume watching — after a Pending outcome, or after the app was killed
    /// between paying and settlement. The Cashu wallet's own reconciliation is
    /// what completes the migration; this only observes it.
    func resumeSettlement() async {
        guard let engine else { return }
        phase = .watching
        do {
            let outcome = try await Task.detached {
                try engine.resume(polls: 24)
            }.value
            apply(outcome)
        } catch {
            phase = .pendingSettlement(cashuSats: cashuBalanceSats)
        }
    }

    func refreshBalances(source: BreezMigrationSource) async {
        if let cashu {
            cashuBalanceSats =
                (try? await Task.detached { try cashu.balance().confirmedSats }.value) ?? cashuBalanceSats
        }
        breezBalanceSats =
            (try? await Task.detached { try source.balanceSats() }.value) ?? breezBalanceSats
    }

    func cancelUnspentOnLeave() async {
        guard let engine else { return }
        let status = try? await Task.detached { try engine.status() }.value
        guard status?.state == .awaitingConsent || status?.state == .expiredUnsent else { return }
        _ = try? await Task.detached { try engine.cancelUnspent() }.value
        planId = nil
    }

    private func apply(_ outcome: MigrationOutcome) {
        switch outcome {
        case .settled(let cashuConfirmedSats):
            cashuBalanceSats = cashuConfirmedSats
            phase = .settled(cashuSats: cashuConfirmedSats)
        case .pending(let cashuConfirmedSats):
            cashuBalanceSats = cashuConfirmedSats
            phase = .pendingSettlement(cashuSats: cashuConfirmedSats)
        }
    }

    private func apply(_ status: MigrationAttemptStatus) {
        switch status.state {
        case .settled:
            phase = .settled(cashuSats: status.amountSats)
        case .sourceFailed:
            phase = .failed(String(localized: "The Lightning payment failed without moving funds."))
        case .awaitingConsent:
            phase = .awaitingConsent(amountSats: status.amountSats, feeSats: status.feeSats)
        case .expiredUnsent:
            phase = .idle
        default:
            phase = .pendingSettlement(cashuSats: cashuBalanceSats)
        }
    }
}

// MARK: - Screen

/// Consent + progress. The custody change is stated before the confirm button
/// exists, and the fee is on screen at the moment of consent.
struct SonarWalletMigrationScreen: View {
    @ObservedObject var model: SonarMigrationModel
    let mintHost: String
    let source: BreezMigrationSource
    let nsec: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                switch model.phase {
                case .idle:
                    custodyExplainer
                    actionButton(String(localized: "Check amount and fee")) {
                        Task { await model.quote(nsec: nsec, source: source) }
                    }
                case .quoting:
                    progressRow(String(localized: "Pricing the migration…"))
                case .awaitingConsent(let amount, let fee):
                    custodyExplainer
                    quoteSummary(amount: amount, fee: fee)
                    actionButton(
                        String(
                            format: String(localized: "Move %@ sats to %@"),
                            String(amount),
                            mintHost
                        )
                    ) {
                        Task { await model.confirmAndMigrate() }
                    }
                    Text("This pays now. It cannot be undone from then.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .paying:
                    progressRow(String(localized: "Paying from the Lightning wallet…"))
                case .watching:
                    progressRow(String(localized: "Waiting for the mint to issue your ecash…"))
                case .settled(let sats):
                    resultRow(
                        title: String(localized: "Migration complete"),
                        detail: String(
                            format: String(localized: "%@ sats are now in your Cashu wallet."),
                            String(sats)
                        ),
                        systemImage: "checkmark.circle"
                    )
                case .pendingSettlement(let sats):
                    resultRow(
                        title: String(localized: "Paid — waiting on the mint"),
                        detail: String(
                            format: String(
                                localized: "Your payment went out. The mint has not issued the ecash yet; your wallet keeps trying. Current Cashu balance: %@ sats."
                            ),
                            String(sats)
                        ),
                        systemImage: "clock"
                    )
                    actionButton(String(localized: "Check again")) {
                        Task { await model.resumeSettlement() }
                    }
                case .failed(let message):
                    resultRow(
                        title: String(localized: "Migration stopped"),
                        detail: message,
                        systemImage: "exclamationmark.triangle"
                    )
                    actionButton(String(localized: "Try again")) {
                        Task { await model.quote(nsec: nsec, source: source) }
                    }
                }
                balances
            }
            .padding(20)
        }
        .navigationTitle(String(localized: "Move to Cashu"))
        .task { await model.refreshBalances(source: source) }
        .onDisappear {
            Task { await model.cancelUnspentOnLeave() }
        }
    }

    private var header: some View {
        Text("Move your Lightning balance into ecash held on this device.")
            .font(.body)
    }

    /// The custody change, in plain language, BEFORE any confirm affordance.
    private var custodyExplainer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("This changes who holds your money", systemImage: "info.circle")
                .font(.headline)
            Text(
                String(
                    format: String(
                        localized: "Today your balance is self-custodial. After moving, you hold ecash tokens on this device and %@ holds the Lightning side. If that mint disappears, the ecash it issued cannot be redeemed."
                    ),
                    mintHost
                )
            )
            Text("Your tokens are recoverable from your account key on this mint, so a reinstall does not lose them.")
            .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private func quoteSummary(amount: UInt64, fee: UInt64?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            row(
                String(localized: "Arrives in Cashu"),
                String(format: String(localized: "%@ sats"), String(amount))
            )
            row(
                String(localized: "Network fee"),
                fee.map {
                    String(format: String(localized: "%@ sats"), String($0))
                } ?? String(localized: "Fee unknown")
            )
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private var balances: some View {
        VStack(alignment: .leading, spacing: 6) {
            row(
                String(localized: "Lightning wallet"),
                String(format: String(localized: "%@ sats"), String(model.breezBalanceSats))
            )
            row(
                String(localized: "Cashu wallet"),
                String(format: String(localized: "%@ sats"), String(model.cashuBalanceSats))
            )
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).monospacedDigit()
        }
    }

    private func progressRow(_ label: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(label)
        }
    }

    private func resultRow(title: String, detail: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
    }
}

#endif
