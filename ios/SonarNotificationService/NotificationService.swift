//
// NotificationService.swift
// SonarNotificationService
//
// Breez Notification Plugin entry point — wakes the Breez SDK in this extension
// process (even when the Sonar app is backgrounded or force-quit) to answer
// offline BOLT12 invoice requests and swap updates. This is what lets a payer
// pay this device's BOLT12 offer while Sonar isn't running.
//
// The base class `SDKNotificationService` (from BreezSDKLiquid) does the work:
// it parses the push, connects the SDK with the ConnectRequest we return below,
// runs the matching task (e.g. InvoiceRequestTask), and posts a notification.
// On success the invoice-request task is silent — the user-facing notice arrives
// as the Sonar ⚡PAY message on the Transponder channel.
//
// Creds + working dir are shared by SonarWallet via the App Group; keep the keys
// and the working-dir layout in sync with SonarWalletKit/Sources/SonarWallet.swift.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BreezSDKLiquid
import UserNotifications
import os

class NotificationService: SDKNotificationService {

    private let appGroupId = "group.sh.hedwig.sonar"
    private static let log = OSLog(subsystem: "sh.hedwig.sonar", category: "NSE")

    #if DEBUG
    /// DEBUG-only: log entry + forward Breez's internal logs so the offline-receive
    /// path is observable via idevicesyslog (process `SonarNotificationService`).
    /// Never compiled into release — it logs the full push payload, which carries
    /// the BOLT12 offer / invoice-request data.
    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        os_log("NSE: didReceive push, userInfo=%{public}@",
               log: Self.log, type: .info, String(describing: request.content.userInfo))
        setServiceLogger(logger: NSEBreezLogger())
        super.didReceive(request, withContentHandler: contentHandler)
    }
    #endif

    override func getConnectRequest() -> ConnectRequest? {
        guard let defaults = UserDefaults(suiteName: appGroupId),
              let apiKey = defaults.string(forKey: "breez_api_key"),
              let seedHex = defaults.string(forKey: "breez_seed_hex"),
              let seed = Self.bytes(fromHex: seedHex)
        else {
            os_log("NSE: getConnectRequest -> MISSING creds in App Group (api/seed)",
                   log: Self.log, type: .error)
            return nil
        }
        os_log("NSE: getConnectRequest -> creds OK, connecting Breez",
               log: Self.log, type: .info)

        let mainnet = defaults.bool(forKey: "breez_mainnet")
        let network: LiquidNetwork = mainnet ? .mainnet : .testnet

        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
        else {
            return nil
        }
        let workingDir = container
            .appendingPathComponent("breez-sdk", isDirectory: true)
            .appendingPathComponent(mainnet ? "mainnet" : "testnet", isDirectory: true)
        try? FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)

        do {
            var config = try defaultConfig(network: network, breezApiKey: apiKey)
            config.workingDir = workingDir.path
            // Keep the extension's work to just the invoice-request / swap-update
            // handling the push is for; skip the background realtime-sync service.
            config.syncServiceUrl = nil
            return ConnectRequest(config: config, mnemonic: nil, passphrase: nil, seed: seed)
        } catch {
            return nil
        }
    }

    private static func bytes(fromHex s: String) -> [UInt8]? {
        guard s.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let b = UInt8(s[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        return out
    }
}

#if DEBUG
/// DEBUG-only: forwards the Breez SDK's internal logs (connect, invoice-request
/// handling) to os_log so the offline-receive flow is visible during testing.
final class NSEBreezLogger: BreezSDKLiquid.Logger {
    private static let log = OSLog(subsystem: "sh.hedwig.sonar", category: "NSE-Breez")
    func log(l: LogEntry) {
        let lvl = l.level.uppercased()
        let lower = l.line.lowercased()
        let interesting = lvl == "ERROR" || lvl == "WARN"
            || ["invoice", "swap", "connect", "bolt12", "payment", "fetch", "magic"]
                .contains { lower.contains($0) }
        guard interesting else { return }
        os_log("BREEZ[%{public}@] %{public}@", log: Self.log, type: .info, lvl, l.line)
    }
}
#endif
