//
// SonarHandleAddress.swift
// bitchat
//
// Which wallet the claimed handle (`name@sonarprivacy.xyz`) pays: the offer
// its BIP-353 DNS record at the Sonar registrar carries. The handle is a
// public address that can be printed or shared outside the app, so moving it
// from the legacy Breez wallet to the Cashu wallet (custody at the mint) is
// the user's decision, never a side effect of an app update.
// docs/WALLET-INTEGRATION.md "The handle's payment address". Compose mirror:
// `wallet/HandleAddress.kt`.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Which wallet the handle's BIP-353 record pays.
enum SonarHandleAddressWallet: String, Equatable {
    case legacy
    case cashu
}

/// What the app may do with the handle when the Cashu offer is known.
enum SonarHandleOfferAction: Equatable {
    /// Nothing to register.
    case none
    /// Re-register the handle with the Cashu offer, with no prompt.
    case reclaimWithCashu
    /// The handle pays the old wallet and one exists here: leave it, and show
    /// "still pays your old wallet" with a confirmed move.
    case askToMove
}

/// What the notice next to the address shows.
enum SonarHandleAddressNotice: Equatable {
    case none
    /// "Your address … still pays your old wallet." + Move.
    case paysOldWallet(address: String)
    /// An automatic re-registration failed; it is retried with backoff.
    case updateFailing(address: String)
}

enum SonarHandleOfferPolicy {
    /// The handle decision (Compose: `handleOfferAction`).
    ///
    /// - No claimed handle: nothing.
    /// - Recorded as paying Cashu: re-register when the Cashu offer differs
    ///   from the one last registered (a rotated offer, or a chat-only claim
    ///   made before the wallet had one).
    /// - Otherwise (recorded as paying the old wallet, or not known yet: an
    ///   install that claimed its handle before Cashu):
    ///   - a legacy wallet is present: `.askToMove`. The app never retargets
    ///     it on its own;
    ///   - presence not established yet: nothing, until it is;
    ///   - no legacy wallet: nothing to move away from, so re-register as above.
    static func action(
        claimedHandle: String?,
        legacyPresence: SonarLegacyPresence,
        addressWallet: SonarHandleAddressWallet?,
        cashuOffer: String?,
        lastRegisteredOffer: String?
    ) -> SonarHandleOfferAction {
        guard let claimed = claimedHandle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !claimed.isEmpty
        else { return .none }
        let offerChanged: Bool = {
            guard let cashuOffer, !cashuOffer.isEmpty else { return false }
            return cashuOffer != lastRegisteredOffer
        }()
        if addressWallet == .cashu {
            return offerChanged ? .reclaimWithCashu : .none
        }
        switch legacyPresence {
        case .present: return .askToMove
        case .unknown: return .none
        case .absent: return offerChanged ? .reclaimWithCashu : .none
        }
    }

    /// "Move back to your old wallet" is offered while the handle pays Cashu
    /// and the old wallet is here.
    static func canMoveBack(
        claimedHandle: String?,
        legacyPresence: SonarLegacyPresence,
        addressWallet: SonarHandleAddressWallet?
    ) -> Bool {
        guard let claimed = claimedHandle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !claimed.isEmpty
        else { return false }
        return legacyPresence == .present && addressWallet == .cashu
    }
}

/// The per-account record: which wallet the handle pays, and the offer last
/// registered with it (so a re-claim runs once per offer, not once per
/// launch). Keyed by the account's npub.
struct SonarHandleAddressRecord: Equatable {
    static let walletKeyPrefix = "sonar.handle.addressWallet."
    static let offerKeyPrefix = "sonar.handle.registeredOffer."

    var wallet: SonarHandleAddressWallet?
    var registeredOffer: String?

    static func load(defaults: UserDefaults, account: String) -> SonarHandleAddressRecord {
        let wallet = defaults.string(forKey: walletKeyPrefix + account).flatMap(SonarHandleAddressWallet.init(rawValue:))
        let offer = defaults.string(forKey: offerKeyPrefix + account).flatMap { $0.isEmpty ? nil : $0 }
        return SonarHandleAddressRecord(wallet: wallet, registeredOffer: offer)
    }

    func save(defaults: UserDefaults, account: String) {
        if let wallet {
            defaults.set(wallet.rawValue, forKey: Self.walletKeyPrefix + account)
        } else {
            defaults.removeObject(forKey: Self.walletKeyPrefix + account)
        }
        if let registeredOffer, !registeredOffer.isEmpty {
            defaults.set(registeredOffer, forKey: Self.offerKeyPrefix + account)
        } else {
            defaults.removeObject(forKey: Self.offerKeyPrefix + account)
        }
    }

    /// Panic wipe: every account's record.
    static func removeAll(defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(walletKeyPrefix) || key.hasPrefix(offerKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
